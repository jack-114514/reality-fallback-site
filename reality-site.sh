#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

readonly CADDY_VERSION=2.11.9
readonly CONFIG_DIR=/etc/reality-site
readonly WEB_ROOT=/var/www/reality-site
readonly BIN_DIR=/usr/local/lib/reality-site
readonly SERVICE=reality-site.service
readonly UNIT_PATH="/etc/systemd/system/$SERVICE"
readonly CADDY="$BIN_DIR/caddy-$CADDY_VERSION"
readonly DEFAULT_PORT=8443

die() { printf '错误：%s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
部署用于自建节点 HTTPS 回落验证的静态网页。

  sudo bash reality-site.sh                      交互填写域名和端口
  sudo bash reality-site.sh node.example.com     使用本机端口 8443
  sudo bash reality-site.sh node.example.com 9443

需要 Linux、systemd、root、curl、iproute2 和常用 GNU 工具。
域名应直接解析到 VPS，公网 TCP 80 用于签发和续期，已有 Xray 可继续使用 TCP 443。
EOF
}

valid_domain() {
  local label
  local -a labels
  local LC_ALL=C
  [[ ${#1} -le 253 && $1 == *.* && $1 != .* && $1 != *. && $1 != *..* ]] || return 1
  [[ ${1##*.} == *[a-z]* ]] || return 1
  IFS=. read -r -a labels <<< "$1"
  for label in "${labels[@]}"; do
    [[ $label =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || return 1
  done
}

valid_port() {
  [[ $1 =~ ^[1-9][0-9]{3,4}$ ]] && (( $1 >= 1024 && $1 <= 65535 ))
}

write_caddyfile() {
  local domain=$1 port=$2
  cat <<EOF
{
    admin off
    auto_https disable_redirects
    default_sni $domain
    cert_issuer acme https://acme-v02.api.letsencrypt.org/directory {
        disable_tlsalpn_challenge
    }
    servers {
        protocols h1 h2
    }
}

http://$domain {
    redir https://$domain{uri} 308
}

https://$domain:$port {
    bind 127.0.0.1
    root * $WEB_ROOT
    header X-Content-Type-Options nosniff
    file_server
}
EOF
}

write_unit() {
  cat <<EOF
[Unit]
Description=Static HTTPS site for self-hosted node
Wants=network-online.target
After=network-online.target

[Service]
Type=notify
ExecStart=$CADDY run --config $CONFIG_DIR/Caddyfile --adapter caddyfile
DynamicUser=yes
StateDirectory=reality-site
Environment=XDG_DATA_HOME=/var/lib/reality-site
Environment=XDG_CONFIG_HOME=/var/lib/reality-site
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=yes
UMask=0077
Restart=on-failure
RestartSec=5s
TimeoutStartSec=30s

[Install]
WantedBy=multi-user.target
EOF
}

write_page() {
  cat <<'HTML'
<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="description" content="此静态网页仅用于自建节点的 HTTPS 回落验证。">
  <title>自建节点 · HTTPS 回落验证</title>
  <style>
    :root {
      color-scheme: light;
      font-family: "Segoe UI", "PingFang SC", "Microsoft YaHei", system-ui, sans-serif;
      color: #182a26;
      background: #edf3ef;
    }
    * { box-sizing: border-box; }
    body { margin: 0; min-height: 100vh; display: grid; align-items: center; padding: 1.5rem; }
    main { width: min(100%, 44rem); margin-inline: auto; padding: clamp(1.5rem, 6vw, 4.25rem); background: #fff; border: 1px solid #b6c9bf; border-top: .35rem solid #16634f; }
    p { margin: 0; color: #3d564e; line-height: 1.8; }
    .service { color: #16634f; font-weight: 650; }
    h1 { margin: .65rem 0 1rem; font-size: clamp(2rem, 6vw, 3.4rem); line-height: 1.15; letter-spacing: -.035em; }
    .details { margin-top: 2rem; padding-top: 1.25rem; border-top: 1px solid #d4e0da; }
    h2 { margin: 0 0 .35rem; font-size: 1.1rem; }
  </style>
</head>
<body>
  <main>
    <header>
      <p class="service">自建节点</p>
      <h1>HTTPS 回落验证</h1>
      <p>此静态网页仅用于自建节点的 HTTPS 回落验证。</p>
    </header>
    <section class="details" aria-labelledby="check-title">
      <h2 id="check-title">如何核验</h2>
      <p>请确认浏览器地址为配置的域名，并且证书有效。代理连接请通过节点客户端另行测试。</p>
    </section>
  </main>
</body>
</html>
HTML
}

same_or_missing() {
  [[ ! -e $2 ]] || cmp -s "$1" "$2" || die "$2 已有不同内容，请先检查现有配置。"
}

write_new_file() {
  local source=$1 destination=$2 mode=$3 temp_file
  [[ ! -e $destination ]] || return 0
  temp_file=$(mktemp "${destination}.tmp.XXXXXXXX")
  install -m "$mode" -- "$source" "$temp_file"
  mv -nT -- "$temp_file" "$destination"
  rm -f -- "$temp_file"
}

check_unused_port() {
  local listeners
  listeners=$(ss -H -ltnp "sport = :$1") || die "无法查询 TCP $1。"
  if [[ -n $listeners ]]; then
    printf '%s\n' "$listeners" >&2
    die "TCP $1 已在监听。请先检查占用进程。"
  fi
}

fetch_caddy() {
  local stage=$1 arch=$2 digest=$3
  local archive="caddy_${CADDY_VERSION}_linux_${arch}.tar.gz"
  printf '正在下载并验证 Caddy %s（%s）…\n' "$CADDY_VERSION" "$arch"
  curl --fail --silent --show-error --location --retry 2 \
    --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 120 \
    "https://github.com/caddyserver/caddy/releases/download/v$CADDY_VERSION/$archive" \
    --output "$stage/$archive"
  printf '%s  %s\n' "$digest" "$stage/$archive" | sha256sum --check --status || die 'Caddy 下载包 SHA-256 校验失败。'
  tar -xzf "$stage/$archive" -C "$stage" caddy
  chmod 755 "$stage/caddy"
}

verify_site() {
  local domain=$1 port=$2 deadline=$((SECONDS + 100)) response
  printf '等待本机 HTTPS 及证书验证…\n'
  while (( SECONDS < deadline )); do
    if response=$(curl --noproxy '*' --silent --fail --connect-timeout 2 --max-time 3 \
      --tlsv1.3 --connect-to "$domain:443:127.0.0.1:$port" \
      --output /dev/null --write-out '%{http_code}' "https://$domain/") && [[ $response == 200 ]]; then
      printf '本机 HTTPS 验证成功，证书可信且网页返回 HTTP 200。\n'
      printf '\n3X-UI 入站参数\n  SNI       %s\n  Target    127.0.0.1:%s\n  Xver      0\n' "$domain" "$port"
      printf '公网验证    https://%s/\n网页路径    %s/index.html\n' "$domain" "$WEB_ROOT"
      printf '公网 443 由现有 Xray 入站监听。保存参数后，从另一台设备验证网页并测试客户端。\n'
      return 0
    fi
    sleep 3
  done
  printf '服务已启动，但本机 HTTPS 验证未通过。请检查 A/AAAA、TCP 80 和以下日志。\n' >&2
  printf '  sudo journalctl -u %s -n 60 --no-pager\n' "$SERVICE" >&2
  return 2
}

main() {
  if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage; return; fi
  (( $# <= 2 )) || die '参数过多。运行 bash reality-site.sh --help 查看用法。'
  [[ $(uname -s) == Linux && -d /run/systemd/system ]] || die '请在运行 systemd 的 Linux VPS 上执行。'
  (( EUID == 0 )) || die '请以 root 执行，或在命令前加 sudo。'

  local command arch digest domain port saved_domain='' saved_port='' path candidate
  for command in curl ss sha256sum tar systemctl flock getent install cmp; do
    command -v "$command" >/dev/null || die "缺少 $command，请通过系统软件源安装。"
  done
  case $(uname -m) in
    x86_64) arch=amd64; digest=5b8cb7faf8726a2028ad96a66e54e6e81e8f361bc6175e5d22bbd997cc5177fb ;;
    aarch64) arch=arm64; digest=5e377cff994fc9362a6fcf695c53f226cfca3a3ef85bd3a3687cf252d6310165 ;;
    *) die '仅支持 x86_64 和 aarch64。' ;;
  esac

  exec 9>/run/reality-site-install.lock
  flock -n 9 || die '另一个部署进程正在运行。'
  for path in "$CONFIG_DIR" "$BIN_DIR" "$WEB_ROOT" "$UNIT_PATH" \
    "$CONFIG_DIR/deployment" "$CONFIG_DIR/Caddyfile" "$CADDY" "$WEB_ROOT/index.html"; do
    [[ ! -L $path ]] || die "请先检查符号链接 $path。"
  done
  if [[ -f $CONFIG_DIR/deployment ]]; then
    read -r saved_domain saved_port < "$CONFIG_DIR/deployment" || die '无法读取已有部署。'
    valid_domain "$saved_domain" && valid_port "$saved_port" || die '已有部署记录无效。'
  elif [[ -e $CONFIG_DIR/Caddyfile || -e $UNIT_PATH || -e $BIN_DIR || -e $WEB_ROOT ]]; then
    die '检测到现有站点或服务文件。请先检查这些路径的归属。'
  fi

  domain=${1:-$saved_domain}
  port=${2:-${saved_port:-$DEFAULT_PORT}}
  if (( $# == 0 )) && [[ -z $domain ]]; then
    read -r -p '自有域名（例如 node.example.com）: ' domain || die '缺少域名。'
    read -r -p "本机 HTTPS 端口 [$DEFAULT_PORT]: " port || die '缺少端口输入。'
    port=${port:-$DEFAULT_PORT}
  fi
  domain=${domain,,}
  valid_domain "$domain" || die '请输入有效域名，国际化域名使用 Punycode。'
  valid_port "$port" || die '本机端口必须为 1024–65535 的数字。'
  if [[ -n $saved_domain && ( $domain != "$saved_domain" || $port != "$saved_port" ) ]]; then
    die "已有部署使用 $saved_domain 和端口 $saved_port。请按原参数重试。"
  fi
  getent ahosts "$domain" >/dev/null || die "无法解析 $domain，请先配置 DNS。"

  STAGE=$(mktemp -d /run/reality-site.XXXXXXXX)
  trap 'rm -rf -- "$STAGE"' EXIT
  write_caddyfile "$domain" "$port" > "$STAGE/Caddyfile"
  write_unit > "$STAGE/$SERVICE"
  same_or_missing "$STAGE/Caddyfile" "$CONFIG_DIR/Caddyfile"
  same_or_missing "$STAGE/$SERVICE" "$UNIT_PATH"

  if ! systemctl is-active --quiet "$SERVICE"; then
    check_unused_port 80
    check_unused_port "$port"
  fi
  candidate=$CADDY
  if [[ ! -x $CADDY ]]; then
    [[ ! -e $CADDY ]] || die "$CADDY 存在但无法执行。"
    fetch_caddy "$STAGE" "$arch" "$digest"
    candidate=$STAGE/caddy
  fi
  XDG_DATA_HOME="$STAGE" XDG_CONFIG_HOME="$STAGE" \
    "$candidate" validate --config "$STAGE/Caddyfile" --adapter caddyfile

  printf '部署 %s，站点 HTTPS 监听 127.0.0.1:%s。\n' "$domain" "$port"
  install -d -m 755 -- "$CONFIG_DIR"
  printf '%s %s\n' "$domain" "$port" > "$STAGE/deployment"
  write_new_file "$STAGE/deployment" "$CONFIG_DIR/deployment" 644
  for path in "$BIN_DIR" "$WEB_ROOT"; do
    [[ -d $path ]] || install -d -m 755 -- "$path"
  done
  write_new_file "$candidate" "$CADDY" 755
  write_page > "$STAGE/index.html"
  write_new_file "$STAGE/index.html" "$WEB_ROOT/index.html" 644
  write_new_file "$STAGE/Caddyfile" "$CONFIG_DIR/Caddyfile" 644
  write_new_file "$STAGE/$SERVICE" "$UNIT_PATH" 644

  systemctl daemon-reload
  systemctl enable --now "$SERVICE"
  verify_site "$domain" "$port"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi

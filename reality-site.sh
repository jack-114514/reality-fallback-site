#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

readonly VERSION=1.1
readonly CADDY_VERSION=2.11.9
readonly CONFIG_DIR=/etc/reality-site
readonly WEB_ROOT=/var/www/reality-site
readonly BIN_DIR=/usr/local/lib/reality-site
readonly SERVICE=reality-site.service
readonly UNIT_PATH="/etc/systemd/system/$SERVICE"
readonly STATE_DIR=/var/lib/reality-site
readonly PRIVATE_STATE_DIR=/var/lib/private/reality-site
readonly CADDY="$BIN_DIR/caddy-$CADDY_VERSION"
readonly DEFAULT_PORT=8443
readonly PAGE_URL=https://raw.githubusercontent.com/jack-114514/reality-fallback-site/refs/heads/main/index.html

die() { printf '错误：%s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
部署静态个人网站。

  sudo bash reality-site.sh                      交互填写域名和端口
  sudo bash reality-site.sh node.example.com     使用本机端口 8443
  sudo bash reality-site.sh node.example.com 9443
  sudo bash reality-site.sh --refresh-page        从 GitHub 更新已部署的首页
  sudo bash reality-site.sh --uninstall           停止服务并删除本项目安装的内容
  bash reality-site.sh --version                  显示安装脚本版本

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

start_stage() {
  # Keep the archive and extracted binary off systemd's /run tmpfs.
  STAGE=$(mktemp -d /var/tmp/reality-site.XXXXXXXX) || die '无法在 /var/tmp 创建安装临时目录。'
  trap 'rm -rf -- "$STAGE"' EXIT
}

download_page() {
  local destination=$1 first_line
  curl --fail --silent --show-error --location --retry 2 \
    --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 30 \
    "$PAGE_URL" --output "$destination" || die '下载 GitHub 首页失败。请检查网络后重试。'
  IFS= read -r first_line < "$destination" || die '下载的首页为空。'
  [[ ${first_line,,} == '<!doctype html>' ]] || die 'GitHub 首页的第一行应为 <!doctype html>。'
}

refresh_page() {
  local page="$WEB_ROOT/index.html" backup temp_file
  [[ -f $CONFIG_DIR/deployment && ! -L $CONFIG_DIR && ! -L $CONFIG_DIR/deployment ]] || die '请先完成站点部署。'
  [[ -d $WEB_ROOT && ! -L $WEB_ROOT && ! -L $page ]] || die '请先检查网站目录及首页路径。'
  [[ ! -e $page || -f $page ]] || die '现有首页路径不是普通文件。'

  start_stage
  download_page "$STAGE/index.html"
  if [[ -f $page ]] && cmp -s "$STAGE/index.html" "$page"; then
    printf '首页已和 GitHub 上的版本一致。\n'
    return 0
  fi
  if [[ -f $page ]]; then
    backup=$(mktemp "$CONFIG_DIR/index.html.backup.XXXXXXXX")
    install -m 600 -- "$page" "$backup"
    printf '旧首页已备份到 %s\n' "$backup"
  fi
  temp_file=$(mktemp "$WEB_ROOT/.index.html.XXXXXXXX")
  install -m 644 -- "$STAGE/index.html" "$temp_file"
  mv -fT -- "$temp_file" "$page"
  printf '首页已更新，刷新浏览器即可查看。\n'
}

remove_project_downloads() {
  local file
  for file in "$PWD/reality-site.sh" /root/reality-site.sh; do
    if [[ -f $file && ! -L $file ]] &&
      grep -Fxq -- "readonly SERVICE=$SERVICE" "$file" &&
      grep -Fxq -- 'readonly WEB_ROOT=/var/www/reality-site' "$file"; then
      rm -f -- "$file"
      printf '已删除安装脚本 %s\n' "$file"
    fi
  done
}

uninstall_site() {
  local marker="$CONFIG_DIR/deployment" domain port path link mounts mount
  local -a paths=("$CONFIG_DIR" "$WEB_ROOT" "$BIN_DIR" "$UNIT_PATH" "$STATE_DIR" "$PRIVATE_STATE_DIR")

  if [[ ! -f $marker ]]; then
    for path in "${paths[@]}"; do
      [[ ! -e $path && ! -L $path ]] || die "缺少安装记录 $marker，无法确认 $path 属于本项目。"
    done
    remove_project_downloads
    printf '当前没有本项目的已安装站点。\n'
    return 0
  fi
  [[ ! -L $marker ]] || die "安装记录 $marker 是符号链接。"
  read -r domain port < "$marker" || die "无法读取 $marker。"
  valid_domain "$domain" && valid_port "$port" || die "安装记录 $marker 无效。"

  for path in "$CONFIG_DIR" "$WEB_ROOT" "$BIN_DIR" "$UNIT_PATH" "$PRIVATE_STATE_DIR"; do
    [[ ! -L $path ]] || die "请先检查符号链接 $path。"
  done
  if [[ -L $STATE_DIR ]]; then
    link=$(readlink -- "$STATE_DIR")
    [[ $link == "$PRIVATE_STATE_DIR" || $link == private/reality-site ]] || die "证书目录链接 $STATE_DIR 指向未知路径。"
  fi

  mounts=$(findmnt --raw --noheadings --output TARGET) || die '读不到挂载信息，无法安全清理目录。'
  while IFS= read -r mount; do
    for path in "${paths[@]}"; do
      if [[ $mount == "$path" || $mount == "$path/"* ]]; then
        die "发现挂载点 $mount，请先处理该挂载。"
      fi
    done
  done <<< "$mounts"

  if [[ -e $UNIT_PATH ]]; then
    grep -Fxq -- 'Description=Static HTTPS site for self-hosted node' "$UNIT_PATH" &&
      grep -Fq -- " --config $CONFIG_DIR/Caddyfile --adapter caddyfile" "$UNIT_PATH" ||
      die "服务文件 $UNIT_PATH 与本项目不符。"
    systemctl disable --now "$SERVICE"
    rm -f -- "$UNIT_PATH"
    systemctl daemon-reload
  elif systemctl is-active --quiet "$SERVICE"; then
    die "发现运行中的 $SERVICE，但找不到本项目的服务文件。"
  fi

  rm -rf --one-file-system -- "$WEB_ROOT" "$BIN_DIR" "$STATE_DIR" "$PRIVATE_STATE_DIR"
  rm -rf --one-file-system -- "$CONFIG_DIR"
  remove_project_downloads
  printf '已卸载 %s 的本项目站点和服务，并删除安装文件、证书及网页备份。\n' "$domain"
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

print_panel_guide() {
  local domain=$1 port=$2
  cat <<EOF

在 3X-UI 填写 VLESS + TCP/RAW + REALITY
  已有使用 443 的 VLESS + REALITY 入站时，编辑该入站。首次配置时先确认 443 可用。

  [基础配置] 端口                 443
  [协议]     协议                 VLESS
  [传输]     传输协议             TCP（有些版本显示为 RAW）

  [安全]     安全                 Reality
             显示                 关闭
             Xver                 0
             uTLS                 chrome
             目标 / Target / Dest 127.0.0.1:$port
             SNI                  $domain（删掉旧域名）
             最大时间差 (ms)      0
             最小 / 最大客户端版本 新建时留空
             Short IDs            已有值可沿用；新建时点右侧刷新按钮生成
             SpiderX              用面板默认值；新建时也可填 /
             公钥 / 私钥          新建时点「获取新证书」生成 REALITY 密钥对
             mldsa65 Seed / Verify 新建时留空
             主密钥日志           留空
             限制 Fallback        新建时用默认设置

  [客户端]   Flow                 xtls-rprx-vision

保存前可点「扫描」。目标是本机地址，显示「已通过内网/本地网络检测」属正常。
核对扫描的 SNI 和证书域名都是 $domain，再保存并重新导出客户端链接。
外部设备打开 https://$domain/ 检查网页，再用客户端测试代理。
网页路径 $WEB_ROOT/index.html
逐项填写说明 https://github.com/jack-114514/reality-fallback-site#3x-ui
EOF
}

verify_site() {
  local domain=$1 port=$2 deadline=$((SECONDS + 100)) response
  printf '等待本机 HTTPS 及证书验证…\n'
  while (( SECONDS < deadline )); do
    if response=$(curl --noproxy '*' --silent --fail --connect-timeout 2 --max-time 3 \
      --tlsv1.3 --connect-to "$domain:443:127.0.0.1:$port" \
      --output /dev/null --write-out '%{http_code}' "https://$domain/") && [[ $response == 200 ]]; then
      printf '本机 HTTPS 验证成功，证书可信且网页返回 HTTP 200。\n'
      print_panel_guide "$domain" "$port"
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
  if [[ ${1:-} == --version ]]; then printf '%s\n' "$VERSION"; return; fi
  (( $# <= 2 )) || die '参数过多。运行 bash reality-site.sh --help 查看用法。'
  [[ $(uname -s) == Linux && -d /run/systemd/system ]] || die '请在运行 systemd 的 Linux VPS 上执行。'
  (( EUID == 0 )) || die '请以 root 执行，或在命令前加 sudo。'

  command -v flock >/dev/null || die '缺少 flock，请通过系统软件源安装 util-linux。'
  exec 9>/run/reality-site-install.lock
  flock -n 9 || die '另一个部署进程正在运行。'
  if [[ ${1:-} == --uninstall ]]; then
    (( $# == 1 )) || die '--uninstall 无需其他参数。'
    uninstall_site
    return
  fi

  local command arch digest domain port saved_domain='' saved_port='' path candidate
  for command in curl ss sha256sum tar systemctl getent install cmp; do
    command -v "$command" >/dev/null || die "缺少 $command，请通过系统软件源安装。"
  done

  if [[ ${1:-} == --refresh-page ]]; then
    (( $# == 1 )) || die '--refresh-page 无需其他参数。'
    refresh_page
    return
  fi

  case $(uname -m) in
    x86_64) arch=amd64; digest=5b8cb7faf8726a2028ad96a66e54e6e81e8f361bc6175e5d22bbd997cc5177fb ;;
    aarch64) arch=arm64; digest=5e377cff994fc9362a6fcf695c53f226cfca3a3ef85bd3a3687cf252d6310165 ;;
    *) die '仅支持 x86_64 和 aarch64。' ;;
  esac

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

  start_stage
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
  if [[ ! -e $WEB_ROOT/index.html ]]; then
    download_page "$STAGE/index.html"
  fi

  printf '部署 %s，站点 HTTPS 监听 127.0.0.1:%s。\n' "$domain" "$port"
  install -d -m 755 -- "$CONFIG_DIR"
  printf '%s %s\n' "$domain" "$port" > "$STAGE/deployment"
  write_new_file "$STAGE/deployment" "$CONFIG_DIR/deployment" 644
  for path in "$BIN_DIR" "$WEB_ROOT"; do
    [[ -d $path ]] || install -d -m 755 -- "$path"
  done
  write_new_file "$candidate" "$CADDY" 755
  # The temporary filesystem may be mounted noexec.
  XDG_DATA_HOME="$STAGE" XDG_CONFIG_HOME="$STAGE" \
    "$CADDY" validate --config "$STAGE/Caddyfile" --adapter caddyfile || \
    die "Caddy 无法从安装路径运行或配置不通过。请检查 $CADDY 的执行权限及上方日志。"
  if [[ -f $STAGE/index.html ]]; then
    write_new_file "$STAGE/index.html" "$WEB_ROOT/index.html" 644
  fi
  write_new_file "$STAGE/Caddyfile" "$CONFIG_DIR/Caddyfile" 644
  write_new_file "$STAGE/$SERVICE" "$UNIT_PATH" 644

  rm -rf -- "$STAGE"
  trap - EXIT
  systemctl daemon-reload || die 'systemd 未能重载。若上方提示 /run 空间不足，请运行 df -h /run 查看剩余空间，处理后按原参数重试。'
  systemctl enable --now "$SERVICE"
  verify_site "$domain" "$port"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi

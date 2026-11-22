#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPOSITORY=jack-114514/reality-fallback-site
readonly RELEASE_TAG_URL="https://github.com/$REPOSITORY/releases/tag/"
readonly RAW_URL="https://raw.githubusercontent.com/$REPOSITORY"

fail() { printf '错误：%s\n' "$*" >&2; exit 1; }

github_curl() {
  curl --fail --silent --show-error --location --max-redirs 5 \
    --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 45 "$@"
}

main() {
  (( $# <= 1 )) || fail '请只指定一个版本标签，或使用 --uninstall。'
  local tag=${1:-latest} release_info release_url script first_line
  local -a args=()
  if [[ $tag == --help || $tag == -h ]]; then
    printf '%s\n' '用法：bash install.sh [latest | v1.0 | --refresh-page | --uninstall]'
    return 0
  fi
  if [[ $tag == --uninstall || $tag == --refresh-page ]]; then
    args=("$tag")
    tag=latest
  fi

  if [[ $tag == latest ]]; then
    tag=''
    if release_info=$(github_curl -H 'Accept: application/vnd.github+json' \
      "https://api.github.com/repos/$REPOSITORY/releases/latest" 2>/dev/null); then
      tag=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' <<< "$release_info")
    fi
    if [[ -z $tag ]]; then
      release_url=$(github_curl --head --output /dev/null --write-out '%{url_effective}' \
        "https://github.com/$REPOSITORY/releases/latest") || fail '暂时无法获取 GitHub 最新正式版本。'
      [[ $release_url == "$RELEASE_TAG_URL"* ]] || fail 'GitHub 未返回有效的 Release 地址。'
      tag=${release_url#"$RELEASE_TAG_URL"}
    fi
  fi
  [[ $tag =~ ^v[0-9]+(\.[0-9]+){1,2}(-[a-zA-Z0-9]+([.-][a-zA-Z0-9]+)*)?$ ]] || \
    fail '版本标签格式不正确，请使用 v1.0 或 v1.1 等标签。'

  INSTALL_TMP=$(mktemp -d /var/tmp/reality-site-launcher.XXXXXXXX) || fail '无法创建临时下载目录。'
  trap 'rm -rf -- "$INSTALL_TMP"' EXIT
  script="$INSTALL_TMP/reality-site.sh"
  printf '正在下载发行版本 %s。\n' "$tag"
  github_curl --output "$script" "$RAW_URL/refs/tags/$tag/reality-site.sh" || \
    fail "下载 $tag 失败，请确认标签存在并检查网络。"
  IFS= read -r first_line < "$script" || fail "发行版本 $tag 的脚本为空。"
  [[ $first_line == '#!/usr/bin/env bash' ]] && bash -n "$script" || \
    fail "发行版本 $tag 的安装脚本校验失败。"
  if (( EUID == 0 )); then
    bash "$script" "${args[@]}"
  else
    sudo bash "$script" "${args[@]}"
  fi
}

main "$@"

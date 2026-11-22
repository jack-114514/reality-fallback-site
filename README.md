# 静态个人站点部署

首页是一份可直接阅读和编辑的静态个人博客。在 VPS 上用于 REALITY 回落时，浏览器打开博客可验证 HTTPS 连接，代理连接需要在节点客户端中单独验证。

首页可在 [GitHub Pages](https://jack-114514.github.io/reality-fallback-site/) 直接打开。`reality-site.sh` 会把同一个 `index.html` 部署到你的 VPS，每台 VPS 填写自己的域名和本机端口。脚本从 Caddy 官方发行页下载对应架构的软件包，按固定 SHA-256 校验，并启动独立的 `reality-site.service`。证书由 Caddy 向 Let's Encrypt 申请和自动续期。

## VPS 准备

- 使用运行 systemd 的 Linux VPS，架构为 x86_64 或 aarch64。需要 root 或 sudo，以及 `curl`、`iproute2`（`ss`）、`util-linux`（`flock`）和常见 GNU 工具。
- 为每台 VPS 准备直接解析到该服务器的自有域名或子域名。关闭 CDN 代理。发布 `AAAA` 记录时，请确认对应公网 IPv6 能实际访问该 VPS。
- 将公网 TCP `80` 放行到此 VPS，并确保 `80` 空闲，供 HTTP-01 签发、续期和 HTTP 跳转使用。安全组和系统防火墙都需允许该端口。
- 公网 TCP `443` 由现有 Xray 入站监听。默认网站端口为本机 `127.0.0.1:8443`，可在首次安装时改为其他空闲高端口。Xray 和网站需要共享网络命名空间才能使用这个回环地址。

## 从 GitHub 下载和安装

在 VPS 上执行以下命令。也可以打开仓库里的 `reality-site.sh`，点击 **Raw** 复制同一个地址。

```bash
curl -fL 'https://raw.githubusercontent.com/jack-114514/reality-fallback-site/refs/heads/main/reality-site.sh' -o reality-site.sh &&
  sudo bash reality-site.sh
```

以 root 登录时直接运行 `bash reality-site.sh`。如需给多台 VPS 明确指定域名和端口，可将最后一行改为以下形式。

```bash
sudo bash reality-site.sh node.example.com 8443
```

如需多台 VPS 部署完全相同的脚本版本，可把 Raw URL 里的 `refs/heads/main` 换成提交 SHA。脚本打印「本机 HTTPS 验证成功」后，会按 3X-UI 的标签列出填写项，并带上这台 VPS 的实际域名和本机端口。

## 3X-UI

以下以 `node.example.com` 和本机端口 `8443` 为例。填写时使用你自己终端显示的域名和端口。已有使用 `443` 的 VLESS + REALITY 入站时，从入站列表编辑该入站。第一次配置时，请先确认公网 TCP `443` 空闲。

### 基础配置、协议和传输

| 标签或字段 | 怎么填 |
| --- | --- |
| 基础配置 → 端口 | `443`，这是浏览器和节点客户端连接的公网端口。 |
| 协议 | `VLESS`。 |
| 传输 → 传输协议 | `TCP`，有些版本显示为 `RAW`。 |

### 安全

| 面板字段 | 怎么填 |
| --- | --- |
| 安全 | `Reality`。 |
| 显示 | 关闭。此项用于调试输出。 |
| Xver | `0`。本脚本部署的 Caddy 接收普通 TLS 连接。 |
| uTLS | `chrome`。 |
| 目标 / Target / Dest | 复制终端给出的完整本机地址，例如 `127.0.0.1:8443`。末尾的端口是 Caddy 的本机 HTTPS 端口。 |
| SNI | 复制终端给出的域名，例如 `node.example.com`。只填域名，省略协议、端口和路径，并移除旧域名。 |
| 最大时间差 (ms) | 新建时填 `0`。 |
| 最小客户端版本、最大客户端版本 | 新建时留空，沿用当前核心的默认行为。 |
| Short IDs | 已有值可沿用。新建或空白时点右侧刷新按钮生成。手动设置客户端时选面板列表中的一项。 |
| SpiderX | 可以沿用面板默认值。新建时也可填 `/`。 |
| 公钥、私钥 | 新建或空白时点「获取新证书」，面板会生成 REALITY 密钥对。私钥只存服务端，客户端配置使用配对的公钥。网站的 HTTPS 证书由 Caddy 申请。 |
| mldsa65 Seed、mldsa65 Verify | 新建时可留空。这是一组可选的签名验证参数。 |
| 主密钥日志 | 留空。 |
| 限制 Fallback | 新建时用面板默认设置。 |

修改既有节点时，原有客户端的 UUID、REALITY 密钥和 Short IDs 可沿用。更换密钥或 Short IDs 后需要重新导出链接并更新客户端。若 Xray 位于独立 Docker 网络，`127.0.0.1` 指向容器自身，先确认 Xray 能连接到你部署的 HTTPS 站点。 [3X-UI REALITY 说明](https://github.com/MHSanaei/3x-ui/blob/main/docs/content/docs/en/config/reality.mdx) · [Xray REALITY 字段说明](https://xtls.github.io/config/transports/reality.html)

### 扫描、保存和验证

1. 在「目标」旁点「扫描」。目标是 `127.0.0.1` 时，「可用」和「已通过内网/本地网络检测」可以同时出现。核对「使用的 SNI」及「证书」都对应你的域名，并确认 TLS `1.3`、ALPN `h2`。如果面板版本限制扫描本机地址，可以从 VPS 终端运行下方命令验证 Caddy。
2. 在入站的 VLESS 客户端条目中确认 Flow 为 `xtls-rprx-vision`，保存并重新导出节点链接。在客户端中，连接地址用自有域名，端口为 `443`，SNI 和面板一致。通过面板生成的分享链接会同时提供 UUID、公钥和 Short ID。
3. 从 VPS 外直接打开 `https://你的域名/`，确认浏览器能看到验证页且证书有效。最后在代理客户端测试连接。本机扫描、浏览器访问和代理客户端连接是三项独立检查。

在 VPS 上直接验证 Caddy 的示例。把域名和 `8443` 换成自己的值，正常应返回 `HTTP 200`。

```bash
curl -fsS --connect-to node.example.com:443:127.0.0.1:8443 \
  -o /dev/null -w 'HTTP %{http_code}\n' https://node.example.com/
```

## 编辑和更新首页

在 GitHub 打开 [index.html](index.html)，点击铅笔图标（Edit this file）。文件里用中文注释标记了站名、标题、简介和正文的位置。保留第一行 `<!doctype html>`，修改文字后点 **Commit changes** 提交到 `main`。GitHub Pages 会自动发布新版。

要让已安装的 VPS 使用新版首页，在 VPS 上重新下载脚本并运行更新命令。更新前，旧首页会备份到 `/etc/reality-site/`，备份的完整路径会显示在终端。

```bash
curl -fL 'https://raw.githubusercontent.com/jack-114514/reality-fallback-site/refs/heads/main/reality-site.sh' -o reality-site.sh &&
  sudo bash reality-site.sh --refresh-page
```

也可以在单台 VPS 上直接编辑 `/var/www/reality-site/index.html`。保存后刷新浏览器即可查看。按原参数重跑安装命令会保留已存在的首页。

## 一键卸载

在 VPS 上复制执行这一段。以 root 登录时，把 `sudo bash` 改为 `bash`。

```bash
(
  installer=$(mktemp) || exit 1
  trap 'rm -f -- "$installer"' EXIT
  curl -fL 'https://raw.githubusercontent.com/jack-114514/reality-fallback-site/refs/heads/main/reality-site.sh' -o "$installer" &&
    sudo bash "$installer" --uninstall
)
```

卸载会停止并移除 `reality-site.service`，删除项目的 Caddy 程序、站点配置、首页、网页备份和本地证书数据。当前目录或 `/root` 下识别为本项目的 `reality-site.sh` 也会清理。重要的自定义文章请先备份。在其他路径手动下载或改名的文件需要按实际位置清理。

卸载后，原来指向本站点的 REALITY Target 将失去 HTTPS 目标。其他服务、Xray 与 3X-UI 配置、DNS 和防火墙规则保留。

## 排查

- 旧版如果在 `/run/reality-site.*/caddy` 报 `Permission denied`，请用上面的 Raw 链接重新下载，再运行常规安装命令。新版在 `/run` 解包，从安装目录执行 Caddy。
- 查看服务日志时，执行 `sudo journalctl -u reality-site.service -n 60 --no-pager`。
- 本机验证超时通常需要检查 DNS、TCP `80` 和日志里的证书签发错误。修复后以原域名、原端口重跑脚本即可。Caddy 也会继续尝试签发。
- 如果本机 HTTPS 验证成功、外部站点却打不开，检查 TCP `443`、Xray 入站及 Target。若网页正常、客户端连接失败，核对客户端的 SNI、公钥、Short ID 和 Flow。
- 脚本使用独立的配置和服务。遇到已有网站目录、不同内容的配置或端口冲突时会停下来，并显示需要检查的位置。

[Caddy 证书自动化](https://caddyserver.com/docs/automatic-https) · [Xray REALITY 配置](https://xtls.github.io/config/transports/reality.html)

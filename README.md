# 静态个人站点部署

安装后得到一个可以浏览和编辑的静态个人站点。在 VPS 上用于 REALITY 回落时，浏览器打开这个站点可验证 HTTPS 连接，代理连接需要在节点客户端中单独验证。

首次安装会独立抽取站点类型，并为整站随机组合内容和样式。所有类型共用 6 套基础色系、7 组标题字体和 5 组正文字体。标题字重、字号、背景与文字色调、卡片间距、导航和按钮对齐方式也会随站点变化。页面生成后会在重跑安装时保留。[查看个人博客示例](https://jack-114514.github.io/reality-fallback-site/)

- **个人博客**提供三种首页版式，从 30 篇随笔中抽 3–5 篇。
- **第一个网站**从 5 份 Python 学习计划中抽 1 份。
- **小白的第一次尝试**从 5 篇初次建站经验中抽 1 篇。
- **个人工具箱**从 10 个工具中抽 4–6 个，包括 PDF 提取文字、7-Zip 官方安装包、下载 TXT、时间戳转换、URL 编码、文字计数、两种单位换算、JSON 整理和转大写。PDF 提取在浏览器中处理文件，使用时需要加载 PDF.js，适用于带文字层的 PDF。
- **官网导航工具箱**从 100 个官网中抽 30 个。同一页内的链接各不相同。入库网址在 2026 年 11 月 22 日分别从可用的大陆节点实测返回 HTTP 200，具体访问结果会随地区、运营商和时间变化。[Globalping 节点与测量方法](https://globalping.io/docs/api.globalping.io)
- **测试服务器**展示站点所在文件系统的总容量，以及浏览器向当前页面发出一次 HTTPS 请求的实际耗时。

每台 VPS 填写自己的域名和本机端口。脚本从 Caddy 官方发行页下载对应架构的软件包，按固定 SHA-256 校验，并启动独立的 `reality-site.service`。证书由 Caddy 向 Let's Encrypt 申请和自动续期。

## VPS 准备

- 使用运行 systemd 的 Linux VPS，架构为 x86_64 或 aarch64。需要 root 或 sudo，以及 `curl`、`iproute2`（`ss`）、`util-linux`（`flock`）和常见 GNU 工具。
- 为每台 VPS 准备直接解析到该服务器的自有域名或子域名。关闭 CDN 代理。发布 `AAAA` 记录时，请确认对应公网 IPv6 能实际访问该 VPS。
- 将公网 TCP `80` 放行到此 VPS，并确保 `80` 空闲，供 HTTP-01 签发、续期和 HTTP 跳转使用。安全组和系统防火墙都需允许该端口。
- 公网 TCP `443` 由现有 Xray 入站监听。默认网站端口为本机 `127.0.0.1:8443`，可在首次安装时改为其他空闲高端口。Xray 和网站需要共享网络命名空间才能使用这个回环地址。

## 安装或更新

### 安装最新版

在 VPS 的 Bash 终端运行。命令使用固定的下载入口，每次执行都会选用 GitHub 标为 Latest 的正式 Release。首次安装时按提示填写域名和端口，已有部署会读取安装记录。[查看最新发行版](https://github.com/jack-114514/reality-fallback-site/releases/latest)

```bash
launcher=$(curl -fsSL 'https://raw.githubusercontent.com/jack-114514/reality-fallback-site/refs/tags/v1.2/install.sh') &&
  bash -c "$launcher" --
```

### 安装指定版本

把命令末尾的 `v1.0` 换成所需标签，例如 `v1.1`。[查看可用标签](https://github.com/jack-114514/reality-fallback-site/tags)

```bash
launcher=$(curl -fsSL 'https://raw.githubusercontent.com/jack-114514/reality-fallback-site/refs/tags/v1.2/install.sh') &&
  bash -c "$launcher" -- v1.0
```

## 一键卸载

卸载会停止并移除 `reality-site.service`，删除本项目的 Caddy 程序、站点配置、首页、网页备份和本地证书数据。自写文章请先另存。原来指向本站点的 REALITY Target 将失去 HTTPS 目标。

```bash
launcher=$(curl -fsSL 'https://raw.githubusercontent.com/jack-114514/reality-fallback-site/refs/tags/v1.2/install.sh') &&
  bash -c "$launcher" -- --uninstall
```

当前目录或 `/root` 下识别为本项目的 `reality-site.sh` 也会清理。手动改名或放在其他目录的副本需要按实际位置清理。

## 一键重新生成网站

在已部署的 VPS 上运行。每次都会重新抽取站点类型、内容和样式，生成一份新首页。旧首页先备份到 `/etc/reality-site/`，备份路径会显示在终端。

```bash
launcher=$(curl -fsSL 'https://raw.githubusercontent.com/jack-114514/reality-fallback-site/refs/tags/v1.2/install.sh') &&
  bash -c "$launcher" -- --new-site
```

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

安装生成的页面保存在 `/var/www/reality-site/index.html`。可以在单台 VPS 上直接编辑，保存后刷新浏览器即可。网页内容在部署时生成，访客每次打开会看到同一个站点。

已有 VPS 可以使用[一键重新生成网站](#一键重新生成网站)换一套内容和样式。

GitHub 上的 [index.html](index.html) 用于公开示例，也可以作为自定义共享首页。点击铅笔图标修改，保留第一行 `<!doctype html>`。提交到 `main` 后，GitHub Pages 会发布新版。

要让已安装的 VPS 使用新版首页，在 VPS 上重新下载脚本并运行更新命令。更新前，旧首页会备份到 `/etc/reality-site/`，备份的完整路径会显示在终端。

```bash
launcher=$(curl -fsSL 'https://raw.githubusercontent.com/jack-114514/reality-fallback-site/refs/tags/v1.2/install.sh') &&
  bash -c "$launcher" -- --refresh-page
```

按原参数重跑安装命令会保留已存在的首页。

## 排查

- 旧版如果在 `/run/reality-site.*/caddy` 报 `Permission denied`，或 `systemctl daemon-reload` 提示 `/run/systemd` 空间不足，请用上面的 Raw 链接重新下载，再按原域名和端口运行安装命令。新版在 `/var/tmp` 解包，从安装目录执行 Caddy，并在 systemd 重载前清理临时文件。
- 若新版重载时仍报告空间不足，用 `df -h /run` 查看剩余空间，再用 `du -xhd1 /run | sort -h` 检查占用。
- 查看服务日志时，执行 `sudo journalctl -u reality-site.service -n 60 --no-pager`。
- 本机验证超时通常需要检查 DNS、TCP `80` 和日志里的证书签发错误。修复后以原域名、原端口重跑脚本即可。Caddy 也会继续尝试签发。
- 如果本机 HTTPS 验证成功、外部站点却打不开，检查 TCP `443`、Xray 入站及 Target。若网页正常、客户端连接失败，核对客户端的 SNI、公钥、Short ID 和 Flow。
- 脚本使用独立的配置和服务。遇到已有网站目录、不同内容的配置或端口冲突时会停下来，并显示需要检查的位置。

[Caddy 证书自动化](https://caddyserver.com/docs/automatic-https) · [Xray REALITY 配置](https://xtls.github.io/config/transports/reality.html)

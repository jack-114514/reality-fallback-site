# 自建节点 HTTPS 回落验证页

**此静态网页仅用于自建节点的 HTTPS 回落验证。** 在浏览器看到页面并验证证书，可以确认普通 HTTPS 请求到达站点。代理连接需要在节点客户端中单独验证。

`reality-site.sh` 是单文件安装脚本，内置中文首页。每台 VPS 运行时填写它自己的域名和本机端口。脚本从 Caddy 官方发行页下载对应架构的软件包，按固定 SHA-256 校验，并启动独立的 `reality-site.service`。证书由 Caddy 向 Let's Encrypt 申请和自动续期。

## VPS 准备

- 使用运行 systemd 的 Linux VPS，架构为 x86_64 或 aarch64。需要 root 或 sudo，以及 `curl`、`iproute2`（`ss`）、`util-linux`（`flock`）和常见 GNU 工具。
- 为每台 VPS 准备直接解析到该服务器的自有域名或子域名。关闭 CDN 代理。发布 `AAAA` 记录时，请确认对应公网 IPv6 能实际访问该 VPS。
- 将公网 TCP `80` 放行到此 VPS，并确保 `80` 空闲，供 HTTP-01 签发、续期和 HTTP 跳转使用。安全组和系统防火墙都需允许该端口。
- 公网 TCP `443` 由现有 Xray 入站监听。默认网站端口为本机 `127.0.0.1:8443`，可在首次安装时改为其他空闲高端口。Xray 和网站需要共享网络命名空间才能使用这个回环地址。

## 从 GitHub 下载和安装

在 VPS 上执行以下命令。也可以打开仓库里的 `reality-site.sh`，点击 **Raw** 复制同一个地址。

```bash
curl -fL 'https://raw.githubusercontent.com/jack-114514/reality-fallback-site/main/reality-site.sh' -o reality-site.sh &&
  sudo bash reality-site.sh
```

以 root 登录时直接运行 `bash reality-site.sh`。如需给多台 VPS 明确指定域名和端口，可将最后一行改为以下形式。

```bash
sudo bash reality-site.sh node.example.com 8443
```

如需多台 VPS 部署完全相同的脚本版本，可把 Raw URL 里的分支名换成提交 SHA。脚本打印「本机 HTTPS 验证成功」后，会显示实际的 SNI、Target 和 Xver。

## 将站点接到现有 REALITY 入站

| 3X-UI 字段 | 填写 |
| --- | --- |
| 入站端口 | 公网 `443` |
| SNI | 站点域名，省略 `https://` 和端口 |
| Target / Dest | 脚本输出的本机地址，默认 `127.0.0.1:8443` |
| Xver | `0` |

保存并同步客户端的 SNI 后，从 VPS 外访问 `https://你的域名/`，确认能看到验证页且证书有效。再通过节点客户端测试代理。若 Xray 跑在独立 Docker 网络中，需使用从该容器能访问的 HTTPS 目标地址。

## 更新页面与排查

- 首页文件位于 `/var/www/reality-site/index.html`。可编辑或替换，重新运行安装脚本会保留它。
- 查看服务日志时，执行 `sudo journalctl -u reality-site.service -n 60 --no-pager`。
- 本机验证超时通常需要检查 DNS、TCP `80` 和日志里的证书签发错误。修复后以原域名、原端口重跑脚本即可。Caddy 也会继续尝试签发。
- 如果本机 HTTPS 验证成功、外部站点却打不开，检查 TCP `443`、Xray 入站及 Target。若网页正常、客户端连接失败，核对客户端的 SNI、公钥、Short ID 和 Flow。
- 脚本使用独立的配置和服务。遇到已有网站目录、不同内容的配置或端口冲突时会停下来，并显示需要检查的位置。

[Caddy 证书自动化](https://caddyserver.com/docs/automatic-https) · [Xray REALITY 配置](https://xtls.github.io/config/transports/reality.html)

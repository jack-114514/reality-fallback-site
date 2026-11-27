#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

readonly VERSION=1.3.1
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
  sudo bash reality-site.sh --new-site            生成新的站点并备份原首页
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

blog_article() {
  local order=$1 record=$2 category title first second
  IFS='|' read -r category title first second <<< "$record"
  cat <<EOF
<article id="entry-$order" aria-labelledby="title-$order">
  <p class="category">$category</p>
  <h2 id="title-$order">$title</h2>
  <p>$first</p>
  <p>$second</p>
</article>
EOF
}

readonly -a SITE_PALETTES=(
  '#f7f8f2|#20362d|#4d6157|#984b37|#e8efe4|#becdc3'
  '#fcf5f0|#382c31|#69515b|#923b57|#f4e5e8|#d5bec7'
  '#eef4f8|#1d3445|#4a6173|#245b82|#dfeaf2|#b9cad8'
  '#f7f1e5|#382d24|#654f3d|#8a4b20|#eee2d0|#d4c1a9'
  '#f2f1fa|#30294a|#57516d|#584099|#e6e2f4|#c8bfdd'
  '#1b2928|#f0f3eb|#c4d2c9|#afd29f|#263734|#4f665b'
)
readonly -a SITE_HEADINGS=(
  '"Songti SC",SimSun,Georgia,serif'
  'system-ui,"PingFang SC","Microsoft YaHei",sans-serif'
  '"Kaiti SC",KaiTi,"STKaiti",Georgia,serif'
  '"Noto Serif CJK SC","Source Han Serif SC",Cambria,serif'
  '"FangSong","STFangsong",Georgia,serif'
  '"Source Han Sans SC","Microsoft YaHei UI",Arial,sans-serif'
  '"Noto Sans Mono CJK SC","Microsoft YaHei",Consolas,monospace'
)
readonly -a SITE_BODY_FONTS=(
  'system-ui,"Microsoft YaHei",sans-serif'
  '"Noto Serif CJK SC","Songti SC",SimSun,serif'
  '"PingFang SC","Noto Sans CJK SC",Arial,sans-serif'
  '"Microsoft YaHei UI","Noto Sans SC",Tahoma,sans-serif'
  '"Kaiti SC",KaiTi,"STKaiti",Georgia,serif'
)

readonly -a SITE_OFFICIAL_LINKS=(
  '苹果|https://www.apple.com.cn/|消费电子'
  '微软|https://www.microsoft.com/zh-cn/|软件与服务'
  '英特尔|https://www.intel.cn/content/www/cn/zh/homepage.html|半导体'
  '百度|https://www.baidu.com/|搜索与技术'
  '索尼|https://www.sony.com.cn/|消费电子'
  '三星|https://www.samsung.com.cn/|消费电子'
  '联想|https://www.lenovo.com.cn/|电脑与设备'
  '戴尔|https://www.dell.com/zh-cn|电脑与设备'
  '惠普|https://www.hp.com/cn-zh/home.html|电脑与设备'
  '华硕|https://www.asus.com.cn/|电脑与设备'
  '宏碁|https://www.acer.com.cn/|电脑与设备'
  '技嘉|https://www.gigabyte.cn/|电脑与设备'
  '罗技|https://www.logitech.com/zh-cn|电脑外设'
  '佳能|https://www.canon.com.cn/|影像与办公'
  '理光|https://www.ricoh.com.cn/|影像与办公'
  '兄弟|https://www.brother.cn/|打印与办公'
  '飞利浦|https://www.philips.com.cn/|消费电子'
  '松下|https://panasonic.cn/|消费电子'
  '夏普|https://www.sharp.cn/|消费电子'
  '英伟达|https://www.nvidia.cn/|半导体'
  '高通|https://www.qualcomm.cn/|半导体'
  'Arm|https://www.arm.com/zh-cn|芯片架构'
  '德州仪器|https://www.ti.com.cn/|半导体'
  '恩智浦|https://www.nxp.com.cn/|半导体'
  '亚德诺|https://www.analog.com/cn/index.html|半导体'
  '美光|https://www.micron.cn/|内存与存储'
  '希捷|https://www.seagate.com/cn/zh/|存储设备'
  '西部数据|https://www.westerndigital.com/zh-cn|存储设备'
  '东芝|https://www.toshiba.com.cn/|电子与工业'
  '日立|https://www.hitachi.com.cn/|工业技术'
  '欧姆龙|https://www.omron.com.cn/|自动化与健康'
  '基恩士|https://www.keyence.com.cn/|工业自动化'
  '安川电机|https://www.yaskawa.com.cn/|工业自动化'
  '施耐德电气|https://www.se.com/cn/zh/|能源与自动化'
  'ABB|https://new.abb.com/cn|工业电气'
  '博世|https://www.bosch.com.cn/|工业与消费技术'
  '霍尼韦尔|https://www.honeywell.com.cn/|工业技术'
  '奥的斯|https://www.otis.com/zh/cn|电梯与楼宇'
  '小松|https://www.komatsu.com.cn/|工程设备'
  '约翰迪尔|https://www.deere.com.cn/zh/index.html|农业设备'
  '康明斯|https://www.cummins.com.cn/|动力技术'
  'IBM|https://www.ibm.com/cn-zh|企业技术'
  '甲骨文|https://www.oracle.com/cn/|企业软件'
  'Adobe|https://www.adobe.com/cn/|创意软件'
  '欧特克|https://www.autodesk.com.cn/|设计软件'
  '美国国家仪器|https://www.ni.com/zh-cn.html|测试测量'
  '亚马逊云科技|https://www.amazonaws.cn/|云计算'
  '华为|https://www.huawei.com/cn/|通信与技术'
  '小米|https://www.mi.com/|消费电子'
  '荣耀|https://www.honor.com/cn/|消费电子'
  'OPPO|https://www.oppo.com/cn/|消费电子'
  'vivo|https://www.vivo.com.cn/|消费电子'
  '大疆|https://www.dji.com/cn|影像设备'
  'TP-Link|https://www.tp-link.com.cn/|网络设备'
  '海尔|https://www.haier.com/|家电'
  '海信|https://www.hisense.com/|家电'
  '丰田|https://www.toyota.com.cn/|汽车'
  '本田|https://www.honda.com.cn/|汽车'
  '日产|https://www.nissan.com.cn/|汽车'
  '梅赛德斯-奔驰|https://www.mercedes-benz.com.cn/|汽车'
  '大众汽车|https://www.vw.com.cn/|汽车'
  '保时捷|https://www.porsche.cn/china/zh/|汽车'
  '特斯拉|https://www.tesla.cn/|汽车'
  '福特|https://www.ford.com.cn/|汽车'
  '斯巴鲁|https://www.subaru-china.cn/|汽车'
  '凯迪拉克|https://www.cadillac.com.cn/|汽车'
  '比亚迪|https://www.byd.com/cn|汽车'
  '米其林|https://www.michelin.com.cn/|轮胎与出行'
  '普利司通|https://www.bridgestone.com.cn/|轮胎与出行'
  '固特异|https://www.goodyear.com.cn/|轮胎与出行'
  '壳牌|https://www.shell.com.cn/|能源'
  '巴斯夫|https://www.basf.com/cn/zh|化工与材料'
  '陶氏|https://cn.dow.com/zh-cn|化工与材料'
  '汉高|https://www.henkel.cn/|材料与消费品'
  '圣戈班|https://www.saint-gobain.com.cn/|建筑材料'
  '罗氏|https://www.roche.com.cn/|生命科学'
  '赛默飞|https://www.thermofisher.cn/cn/zh/home.html|实验室设备'
  '赛多利斯|https://www.sartorius.com.cn/|实验室设备'
  '宜家|https://www.ikea.cn/cn/zh/|家居'
  '无印良品|https://www.muji.com.cn/|生活用品'
  '优衣库|https://www.uniqlo.cn/|服装'
  '耐克|https://www.nike.com.cn/|运动用品'
  '阿迪达斯|https://www.adidas.com.cn/|运动用品'
  '亚瑟士|https://www.asics.com.cn/|运动用品'
  '新百伦|https://www.newbalance.com.cn/|运动用品'
  '宝洁|https://www.pg.com.cn/|消费品'
  '达能|https://www.danone.com.cn/|食品与饮料'
  '可口可乐|https://www.coca-cola.com/cn/zh|食品与饮料'
  '百事|https://www.pepsico.com.cn/|食品与饮料'
  '星巴克|https://www.starbucks.com.cn/|餐饮'
  '麦当劳|https://www.mcdonalds.com.cn/|餐饮'
  '资生堂|https://www.shiseido.com.cn/|消费品'
  '强生|https://www.jnj.com.cn/|健康与消费品'
  '联邦快递|https://www.fedex.com/zh-cn/home.html|国际物流'
  'UPS|https://www.ups.com/cn/zh/home|国际物流'
  'DHL|https://www.dhl.com/cn-zh/home.html|国际物流'
  '波音|https://www.boeing.cn/|航空制造'
  '汇丰中国|https://www.hsbc.com.cn/|金融服务'
  '渣打中国|https://www.sc.com/cn/|金融服务'
  'Visa|https://www.visa.cn/|支付服务'
)

shade_color() {
  local hex=$1 endpoint=$2 amount=$3
  printf '#%02x%02x%02x' \
    "$(((16#${hex:1:2} * (100 - amount) + endpoint * amount + 50) / 100))" \
    "$(((16#${hex:3:2} * (100 - amount) + endpoint * amount + 50) / 100))" \
    "$(((16#${hex:5:2} * (100 - amount) + endpoint * amount + 50) / 100))"
}

site_theme() {
  local digest=$1 paper ink muted accent surface rule heading body background_toward ink_toward
  local palette measure hero_space radius gap text_size title_size section_size weight nav_gap action start end intro_align
  local -a controls=(start center end)
  palette=$((16#${digest:2:2} % ${#SITE_PALETTES[@]}))
  IFS='|' read -r paper ink muted accent surface rule <<< "${SITE_PALETTES[palette]}"
  # Darken text on light backgrounds, and lighten it on the dark palette.
  if (( 16#${paper:1:2} < 128 )); then background_toward=0; ink_toward=255; else background_toward=255; ink_toward=0; fi
  paper=$(shade_color "$paper" "$background_toward" "$((16#${digest:28:2} % 26))")
  surface=$(shade_color "$surface" "$background_toward" "$((16#${digest:30:2} % 31))")
  ink=$(shade_color "$ink" "$ink_toward" "$((16#${digest:32:2} % 27))")
  muted=$(shade_color "$muted" "$ink_toward" "$((16#${digest:34:2} % 21))")
  accent=$(shade_color "$accent" "$ink_toward" "$((16#${digest:36:2} % 21))")
  heading=${SITE_HEADINGS[16#${digest:4:2} % ${#SITE_HEADINGS[@]}]}
  body=${SITE_BODY_FONTS[16#${digest:26:2} % ${#SITE_BODY_FONTS[@]}]}
  measure=$((57 + 16#${digest:18:2} % 18))
  hero_space=$((45 + 16#${digest:20:2} % 38))
  radius=$((16#${digest:22:2} % 19))
  gap=$((12 + 16#${digest:24:2} % 15))
  text_size=$((16 + 16#${digest:38:2} % 4))
  title_size=$((58 + 16#${digest:40:2} % 31))
  section_size=$((24 + 16#${digest:42:2} % 9))
  weight=$((500 + 100 * (16#${digest:44:2} % 4)))
  nav_gap=$((14 + 16#${digest:48:2} % 15))
  action=${controls[16#${digest:50:2} % ${#controls[@]}]}
  intro_align=${controls[16#${digest:44:2} % ${#controls[@]}]}
  case "$action" in
    start) start=0; end=auto;;
    center) start=auto; end=auto;;
    end) start=auto; end=0;;
  esac
  cat <<EOF
:root {
  --paper:$paper; --ink:$ink; --muted:$muted; --accent:$accent; --surface:$surface; --rule:$rule;
  --heading:$heading; --body:$body; --text-size:${text_size}px; --title-max:${title_size}px; --section-max:${section_size}px; --heading-weight:$weight;
  --measure:${measure}rem; --hero:${hero_space}px; --radius:${radius}px; --gap:${gap}px;
  --nav-gap:${nav_gap}px; --intro-align:$intro_align; --action-align:$action; --action-start:$start; --action-end:$end;
}
EOF
}

site_navigation_style() {
  cat <<'CSS'
.site-frame { width:min(var(--measure), calc(100% - 2.25rem)); margin-inline:auto; }
.site-frame .wrap { width:100%; }
.site-content { min-width:0; }
.site-nav,.site-return { padding-block:.9rem; }
.site-nav { display:flex; align-items:center; flex-wrap:wrap; gap:.35rem var(--nav-gap); }
.site-nav a,.site-return a { display:inline-block; padding:.3rem 0; overflow-wrap:anywhere; }
.site-name { font:700 1.15rem/1.35 var(--heading); overflow-wrap:anywhere; }
.nav-top > .site-nav { border-bottom:1px solid var(--rule); }
.nav-bottom > .site-nav,.site-return { margin-top:var(--gap); border-top:1px solid var(--rule); }
.nav-align-start > .site-nav { justify-content:flex-start; text-align:start; }
.nav-align-center > .site-nav { justify-content:center; text-align:center; }
.nav-align-end > .site-nav { justify-content:flex-end; text-align:end; }
.site-return { text-align:var(--action-align); }
@media (min-width:58rem) {
  .nav-left,.nav-right { display:grid; align-items:start; gap:clamp(1.25rem, 4vw, 3.25rem); }
  .nav-left { grid-template-columns:minmax(8rem, 12rem) minmax(0, 1fr); }
  .nav-right { grid-template-columns:minmax(0, 1fr) minmax(8rem, 12rem); }
  .nav-left > .site-nav,.nav-right > .site-nav {
    position:sticky; top:1rem; display:grid; justify-content:stretch; margin-top:var(--gap); padding:.9rem;
    border:1px solid var(--rule); border-radius:var(--radius); background:var(--surface);
  }
  .nav-right > .site-nav { grid-column:2; grid-row:1; }
  .nav-right > .site-content { grid-column:1; grid-row:1; }
  .nav-top.nav-keep > .site-nav { position:sticky; top:0; background:var(--paper); z-index:1; }
  .nav-top.nav-keep .site-content [id] { scroll-margin-top:6rem; }
}
@media (max-width:57.999rem) {
  .nav-left > .site-nav,.nav-right > .site-nav { border-bottom:1px solid var(--rule); }
  .nav-left > .site-nav > .site-name,.nav-right > .site-nav > .site-name { flex:0 1 100%; }
}
CSS
}

site_navigation() {
  local digest=$1 name=$2 items=$3 phase=$4
  local -a regions=(top left right bottom) labels=('返回顶部' '回到页首' '回到开头' '回到首页顶部' '回到最上方') alignments=(start center end)
  local region=${regions[16#${digest:54:2} % ${#regions[@]}]}
  local label=${labels[16#${digest:58:2} % ${#labels[@]}]}
  local alignment=${alignments[16#${digest:46:2} % ${#alignments[@]}]}
  local top_link="<a href=\"#top\">$label</a>" footer='' nav
  if [[ $region == top ]] && (( 16#${digest:56:2} % 2 == 0 )); then
    footer=$top_link
    top_link=''
  fi
  nav="<nav class=\"site-nav\" aria-label=\"站内导航\"><span class=\"site-name\">$name</span>$items$top_link</nav>"
  if [[ $phase == open ]]; then
    local sticky=''
    if [[ $region == top && -n $top_link ]]; then sticky=' nav-keep'; fi
    printf '<div class="site-frame nav-%s nav-align-%s%s">\n' "$region" "$alignment" "$sticky"
    if [[ $region != bottom ]]; then printf '%s\n' "$nav"; fi
    printf '<div class="site-content">\n'
  else
    printf '</div>\n'
    if [[ $region == bottom ]]; then printf '%s\n' "$nav"; fi
    if [[ -n $footer ]]; then printf '<footer class="site-return">%s</footer>\n' "$footer"; fi
    printf '</div>\n'
  fi
}

render_blog() {
  local digest choice record name intro about layout theme
  local -a identities=(
    '留白笔记|读到的几句话，路过的几条街。|喜欢把一件小事多看一会儿，偶尔记下它的起因和后来。'
    '窗边摘录|窗台、书页和周末的短文。|这里是几本随身笔记的续页，有观察，也有随手记下的问题。'
    '沿街手记|从家门口出发，记一点街巷和日常。|篇幅不长，题材也不固定。出门走一段，回来坐下来写。'
    '未寄的明信片|写给路上遇见的光和声音。|这里收着没有收件地址的短文。每一篇都可以从任何时候读起。'
    '慢整理|读书、做饭，顺手把零散的想法写下来。|笔记的主题随日子变化，留下来的大多是以后还想再做一次的事。'
    '小页集|给琐碎日常留一页纸。|写作从一个具体的东西开始，有时是一张旧票根，有时是没有喝完的茶。'
  )
  local -a layouts=(journal archive feature)
  local -a articles=(
    '阅读|用一张纸接住一句话|读到喜欢的段落，把书合上，再试着写出最想留下的那句。写出来的措辞常常和原文不同，却能看出自己在意哪一部分。|隔一周翻回那张纸，先看当时的问题，再读原来那页。重读就有了一个入口。'
    '散步|换过街的一边走走|熟悉的街换一边走，招牌就在不一样的高度。原以为一直关着的旧店，侧边那扇窄窗其实每天都开。|回家路上挑一件能描述清楚的小事记下，慢慢就会有一本属于这几条街的笔记。'
    '厨房|番茄汤等到哪一步|把番茄切小一点，和少量油在锅里煸软。等锅底出现一层红汁，再加热水，汤的味道就容易浓起来。|豆腐最后放，盛碗前才调盐。汤滚着的时候，正好把刀和砧板洗掉。'
    '摄影|阴天的边缘光|阴天很适合拍一扇窗。窗外的亮度刚好能把室内的边缘描出来，玻璃上的反光也比较容易取舍。|试着往旁边挪一步，等画面里的两个亮处不再重叠，再按快门。'
    '居家|给桌面留下一个空角|桌上的东西有很多可以留着，只需把靠手边的一角空出来。进门时能把钥匙放下，想翻书时也有地方摊开。|收拾的标准很简单，第二天还能直接用。偶尔用不到的线和本子，可以先放回抽屉。'
    '城市|早点铺门口的几分钟|天刚亮时，热气会先从蒸笼边缘冒出来。客人报完想吃的东西，老板边找钱边把下一笼提上来。|这种小铺子往往只有门口几步热闹。站到街对面，声音已经和公交车的刹车声混在一起。'
    '阅读|给借来的书夹一张便签|读借来的书时，想做批注就另夹一张纸。写下页码和自己想到的例子，读完后把纸收走。|以后还书时，书页回到原样，真正留下的是那几条可以再写下去的线索。'
    '散步|下一站再下车|有空时从下一站开始往回走。一站路不够远，走错一条小巷也还能在晚饭前到家。|地图建议走直线，我更愿意沿着有树荫的一侧慢慢回来。'
    '厨房|把剩饭蒸软|冷藏米饭在盘里拨开，撒一点水，盖起来蒸几分钟。饭粒重新变软就可以拌菜，先尝一口再决定是否加调味料。|一个盘子比重新开火炒一锅轻松，吃完也少洗一个锅。'
    '摄影|把画面边角看一遍|取景时很容易只看画面中间。拍之前绕着边缘看一圈，常会发现一个被截掉的字，或者一小截过亮的墙。|很多时候只需要降一点机位，就可以让原来的主体和边缘都有位置。'
    '手作|修一把松动的木椅|先在平地上轻轻晃一下，找到松动的一条腿。看看是连接件松了，还是椅脚垫磨薄了。|适合紧固的地方拧紧之后再试。等弄清楚问题在哪里，垫纸片就可以先省下来。'
    '日常|旧票根放到哪里|抽屉里常有不知道哪一天留下的票根。能想起来的，在背后写一行同行的人和当时走过的路。|具体写不出来的，挑几张留下就好。剩下的纸让出位置，下一次出门回来还可以再放一张。'
    '阅读|重读时改一个问题|隔一阵子，再读一遍曾经划过线的文章，看看当时的问题现在还有没有用。被觉得新鲜的句子可能很快懂，被跳过的一段却值得多停一下。|把新的问题写在原来那个下面。两次读书之间经历了什么，有时从这两个问题就能看出来。'
    '城市|雨后去桥上看一眼|雨停后桥面还湿着，两边的灯在水面上留下长线。走到离护栏一臂远的地方，能听见车轮擦过浅水。|天气转晴之前适合在桥上站一会儿。河对岸的窗户，一盏一盏地亮起来。'
    '手作|用一根线收好散页|零散的几页纸对齐，先找一张稍厚的封面折出书脊。打两个小孔，用粗一点的线穿过去。|只装最近还想翻看的几页，别的留在原处。薄薄的一册反倒容易常拿在手边。'
    '居家|日光移到窗台哪一格|上午的光先照到最里面那盆。把两盆植物对调后观察几天，叶子朝哪边伸比日历更直观。|不用一天挪好几次，等光线和叶子都安静下来，再决定这个位置。'
    '城市|最后一班有轨电车|晚一点坐车，车厢里没有上下班时的人声。车沿着街道慢慢转弯，能看清每一条并行的小路。|下车时记住掉头的地方，改天沿轨道旁的人行道走过去看看。'
    '厨房|练习把葱切得一样细|葱洗好后先沥干，分成两段叠在一起，再从靠手的一端往前切。厚薄整齐更容易估计最后放多少。|剩下一半切大段冻好，周末炒饭时用，不必再洗一整把。'
    '阅读|把一首诗抄在纸背|报纸边上的诗只读了一遍，留下的却是末尾那个动作。试着抄下来，抄到一半才看清中间有两次停顿。|抄完折起纸留在书里，再读到相似的句子时取出来对照看看。'
    '摄影|一次只拍一种形状|散步时专找拱门。第一眼容易看到公园门口的大拱，转过街角才发现窗台和自行车架上也有相似的弧线。|拍完回来看，选出差别最大的三张。剩下的图下次再挑。'
    '散步|在河的上游掉头|沿河走上半小时，房子渐渐少下去，岸边只剩一条碎石路。往回走时注意另一侧的水草，更容易分辨哪里水流慢。|走累了在树下站一会儿，等呼吸平稳了再接着走。'
    '手作|给松散的插头贴一个标签|几根线放进抽屉后，长得越来越像。把用途写在纸条上，贴在接头附近，取用时就能先看到。|旧标签脏了可以剪掉换一张，比拆开每根线重新试一遍省事。'
    '日常|周日只安排一个大件|周日很容易顺手列十件事，做事前先挑一件最需要完整时间的。其余放在一旁，等那件结束再挑能顺便做的。|到了傍晚还能有空走去买水果，这天就没有被切得太碎。'
    '居家|把菜谱放在常看的地方|做饭时手机总会在切菜前锁屏。把常做的一道菜写成六行，贴在不见油烟的柜门内侧。|上面留点空位，下次发现更省时的顺序就直接改在上面。'
    '城市|回家前经过花摊|收摊的人会按花梗长短重新捆一遍。街灯照下来，桶里的水把叶子映成了两层。|买之前先想花瓶的高度，挑几枝回去，剪一截浸在水里。'
    '摄影|用薄纸挡一下直光|桌上玻璃杯太亮时，在窗边挡一张薄纸试试。杯口的反光变宽之后，水里的影子更容易拍清楚。|拍照前也可以先把杯子移离窗台，比较两种得到的阴影。'
    '阅读|把正文前的目录读完|目录常常比书封更能说明作者想回答什么。先按标题猜一下章节关系，再从最有兴趣的地方打开。|读了几页如果不明白术语，再回到前一章找它第一次出现的位置。'
    '散步|去树影短一些的街|午后的树影向人行道伸出来，脚步走到光和影交界时会不自觉地慢下来。避开大路，找几处可以安静站着的地方。|以后天气热起来，走同一条线时知道在哪儿能歇脚。'
    '厨房|煎剩下一小块豆腐|豆腐压去表面水分，切片放进锅里，等一面成形才翻。把盘底的两勺汤留到最后加进去。|煎好夹在馒头里，午饭就可以只再切一只番茄。'
    '日常|一周记三样见闻|想写日记但时间不够，可以只挑一种声音、一件借过的物品和一个想再去的地方记下来。|隔几周翻看，会发现几条记录说的是同一件事，再把它们合成一篇短文。'
  )
  local -a selected=()
  local i position count category title section_label about_label menu_label menu_items='' nav_items
  local -a section_labels=('文章' '阅读文章' '随笔列表' '查看笔记') about_labels=('关于' '关于这里' '小站介绍' '认识这个小站')
  local -a menu_labels=('最近文章' '随笔索引' '文章一览' '本页选读')

  digest=$(printf '%s' "$1" | sha256sum)
  IFS='|' read -r name intro about <<< "${identities[16#${digest:0:2} % ${#identities[@]}]}"
  theme=$(site_theme "$digest")
  layout=${layouts[16#${digest:6:2} % ${#layouts[@]}]}
  section_label=${section_labels[16#${digest:60:2} % ${#section_labels[@]}]}
  about_label=${about_labels[16#${digest:62:2} % ${#about_labels[@]}]}
  menu_label=${menu_labels[16#${digest:48:2} % ${#menu_labels[@]}]}
  nav_items="<a href=\"#notes\">$section_label</a><a href=\"#about\">$about_label</a>"
  count=$((3 + 16#${digest:52:2} % 3))
  for ((position=1; position<=count; position++)); do
    i=$((6 + position * 2))
    choice=$((16#${digest:i:2} % ${#articles[@]}))
    record=${articles[choice]}
    selected+=("$record")
    articles=("${articles[@]:0:choice}" "${articles[@]:choice+1}")
    IFS='|' read -r category title _ <<< "$record"
    menu_items+="<li><a href=\"#entry-$position\">$title</a></li>"
  done

  cat <<EOF
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="$intro">
<title>$name</title>
<style>
$theme
$(site_navigation_style)
* { box-sizing:border-box; }
body { margin:0; background:var(--paper); color:var(--ink); font:var(--text-size)/1.75 var(--body); }
a { color:inherit; text-underline-offset:.22em; }
a:hover { color:var(--accent); }
a:focus-visible { outline:2px solid var(--accent); outline-offset:.25rem; }
.skip { position:absolute; inset-block-start:.5rem; inset-inline-start:.5rem; padding:.4rem .8rem; transform:translateY(-160%); background:var(--paper); }
.skip:focus { transform:none; }
.wrap { width:min(var(--measure), calc(100% - 2.25rem)); margin-inline:auto; }
.skip { z-index:2; }
h1,h2 { font-family:var(--heading); font-weight:var(--heading-weight); line-height:1.22; overflow-wrap:anywhere; }
h1 { font-size:clamp(2.45rem, 8vw, var(--title-max)); letter-spacing:-.04em; margin:0 0 .55rem; }
h2 { font-size:clamp(1.42rem, 3.8vw, var(--section-max)); margin:.25rem 0 .8rem; }
p { margin:0 0 .8rem; }
article p:last-child, .hero p, .about p { margin-bottom:0; }
.main { padding-block:clamp(1.65rem, 6vw, var(--hero)); }
.hero { text-align:var(--intro-align); }
.hero p,.about p { color:var(--muted); }
.category { color:var(--accent); font-size:.9rem; font-weight:650; }
.menu { padding:1.15rem 1.3rem; border:1px solid var(--rule); }
.menu h2 { font-size:1.05rem; }
.menu ul { padding-inline-start:1.25rem; margin:0; }
.menu li { margin-block:.32rem; }
article { scroll-margin-top:1rem; padding:1.35rem 0; border-top:1px solid var(--rule); }
.journal .main { max-width:44rem; }
.journal .hero { padding:1rem 0 2.5rem; }
.journal .menu { margin-bottom:1.4rem; border-width:1px 0; }
.journal .menu ul { display:flex; flex-wrap:wrap; gap:.2rem 1.25rem; list-style:none; padding:0; }
.archive .main { display:grid; grid-template-columns:minmax(12rem, .65fr) minmax(0, 1.35fr); align-items:start; gap:clamp(1.25rem, 4vw, 3.5rem); }
.archive .hero h1,.feature .hero h1 { font-size:clamp(2rem, 5vw, calc(var(--title-max) - 16px)); }
.archive .menu { background:var(--surface); margin-top:1.3rem; }
.archive article:first-child { border-top:0; padding-top:0; }
.feature .hero { border-left:3px solid var(--accent); padding-left:1rem; margin-bottom:1.25rem; }
.feature .lead { background:var(--surface); margin-bottom:1.4rem; padding:clamp(1.2rem, 5vw, 3.5rem); }
.feature .lead h2 { font-size:clamp(1.75rem, 5vw, calc(var(--section-max) + 16px)); }
.feature .lead article { padding:0; border:0; max-width:45rem; }
.feature .grid { display:grid; grid-template-columns:minmax(0, 1fr) minmax(0, 1fr); gap:var(--gap); margin-top:1.4rem; }
.about { padding-block:1rem 2rem; }
.about h2 { font-size:1.35rem; }
@container (max-width:40rem) { .archive .main,.feature .grid { grid-template-columns:1fr; } }
.site-content { container-type:inline-size; }
</style>
</head>
<body id="top" class="$layout">
<a class="skip" href="#main">跳到正文</a>
$(site_navigation "$digest" "$name" "$nav_items" open)
<main class="wrap main" id="main">
EOF
  local hero="<section class=\"hero\"><h1>$name</h1><p>$intro</p></section>"
  local menu="<nav class=\"menu\" aria-label=\"$menu_label\"><h2>$menu_label</h2><ul>$menu_items</ul></nav>"
  case "$layout" in
    archive)
      printf '<aside>%s%s</aside>\n<section id="notes" aria-label="文章">\n' "$hero" "$menu"
      for i in "${!selected[@]}"; do blog_article "$((i + 1))" "${selected[i]}"; done
      printf '</section>\n'
      ;;
    feature)
      printf '%s\n<section id="notes" aria-label="文章"><div class="lead">\n' "$hero"
      blog_article 1 "${selected[0]}"
      printf '</div>\n%s\n<div class="grid">\n' "$menu"
      for ((i=1; i<${#selected[@]}; i++)); do blog_article "$((i + 1))" "${selected[i]}"; done
      printf '</div></section>\n'
      ;;
    journal)
      printf '%s\n%s\n<section id="notes" aria-label="文章">\n' "$hero" "$menu"
      for i in "${!selected[@]}"; do blog_article "$((i + 1))" "${selected[i]}"; done
      printf '</section>\n'
      ;;
  esac
  cat <<EOF
</main>
<section class="wrap about" id="about"><h2>$about_label</h2><p>$about</p></section>
$(site_navigation "$digest" "$name" "$nav_items" close)
</body>
</html>
EOF
}

tool_card() {
  local tool=$1 title label field submit
  case "$tool" in
    archive)
      printf '%s\n' '<article class="card"><h2>7-Zip 安装包</h2><p>在官方页面选择适合你的操作系统和处理器架构的安装包。</p><p class="link-actions"><a href="https://www.7-zip.org/download.html" rel="noreferrer">获取官方安装包</a></p></article>'
      return
      ;;
    count) title='文字计数'; label='输入文字'; submit='统计'; field='<textarea name="value" rows="3" required></textarea>';;
    temperature) title='摄氏度转华氏度'; label='温度（°C）'; submit='换算'; field='<input name="value" type="number" step="any" required>';;
    length) title='厘米转英寸'; label='长度（cm）'; submit='换算'; field='<input name="value" type="number" min="0" step="any" required>';;
    format) title='JSON 整理'; label='输入 JSON'; submit='格式化'; field='<textarea name="value" rows="3" required spellcheck="false"></textarea>';;
    uppercase) title='转大写'; label='输入文字'; submit='转换'; field='<textarea name="value" rows="3" required></textarea>';;
    pdf) title='PDF 提取文字'; label='选择 PDF 文件'; submit='提取文字'; field='<input name="value" type="file" accept=".pdf,application/pdf" required><span class="hint">支持带文字层的 PDF。文件在浏览器中处理。</span>';;
    download) title='一键下载文本'; label='输入要保存的文字'; submit='下载 TXT'; field='<textarea name="value" rows="3" required></textarea>';;
    timestamp) title='时间戳转换'; label='输入 Unix 时间戳（秒）'; submit='转换时间'; field='<input name="value" type="number" step="1" required>';;
    urlcode) title='URL 编码'; label='输入要编码的文字'; submit='编码'; field='<textarea name="value" rows="3" required></textarea>';;
  esac
  printf '<form class="card" data-tool="%s"><h2>%s</h2><label>%s%s</label><button type="submit">%s</button><output aria-live="polite"></output></form>\n' \
    "$tool" "$title" "$label" "$field" "$submit"
}

site_storage() {
  local path=$WEB_ROOT result
  while [[ ! -d $path && $path != / ]]; do
    path=${path%/*}
    path=${path:-/}
  done
  if result=$(LC_ALL=C df -Pk -- "$path" 2>/dev/null | awk 'NR == 2 && $2 ~ /^[0-9]+$/ { printf "%.1f GiB", $2 / 1048576 }') && [[ -n $result ]]; then
    printf '%s' "$result"
  else
    printf '暂不可用'
  fi
}

render_other_site() {
  local digest=$1 type=$2 name intro nav_label nav_items theme choice i detail title url count position storage draw extra has_pdf=0
  local caption cta
  local -a names=() summaries=() cards=() tools=(count temperature length format uppercase pdf archive download timestamp urlcode)
  local -a link_labels=('打开%s官网' '访问%s官方网站' '前往%s官网' '%s官方主页' '浏览%s官网')
  case "$type" in
    home)
      names=('我的第一个网站' '小站第一天' '一页个人主页' '从一张空白页开始' '搭个小站' '书签里的主页')
      summaries=('Python 学习计划|给自己留一份能按天做的上手练习。' '查看学习路线|从一个小项目开始，把练过的东西串起来。' 'Python 练习|按下面的顺序动手，每一步都能跑出来看看。' '项目练习计划|给刚开始写 Python 的自己排一份短计划。')
      cards=(
        '七天写出一个终端记账本|第 1、2 天练习变量、输入和数字转换。第 3、4 天用条件语句和循环处理菜单。第 5 天把记录放进列表、拆成函数。第 6 天写入 CSV。第 7 天用五笔样例核对收支总额。'
        '两周做一个阅读清单|第一周学习字符串、字典、列表和文件读写，把书名和页码存成 JSON。第二周加上命令行的添加、搜索和完成操作。验收时关掉程序再打开，记录仍能读出来。'
        '十天练习处理表格数据|先用三天学习 csv 模块和异常处理，再用四天练习筛选、排序和按类别汇总。最后三天把练习合成一个脚本，用包含空值和重复行的数据检查输出。'
        '用三个周末写一个 Python 小站|第一个周末把基本函数和虚拟环境跑通。第二个周末用 Flask 写首页和表单。第三个周末把提交内容存进 SQLite，并补两个测试。完成后写清从零启动项目的命令。'
        '一个月从基础到自动整理文件|第一周掌握路径和文件列表，第二周学习条件、循环和函数，第三周练习异常处理和日志，第四周实现文件分类工具。默认先预览移动计划，用临时目录测试通过后再操作真实文件。'
      )
      ;;
    learner)
      names=('小白的第一次尝试' '网页练习册' '第一次写页面' '学一点前端' '动手练习记录' '新手实验簿')
      summaries=('第一次建站|记一下做第一张网页时真正用上的步骤。' '建站手记|第一次发布自己的页面，有些问题是上线才发现的。' '查看经验|把自己试过的办法记下来，下次从这里接着做。' '动手记录|从打开本地文件到发给朋友，我把过程中遇到的小问题写在这里。')
      cards=(
        '第一次发布，先做一张能打开的首页|最初想一次做出导航、图库和留言板，结果一项都没收尾。我后来只留下标题、介绍和两个站内链接。先在本机用浏览器打开，再上传 index.html。能从手机访问之后，才继续添加下一页。'
        '域名配置完成，别急着改服务器|新记录保存后，浏览器还访问到旧地址。我先查解析值是否已更新，再核对网站的域名配置。把解析、站点监听和 HTTPS 分成三步，排查比反复重启服务快。'
        '本地正常，手机却横向滚动|桌面上图片刚好装得下，手机端却把整个页面撑宽了。我给图片加了最大宽度，让文字自然换行，再用窄屏和放大字体各试一次。这个问题只有实际打开小屏幕才容易看到。'
        '第一次部署后才发现相对路径的重要性|首页能打开，样式和图片却空了。原来本地文件路径写成了电脑目录。换成站点里的相对路径，并按服务器上的大小写重新命名。部署完成后，我逐个打开了导航和图片链接。'
        '上线前给旧首页留一份副本|第一次换页面时，直接覆盖让回退变得费劲。现在我会先留一份旧的 index.html，再发布并从另一台设备打开。遇到问题可以先换回旧页，之后再慢慢定位新版本的错误。'
      )
      ;;
    tools)
      names=('个人工具箱' '桌面小工具' '口袋计算台' '随手处理' '轻量工具架' '日常换算桌')
      summaries=('工具|几个在浏览器里就能用的小工具。' '打开工具箱|平时用到的换算和文本处理，放在一页里。' '试用工具|遇到些零碎的小活，可以直接在这页处理。' '常用工具|在这里整理文字、转换数据，或找到常用软件入口。')
      ;;
    links)
      names=('官网导航工具箱' '常用官网书签' '网页路标' '桌面导航卡' '官网入口集' '常用网站收藏')
      summaries=('官网目录|把平时会查的品牌官网放到一起。' '浏览品牌|想找产品资料或售后支持，可以先从品牌官网进入。' '查看网站清单|按站名找入口。每张卡片都通向对应的官方网站。' '官网收藏|从设备到生活用品，这一页收着几个行业的官方入口。' '品牌官网一览|需要找新品或查使用说明时，可以打开下面的官网。')
      cards=("${SITE_OFFICIAL_LINKS[@]}")
      ;;
    check)
      names=('测试服务器' '站点测试台' '页面部署实验' '单页站自检' '网页实验室' '浏览器小测试')
      intro='站点所在文件系统的总容量与浏览器请求本页的延时。'
      nav_label='服务器测试'
      ;;
  esac
  name=${names[16#${digest:0:2} % ${#names[@]}]}
  if [[ $type != check ]]; then
    IFS='|' read -r nav_label intro <<< "${summaries[16#${digest:60:2} % ${#summaries[@]}]}"
    nav_items="<a href=\"#content\">$nav_label</a>"
  fi
  theme=$(site_theme "$digest")

  cat <<EOF
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="$intro">
<title>$name</title>
<style>
$theme
$(site_navigation_style)
* { box-sizing:border-box; }
body { margin:0; background:var(--paper); color:var(--ink); font:var(--text-size)/1.62 var(--body); }
.wrap { width:min(var(--measure), calc(100% - 2.25rem)); margin-inline:auto; }
a { color:inherit; text-underline-offset:.24em; }
h1,h2 { font-family:var(--heading); font-weight:var(--heading-weight); line-height:1.2; overflow-wrap:anywhere; }
h1 { font-size:clamp(2.4rem, 7vw, var(--title-max)); margin:0 0 .6rem; }
h2 { font-size:clamp(1.25rem, 3vw, var(--section-max)); margin:0 0 .65rem; }
p { margin:0; }
.intro { padding-block:clamp(2rem, 6vw, var(--hero)); text-align:var(--intro-align); }
.intro p,.card p { color:var(--muted); }
.grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(min(100%,15rem),1fr)); gap:var(--gap); }
.card { min-width:0; padding:1.2rem; background:var(--surface); border:1px solid var(--rule); border-radius:var(--radius); }
.home .intro { margin-top:1rem; padding-inline:clamp(1rem, 4vw, 2.5rem); border-left:.35rem solid var(--accent); }
.learner .wrap { max-width:45rem; }
.learner .grid { display:grid; grid-template-columns:1fr; padding-left:1rem; border-left:2px solid var(--accent); }
.tools .intro { padding-block:2.5rem; }
.links .grid { grid-template-columns:repeat(auto-fit,minmax(min(100%,22rem),1fr)); }
.links .nav-left .grid,.links .nav-right .grid { grid-template-columns:repeat(auto-fit,minmax(min(100%,17rem),1fr)); }
.links .intro { border-bottom:1px solid var(--rule); margin-bottom:var(--gap); }
.link-actions { text-align:var(--action-align); margin-top:.9rem; }
.link-actions-first { margin:0 0 .9rem; }
.link-actions a { display:inline-block; padding:.35rem .8rem; color:var(--paper); background:var(--accent); text-decoration:none; border-radius:var(--radius); }
.link-actions a:hover { text-decoration:underline; }
.check .intro { margin:1rem 0; padding:clamp(1rem, 4vw, 2rem); background:var(--surface); }
.check .grid { margin-top:1rem; }
button,input,textarea { font:inherit; }
textarea,input { width:100%; color:var(--ink); background:var(--paper); border:1px solid var(--accent); padding:.45rem .55rem; margin:.35rem 0 .65rem; }
textarea { resize:vertical; }
button { display:block; margin-inline-start:var(--action-start); margin-inline-end:var(--action-end); cursor:pointer; color:var(--paper); background:var(--accent); border:1px solid var(--accent); padding:.35rem .8rem; border-radius:var(--radius); }
output { display:block; margin-top:.55rem; white-space:pre-wrap; overflow-wrap:anywhere; }
.hint { display:block; color:var(--muted); font-size:.9em; margin-bottom:.65rem; }
.metrics { margin:0; }
.metrics dd { margin:0; font:var(--heading-weight) clamp(1.75rem,5vw,2.8rem)/1.25 var(--heading); }
.metrics dt { color:var(--muted); margin-bottom:.6rem; }
a:focus-visible, button:focus-visible, input:focus-visible, textarea:focus-visible { outline:2px solid var(--accent); outline-offset:3px; }
</style>
</head>
<body id="top" class="$type">
EOF
  if [[ $type == check ]]; then
    storage=$(site_storage)
    cat <<EOF
<main class="wrap">
<section class="intro"><h1>$name</h1></section>
<dl class="grid metrics"><div class="card"><dt>站点磁盘总容量</dt><dd>$storage</dd></div><div class="card"><dt>本页请求延时</dt><dd id="latency" aria-live="polite">测量中…</dd></div></dl>
</main>
EOF
    cat <<'HTML'
<script>
(async () => {
  const value = document.querySelector('#latency');
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 8000);
  const start = performance.now();
  try {
    const response = await fetch(location.href, {
      method:'HEAD', cache:'no-store', mode:'same-origin', redirect:'error', signal:controller.signal,
    });
    value.textContent = response.ok ? `${Math.round(performance.now() - start)} ms` : '暂不可用';
  } catch {
    value.textContent = '暂不可用';
  } finally {
    clearTimeout(timeout);
  }
})();
</script>
</body></html>
HTML
    return
  fi
  cat <<EOF
$(site_navigation "$digest" "$name" "$nav_items" open)
<main class="wrap">
<section class="intro"><h1>$name</h1><p>$intro</p></section>
<section id="content" aria-label="$nav_label">
EOF
  printf '<div class="grid">\n'
  if [[ $type == tools ]]; then
    count=$((4 + 16#${digest:52:2} % 3))
    for ((position=1; position<=count; position++)); do
      i=$((6 + position * 2))
      choice=$((16#${digest:i:2} % ${#tools[@]}))
      if [[ ${tools[choice]} == pdf ]]; then has_pdf=1; fi
      tool_card "${tools[choice]}"
      tools=("${tools[@]:0:choice}" "${tools[@]:choice+1}")
    done
  elif [[ $type == links ]]; then
    draw=$(printf '%s:links:0' "$digest" | sha256sum)
    extra=$(printf '%s:links:1' "$digest" | sha256sum)
    draw="${draw%% *}${extra%% *}"
    for ((position=0; position<30; position++)); do
      i=$((position * 4))
      choice=$((16#${draw:i:4} % ${#cards[@]}))
      IFS='|' read -r title url detail <<< "${cards[choice]}"
      printf -v caption "${link_labels[16#${digest:62:2} % ${#link_labels[@]}]}" "$title"
      printf -v cta '<a href="%s" rel="noreferrer">%s</a>' "$url" "$caption"
      if (( 16#${digest:52:2} % 2 == 0 )); then
        printf '<article class="card"><p class="link-actions link-actions-first">%s</p><h2>%s</h2><p>%s</p></article>\n' "$cta" "$title" "$detail"
      else
        printf '<article class="card"><h2>%s</h2><p>%s</p><p class="link-actions">%s</p></article>\n' "$title" "$detail" "$cta"
      fi
      cards=("${cards[@]:0:choice}" "${cards[@]:choice+1}")
    done
  else
    choice=$((16#${digest:8:2} % ${#cards[@]}))
    IFS='|' read -r title detail <<< "${cards[choice]}"
    printf '<article class="card"><h2>%s</h2><p>%s</p></article>\n' "$title" "$detail"
  fi
  printf '</div></section></main>\n'
  site_navigation "$digest" "$name" "$nav_items" close
  case "$type" in
    tools)
      printf '<script>\n'
      if (( has_pdf )); then
        cat <<'HTML'
async function extractPdfText(file) {
  const base = 'https://cdn.jsdelivr.net/npm/pdfjs-dist@6.5.438/';
  const pdfjs = await import(`${base}build/pdf.min.mjs`);
  pdfjs.GlobalWorkerOptions.workerSrc = `${base}build/pdf.worker.min.mjs`;
  const task = pdfjs.getDocument({
    data:new Uint8Array(await file.arrayBuffer()), isEvalSupported:false,
    cMapUrl:`${base}cmaps/`, cMapPacked:true, standardFontDataUrl:`${base}standard_fonts/`, wasmUrl:`${base}wasm/`,
  });
  try {
    const pdf = await task.promise;
    const pages = [];
    for (let number = 1; number <= pdf.numPages; number += 1) {
      const page = await pdf.getPage(number);
      const content = await page.getTextContent();
      pages.push(content.items.map((item) => ('str' in item) ? item.str + (item.hasEOL ? '\n' : ' ') : '').join('').trim());
      page.cleanup();
    }
    return pages.join('\n\n').trim();
  } finally {
    await task.destroy();
  }
}
HTML
      fi
      cat <<'HTML'
for (const form of document.querySelectorAll('[data-tool]')) {
  form.addEventListener('submit', async (event) => {
    event.preventDefault();
    const text = new FormData(form).get('value');
    const output = form.querySelector('output');
    switch (form.dataset.tool) {
      case 'count': output.textContent = `字符数 ${Array.from(text).length} · 行数 ${text.split(/\r?\n/).length}`; break;
      case 'temperature': output.textContent = `${(Number(text) * 9 / 5 + 32).toFixed(2)} °F`; break;
      case 'length': output.textContent = `${(Number(text) / 2.54).toFixed(3)} in`; break;
      case 'uppercase': output.textContent = text.toUpperCase(); break;
      case 'urlcode': output.textContent = encodeURIComponent(text); break;
      case 'timestamp': {
        const date = new Date(Number(text) * 1000);
        output.textContent = Number.isFinite(date.getTime()) ? date.toISOString() : '时间戳超出可转换范围。';
        break;
      }
      case 'download': {
        const link = document.createElement('a');
        const url = URL.createObjectURL(new Blob([text], {type:'text/plain;charset=utf-8'}));
        link.href = url;
        link.download = 'notes.txt';
        link.click();
        setTimeout(() => URL.revokeObjectURL(url), 1000);
        output.textContent = '已交给浏览器下载 notes.txt。';
        break;
      }
      case 'pdf': {
        const button = form.querySelector('button');
        button.disabled = true;
        output.textContent = '正在读取 PDF…';
        try { output.textContent = await extractPdfText(text) || '这份 PDF 未找到可提取的文字层。'; }
        catch { output.textContent = '无法提取文字，请检查文件、密码和 PDF 组件的网络连接。'; }
        finally { button.disabled = false; }
        break;
      }
      case 'format':
        try { output.textContent = JSON.stringify(JSON.parse(text), null, 2); }
        catch { output.textContent = '请检查 JSON 的引号、逗号和括号。'; }
        break;
    }
  });
}
</script>
HTML
      ;;
  esac
  printf '</body></html>\n'
}

render_site() {
  local digest type
  local -a types=(blog home learner tools check links)
  digest=$(printf '%s' "$1" | sha256sum)
  type=${types[16#${digest:14:4} % ${#types[@]}]}
  if [[ $type == blog ]]; then render_blog "$1"; else render_other_site "$digest" "$type"; fi
}

stage_site() {
  local seed='' seed_file="$CONFIG_DIR/site-seed"
  if [[ ${1:-} != new-site && -f $seed_file ]]; then
    IFS= read -r seed < "$seed_file" || die '无法读取站点生成记录。'
    [[ $seed =~ ^[0-9a-f]{24}$ ]] || die '站点生成记录无效，请用 --new-site 重新生成。'
  else
    seed=$(od -An -N12 -tx1 /dev/urandom | tr -d '[:space:]')
    [[ $seed =~ ^[0-9a-f]{24}$ ]] || die '无法生成站点随机值。'
    printf '%s\n' "$seed" > "$STAGE/site-seed"
  fi
  render_site "$seed" > "$STAGE/index.html"
}

save_site_seed() {
  local temp_file
  [[ -f $STAGE/site-seed ]] || return 0
  temp_file=$(mktemp "$CONFIG_DIR/.site-seed.XXXXXXXX")
  install -m 600 -- "$STAGE/site-seed" "$temp_file"
  mv -fT -- "$temp_file" "$CONFIG_DIR/site-seed"
}

refresh_page() {
  local page="$WEB_ROOT/index.html" backup temp_file attempt
  [[ -f $CONFIG_DIR/deployment && ! -L $CONFIG_DIR && ! -L $CONFIG_DIR/deployment ]] || die '请先完成站点部署。'
  [[ -d $WEB_ROOT && ! -L $WEB_ROOT && ! -L $page ]] || die '请先检查网站目录及首页路径。'
  [[ ! -e $page || -f $page ]] || die '现有首页路径不是普通文件。'
  [[ ! -L $CONFIG_DIR/site-seed ]] || die '站点生成记录不能是符号链接。'

  start_stage
  if [[ ${1:-} == new-site ]]; then
    for attempt in 1 2 3; do
      stage_site new-site
      if ! cmp -s "$STAGE/index.html" "$page"; then break; fi
    done
    if cmp -s "$STAGE/index.html" "$page"; then die '抽样结果仍与现有首页相同，请重试。'; fi
  else
    download_page "$STAGE/index.html"
  fi
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
  save_site_seed
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

  if [[ ${1:-} == --refresh-page || ${1:-} == --new-site ]]; then
    (( $# == 1 )) || die "$1 无需其他参数。"
    refresh_page "${1#--}"
    return
  fi

  case $(uname -m) in
    x86_64) arch=amd64; digest=5b8cb7faf8726a2028ad96a66e54e6e81e8f361bc6175e5d22bbd997cc5177fb ;;
    aarch64) arch=arm64; digest=5e377cff994fc9362a6fcf695c53f226cfca3a3ef85bd3a3687cf252d6310165 ;;
    *) die '仅支持 x86_64 和 aarch64。' ;;
  esac

  for path in "$CONFIG_DIR" "$BIN_DIR" "$WEB_ROOT" "$UNIT_PATH" \
    "$CONFIG_DIR/deployment" "$CONFIG_DIR/Caddyfile" "$CONFIG_DIR/site-seed" "$CADDY" "$WEB_ROOT/index.html"; do
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
    stage_site
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
    save_site_seed
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

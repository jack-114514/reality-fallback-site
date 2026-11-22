#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

readonly VERSION=1.2
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
readonly -a SITE_FONTS=(
  '"Songti SC",SimSun,serif|system-ui,"Microsoft YaHei",sans-serif'
  'system-ui,"PingFang SC","Microsoft YaHei",sans-serif|system-ui,"Microsoft YaHei",sans-serif'
  '"Kaiti SC",KaiTi,serif|"Noto Serif CJK SC",SimSun,serif'
  '"Noto Serif CJK SC","Songti SC",serif|"Noto Serif CJK SC",SimSun,serif'
)

render_blog() {
  local digest choice record name intro about layout paper ink muted accent surface rule heading body measure hero_space gap
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
  )
  local -a selected=()
  local -a titles=()
  local i category title

  digest=$(printf '%s' "$1" | sha256sum)
  IFS='|' read -r name intro about <<< "${identities[16#${digest:0:2} % ${#identities[@]}]}"
  IFS='|' read -r paper ink muted accent surface rule <<< "${SITE_PALETTES[16#${digest:2:2} % ${#SITE_PALETTES[@]}]}"
  IFS='|' read -r heading body <<< "${SITE_FONTS[16#${digest:4:2} % ${#SITE_FONTS[@]}]}"
  layout=${layouts[16#${digest:6:2} % ${#layouts[@]}]}
  measure=$((58 + 16#${digest:18:2} % 17))
  hero_space=$((45 + 16#${digest:20:2} % 38))
  gap=$((17 + 16#${digest:22:2} % 13))
  for i in 8 10 12; do
    choice=$((16#${digest:i:2} % ${#articles[@]}))
    record=${articles[choice]}
    selected+=("$record")
    articles=("${articles[@]:0:choice}" "${articles[@]:choice+1}")
    IFS='|' read -r category title _ <<< "$record"
    titles+=("$title")
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
:root { --paper:$paper; --ink:$ink; --muted:$muted; --accent:$accent; --surface:$surface; --rule:$rule; --heading:$heading; --body:$body; --measure:${measure}rem; --hero:${hero_space}px; --gap:${gap}px; }
* { box-sizing:border-box; }
body { margin:0; background:var(--paper); color:var(--ink); font:1rem/1.75 var(--body); }
a { color:inherit; text-underline-offset:.22em; }
a:hover { color:var(--accent); }
a:focus-visible { outline:2px solid var(--accent); outline-offset:.25rem; }
.skip { position:absolute; inset-block-start:.5rem; inset-inline-start:.5rem; padding:.4rem .8rem; transform:translateY(-160%); background:var(--paper); }
.skip:focus { transform:none; }
.wrap { width:min(var(--measure), calc(100% - 2.25rem)); margin-inline:auto; }
.bar { display:flex; justify-content:space-between; align-items:center; gap:.7rem 1.25rem; flex-wrap:wrap; padding-block:1.15rem; border-bottom:1px solid var(--rule); }
.bar nav { display:flex; gap:1.25rem; }
.brand { font:700 1.25rem/1.3 var(--heading); text-decoration:none; }
h1,h2 { font-family:var(--heading); line-height:1.22; overflow-wrap:anywhere; }
h1 { font-size:clamp(2.45rem, 8vw, 5.6rem); letter-spacing:-.04em; margin:0 0 .55rem; }
h2 { font-size:clamp(1.42rem, 3.8vw, 2rem); margin:.25rem 0 .8rem; }
p { margin:0 0 .8rem; }
article p:last-child, .hero p, .about p { margin-bottom:0; }
.main { padding-block:clamp(1.65rem, 6vw, var(--hero)); }
.hero p,.about p { color:var(--muted); }
.category { color:var(--accent); font-size:.9rem; font-weight:650; }
.menu { padding:1.15rem 1.3rem; border:1px solid var(--rule); }
.menu h2 { font-size:1.05rem; }
.menu ul { padding-inline-start:1.25rem; margin:0; }
.menu li { margin-block:.32rem; }
article { scroll-margin-top:1rem; padding:1.35rem 0; border-top:1px solid var(--rule); }
.journal .main { max-width:44rem; }
.journal .hero { text-align:center; padding:1rem 0 2.5rem; }
.journal .menu { margin-bottom:1.4rem; border-width:1px 0; }
.journal .menu ul { display:flex; flex-wrap:wrap; gap:.2rem 1.25rem; list-style:none; padding:0; }
.archive .main { display:grid; grid-template-columns:minmax(12rem, .65fr) minmax(0, 1.35fr); align-items:start; gap:clamp(1.25rem, 4vw, 3.5rem); }
.archive .hero h1,.feature .hero h1 { font-size:clamp(2rem, 5vw, 3.7rem); }
.archive .menu { background:var(--surface); margin-top:1.3rem; }
.archive article:first-child { border-top:0; padding-top:0; }
.feature .hero { border-left:3px solid var(--accent); padding-left:1rem; margin-bottom:1.25rem; }
.feature .lead { background:var(--surface); margin-bottom:1.4rem; padding:clamp(1.2rem, 5vw, 3.5rem); }
.feature .lead h2 { font-size:clamp(2rem, 5vw, 3.25rem); }
.feature .lead article { padding:0; border:0; max-width:45rem; }
.feature .grid { display:grid; grid-template-columns:minmax(0, 1fr) minmax(0, 1fr); gap:var(--gap); margin-top:1.4rem; }
.about { padding-block:1rem 2rem; }
.about h2 { font-size:1.35rem; }
footer { border-top:1px solid var(--rule); padding-block:1rem 1.5rem; }
@media (max-width:40rem) { .archive .main,.feature .grid { grid-template-columns:1fr; } }
</style>
</head>
<body id="top" class="$layout">
<a class="skip" href="#main">跳到正文</a>
<header class="wrap bar"><a class="brand" href="#top">$name</a><nav aria-label="页面导航"><a href="#notes">文章</a><a href="#about">关于</a></nav></header>
<main class="wrap main" id="main">
EOF
  local hero="<section class=\"hero\"><h1>$name</h1><p>$intro</p></section>"
  local menu="<nav class=\"menu\" aria-label=\"文章目录\"><h2>最近文章</h2><ul><li><a href=\"#entry-1\">${titles[0]}</a></li><li><a href=\"#entry-2\">${titles[1]}</a></li><li><a href=\"#entry-3\">${titles[2]}</a></li></ul></nav>"
  case "$layout" in
    archive)
      printf '<aside>%s%s</aside>\n<section id="notes" aria-label="文章">\n' "$hero" "$menu"
      for i in 0 1 2; do blog_article "$((i + 1))" "${selected[i]}"; done
      printf '</section>\n'
      ;;
    feature)
      printf '%s\n<section id="notes" aria-label="文章"><div class="lead">\n' "$hero"
      blog_article 1 "${selected[0]}"
      printf '</div>\n%s\n<div class="grid">\n' "$menu"
      for i in 1 2; do blog_article "$((i + 1))" "${selected[i]}"; done
      printf '</div></section>\n'
      ;;
    journal)
      printf '%s\n%s\n<section id="notes" aria-label="文章">\n' "$hero" "$menu"
      for i in 0 1 2; do blog_article "$((i + 1))" "${selected[i]}"; done
      printf '</section>\n'
      ;;
  esac
  cat <<EOF
</main>
<section class="wrap about" id="about"><h2>关于这里</h2><p>$about</p></section>
<footer class="wrap"><a href="#top">返回顶部</a></footer>
</body>
</html>
EOF
}

tool_card() {
  local tool=$1 title label field submit
  case "$tool" in
    count) title='文字计数'; label='输入文字'; submit='统计'; field='<textarea name="value" rows="3" required></textarea>';;
    temperature) title='摄氏度转华氏度'; label='温度（°C）'; submit='换算'; field='<input name="value" type="number" step="any" required>';;
    length) title='厘米转英寸'; label='长度（cm）'; submit='换算'; field='<input name="value" type="number" min="0" step="any" required>';;
    format) title='JSON 整理'; label='输入 JSON'; submit='格式化'; field='<textarea name="value" rows="3" required spellcheck="false"></textarea>';;
    uppercase) title='转大写'; label='输入文字'; submit='转换'; field='<textarea name="value" rows="3" required></textarea>';;
  esac
  printf '<form class="card" data-tool="%s"><h2>%s</h2><label>%s%s</label><button type="submit">%s</button><output aria-live="polite"></output></form>\n' \
    "$tool" "$title" "$label" "$field" "$submit"
}

render_other_site() {
  local digest=$1 type=$2 name intro nav_label paper ink muted accent surface rule heading body choice i detail title measure hero_space radius gap
  local -a names=() cards=() tools=(count temperature length format uppercase)
  case "$type" in
    home)
      names=('我的第一个网站' '小站第一天' '一页个人主页' '从一张空白页开始' '搭个小站' '书签里的主页')
      intro='把最近在做的几件事放在一起，过一段时间回来看看。'
      nav_label='最近在做'
      cards=(
        '整理读书摘录|每周挑一个问题，写下读到的两种回答，留作下一次阅读的起点。'
        '画一张街区地图|从常走的小路开始，用几种颜色区分树荫、便利店和能坐一会儿的地方。'
        '做一个静态主页|先写清要展示的内容，再练习用标题、列表和段落把信息整理出来。'
        '归档照片|把同一次出门的照片放进一个文件夹，每一组只保留最能说明那一天的几张。'
        '攒一份食谱|把常做的三道菜写清用量和顺序，下次做的时候补上时间。'
      )
      ;;
    learner)
      names=('小白的第一次尝试' '网页练习册' '第一次写页面' '学一点前端' '动手练习记录' '新手实验簿')
      intro='边做边记，留下一些以后可以照着重做的练习。'
      nav_label='练习记录'
      cards=(
        '从语义标签开始|用 main 放正文，用 nav 放导航。只有在信息关系明确之后，再决定每一块长什么样。'
        '把长段落拆开|一个段落只讲一个主题。给每一段起个小标题，试着只看标题也能读懂顺序。'
        '照顾小屏幕|把浏览器调到手机宽度，确认手指能点到链接，字不会挤在两侧，也没有横向滚动。'
        '给按钮留出反馈|提交后让页面在按钮旁显示结果。键盘也要能按到按钮，并看清焦点在哪里。'
        '上线后再检查一次|从另一个浏览器打开页面，试一次目录跳转，看看图片、字号和按钮是否还正常。'
      )
      ;;
    tools)
      names=('个人工具箱' '桌面小工具' '口袋计算台' '随手处理' '轻量工具架' '日常换算桌')
      intro='几个在浏览器里就能用的小工具。'
      nav_label='工具'
      ;;
    check)
      names=('测试服务器' '站点测试台' '页面部署实验' '单页站自检' '网页实验室' '浏览器小测试')
      intro='用这页检查网页能否打开、站内链接能否跳转，以及本页的响应状态。'
      nav_label='页面测试'
      cards=('标题与换行|窄屏下标题会按可用宽度换行。' '键盘焦点|按 Tab 时可看到当前链接或按钮的焦点。' '页内跳转|页面上方的入口可以跳到对应区块。' '文字可读性|在不同屏幕宽度下检查行距、字号和颜色对比。')
      ;;
  esac
  name=${names[16#${digest:0:2} % ${#names[@]}]}
  IFS='|' read -r paper ink muted accent surface rule <<< "${SITE_PALETTES[16#${digest:2:2} % ${#SITE_PALETTES[@]}]}"
  IFS='|' read -r heading body <<< "${SITE_FONTS[16#${digest:4:2} % ${#SITE_FONTS[@]}]}"
  measure=$((57 + 16#${digest:18:2} % 15))
  hero_space=$((45 + 16#${digest:20:2} % 35))
  radius=$((16#${digest:22:2} % 19))
  gap=$((12 + 16#${digest:24:2} % 15))

  cat <<EOF
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="description" content="$intro">
<title>$name</title>
<style>
:root { --paper:$paper; --ink:$ink; --muted:$muted; --accent:$accent; --surface:$surface; --rule:$rule; --heading:$heading; --body:$body; --measure:${measure}rem; --hero:${hero_space}px; --radius:${radius}px; --gap:${gap}px; }
* { box-sizing:border-box; }
body { margin:0; background:var(--paper); color:var(--ink); font:1rem/1.62 var(--body); }
.wrap { width:min(var(--measure), calc(100% - 2.25rem)); margin-inline:auto; }
header,footer { padding-block:1rem; border-bottom:1px solid var(--rule); }
header { display:flex; justify-content:space-between; gap:1rem; align-items:center; flex-wrap:wrap; }
a { color:inherit; text-underline-offset:.24em; }
h1,h2 { font-family:var(--heading); line-height:1.2; overflow-wrap:anywhere; }
h1 { font-size:clamp(2.4rem, 7vw, 5rem); margin:0 0 .6rem; }
h2 { font-size:1.3rem; margin:0 0 .65rem; }
p { margin:0; }
.intro { padding-block:clamp(2rem, 6vw, var(--hero)); }
.intro p,.card p { color:var(--muted); }
.grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(min(100%,15rem),1fr)); gap:var(--gap); }
.card { min-width:0; padding:1.2rem; background:var(--surface); border:1px solid var(--rule); border-radius:var(--radius); }
.home .intro { margin-top:1rem; padding-inline:clamp(1rem, 4vw, 2.5rem); border-left:.35rem solid var(--accent); }
.learner .wrap { max-width:45rem; }
.learner .grid { display:grid; grid-template-columns:1fr; padding-left:1rem; border-left:2px solid var(--accent); }
.tools .intro { padding-block:2.5rem; }
.check .intro { margin:1rem 0; padding:clamp(1rem, 4vw, 2rem); background:var(--surface); }
.check .grid { margin-top:1rem; }
footer { border-bottom:none; border-top:1px solid var(--rule); margin-top:2.5rem; }
button,input,textarea { font:inherit; }
textarea,input { width:100%; color:var(--ink); background:var(--paper); border:1px solid var(--accent); padding:.45rem .55rem; margin:.35rem 0 .65rem; }
textarea { resize:vertical; }
button { cursor:pointer; color:var(--paper); background:var(--accent); border:1px solid var(--accent); padding:.35rem .8rem; }
output { display:block; margin-top:.55rem; white-space:pre-wrap; overflow-wrap:anywhere; }
a:focus-visible, button:focus-visible, input:focus-visible, textarea:focus-visible { outline:2px solid var(--accent); outline-offset:3px; }
</style>
</head>
<body id="top" class="$type">
<header class="wrap"><a href="#top">$name</a><a href="#content">$nav_label</a></header>
<main class="wrap">
<section class="intro"><h1>$name</h1><p>$intro</p></section>
<section id="content" aria-label="$nav_label">
EOF
  if [[ $type == check ]]; then
    cat <<'HTML'
<div class="card"><h2>检查本页的 HTTP 响应</h2><button type="button" id="check-response">检查响应</button><output id="check-result" aria-live="polite"></output></div>
HTML
  fi
  printf '<div class="grid">\n'
  if [[ $type == tools ]]; then
    for i in 8 10 12; do
      choice=$((16#${digest:i:2} % ${#tools[@]}))
      tool_card "${tools[choice]}"
      tools=("${tools[@]:0:choice}" "${tools[@]:choice+1}")
    done
  else
    for i in 8 10 12; do
      choice=$((16#${digest:i:2} % ${#cards[@]}))
      IFS='|' read -r title detail <<< "${cards[choice]}"
      printf '<article class="card"><h2>%s</h2><p>%s</p></article>\n' "$title" "$detail"
      cards=("${cards[@]:0:choice}" "${cards[@]:choice+1}")
    done
  fi
  printf '</div></section></main>\n<footer class="wrap"><a href="#top">返回顶部</a></footer>\n'
  case "$type" in
    tools)
      cat <<'HTML'
<script>
for (const form of document.querySelectorAll('[data-tool]')) {
  form.addEventListener('submit', (event) => {
    event.preventDefault();
    const text = new FormData(form).get('value');
    const output = form.querySelector('output');
    switch (form.dataset.tool) {
      case 'count': output.textContent = `字符数 ${Array.from(text).length} · 行数 ${text.split(/\r?\n/).length}`; break;
      case 'temperature': output.textContent = `${(Number(text) * 9 / 5 + 32).toFixed(2)} °F`; break;
      case 'length': output.textContent = `${(Number(text) / 2.54).toFixed(3)} in`; break;
      case 'uppercase': output.textContent = text.toUpperCase(); break;
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
    check)
      cat <<'HTML'
<script>
const button = document.querySelector('#check-response');
const output = document.querySelector('#check-result');
button.addEventListener('click', async () => {
  button.disabled = true;
  output.textContent = '正在请求本页…';
  try {
    const response = await fetch(location.href, {method:'HEAD', cache:'no-store', mode:'same-origin', redirect:'error'});
    output.textContent = `本页响应 HTTP ${response.status}`;
  } catch {
    output.textContent = '本页请求失败，请检查当前连接。';
  } finally {
    button.disabled = false;
  }
});
</script>
HTML
      ;;
  esac
  printf '</body></html>\n'
}

render_site() {
  local digest type
  local -a types=(blog home learner tools check)
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
  local page="$WEB_ROOT/index.html" backup temp_file
  [[ -f $CONFIG_DIR/deployment && ! -L $CONFIG_DIR && ! -L $CONFIG_DIR/deployment ]] || die '请先完成站点部署。'
  [[ -d $WEB_ROOT && ! -L $WEB_ROOT && ! -L $page ]] || die '请先检查网站目录及首页路径。'
  [[ ! -e $page || -f $page ]] || die '现有首页路径不是普通文件。'
  [[ ! -L $CONFIG_DIR/site-seed ]] || die '站点生成记录不能是符号链接。'

  start_stage
  if [[ ${1:-} == new-site ]]; then stage_site new-site; else download_page "$STAGE/index.html"; fi
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

#!/bin/bash
# ============================================================
#  acme-dns 多域名泛证书管理  (单文件)
#  用法: ./acme-mgr.sh <命令> [域名...]
# ============================================================

# ==================== 配置区 ====================
ROOT="example.com"

# 每行一个，各自签发 <域名> + *.<域名>；不需要就留空 SUBS=""
SUBS="
app.example.com
api.example.com
dev.example.com
"

ACMEDNS_BASE_URL="https://auth.acme-dns.io"

ACME_HOME="/opt/acme"
SSL_DIR="/opt/docker-data/nginx/ssl"      # 宿主机上 nginx 读取证书的目录

NGINX_CONTAINER="nginx"
NGINX_SSL_PATH="/etc/nginx/ssl"           # 同一目录在 nginx 容器内的路径
NGINX_PORT="8443"
NGINX_CONF_OUT="/opt/docker-data/nginx/conf.d/acme-ssl.conf"

ACME_IMAGE="neilpang/acme.sh"
DNSSLEEP=120

# acme.sh 容器内自动升级: 0=关闭(推荐) 1=开启
# 容器是 --rm 的, 升级产物不持久化, 开启只会每次 cron 都重新从 GitHub 下载一遍
AUTO_UPGRADE="0"
# ================== 配置区结束 ==================

set -uo pipefail

DATA_DIR="$ACME_HOME/data"
ENV_FILE="$ACME_HOME/acmedns.env"
DOMAINS="$ROOT $SUBS"

C_G='\033[32m'; C_R='\033[31m'; C_Y='\033[33m'; C_0='\033[0m'
ok()   { echo -e "${C_G}$*${C_0}"; }
err()  { echo -e "${C_R}$*${C_0}"; }
warn() { echo -e "${C_Y}$*${C_0}"; }
hr()   { echo "----- $* -----"; }

# 依赖表: 命令|是否必需|缺失时的安装提示|用途
DEPS="
docker|必需|opkg install dockerd docker|运行 acme.sh 容器
dig|必需|opkg install bind-dig|cname 核对解析
openssl|必需|opkg install openssl-util|check 验证证书
sha256sum|必需|opkg install coreutils-sha256sum|renew 判断证书是否更新
tar|可选|opkg install tar|backup 打包
crontab|可选|busybox 自带, 检查 /etc/crontabs|cron 定时续期
"

check_deps() {
  local miss_req=0 c need pkg use path
  printf '%-11s %-8s %-34s %s\n' "命令" "状态" "位置 / 安装方式" "用途"
  echo "$DEPS" | while IFS='|' read -r c need pkg use; do
    [ -z "$c" ] && continue
    path=$(command -v "$c" 2>/dev/null)
    if [ -n "$path" ]; then
      printf "${C_G}%-11s %-8s %-34s %s${C_0}\n" "$c" "OK" "$path" "$use"
    elif [ "$need" = "必需" ]; then
      printf "${C_R}%-11s %-8s %-34s %s${C_0}\n" "$c" "缺失" "$pkg" "$use"
    else
      printf "${C_Y}%-11s %-8s %-34s %s${C_0}\n" "$c" "缺失*" "$pkg" "$use"
    fi
  done

  for c in docker dig openssl sha256sum; do
    command -v "$c" >/dev/null 2>&1 || miss_req=1
  done
  echo
  echo "* 号表示可选依赖，缺失只影响对应子命令"
  if [ "$miss_req" = 1 ]; then
    warn "缺少必需工具，相关子命令会静默失效或报错"
    warn "OpenWrt 25.x / snapshot 请把 opkg install 换成 apk add"
  fi
}

need_docker() {
  command -v docker >/dev/null || { err "未找到 docker"; exit 1; }
}

write_env() {
  [ -f "$ENV_FILE" ] && return
  mkdir -p "$ACME_HOME"
  echo "ACMEDNS_BASE_URL=$ACMEDNS_BASE_URL" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

acme_run() {
  local d="$1"; shift
  docker run --rm -i \
    -v "$DATA_DIR/$d:/acme.sh" \
    -v "$SSL_DIR:/certs" \
    --env-file "$ENV_FILE" \
    "$ACME_IMAGE" "$@"
}

# 解析目标域名：无参数则全部
targets() {
  if [ $# -gt 0 ]; then echo "$*"; else echo "$DOMAINS"; fi
}

# 写入单个域名的 AUTO_UPGRADE
_set_upgrade_one() {
  local d="$1" v="$2" f="$DATA_DIR/$d/account.conf"
  [ -d "$DATA_DIR/$d" ] || return 1
  [ -f "$f" ] || : > "$f"
  if grep -q '^AUTO_UPGRADE=' "$f" 2>/dev/null; then
    sed -i "s/^AUTO_UPGRADE=.*/AUTO_UPGRADE='$v'/" "$f"
  else
    echo "AUTO_UPGRADE='$v'" >> "$f"
  fi
}

# ------------------------------------------------------------
cmd_init() {
  need_docker; write_env
  docker pull "$ACME_IMAGE"
  mkdir -p "$SSL_DIR"
  for d in $(targets "$@"); do
    hr "init $d"
    mkdir -p "$DATA_DIR/$d"
    acme_run "$d" --set-default-ca --server letsencrypt
    _set_upgrade_one "$d" "$AUTO_UPGRADE" \
      && echo "AUTO_UPGRADE=$AUTO_UPGRADE"
  done
  ok "初始化完成"
}

cmd_upgrade() {
  local v="${1:-}"
  case "$v" in
    off|0) v=0 ;;
    on|1)  v=1 ;;
    ""|status)
      printf '%-26s %s\n' "域名" "AUTO_UPGRADE"
      for d in $DOMAINS; do
        local cur
        cur=$(grep '^AUTO_UPGRADE=' "$DATA_DIR/$d/account.conf" 2>/dev/null \
              | head -1 | sed "s/.*='\?\([01]\)'\?.*/\1/")
        case "$cur" in
          0) printf "${C_G}%-26s %s${C_0}\n" "$d" "0 (已关闭)" ;;
          1) printf "${C_Y}%-26s %s${C_0}\n" "$d" "1 (开启, 每次 cron 会联网下载)" ;;
          *) printf "${C_Y}%-26s %s${C_0}\n" "$d" "未设置 (镜像默认为 1)" ;;
        esac
      done
      echo
      echo "用法: $0 upgrade off|on   (配置区 AUTO_UPGRADE=$AUTO_UPGRADE)"
      return 0 ;;
    *) err "用法: $0 upgrade [off|on|status]"; return 1 ;;
  esac
  [ $# -gt 0 ] && shift
  for d in $(targets "$@"); do
    if _set_upgrade_one "$d" "$v"; then
      ok "$d -> AUTO_UPGRADE='$v'"
    else
      warn "$d 数据目录不存在, 跳过"
    fi
  done
}

_issue() {
  local ca="$1"; shift
  need_docker; write_env
  local fail=""
  for d in $(targets "$@"); do
    hr "$d  [$ca]"
    mkdir -p "$DATA_DIR/$d"
    acme_run "$d" --issue --dns dns_acmedns --server "$ca" --force \
      -d "$d" -d "*.$d" --dnssleep "$DNSSLEEP" || fail="$fail $d"
  done
  echo
  if [ -n "$fail" ]; then
    err "失败:$fail"
    warn "若提示 CNAME record，请到 DNS 控制台添加后重跑，再用 cname 子命令核对"
    return 1
  fi
  ok "全部成功"
}

cmd_staging() { _issue letsencrypt_test "$@"; }
cmd_prod()    { _issue letsencrypt      "$@"; }

cmd_cname() {
  if ! command -v dig >/dev/null 2>&1; then
    err "未找到 dig，无法查询当前解析 (opkg install bind-dig)"
    echo
  fi
  printf '%-36s %-46s %s\n' "记录名" "当前解析" "本地已注册"
  for d in $(targets "$@"); do
    local live local_sd
    live=$(dig +short "_acme-challenge.$d" CNAME 2>/dev/null | head -1)
    local_sd=$(grep -h 'ACMEDNS_SUBDOMAIN' \
                 "$DATA_DIR/$d/${d}_ecc/${d}.conf" \
                 "$DATA_DIR/$d/${d}/${d}.conf" 2>/dev/null \
               | head -1 | sed "s/.*='\([^']*\)'.*/\1/")
    [ -n "$local_sd" ] && local_sd="$local_sd.auth.acme-dns.io."
    if [ -n "$live" ] && [ "$live" = "$local_sd" ]; then
      printf "${C_G}%-36s %-46s %s${C_0}\n" "_acme-challenge.$d" "$live" "OK"
    else
      printf "${C_R}%-36s %-46s %s${C_0}\n" "_acme-challenge.$d" "${live:--}" "${local_sd:--}"
    fi
  done
  echo
  echo "主机记录 = 记录名去掉末尾的主域名部分"
}

cmd_install() {
  need_docker
  for d in $(targets "$@"); do
    hr "install $d"
    acme_run "$d" --install-cert -d "$d" \
      --key-file "/certs/$d.key" --fullchain-file "/certs/$d.crt"
  done
  ls -l "$SSL_DIR"
}

cmd_renew() {
  need_docker
  echo "$(date -Is) cron start"
  local before after
  before=$(cat "$SSL_DIR"/*.crt 2>/dev/null | sha256sum)
  for d in $DOMAINS; do
    [ -d "$DATA_DIR/$d" ] || continue
    acme_run "$d" --cron
  done
  after=$(cat "$SSL_DIR"/*.crt 2>/dev/null | sha256sum)
  if [ "$before" != "$after" ]; then
    echo "$(date -Is) renewed, reloading $NGINX_CONTAINER"
    docker exec "$NGINX_CONTAINER" nginx -t \
      && docker exec "$NGINX_CONTAINER" nginx -s reload
  fi
}

cmd_nginx() {
  for d in $DOMAINS; do
    cat <<CONF
server {
    listen $NGINX_PORT ssl;
    listen [::]:$NGINX_PORT ssl;
    http2 on;
    server_name $d *.$d;

    ssl_certificate     $NGINX_SSL_PATH/$d.crt;
    ssl_certificate_key $NGINX_SSL_PATH/$d.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    location / {
        root /usr/share/nginx/html;
        index index.html;
    }
}

CONF
  done
}

cmd_apply() {
  cmd_nginx > "$NGINX_CONF_OUT" || { err "写入失败"; return 1; }
  ok "已写入 $NGINX_CONF_OUT"
  docker exec "$NGINX_CONTAINER" nginx -t \
    && docker exec "$NGINX_CONTAINER" nginx -s reload \
    && ok "nginx 已重载"
}

cmd_check() {
  hr "工具依赖"
  check_deps

  hr "证书文件"
  if ! command -v openssl >/dev/null 2>&1; then
    err "未找到 openssl，跳过证书检查 (opkg install openssl-util)"
    return 1
  fi
  for d in $DOMAINS; do
    local f="$SSL_DIR/$d.crt"
    if [ -f "$f" ]; then
      local exp iss
      exp=$(openssl x509 -in "$f" -noout -enddate | cut -d= -f2)
      iss=$(openssl x509 -in "$f" -noout -issuer)
      if echo "$iss" | grep -qi staging; then
        printf "${C_Y}%-26s %-30s STAGING(测试证书)${C_0}\n" "$d" "$exp"
      else
        printf "${C_G}%-26s %-30s OK${C_0}\n" "$d" "$exp"
      fi
    else
      printf "${C_R}%-26s 缺失${C_0}\n" "$d"
    fi
  done
  echo
  hr "TLS 握手 (SNI, 连接 $ROOT:$NGINX_PORT)"
  for d in $DOMAINS; do
    for h in "$d" "test.$d"; do
      printf '%-34s ' "$h"
      echo | openssl s_client -connect "$ROOT:$NGINX_PORT" -servername "$h" 2>/dev/null \
        | openssl x509 -noout -checkhost "$h" 2>/dev/null || err FAIL
    done
  done
}

cmd_deps() {
  hr "工具依赖"
  check_deps
}

cmd_list() {
  echo "ROOT : $ROOT"
  echo "SUBS :"
  for d in $SUBS; do echo "       $d"; done
  echo
  echo "每个域名签发 <域名> + *.<域名>"
  echo "数据目录 $DATA_DIR/<域名>/"
  echo "证书     $SSL_DIR/<域名>.crt / .key"
}

cmd_backup() {
  local f="$ACME_HOME/acme-backup-$(date +%F-%H%M).tar.gz"
  tar czf "$f" -C "$ACME_HOME" data acmedns.env 2>/dev/null \
    && ok "已备份到 $f" || err "备份失败"
}

cmd_cron() {
  local self line
  self=$(readlink -f "$0")
  line="23 4 * * * $self renew >> $ACME_HOME/renew.log 2>&1"
  if [ -d /etc/crontabs ]; then
    # OpenWrt
    if grep -qF "$self renew" /etc/crontabs/root 2>/dev/null; then
      warn "cron 已存在"
    else
      echo "$line" >> /etc/crontabs/root
      /etc/init.d/cron enable 2>/dev/null
      /etc/init.d/cron restart 2>/dev/null
      ok "已添加: $line"
    fi
  else
    if crontab -l 2>/dev/null | grep -qF "$self renew"; then
      warn "cron 已存在"
    else
      (crontab -l 2>/dev/null; echo "$line") | crontab -
      ok "已添加: $line"
    fi
  fi
}

usage() {
  cat <<'USAGE'
用法: ./acme-mgr.sh <命令> [域名...]
      不指定域名则对配置里的全部域名操作

  list      显示当前配置
  deps      只检查工具依赖
  init      拉镜像、建目录、设默认 CA、写入 AUTO_UPGRADE
  upgrade   查看/设置容器内 acme.sh 自动升级
              upgrade          查看各域名当前状态
              upgrade off      关闭(推荐)
              upgrade on       开启
              upgrade off <域名>  只改指定域名
  staging   用测试 CA 签发(首次会失败并输出需添加的 CNAME)
  cname     核对 DNS 上的 CNAME 与本地注册是否一致
  prod      用正式 CA 签发
  install   配置证书输出路径到 nginx ssl 目录
  nginx     打印 nginx 配置到标准输出
  apply     写入 nginx 配置文件并重载
  check     工具依赖 + 证书有效期 + TLS 握手
  renew     续期(供 cron 调用)
  cron      安装每日 cron
  backup    备份 data 与凭据

首次流程:
  deps → init → staging → (加 CNAME) → cname → staging → prod
       → install → apply → check → cron
USAGE
}

CMD="${1:-}"
[ $# -gt 0 ] && shift
case "$CMD" in
  list)    cmd_list ;;
  deps)    cmd_deps ;;
  init)    cmd_init "$@" ;;
  upgrade) cmd_upgrade "$@" ;;
  staging) cmd_staging "$@" ;;
  prod)    cmd_prod "$@" ;;
  cname)   cmd_cname "$@" ;;
  install) cmd_install "$@" ;;
  nginx)   cmd_nginx ;;
  apply)   cmd_apply ;;
  check)   cmd_check ;;
  renew)   cmd_renew ;;
  cron)    cmd_cron ;;
  backup)  cmd_backup ;;
  *)       usage; exit 1 ;;
esac

#!/usr/bin/env bash
# docker-firefox 一键安装（在 Linux 服务器上以 root 或 sudo 执行）
#   FIREFOX_DIR=/opt/firefox   安装目录
#   FIREFOX_INSTALL_ONLY=1     只写入文件，不安装 Docker、不部署
set -euo pipefail
DIR="${FIREFOX_DIR:-/opt/firefox}"
TTY="${FIREFOX_TTY:-/dev/tty}"
mkdir -p "$DIR" && cd "$DIR"

# 写入文件；内容有变化时先把旧文件改名备份，不直接覆盖手工修改。
install_file() {
    local target="$1" mode="$2" temp saved
    temp="$(mktemp "$target.XXXXXX")"
    cat > "$temp"
    chmod "$mode" "$temp"
    if [ -f "$target" ] && ! cmp -s "$temp" "$target"; then
        saved="$target.$(date +%Y%m%d_%H%M%S).bak"
        mv "$target" "$saved"
        echo "已更新 $target，旧文件保存为 $saved"
    fi
    mv -f "$temp" "$target"
}

# 没有 docker 时，确认后下载官方安装脚本再执行（国内用阿里云镜像源）
if [ "${FIREFOX_INSTALL_ONLY:-0}" != 1 ] && ! command -v docker >/dev/null 2>&1; then
    echo "未检测到 Docker。将下载 https://get.docker.com 官方脚本并以 root 执行（阿里云镜像源）。"
    read -rp "继续？[y/N] " ANSWER <"$TTY"
    case "$ANSWER" in
        y|Y|yes|YES) ;;
        *) echo "已取消。手动安装：https://docs.docker.com/engine/install/" >&2; exit 1 ;;
    esac
    GET_DOCKER="$(mktemp)"
    trap 'rm -f "$GET_DOCKER"' EXIT
    curl -fsSL https://get.docker.com -o "$GET_DOCKER"
    sh "$GET_DOCKER" --mirror Aliyun
    systemctl enable --now docker
fi

install_file compose.yaml 644 <<'EOF_COMPOSE'
# 用法：把本文件和同目录的 .env 放到服务器同一目录，执行 docker compose up -d
# 与仓库 compose.ghcr.yaml 的 services 段保持逐字一致（tests/deploy.test.mjs 校验）。
services:
  firefox:
    # 建议固定为 CI 发布的 :sha-<提交> 标签或 @sha256 digest。
    image: ${FIREFOX_IMAGE:-ghcr.io/5121xiaoge/docker-firefox:latest}
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    labels:
      autoheal: "true"
    stop_grace_period: 30s
    shm_size: ${FIREFOX_SHM_SIZE:-512m}
    mem_limit: ${FIREFOX_MEM_LIMIT:-2g}
    cpus: 1.5
    pids_limit: 512
    ports:
      - "${FIREFOX_BIND_IP:-127.0.0.1}:${FIREFOX_PORT:-5800}:5800"
    volumes:
      - firefox_config:/config
    environment:
      USER_ID: ${USER_ID:-1000}
      GROUP_ID: ${GROUP_ID:-1000}
      TZ: ${TZ:-Asia/Shanghai}
      KEEP_APP_RUNNING: "1"
      SERVICES_GRACETIME: "25000"
      DISPLAY_WIDTH: ${DISPLAY_WIDTH:-1280}
      DISPLAY_HEIGHT: ${DISPLAY_HEIGHT:-720}
      FF_OPEN_URL: ${FF_OPEN_URL:-}
      SECURE_CONNECTION: ${SECURE_CONNECTION:-1}
      WEB_AUTHENTICATION: ${WEB_AUTHENTICATION:-1}
      WEB_AUDIO: "0"
      WEB_FILE_MANAGER: "0"
      WEB_TERMINAL: "0"
      WEB_NOTIFICATION: "0"
      VNC_LISTENING_PORT: "-1"
      FF_PREF_PROC: "dom.ipc.processCount=4"
      FF_PREF_UNLOAD: "browser.tabs.unloadOnLowMemory=true"
      FF_PREF_SESSION: "browser.sessionstore.interval=60000"
      FF_PREF_TELEMETRY: "toolkit.telemetry.enabled=false"
      FF_PREF_HEALTH: "datareporting.healthreport.uploadEnabled=false"
      FF_PREF_STUDIES: "app.shield.optoutstudies.enabled=false"
    healthcheck:
      test: ["CMD", "/usr/share/firefox-tools/healthcheck.sh"]
      interval: 30s
      timeout: 5s
      start_period: 60s
      retries: 3
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "2"


  # Restarts containers labelled autoheal=true when they become unhealthy.
  # Note: needs the Docker socket, which grants control over Docker.
  autoheal:
    image: willfarrell/autoheal:1.2.0
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    environment:
      AUTOHEAL_CONTAINER_LABEL: autoheal
      AUTOHEAL_INTERVAL: "30"
      AUTOHEAL_START_PERIOD: "120"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    mem_limit: 64m
    logging:
      driver: json-file
      options:
        max-size: "1m"
        max-file: "1"


  # Daily live backup of the Firefox profile volume to ./backup (keeps 7, one
  # per weekday).  A failed run never replaces the previous archive.
  backup:
    image: alpine:3.24
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    network_mode: none
    mem_limit: 128m
    volumes:
      - firefox_config:/data:ro
      - ./backup:/backup
    command:
      - sh
      - -c
      - |
        umask 077
        chmod 700 /backup
        while :; do
          N="$$(date +%u)"
          for TRY in 1 2 3; do
            if tar czf /backup/.tmp.tgz -C /data --exclude=profile/cache2 --exclude=profile/startupCache --exclude=xdg/cache .; then
              mv -f /backup/.tmp.tgz "/backup/firefox_config_$$N.tgz"
              break
            fi
            rm -f /backup/.tmp.tgz
            echo "backup attempt $$TRY failed" >&2
            sleep 300
          done
          sleep 86400
        done
    logging:
      driver: json-file
      options:
        max-size: "1m"
        max-file: "1"

volumes:
  firefox_config:
    # 复用旧容器的数据卷（书签、登录状态等）。卷名在 .env 的 FIREFOX_CONFIG_VOLUME 里设置。
    external: true
    name: ${FIREFOX_CONFIG_VOLUME:?set FIREFOX_CONFIG_VOLUME in .env}
EOF_COMPOSE

install_file deploy.sh 755 <<'EOF_DEPLOY'
#!/usr/bin/env bash
# docker-firefox 一键部署：bash deploy.sh
# 需要 compose.yaml、.env 与本脚本在同一目录。
set -euo pipefail
cd "$(dirname "$0")"
TTY="${FIREFOX_TTY:-/dev/tty}"

say()  { printf '\033[1;32m>>> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!!! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mXXX %s\033[0m\n' "$*" >&2; exit 1; }

command -v docker >/dev/null || die "未安装 docker"
docker compose version >/dev/null 2>&1 || die "需要 Docker Compose v2（docker compose）"
[ -f compose.yaml ] || die "缺少 compose.yaml"
[ -f .env ] || die "缺少 .env"

# 去掉 Windows 换行，收紧权限
sed -i 's/\r$//' .env compose.yaml
chmod 600 .env

# 键不存在时输出空串并返回 0（grep 无匹配会在 set -e/pipefail 下中断脚本）。
getenv() { sed -n "s/^$1=//p" .env | tail -n1 | sed -e "s/^'//" -e "s/'$//" -e 's/^"//' -e 's/"$//'; }
setenv() {
    if grep -qE "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else echo "$1=$2" >> .env; fi
}

# 旧版把明文密码写在 .env；现在账号以 bcrypt 哈希保存在数据卷，compose 不再读取这两项。
LEGACY_USER="$(getenv WEB_AUTHENTICATION_USERNAME)"
LEGACY_PASSWORD="$(getenv WEB_AUTHENTICATION_PASSWORD)"
LEGACY_FIXED=0
if [ -n "$LEGACY_PASSWORD" ]; then
    warn ".env 中的 WEB_AUTHENTICATION_USERNAME/PASSWORD 已不再使用，账号已保存在数据卷；确认能登录后请删除这两行。"
    case "$LEGACY_PASSWORD" in
        *REDACTED*)
            LEGACY_FIXED=1
            warn "v1.1 安装脚本写入的是固定字符串而不是你输入的密码，部署完成后需要重设密码。" ;;
    esac
fi
unset LEGACY_PASSWORD

# 1. 确定数据卷
VOL="$(getenv FIREFOX_CONFIG_VOLUME)"
if [ -z "$VOL" ]; then
    mapfile -t FOUND < <(docker volume ls -q | grep -E '(^|_)firefox_config$' || true)
    case "${#FOUND[@]}" in
        0) VOL=firefox_config; say "没找到旧数据卷，新建 $VOL"; docker volume create "$VOL" >/dev/null ;;
        1) VOL="${FOUND[0]}"; say "找到旧数据卷：$VOL" ;;
        *) die "找到多个数据卷：${FOUND[*]}，请在 .env 里填写 FIREFOX_CONFIG_VOLUME" ;;
    esac
    setenv FIREFOX_CONFIG_VOLUME "$VOL"
else
    docker volume inspect "$VOL" >/dev/null 2>&1 || die "数据卷 $VOL 不存在"
    say "使用数据卷：$VOL"
fi

# 2. 先拉镜像（失败就不动旧容器）
say "拉取镜像..."
docker compose config --quiet
if ! docker compose pull; then
    die "拉取失败。镜像是私有的话先执行：docker login ghcr.io -u 5121xiaoge"
fi

# 3. 停掉所有使用这个数据卷的容器，保证备份时 Firefox 没有在写数据库。
#    项目名取 Compose 自己算出的值（会去掉特殊字符，也受 COMPOSE_PROJECT_NAME 影响）。
PROJECT="$(docker compose config 2>/dev/null | sed -n '1s/^name: *//p')"
PROJECT="${PROJECT:-$(basename "$PWD" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')}"
STOPPED=()
declare -A POLICY=()
# 已停止的旧容器也要改成不自动重启，否则 Docker 重启后会和新容器抢同一个配置目录。
for C in $(docker ps -aq --filter "volume=$VOL"); do
    P="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$C")"
    if [ "$P" != "$PROJECT" ]; then
        POLICY[$C]="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}{{with .HostConfig.RestartPolicy.MaximumRetryCount}}:{{.}}{{end}}' "$C")"
        warn "停用旧容器 $(docker inspect -f '{{.Name}}' "$C" | tr -d /)（只停止不删除，可回滚）"
        docker update --restart=no "$C" >/dev/null
    fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$C")" = true ]; then
        docker stop -t 30 "$C" >/dev/null
        STOPPED+=("$C")
    fi
done

# 恢复旧容器的重启策略并重新启动它们
restore_old() {
    local C
    if [ "${#POLICY[@]}" -gt 0 ]; then
        for C in "${!POLICY[@]}"; do docker update --restart="${POLICY[$C]:-no}" "$C" >/dev/null || true; done
    fi
    [ "${#STOPPED[@]}" -eq 0 ] || docker start "${STOPPED[@]}" >/dev/null || true
}

# 4. 停机备份数据卷（权限 600，排除缓存；只保留最近 5 份，不影响每日备份 firefox_config_<1-7>.tgz）
BACKUP="backup/firefox_config_deploy_$(date +%Y%m%d_%H%M%S).tgz"
mkdir -p backup && chmod 700 backup
say "备份数据卷到 $BACKUP"
if ! docker run --rm --network none -v "$VOL":/data:ro -v "$PWD/backup":/backup alpine:3.24 \
        sh -c 'umask 077 && tar czf "/backup/$1" -C /data --exclude=profile/cache2 --exclude=profile/startupCache --exclude=xdg/cache .' \
        sh "$(basename "$BACKUP")"; then
    rm -f "$BACKUP"
    restore_old
    die "备份失败，已重新启动原来的容器，没有部署新版本"
fi
ls -1t backup/firefox_config_deploy_*.tgz 2>/dev/null | tail -n +6 | xargs -r rm -f

# 5. 启动
say "启动容器..."
docker compose up -d --remove-orphans

# 6. 等待健康检查
CID="$(docker compose ps -q firefox)"
printf '等待健康检查'
for i in $(seq 1 60); do
    S="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$CID")"
    [ "$S" = healthy ] && break
    [ "$S" = unhealthy ] && break
    printf '.'; sleep 3
done
echo
docker compose ps
if [ "$S" != healthy ]; then
    docker compose logs --tail=80
    if [ "${#POLICY[@]}" -gt 0 ]; then
        warn "回滚：先执行 docker compose down，再恢复旧容器："
        for C in "${!POLICY[@]}"; do warn "  docker update --restart=${POLICY[$C]:-no} $C && docker start $C"; done
    fi
    die "容器状态：$S。旧数据备份在 $BACKUP"
fi

# 7. 网页登录用户（bcrypt 哈希保存在数据卷的 /config/webauth-htpasswd，不写入 .env）
# webauth-user 出错时把 "ERROR: ..." 打到 stdout，这里过滤掉，避免误判为已有用户。
web_users() { docker compose exec -T firefox webauth-user list 2>/dev/null | grep -v '^ERROR:' || true; }
# add/update 需要交互终端（htpasswd 读两次密码）；没有终端或失败时返回 1
web_password() {
    if [ -n "$2" ] && { : <"$TTY"; } 2>/dev/null; then
        say "为网页登录用户 $2 设置密码（输入时不显示）"
        docker compose exec firefox webauth-user "$1" "$2" <"$TTY" && return 0
    fi
    warn "请执行：docker compose exec firefox webauth-user $1 ${2:-<用户名>}"
    return 1
}
case "$(getenv WEB_AUTHENTICATION | tr '[:upper:]' '[:lower:]')" in
    0|false|no|off|n|f) ;;
    *)
        USERS="$(web_users)"
        if [ -z "$USERS" ]; then
            U="$(getenv WEBAUTH_USER)"
            web_password add "${U:-$LEGACY_USER}" || true
        elif [ "$LEGACY_FIXED" = 1 ] && printf '%s\n' "$USERS" | grep -qxF -- "$LEGACY_USER"; then
            # v1.1 的固定密码已随源码公开：重设失败就删除该用户，宁可暂时无法登录。
            if ! web_password update "$LEGACY_USER"; then
                docker compose exec -T firefox webauth-user del "$LEGACY_USER" >/dev/null ||
                    die "无法删除使用公开固定密码的用户 $LEGACY_USER，请立即手动执行上面的 update 命令"
                warn "已删除使用公开固定密码的用户 $LEGACY_USER；执行 docker compose exec firefox webauth-user add $LEGACY_USER 重新设置"
            fi
        fi
        if [ "$LEGACY_FIXED" = 1 ]; then
            # 固定字符串已不再有效，从 .env 删除；用户名转存为 WEBAUTH_USER。
            [ -n "$(getenv WEBAUTH_USER)" ] || [ -z "$LEGACY_USER" ] || setenv WEBAUTH_USER "$LEGACY_USER"
            sed -i -e '/^WEB_AUTHENTICATION_USERNAME=/d' -e '/^WEB_AUTHENTICATION_PASSWORD=/d' .env
        fi
        ;;
esac

PORT="$(getenv FIREFOX_PORT)"; PORT="${PORT:-5800}"
say "部署完成 ✅  访问：ssh -L $PORT:127.0.0.1:$PORT <用户>@<服务器>，然后打开 https://localhost:$PORT"
EOF_DEPLOY

# 第一次运行时生成 .env。密码不写入 .env：部署成功后由 deploy.sh 调用 webauth-user 设置。
if [ ! -f .env ]; then
    exec 3<"$TTY"
    while :; do
        read -rp "网页登录用户名（字母、数字和 . _ @ -）: " U <&3
        case "$U" in
            ''|*[!A-Za-z0-9._@-]*) echo "用户名不能为空，只能包含字母、数字和 . _ @ -" ;;
            *) [ "${#U}" -le 64 ] && break; echo "用户名最长 64 个字符" ;;
        esac
    done
    exec 3<&-
    (umask 077 && cat > .env <<EOF_ENV
FIREFOX_IMAGE=ghcr.io/5121xiaoge/docker-firefox:latest
FIREFOX_CONFIG_VOLUME=
FIREFOX_BIND_IP=127.0.0.1
FIREFOX_PORT=5800
FIREFOX_MEM_LIMIT=2g
FIREFOX_SHM_SIZE=512m
USER_ID=1000
GROUP_ID=1000
TZ=Asia/Shanghai
DISPLAY_WIDTH=1280
DISPLAY_HEIGHT=720
FF_OPEN_URL=
SECURE_CONNECTION=1
WEB_AUTHENTICATION=1
WEBAUTH_USER=$U
EOF_ENV
    )
fi

if [ "${FIREFOX_INSTALL_ONLY:-0}" = 1 ]; then
    echo "文件已写入 $DIR；检查后执行：bash $DIR/deploy.sh"
    exit 0
fi
bash ./deploy.sh

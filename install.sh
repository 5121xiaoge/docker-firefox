#!/usr/bin/env bash
# docker-firefox 一键安装（在 Linux 服务器上以 root 或 sudo 执行）
set -euo pipefail
DIR=/opt/firefox
mkdir -p "$DIR" && cd "$DIR"

# 没有 docker 就自动安装（国内用阿里云镜像源）
if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh -s -- --mirror Aliyun
    systemctl enable --now docker
fi

cat > compose.yaml <<'EOF_COMPOSE'
# 用法：把本文件和同目录的 .env 放到服务器同一目录，执行 docker compose up -d
# 检查配置：docker compose config（会显示密码，注意别截图外发）
services:
  firefox:
    image: ${FIREFOX_IMAGE:?set FIREFOX_IMAGE in .env}
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
      DISPLAY_WIDTH: ${DISPLAY_WIDTH:-1280}
      DISPLAY_HEIGHT: ${DISPLAY_HEIGHT:-720}
      FF_OPEN_URL: ${FF_OPEN_URL:-}
      SECURE_CONNECTION: ${SECURE_CONNECTION:-1}
      WEB_AUTHENTICATION: ${WEB_AUTHENTICATION:-1}
      WEB_AUTHENTICATION_USERNAME: ${WEB_AUTHENTICATION_USERNAME:?set in .env}
      WEB_AUTHENTICATION_PASSWORD: ${WEB_AUTHENTICATION_PASSWORD:?set in .env}
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


  # Daily backup of the Firefox profile volume to ./backup (keeps 7, one per weekday).
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
        while :; do
          N="$$(date +%u)"
          if tar czf /backup/.tmp.tgz -C /data . 2>/dev/null || [ $$? -eq 1 ]; then
            mv -f /backup/.tmp.tgz "/backup/firefox_config_$$N.tgz"
          fi
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

cat > deploy.sh <<'EOF_DEPLOY'
#!/usr/bin/env bash
# docker-firefox 一键部署：bash deploy.sh
# 需要 compose.yaml、.env 与本脚本在同一目录。
set -euo pipefail
cd "$(dirname "$0")"

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

getenv() { grep -E "^$1=" .env | tail -n1 | cut -d= -f2- | sed -e "s/^'//" -e "s/'$//" -e 's/^"//' -e 's/"$//'; }
setenv() {
    if grep -qE "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else echo "$1=$2" >> .env; fi
}

[ -n "$(getenv WEB_AUTHENTICATION_USERNAME)" ] || die ".env 里 WEB_AUTHENTICATION_USERNAME 为空"
[ -n "$(getenv WEB_AUTHENTICATION_PASSWORD)" ] || die ".env 里 WEB_AUTHENTICATION_PASSWORD 为空"

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

# 3. 备份数据卷
BACKUP="backup/firefox_config_$(date +%Y%m%d_%H%M%S).tgz"
mkdir -p backup
say "备份数据卷到 $BACKUP"
docker run --rm -v "$VOL":/data:ro -v "$PWD/backup":/backup alpine \
    tar czf "/backup/$(basename "$BACKUP")" -C /data .
ls -1t backup/*.tgz 2>/dev/null | tail -n +6 | xargs -r rm -f   # 只保留最近 5 份

# 4. 停掉正在使用这个数据卷、但不属于本项目的旧容器
PROJECT="$(basename "$PWD" | tr '[:upper:]' '[:lower:]')"
for C in $(docker ps -q --filter "volume=$VOL"); do
    P="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$C")"
    if [ "$P" != "$PROJECT" ]; then
        warn "停止旧容器 $(docker inspect -f '{{.Name}}' "$C" | tr -d /)（只停止不删除，可回滚）"
        docker update --restart=no "$C" >/dev/null
        docker stop -t 30 "$C" >/dev/null
    fi
done

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
    die "容器状态：$S。旧数据备份在 $BACKUP"
fi

PORT="$(getenv FIREFOX_PORT)"; PORT="${PORT:-5800}"
say "部署完成 ✅  访问：ssh -L $PORT:127.0.0.1:$PORT <用户>@<服务器>，然后打开 https://localhost:$PORT"
EOF_DEPLOY
chmod +x deploy.sh

# 第一次运行时交互式生成 .env（密码不会显示在屏幕上）
if [ ! -f .env ]; then
    read -rp "网页登录用户名: " U </dev/tty
    while :; do
        read -rsp "网页登录密码: " P </dev/tty; echo
        read -rsp "再输入一次: " P2 </dev/tty; echo
        [ "$P" = "$P2" ] || { echo "两次不一致"; continue; }
        [ -n "$P" ] || { echo "密码不能为空"; continue; }
        case "$P$U" in *"'"*) echo "不能包含单引号 '"; continue;; esac
        break
    done
    umask 077
    cat > .env <<EOF_ENV
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
WEB_AUTHENTICATION_USERNAME='$U'
WEB_AUTHENTICATION_PASSWORD='$P'
EOF_ENV
    unset P P2
fi

bash ./deploy.sh

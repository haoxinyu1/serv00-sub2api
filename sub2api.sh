#!/bin/sh

export TZ=Asia/Shanghai

SCRIPT_PATH=$(realpath "$0" 2>/dev/null)
if [ -z "$SCRIPT_PATH" ]; then
    case "$0" in
        /*) SCRIPT_PATH="$0" ;;
        *) SCRIPT_PATH="$(pwd)/$0" ;;
    esac
fi

SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
APP_DIR="$SCRIPT_DIR/sub2api"
APP_NAME="sub2api"
APP_BIN="$APP_DIR/$APP_NAME"
CONFIG_FILE="$APP_DIR/config.yaml"
REDIS_CONF="$APP_DIR/redis.conf"
LOG_DIR="$APP_DIR/logs"
DATA_DIR="$APP_DIR/data"
WATCH_LOG="$LOG_DIR/watchdog.log"
REDIS_LOG="$LOG_DIR/redis.log"
VERSION_FILE="$APP_DIR/current_version.txt"
DOWNLOAD_PATH="$APP_DIR/${APP_NAME}.tar.gz"
EXTRACT_DIR="$APP_DIR/${APP_NAME}_extract"
TEMP_JSON="$APP_DIR/${APP_NAME}_release.json"
CRON_ENTRY="*/2 * * * * nohup $SCRIPT_PATH >/dev/null 2>&1"

GITHUB_PROJECT='KiritoXDone/Sub2API-Freebsd'
PORT='6789'
REDIS_PORT='2345'
REDIS_DATA_DIR="$APP_DIR/redis"

mkdir -p "$APP_DIR"
mkdir -p "$LOG_DIR" "$DATA_DIR" "$REDIS_DATA_DIR"
cd "$APP_DIR" || exit 1

log() {
    timestamp="[$(date '+%Y-%m-%d %H:%M:%S')]"
    echo "$timestamp $1"
    echo "$timestamp $1" >> "$WATCH_LOG"
}

cleanup_temp_files() {
    rm -f "$DOWNLOAD_PATH" "$TEMP_JSON"
    rm -rf "$EXTRACT_DIR"
}

generate_hex_secret() {
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -hex 32 2>/dev/null
        return 0
    fi

    if command -v dd >/dev/null 2>&1 && [ -r /dev/urandom ]; then
        dd if=/dev/urandom bs=32 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n'
        return 0
    fi

    date +%s | sha256 2>/dev/null | awk '{print $1}'
}

is_interactive() {
    [ -e /dev/tty ] && [ -r /dev/tty ] && [ -w /dev/tty ]
}

prompt_value() {
    prompt_text="$1"
    default_value="$2"
    target_var="$3"

    printf "%s [%s]: " "$prompt_text" "$default_value" > /dev/tty
    IFS= read -r input_value < /dev/tty

    if [ -z "$input_value" ]; then
        input_value="$default_value"
    fi

    eval "$target_var=\"\$input_value\""
}

prompt_required_value() {
    prompt_text="$1"
    default_value="$2"
    target_var="$3"

    while :; do
        prompt_value "$prompt_text" "$default_value" "$target_var"
        eval "current_value=\${$target_var}"
        if [ -n "$current_value" ]; then
            break
        fi
        echo "该项不能为空，请重新输入。" > /dev/tty
    done
}

set_default_config_values() {
    CFG_SERVER_PORT=""
    CFG_REDIS_PORT="$REDIS_PORT"
    CFG_REDIS_PASSWORD="please_replace_with_your_redis_password"
}

collect_interactive_config() {
    set_default_config_values

    echo "" > /dev/tty
    echo "===== Sub2API 首次初始化 =====" > /dev/tty
    echo "本脚本只准备 Redis 和运行环境，不预生成 config.yaml。" > /dev/tty
    echo "随后会按你指定的端口启动官方 Setup Wizard，请在浏览器中完成数据库、前端地址和管理员初始化。" > /dev/tty
    echo "" > /dev/tty

    prompt_required_value "Sub2API 服务端口" "$CFG_SERVER_PORT" CFG_SERVER_PORT
    prompt_value "Redis 端口" "$CFG_REDIS_PORT" CFG_REDIS_PORT
    prompt_value "Redis 密码" "$CFG_REDIS_PASSWORD" CFG_REDIS_PASSWORD

    PORT="$CFG_SERVER_PORT"
    REDIS_PORT="$CFG_REDIS_PORT"
}

redis_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

write_redis_file() {
    redis_port="$1"
    redis_password="$2"

    mkdir -p "$REDIS_DATA_DIR"

    esc_redis_password=$(redis_escape "$redis_password")

    cat > "$REDIS_CONF" <<EOF
# Redis 配置文件
#
# 首次初始化由脚本生成。
# 如需修改端口或密码，请同步更新 config.yaml 中的 redis 配置。

# 监听地址
# 默认仅监听本机，更适合当前 serv00 + 反代部署方式
# 如果你后续确实需要远程连 Redis，再手动改成 0.0.0.0
bind 127.0.0.1

# Redis 监听端口
port ${redis_port}

# 建议开启密码保护，并与 config.yaml 中的 redis.password 保持一致
requirepass "${esc_redis_password}"

# 允许远程访问时通常需要关闭保护模式，否则外部可能连不上
protected-mode no

# 允许后台运行，方便脚本用 nohup 拉起
daemonize yes

# 日志级别
loglevel notice

# 数据目录，必须事先存在且当前用户可写
dir ${REDIS_DATA_DIR}

# 最小化持久化配置
save ""
appendonly no
EOF
}

interactive_first_setup() {
    collect_interactive_config
    write_redis_file "$CFG_REDIS_PORT" "$CFG_REDIS_PASSWORD"
    log "首次运行：已根据交互内容生成 $REDIS_CONF"
    return 0
}

ensure_initial_templates() {
    if [ ! -f "$REDIS_CONF" ]; then
        if is_interactive; then
            interactive_first_setup
            return 0
        fi

        log "当前为无交互环境，且缺少 $APP_DIR/redis.conf；跳过启动。请先手动执行 $SCRIPT_PATH 完成交互初始化"
        return 1
    fi

    return 0
}

needs_official_setup() {
    [ ! -f "$CONFIG_FILE" ] || [ ! -f "$APP_DIR/.installed" ]
}

start_official_setup() {
    if [ ! -x "$APP_BIN" ]; then
        log "首次安装：本地未找到 $APP_NAME，先下载最新版本"
        install_latest_release
        download_result=$?
        if [ "$download_result" -ne 0 ] && [ "$download_result" -ne 2 ]; then
            log "错误：下载 $APP_NAME 失败，无法启动 Setup Wizard"
            return 1
        fi
    fi

    if [ ! -x "$APP_BIN" ]; then
        log "错误：未找到可执行文件 $APP_BIN"
        return 1
    fi

    if check_port; then
        log "端口 $PORT 已被占用，无法启动 Setup Wizard"
        return 1
    fi

    export SERVER_HOST="127.0.0.1"
    export SERVER_PORT="$PORT"

    log "启动官方 Setup Wizard，监听 127.0.0.1:$PORT"
    nohup "$APP_BIN" >/dev/null 2>&1 &
    sleep 3

    if check_port; then
        log "官方 Setup Wizard 已启动，请通过反代域名或本机端口完成初始化"
        return 0
    fi

    log "错误：官方 Setup Wizard 启动失败"
    return 1
}

read_local_version() {
    if [ -f "$VERSION_FILE" ]; then
        cat "$VERSION_FILE"
    else
        echo ""
    fi
}

check_port() {
    sockstat -4l 2>/dev/null | grep -q ":${PORT}"
}

check_redis_port() {
    sockstat -4l 2>/dev/null | grep -q ":${REDIS_PORT}"
}

is_sub2api_running() {
    pgrep -f "$APP_BIN" >/dev/null 2>&1
}

is_redis_running() {
    pgrep -f "redis-server.*${REDIS_CONF}" >/dev/null 2>&1 || check_redis_port
}

stop_sub2api() {
    if is_sub2api_running; then
        log "停止 $APP_NAME 进程"
        pkill -f "$APP_BIN" >/dev/null 2>&1 || true
        sleep 2
        if is_sub2api_running; then
            pkill -9 -f "$APP_BIN" >/dev/null 2>&1 || true
            sleep 1
        fi
    fi
}

stop_redis() {
    if is_redis_running; then
        log "停止 Redis 进程"
        pkill -f "redis-server.*${REDIS_CONF}" >/dev/null 2>&1 || true
        sleep 2
        if is_redis_running; then
            pkill -9 -f "redis-server.*${REDIS_CONF}" >/dev/null 2>&1 || true
            sleep 1
        fi
    fi
}

start_redis() {
    if [ ! -f "$REDIS_CONF" ]; then
        log "警告：未找到 redis.conf，跳过 Redis 启动"
        return 0
    fi

    if is_redis_running; then
        log "Redis 已在运行"
        return 0
    fi

    log "启动 Redis"
    nohup redis-server "$REDIS_CONF" >> "$REDIS_LOG" 2>&1 &
    sleep 2

    if is_redis_running; then
        log "Redis 启动成功"
        return 0
    fi

    log "错误：Redis 启动失败"
    return 1
}

start_sub2api() {
    if [ ! -x "$APP_BIN" ]; then
        log "错误：未找到可执行文件 $APP_BIN"
        return 1
    fi

    if needs_official_setup; then
        log "检测到尚未完成官方安装，转为启动 Setup Wizard"
        start_official_setup
        return $?
    fi

    if is_sub2api_running; then
        log "$APP_NAME 已在运行"
        return 0
    fi

    log "启动 $APP_NAME"
    nohup "$APP_BIN" >/dev/null 2>&1 &
    sleep 3

    if is_sub2api_running || check_port; then
        log "$APP_NAME 启动成功"
        return 0
    fi

    log "错误：$APP_NAME 启动失败"
    return 1
}

restart_services() {
    stop_sub2api
    stop_redis

    start_redis || return 1
    start_sub2api || return 1
    return 0
}

fetch_release_info() {
    API_URL="https://api.github.com/repos/${GITHUB_PROJECT}/releases/latest"

    log "检查 GitHub 最新版本"
    if ! curl -fsSL "$API_URL" -o "$TEMP_JSON"; then
        log "错误：获取发布信息失败"
        return 1
    fi

    LATEST_TAG=$(jq -r '.tag_name' "$TEMP_JSON")
    ASSET_URL=$(jq -r '.assets[] | select(.name | test("^sub2api_.*_freebsd_amd64\\.tar\\.gz$")) | .browser_download_url' "$TEMP_JSON" | head -n 1)

    if [ -z "$LATEST_TAG" ] || [ "$LATEST_TAG" = "null" ]; then
        log "错误：无法解析最新版本号"
        return 1
    fi

    if [ -z "$ASSET_URL" ] || [ "$ASSET_URL" = "null" ]; then
        log "错误：未找到 freebsd_amd64 安装包"
        return 1
    fi

    return 0
}

install_latest_release() {
    LOCAL_VERSION=$(read_local_version)

    fetch_release_info || return 1

    if [ "$LATEST_TAG" = "$LOCAL_VERSION" ] && [ -x "$APP_BIN" ]; then
        log "当前已是最新版本：$LATEST_TAG"
        return 2
    fi

    log "发现新版本：$LATEST_TAG"
    log "下载更新包"
    if ! curl -fL "$ASSET_URL" -o "$DOWNLOAD_PATH"; then
        log "错误：下载更新包失败"
        cleanup_temp_files
        return 1
    fi

    rm -rf "$EXTRACT_DIR"
    mkdir -p "$EXTRACT_DIR"

    log "解压更新包"
    if ! tar -xzf "$DOWNLOAD_PATH" -C "$EXTRACT_DIR"; then
        log "错误：解压失败"
        cleanup_temp_files
        return 1
    fi

    if [ ! -f "$EXTRACT_DIR/$APP_NAME" ]; then
        log "错误：压缩包内未找到 $APP_NAME"
        cleanup_temp_files
        return 1
    fi

    chmod +x "$EXTRACT_DIR/$APP_NAME"
    mv -f "$EXTRACT_DIR/$APP_NAME" "$APP_BIN"
    if [ $? -ne 0 ]; then
        log "错误：替换二进制失败"
        cleanup_temp_files
        return 1
    fi

    echo "$LATEST_TAG" > "$VERSION_FILE"
    cleanup_temp_files
    log "更新完成：$LATEST_TAG"
    return 0
}

check_running_and_restart_if_needed() {
    if check_port && is_sub2api_running; then
        log "$APP_NAME 运行正常"
        if is_redis_running; then
            log "Redis 运行正常"
        else
            log "Redis 未运行，执行补启动"
            start_redis || return 1
        fi
        return 0
    fi

    log "检测到服务异常，执行重启"
    restart_services
}

clean_logs() {
    if [ -f "$WATCH_LOG" ]; then
        tail -n 10000 "$WATCH_LOG" > "$WATCH_LOG.tmp" && mv "$WATCH_LOG.tmp" "$WATCH_LOG"
    fi
    if [ -f "$REDIS_LOG" ]; then
        tail -n 10000 "$REDIS_LOG" > "$REDIS_LOG.tmp" && mv "$REDIS_LOG.tmp" "$REDIS_LOG"
    fi
}

ensure_crontab() {
    crontab -l 2>/dev/null | grep -qF "$CRON_ENTRY"
    if [ $? -ne 0 ]; then
        (crontab -l 2>/dev/null; echo "$CRON_ENTRY") | crontab -
        log "已写入 crontab 定时巡检任务"
    else
        log "crontab 定时巡检任务已存在"
    fi
}

show_status() {
    if is_sub2api_running; then
        log "$APP_NAME 进程存在"
    else
        log "$APP_NAME 进程不存在"
    fi

    if check_port; then
        log "端口 $PORT 正在监听"
    else
        log "端口 $PORT 未监听"
    fi

    if is_redis_running; then
        log "Redis 进程存在"
    else
        log "Redis 进程不存在"
    fi
}

run_watchdog() {
    ensure_initial_templates || return 0

    if needs_official_setup; then
        log "检测到尚未完成官方安装，启动 Setup Wizard"
        start_redis || return 1
        start_official_setup || return 1
        clean_logs
        ensure_crontab
        return 0
    fi

    install_latest_release
    update_result=$?

    if [ "$update_result" -eq 0 ]; then
        log "检测到更新，重启服务"
        restart_services || return 1
    elif [ "$update_result" -eq 2 ]; then
        check_running_and_restart_if_needed || return 1
    else
        log "更新检查失败，转为仅检查运行状态"
        check_running_and_restart_if_needed || return 1
    fi

    clean_logs
    ensure_crontab
    return 0
}

case "$1" in
    start)
        ensure_initial_templates || exit 0
        start_redis && start_sub2api
        ;;
    stop)
        stop_sub2api
        stop_redis
        ;;
    restart)
        ensure_initial_templates || exit 0
        restart_services
        ;;
    update)
        ensure_initial_templates || exit 0
        install_latest_release
        result=$?
        if [ "$result" -eq 0 ]; then
            restart_services
        elif [ "$result" -eq 2 ]; then
            log "无需更新"
            exit 0
        else
            exit 1
        fi
        ;;
    status)
        show_status
        ;;
    init)
        ensure_initial_templates || exit 0
        log "配置文件已存在，无需重新生成"
        ;;
    "")
        run_watchdog
        ;;
    *)
        echo "用法: $0 [start|stop|restart|update|status|init]"
        exit 1
        ;;
esac

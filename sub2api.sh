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
REDIS_DATA_DIR="$APP_DIR/redis"
WATCH_LOG="$LOG_DIR/watchdog.log"
REDIS_LOG="$LOG_DIR/redis.log"
VERSION_FILE="$APP_DIR/current_version.txt"
DESIRED_PORT_FILE="$APP_DIR/desired_server_port.txt"
DOWNLOAD_PATH="$APP_DIR/${APP_NAME}.tar.gz"
EXTRACT_DIR="$APP_DIR/${APP_NAME}_extract"
TEMP_JSON="$APP_DIR/${APP_NAME}_release.json"
CRON_ENTRY="*/2 * * * * nohup $SCRIPT_PATH >/dev/null 2>&1"

GITHUB_PROJECT='KiritoXDone/Sub2API-Freebsd'
PORT=''
REDIS_PORT=''

mkdir -p "$APP_DIR" "$LOG_DIR" "$DATA_DIR" "$REDIS_DATA_DIR"
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

redis_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

extract_yaml_scalar() {
    key_path="$1"
    file_path="$2"

    awk -v target="$key_path" '
        function trim(s) {
            gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", s)
            return s
        }
        {
            raw=$0
            indent=match(raw, /[^ ]/) - 1
            if (indent < 0) indent = 0
            line=trim(raw)
            if (line == "" || line ~ /^#/) next
            if (line !~ /:/) next

            split(line, kv, ":")
            value=substr(line, index(line, ":") + 1)
            value=trim(value)

            level=int(indent / 2)
            key=trim(kv[1])
            path[level]=key
            for (i in path) {
                if (i > level) delete path[i]
            }

            current=path[0]
            for (i=1; i<=level; i++) {
                if (path[i] != "") current=current "." path[i]
            }

            if (current == target && value != "") {
                if (value ~ /^".*"$/) value=substr(value, 2, length(value)-2)
                if (value ~ /^\047.*\047$/) value=substr(value, 2, length(value)-2)
                print value
                exit
            }
        }
    ' "$file_path"
}

read_desired_port() {
    if [ -f "$DESIRED_PORT_FILE" ]; then
        desired_port=$(tr -d ' \r\n' < "$DESIRED_PORT_FILE")
        if [ -n "$desired_port" ]; then
            printf '%s' "$desired_port"
            return 0
        fi
    fi
    printf '%s' "$PORT"
}

write_desired_port() {
    printf '%s\n' "$1" > "$DESIRED_PORT_FILE"
}

sync_runtime_ports() {
    desired_port=$(read_desired_port)
    if [ -n "$desired_port" ]; then
        PORT="$desired_port"
    fi

    if [ -f "$CONFIG_FILE" ]; then
        config_redis_port=$(extract_yaml_scalar "redis.port" "$CONFIG_FILE")
        if [ -n "$config_redis_port" ]; then
            REDIS_PORT="$config_redis_port"
        fi
    fi
}

validate_runtime_port() {
    case "$PORT" in
        ''|*[!0-9]*)
            log "错误：server.port 不是有效数字：$PORT"
            return 1
            ;;
    esac

    if [ "$PORT" -lt 1024 ]; then
        log "错误：当前配置的 server.port=$PORT，小于 1024。serv00 普通用户无权监听该端口，请改成 1024 以上端口，例如 6789"
        return 1
    fi

    return 0
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

is_bootstrap_initialized() {
    [ -f "$REDIS_CONF" ] && [ -f "$DESIRED_PORT_FILE" ]
}

is_installed() {
    [ -f "$CONFIG_FILE" ] && [ -f "$APP_DIR/.installed" ]
}

write_redis_conf() {
    redis_port="$1"
    redis_password="$2"
    esc_redis_password=$(redis_escape "$redis_password")

    cat > "$REDIS_CONF" <<EOF
# Redis 配置文件
bind 127.0.0.1
port ${redis_port}
requirepass "${esc_redis_password}"
protected-mode no
daemonize yes
loglevel notice
dir ${REDIS_DATA_DIR}
save ""
appendonly no
EOF
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

install_latest_release() {
    local_version=""
    if [ -f "$VERSION_FILE" ]; then
        local_version=$(tr -d ' \r\n' < "$VERSION_FILE")
    fi

    api_url="https://api.github.com/repos/${GITHUB_PROJECT}/releases/latest"
    log "检查 GitHub 最新版本"
    if ! curl -fsSL "$api_url" -o "$TEMP_JSON"; then
        log "错误：获取发布信息失败"
        return 1
    fi

    latest_tag=$(jq -r '.tag_name' "$TEMP_JSON")
    asset_url=$(jq -r '.assets[] | select(.name | test("^sub2api_.*_freebsd_amd64\\.tar\\.gz$")) | .browser_download_url' "$TEMP_JSON" | head -n 1)

    if [ -z "$latest_tag" ] || [ "$latest_tag" = "null" ]; then
        log "错误：无法解析最新版本号"
        return 1
    fi

    if [ -z "$asset_url" ] || [ "$asset_url" = "null" ]; then
        log "错误：未找到 freebsd_amd64 安装包"
        return 1
    fi

    if [ "$latest_tag" = "$local_version" ] && [ -x "$APP_BIN" ]; then
        log "当前已是最新版本：$latest_tag"
        return 2
    fi

    log "发现新版本：$latest_tag"
    log "下载更新包"
    if ! curl -fL "$asset_url" -o "$DOWNLOAD_PATH"; then
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

    printf '%s\n' "$latest_tag" > "$VERSION_FILE"
    cleanup_temp_files
    log "更新完成：$latest_tag"
    return 0
}

wait_for_sub2api_start() {
    started=0
    i=0
    while [ "$i" -lt 10 ]; do
        sleep 1
        if is_sub2api_running || check_port; then
            started=1
            break
        fi
        i=$((i + 1))
    done

    if [ "$started" -eq 1 ]; then
        return 0
    fi
    return 1
}

start_sub2api() {
    sync_runtime_ports

    if [ ! -x "$APP_BIN" ]; then
        log "本地未找到 $APP_NAME，先下载最新版本"
        install_latest_release
        update_result=$?
        if [ "$update_result" -ne 0 ] && [ "$update_result" -ne 2 ]; then
            log "错误：下载 $APP_NAME 失败"
            return 1
        fi
    fi

    if [ ! -x "$APP_BIN" ]; then
        log "错误：未找到可执行文件 $APP_BIN"
        return 1
    fi

    if is_sub2api_running; then
        log "$APP_NAME 已在运行"
        return 0
    fi

    export SERVER_HOST="127.0.0.1"
    export SERVER_PORT="$PORT"

    if is_installed; then
        validate_runtime_port || return 1
        log "启动 $APP_NAME"
    else
        log "检测到尚未完成官方安装，直接启动 $APP_NAME"
    fi

    nohup "$APP_BIN" >> "$WATCH_LOG" 2>&1 &

    if wait_for_sub2api_start; then
        if is_installed; then
            log "$APP_NAME 启动成功"
        else
            log "$APP_NAME 已启动，请通过反代域名或本机端口继续安装"
        fi
        return 0
    fi

    log "错误：$APP_NAME 启动失败"
    return 1
}

restart_sub2api() {
    stop_sub2api
    start_sub2api
}

set_yaml_server_port() {
    target_port="$1"
    temp_file="$CONFIG_FILE.tmp"

    awk -v target_port="$target_port" '
        function spaces(n, out, i) {
            out=""
            for (i=0; i<n; i++) out=out " "
            return out
        }
        function trim(s) {
            gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", s)
            return s
        }
        BEGIN {
            in_server=0
            server_indent=-1
            port_written=0
        }
        {
            raw=$0
            indent=match(raw, /[^ ]/) - 1
            if (indent < 0) indent = 0
            line=trim(raw)

            if (line ~ /^server:[[:space:]]*$/) {
                in_server=1
                server_indent=indent
                print raw
                next
            }

            if (in_server && line != "" && indent <= server_indent) {
                if (!port_written) {
                    print spaces(server_indent + 2) "port: " target_port
                    port_written=1
                }
                in_server=0
            }

            if (in_server && line ~ /^port:[[:space:]]*/) {
                print spaces(indent) "port: " target_port
                port_written=1
                next
            }

            print raw
        }
        END {
            if (in_server && !port_written) {
                print spaces(server_indent + 2) "port: " target_port
            }
        }
    ' "$CONFIG_FILE" > "$temp_file" && mv "$temp_file" "$CONFIG_FILE"
}

ensure_log_config() {
    if grep -q '^log:' "$CONFIG_FILE"; then
        return 1
    fi

    cat >> "$CONFIG_FILE" <<EOF

log:
  output:
    to_stdout: true
    to_file: true
    file_path: "$APP_DIR/logs/sub2api-app.log"
EOF
    return 0
}

ensure_pricing_config() {
    if grep -q '^pricing:' "$CONFIG_FILE"; then
        return 1
    fi

    cat >> "$CONFIG_FILE" <<EOF

pricing:
  data_dir: "$APP_DIR/data"
EOF
    return 0
}

fix_config_if_needed() {
    if [ ! -f "$CONFIG_FILE" ]; then
        return 0
    fi

    changed=0
    desired_port=$(read_desired_port)
    current_port=$(extract_yaml_scalar "server.port" "$CONFIG_FILE")

    if [ -n "$desired_port" ] && [ "$current_port" != "$desired_port" ]; then
        set_yaml_server_port "$desired_port"
        log "已自动修正 config.yaml 中的 server.port：${current_port:-<empty>} -> $desired_port"
        PORT="$desired_port"
        changed=1
    fi

    ensure_log_config
    if [ $? -eq 0 ]; then
        log "已自动补全 config.yaml 中的日志输出配置"
        changed=1
    fi

    ensure_pricing_config
    if [ $? -eq 0 ]; then
        log "已自动补全 config.yaml 中的 pricing.data_dir 配置"
        changed=1
    fi

    if [ "$changed" -eq 1 ]; then
        return 1
    fi

    return 0
}

manual_initialize() {
    if ! is_interactive; then
        log "当前缺少初始化文件且无交互终端，请先手动执行 $SCRIPT_PATH"
        return 1
    fi

    echo "" > /dev/tty
    echo "===== Sub2API 首次初始化 =====" > /dev/tty
    echo "将记录程序端口，生成 Redis 配置，启动 Redis，下载程序并直接启动。" > /dev/tty
    echo "程序启动后如未安装，会自动进入官方安装页面。" > /dev/tty
    echo "" > /dev/tty

    prompt_required_value "Sub2API 服务端口" "" CFG_SERVER_PORT
    prompt_value "Redis 端口" "$REDIS_PORT" CFG_REDIS_PORT
    prompt_value "Redis 密码" "please_replace_with_your_redis_password" CFG_REDIS_PASSWORD

    PORT="$CFG_SERVER_PORT"
    REDIS_PORT="$CFG_REDIS_PORT"
    write_desired_port "$CFG_SERVER_PORT"
    write_redis_conf "$CFG_REDIS_PORT" "$CFG_REDIS_PASSWORD"
    log "首次运行：已根据交互内容生成 $REDIS_CONF"

    start_redis || return 1
    install_latest_release
    install_result=$?
    if [ "$install_result" -ne 0 ] && [ "$install_result" -ne 2 ]; then
        return 1
    fi
    start_sub2api || return 1
    ensure_crontab
    return 0
}

clean_logs() {
    if [ -f "$WATCH_LOG" ]; then
        tail -n 10000 "$WATCH_LOG" > "$WATCH_LOG.tmp" && mv "$WATCH_LOG.tmp" "$WATCH_LOG"
    fi
    if [ -f "$REDIS_LOG" ]; then
        tail -n 10000 "$REDIS_LOG" > "$REDIS_LOG.tmp" && mv "$REDIS_LOG.tmp" "$REDIS_LOG"
    fi
}

show_status() {
    sync_runtime_ports
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
    if ! is_bootstrap_initialized; then
        if is_interactive; then
            manual_initialize
            return $?
        fi
        log "当前未完成首次初始化，定时任务跳过。请先手动执行 $SCRIPT_PATH"
        return 0
    fi

    sync_runtime_ports

    install_latest_release
    update_result=$?
    if [ "$update_result" -eq 0 ]; then
        log "检测到更新，执行重启"
        start_redis || return 1
        restart_sub2api || return 1
        clean_logs
        ensure_crontab
        return 0
    fi

    if [ -f "$CONFIG_FILE" ]; then
        fix_config_if_needed
        config_fix_result=$?
        if [ "$config_fix_result" -eq 1 ]; then
            sync_runtime_ports
            validate_runtime_port || return 1
            log "检测到配置已自动修正，执行重启使其生效"
            start_redis || return 1
            restart_sub2api || return 1
            clean_logs
            ensure_crontab
            return 0
        fi
        sync_runtime_ports
        validate_runtime_port || return 1
    fi

    start_redis || return 1

    if ! is_sub2api_running; then
        log "检测到 $APP_NAME 进程不存在，执行启动"
        start_sub2api || return 1
    else
        log "$APP_NAME 运行正常"
        log "Redis 运行正常"
    fi

    clean_logs
    ensure_crontab
    return 0
}

case "$1" in
    ""|start)
        run_watchdog
        ;;
    stop)
        stop_sub2api
        ;;
    restart)
        if ! is_bootstrap_initialized; then
            manual_initialize
        else
            start_redis && restart_sub2api
        fi
        ;;
    status)
        show_status
        ;;
    update)
        install_latest_release
        result=$?
        if [ "$result" -eq 0 ]; then
            start_redis && restart_sub2api
        elif [ "$result" -eq 2 ]; then
            log "无需更新"
        else
            exit 1
        fi
        ;;
    init)
        manual_initialize
        ;;
    *)
        echo "用法: $0 [start|stop|restart|status|update|init]"
        exit 1
        ;;
esac

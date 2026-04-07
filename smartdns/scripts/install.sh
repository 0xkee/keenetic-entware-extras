#!/opt/bin/sh
# Install SmartDNS: package, config, custom init script.
set -eu

# --- Logging helpers (POSIX sh, no lib/common.sh dependency) ---

TAG="smartdns-install"

log() {
    printf "[smartdns] %s\n" "$1"
    logger -t "$TAG" "$1" 2>/dev/null || true
}

log_error() {
    printf "[smartdns] ERROR: %s\n" "$1" >&2
    logger -t "$TAG" "ERROR: $1" 2>/dev/null || true
}

# --- Paths ---

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SMARTDNS_CONF_SRC="$PROJECT_DIR/config/smartdns.conf"
SMARTDNS_CONF_DST="/opt/etc/smartdns/smartdns.conf"
SMARTDNS_CONF_BAK="/opt/etc/smartdns/smartdns.conf.bak"
DEFAULT_INIT="/opt/etc/init.d/S38smartdns"
CUSTOM_INIT="/opt/etc/init.d/S60smartdns"

# --- Preflight checks ---

if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root"
    exit 1
fi

if [ ! -f "$SMARTDNS_CONF_SRC" ]; then
    log_error "Config not found: $SMARTDNS_CONF_SRC"
    exit 1
fi

# --- Step 1: Install smartdns package ---

if command -v smartdns >/dev/null 2>&1; then
    log "smartdns already installed"
else
    log "Installing smartdns via opkg..."
    opkg update
    opkg install smartdns
    if ! command -v smartdns >/dev/null 2>&1; then
        log_error "Failed to install smartdns"
        exit 1
    fi
    log "smartdns installed successfully"
fi

# --- Step 2: Backup existing config ---

if [ -f "$SMARTDNS_CONF_DST" ]; then
    log "Backing up existing config to $SMARTDNS_CONF_BAK"
    cp "$SMARTDNS_CONF_DST" "$SMARTDNS_CONF_BAK"
fi

# --- Step 3: Deploy config ---

mkdir -p "$(dirname "$SMARTDNS_CONF_DST")"
cp "$SMARTDNS_CONF_SRC" "$SMARTDNS_CONF_DST"
log "Config deployed: $SMARTDNS_CONF_DST"

# --- Step 4: Disable default init script ---

if [ -f "$DEFAULT_INIT" ]; then
    chmod -x "$DEFAULT_INIT"
    log "Disabled default init: $DEFAULT_INIT"
fi

# --- Step 5: Create custom init script ---

cat > "$CUSTOM_INIT" << 'INITEOF'
#!/opt/bin/sh

DAEMON="/opt/sbin/smartdns"
CONF="/opt/etc/smartdns/smartdns.conf"
PIDFILE="/opt/var/run/smartdns.pid"
LOGFILE="/opt/var/log/smartdns.log"

start() {
    if [ ! -x "$DAEMON" ]; then
        echo "smartdns binary not found or not executable: $DAEMON"
        return 1
    fi

    # если уже запущен — не дёргаем
    if [ -f "$PIDFILE" ]; then
        PID="$(cat "$PIDFILE" 2>/dev/null)"
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            echo "smartdns already running (pid $PID)"
            return 0
        fi
    fi

    echo "starting smartdns..."
    mkdir -p "$(dirname "$PIDFILE")" "$(dirname "$LOGFILE")"

    # -p: smartdns пишет PID-файл
    # без -f: уходит в фон
    "$DAEMON" -c "$CONF" -p "$PIDFILE" >>"$LOGFILE" 2>&1 &
    sleep 1

    if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE" 2>/dev/null)" 2>/dev/null; then
        echo "smartdns started (pid $(cat "$PIDFILE"))"
        return 0
    else
        echo "smartdns failed to start, see $LOGFILE"
        return 1
    fi
}

stop() {
    if [ -f "$PIDFILE" ]; then
        PID="$(cat "$PIDFILE" 2>/dev/null)"
        if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
            echo "stopping smartdns (pid $PID)..."
            kill "$PID" 2>/dev/null
            sleep 1
        fi
        rm -f "$PIDFILE"
    else
        # fallback: pidfile потерялся
        PID="$(pidof smartdns 2>/dev/null || true)"
        if [ -n "$PID" ]; then
            echo "stopping smartdns (pid $PID)..."
            kill "$PID" 2>/dev/null
            sleep 1
        else
            echo "smartdns not running"
        fi
    fi
}

restart() {
    stop
    sleep 1
    start
}

case "$1" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart|reload)
        restart
        ;;
    *)
        echo "Usage: $0 {start|stop|restart}"
        exit 1
        ;;
esac

exit $?
INITEOF

chmod +x "$CUSTOM_INIT"
log "Created custom init: $CUSTOM_INIT"

# --- Step 6: Start SmartDNS ---

log "Starting SmartDNS..."
"$CUSTOM_INIT" start

log "Installation complete"

#!/opt/bin/sh
# Uninstall SmartDNS: stop service, remove custom init, restore defaults.
set -eu

# --- Logging helpers (POSIX sh, no lib/common.sh dependency) ---

TAG="smartdns-ru-uninstall"

log() {
    printf "[smartdns-ru] %s\n" "$1"
    logger -t "$TAG" "$1" 2>/dev/null || true
}

log_error() {
    printf "[smartdns-ru] ERROR: %s\n" "$1" >&2
    logger -t "$TAG" "ERROR: $1" 2>/dev/null || true
}

# --- Paths ---

SMARTDNS_CONF_DST="/opt/etc/smartdns/smartdns.conf"
SMARTDNS_CONF_BAK="/opt/etc/smartdns/smartdns.conf.bak"
DEFAULT_INIT="/opt/etc/init.d/S38smartdns"
CUSTOM_INIT="/opt/etc/init.d/S60smartdns"

# --- Confirmation ---

printf "This will remove SmartDNS custom configuration. Continue? [y/N] "
read -r answer
case "$answer" in
    y|Y|yes|YES) ;;
    *)
        log "Uninstall cancelled by user"
        exit 0
        ;;
esac

# --- Preflight checks ---

if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root"
    exit 1
fi

# --- Step 1: Stop SmartDNS ---

if [ -x "$CUSTOM_INIT" ]; then
    log "Stopping SmartDNS via custom init..."
    "$CUSTOM_INIT" stop || true
else
    # fallback: kill напрямую
    PID="$(pidof smartdns 2>/dev/null || true)"
    if [ -n "$PID" ]; then
        log "Stopping SmartDNS (pid $PID)..."
        kill "$PID" 2>/dev/null || true
        sleep 1
    else
        log "SmartDNS not running"
    fi
fi

# --- Step 2: Remove custom init script ---

if [ -f "$CUSTOM_INIT" ]; then
    rm -f "$CUSTOM_INIT"
    log "Removed custom init: $CUSTOM_INIT"
fi

# --- Step 3: Restore default init script ---

if [ -f "$DEFAULT_INIT" ]; then
    chmod +x "$DEFAULT_INIT"
    log "Restored default init: $DEFAULT_INIT (chmod +x)"
else
    log "Default init not found: $DEFAULT_INIT (skipping)"
fi

# --- Step 4: Restore config backup ---

if [ -f "$SMARTDNS_CONF_BAK" ]; then
    cp "$SMARTDNS_CONF_BAK" "$SMARTDNS_CONF_DST"
    rm -f "$SMARTDNS_CONF_BAK"
    log "Restored config backup: $SMARTDNS_CONF_BAK -> $SMARTDNS_CONF_DST"
else
    log "No config backup found ($SMARTDNS_CONF_BAK), config left as-is"
fi

# --- Step 5: Clean up PID file ---

rm -f /opt/var/run/smartdns.pid

log "Uninstall complete. SmartDNS package is still installed (opkg remove smartdns to remove)."

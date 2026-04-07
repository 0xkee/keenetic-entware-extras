#!/opt/bin/sh
# Install geo-bypass: cron job + init script.
# shellcheck disable=SC1091  # sourced files resolved at runtime on router
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"

INSTALL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log "Installing geo-bypass from: $INSTALL_DIR"

# --- Install Entware dependencies ---
log "Checking required dependencies..."
for pkg in ipset curl; do
  if ! command -v "$pkg" >/dev/null 2>&1; then
    log "Installing $pkg..."
    opkg install "$pkg"
  else
    log "$pkg: already installed"
  fi
done

# Optional: dig for domain DNS resolution (domains.txt → ipset)
if ! command -v dig >/dev/null 2>&1; then
  log "Optional: dig not found. Install for domain resolution: opkg install bind-dig"
else
  log "dig: already installed (domain resolution available)"
fi

# --- Create init script ---
INIT_SCRIPT="/opt/etc/init.d/S99geo-bypass"

cat > "$INIT_SCRIPT" << INITEOF
#!/opt/bin/sh
# geo-bypass startup script

case "\$1" in
  start)
    echo "Starting geo-bypass..."
    "$INSTALL_DIR/scripts/update-domains.sh"
    "$INSTALL_DIR/scripts/apply-routes.sh"
    ;;
  stop)
    echo "Stopping geo-bypass..."
    ipset destroy geo-bypass 2>/dev/null || true
    ;;
  restart)
    "\$0" stop
    sleep 1
    "\$0" start
    ;;
  *)
    echo "Usage: \$0 {start|stop|restart}"
    exit 1
    ;;
esac
INITEOF

chmod +x "$INIT_SCRIPT"
log "Created init script: $INIT_SCRIPT"

# --- Install NDM hook (interface up/down) ---
NDM_HOOK_DIR="/opt/etc/ndm/ifstatechanged.d"
NDM_HOOK_LINK="$NDM_HOOK_DIR/geo-bypass-hook"
HOOK_SCRIPT="$INSTALL_DIR/scripts/ndm-hook.sh"

mkdir -p "$NDM_HOOK_DIR"
chmod +x "$HOOK_SCRIPT"
ln -sf "$HOOK_SCRIPT" "$NDM_HOOK_LINK"
log "Installed NDM hook: $NDM_HOOK_LINK → $HOOK_SCRIPT"

# --- Add cron job (update subnets daily at 4:00) ---
CRON_LINE="0 4 * * * $INSTALL_DIR/scripts/update-domains.sh --force && $INSTALL_DIR/scripts/apply-routes.sh"
CRON_FILE="/opt/etc/crontab"

if [ -f "$CRON_FILE" ] && grep -q "geo-bypass" "$CRON_FILE"; then
  log "Cron job already exists, skipping"
else
  echo "# geo-bypass: update subnets daily" >> "$CRON_FILE"
  echo "$CRON_LINE" >> "$CRON_FILE"
  log "Added cron job to $CRON_FILE"
fi

log "Installation complete. Run: $INIT_SCRIPT start"

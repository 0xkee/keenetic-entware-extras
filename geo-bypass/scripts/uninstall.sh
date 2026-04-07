#!/opt/bin/sh
# Uninstall geo-bypass: detach rules, remove init script, NDM hook, cron entries.
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
# shellcheck disable=SC1091  # sourced files resolved at runtime on router
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"

_CONFIG_DIR="$SCRIPT_DIR/../config"
. "$_CONFIG_DIR/config.sh"

INIT_SCRIPT="/opt/etc/init.d/S99geo-bypass"
NDM_HOOK_LINK="/opt/etc/ndm/ifstatechanged.d/geo-bypass-hook"
CRON_FILE="/opt/etc/crontab"

# --- Confirmation ---

printf "This will remove geo-bypass components (rules, init, cron, hook). Continue? [y/N] "
read -r answer
case "$answer" in
  y|Y|yes|YES) ;;
  *)
    log "Uninstall cancelled by user"
    exit 0
    ;;
esac

# --- Step 1: Stop service if running ---

if [ -x "$INIT_SCRIPT" ]; then
  log "Stopping geo-bypass via init script..."
  "$INIT_SCRIPT" stop || true
else
  # Fallback: detach rules + destroy ipset manually
  log "Init script not found, cleaning up manually..."
  "$SCRIPT_DIR/detach-rules.sh" 2>/dev/null || true
  ipset destroy "$IPSET_NAME" 2>/dev/null || true
fi

# --- Step 2: Remove init script ---

if [ -f "$INIT_SCRIPT" ]; then
  rm -f "$INIT_SCRIPT"
  log "Removed init script: $INIT_SCRIPT"
else
  log "Init script not found (skipping): $INIT_SCRIPT"
fi

# --- Step 3: Remove NDM hook symlink ---

if [ -L "$NDM_HOOK_LINK" ] || [ -f "$NDM_HOOK_LINK" ]; then
  rm -f "$NDM_HOOK_LINK"
  log "Removed NDM hook: $NDM_HOOK_LINK"
else
  log "NDM hook not found (skipping): $NDM_HOOK_LINK"
fi

# --- Step 4: Remove cron entries ---

if [ -f "$CRON_FILE" ]; then
  sed -i '/geo-bypass/d' "$CRON_FILE"
  log "Removed cron entries from $CRON_FILE"
else
  log "Cron file not found (skipping): $CRON_FILE"
fi

# --- Done (cache files intentionally preserved) ---

log "Uninstall complete. Cache files preserved for faster re-install."
log "To remove caches manually: rm -f $SUBNET_LIST_FILE $DOMAINS_CACHE_FILE"

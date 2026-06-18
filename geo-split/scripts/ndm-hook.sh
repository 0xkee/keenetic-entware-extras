#!/opt/bin/sh
# NDM ifstatechanged hook for geo-split.
# Reconciliation pattern: ensures routing tables match desired state
# on every interface state change event.
# Installed as symlink: /opt/etc/ndm/ifstatechanged.d/geo-split-hook
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
# shellcheck disable=SC1091  # sourced files resolved at runtime on router
set -eu

REAL_PATH="$(readlink -f "$0" 2>/dev/null || readlink "$0")"
HOOK_DIR="$(dirname "$REAL_PATH")"
_CONFIG_DIR="$HOOK_DIR/../config"

. /opt/keenetic-entware-extras/lib/common.sh
. /opt/keenetic-entware-extras/lib/ip.sh
. "$_CONFIG_DIR/defaults.conf"
[ -f "$_CONFIG_DIR/config.conf" ] && . "$_CONFIG_DIR/config.conf"

# ── Guards ─────────────────────────────────────────────────────────
is_service_enabled "S99geo-split" || exit 0
[ "${1:-}" != "hook" ] && exit 0

# Lock file (tmpfs) for background dedup
LOCK="/opt/tmp/geo-split-hook.lock"

# ── Determine target interface mode ────────────────────────────────
TARGET_IFACE=""
case "${ROUTE_OUT:-auto}" in
  auto|"") ;;
  *) TARGET_IFACE="$ROUTE_OUT" ;;
esac

# ── Check if tables are correctly filled ───────────────────────────
# Returns 0 if both tables non-empty AND route dev matches desired dev.
tables_ok() {
  is_table_filled "$SUBNET_ROUTE_TABLE" || return 1
  is_table_filled "$DOMAIN_ROUTE_TABLE" || return 1
  local desired_dev cur_dev
  desired_dev=$(resolve_target_interface 2>/dev/null) || return 1
  cur_dev=$(cat "${TABLE_STAMP_PREFIX}${SUBNET_ROUTE_TABLE}.filled" 2>/dev/null) || cur_dev=""
  # Fallback: read from actual route table if stamp has no dev info
  if [ -z "$cur_dev" ] || [ "$cur_dev" = "" ]; then
    cur_dev=$(ip route show table "$SUBNET_ROUTE_TABLE" 2>/dev/null | \
      sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)
  fi
  [ "$cur_dev" = "$desired_dev" ]
}

# ── Fast path: everything correct → exit ───────────────────────────
tables_ok && exit 0

# ── Explicit mode: target interface down → detach ──────────────────
if [ -n "$TARGET_IFACE" ]; then
  if ! ip link show "$TARGET_IFACE" 2>/dev/null | grep -q ",UP"; then
    # Target interface not up — detach rules (don't fallback to ISP)
    if ip rule show 2>/dev/null | grep -q "lookup $SUBNET_ROUTE_TABLE"; then
      logger -t "$LOG_TAG" "Target $TARGET_IFACE down, detaching rules"
      "$HOOK_DIR/detach-rules.sh"
    fi
    exit 0
  fi
fi

# ── Dedup: skip if another refill is in progress ──────────────────
if [ -f "$LOCK" ]; then
  # Stale lock protection (>60s = crashed process)
  lock_age=$(( $(date +%s) - $(stat -t "$LOCK" | awk '{print $13}') )) 2>/dev/null || lock_age=999
  [ "$lock_age" -lt 60 ] && exit 0
  rm -f "$LOCK"
fi

# Create lock synchronously before forking background
touch "$LOCK"

# ── Background reconciliation ─────────────────────────────────────
{
  trap 'rm -f "$LOCK"' EXIT

  sleep 3  # debounce: let routing stabilize after state change

  # Re-check: another instance or cron may have fixed it
  if tables_ok; then
    exit 0
  fi

  # Resolve target interface (fails if no route available)
  dev=$(resolve_target_interface) || {
    logger -t "$LOG_TAG" "No target interface available after debounce"
    exit 0
  }

  logger -t "$LOG_TAG" "Reconciling tables via $dev (trigger: ${system_name:-unknown})"
  "$HOOK_DIR/update-subnets.sh" --refill &
  "$HOOK_DIR/update-domains.sh" --refill &
  wait
  "$HOOK_DIR/attach-rules.sh"
} &

exit 0

#!/opt/bin/sh
# NDM ifstatechanged hook for geo-split.
# Reacts to target interface up/down events.
# Installed as symlink: /opt/etc/ndm/ifstatechanged.d/geo-split-hook
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
# shellcheck disable=SC1091  # sourced files resolved at runtime on router
set -eu

LOG_TAG="geo-split-hook"

# Resolve symlink to find real script location
REAL_PATH="$(readlink -f "$0" 2>/dev/null || readlink "$0")"
HOOK_DIR="$(dirname "$REAL_PATH")"
CONFIG="$HOOK_DIR/../config/config.sh"

[ -f "$CONFIG" ] || exit 0

# Extract only needed variables from config
# (faster than full source — only simple vars, no path computation)
eval "$(grep -E '^(ROUTE_OUT|DOMAIN_ROUTE_TABLE|DOMAIN_RULE_PRIORITY|SUBNET_ROUTE_TABLE|SUBNET_RULE_PRIORITY|ROUTE_IN)=' "$CONFIG")"

# NDM hook filter
[ "${1:-}" != "hook" ] && exit 0

# Determine which interface to listen for
TARGET_IFACE=""
case "${ROUTE_OUT:-auto}" in
  auto|"")
    TARGET_IFACE=""   # auto mode: match interface with default route
    ;;
  *)
    TARGET_IFACE="$ROUTE_OUT"
    ;;
esac

# If target interface is known, filter by it
if [ -n "$TARGET_IFACE" ]; then
  [ "${system_name:-}" != "$TARGET_IFACE" ] && exit 0
fi

case "${connected:-}-${link:-}-${up:-}" in
  yes-up-up)
    # In auto mode (empty TARGET_IFACE), only react if this interface has default route
    if [ -z "$TARGET_IFACE" ]; then
      ip route show default | grep -q "dev ${system_name:-}" || exit 0
    fi
    logger -t "$LOG_TAG" "Interface ${system_name:-} up, filling tables + attaching rules"
    {
      sleep 2  # debounce: wait for interface to stabilize
      "$HOOK_DIR/update-subnets.sh" --refill &
      "$HOOK_DIR/update-domains.sh" --refill &
      wait
      "$HOOK_DIR/attach-rules.sh"
    } &
    ;;
  no-down-*)
    # In auto mode (empty TARGET_IFACE), only react if our tables use this interface
    if [ -z "$TARGET_IFACE" ]; then
      has_routes=0
      ip route show table "$SUBNET_ROUTE_TABLE" 2>/dev/null | grep -q "dev ${system_name:-}" && has_routes=1
      ip route show table "$DOMAIN_ROUTE_TABLE" 2>/dev/null | grep -q "dev ${system_name:-}" && has_routes=1
      [ "$has_routes" -eq 1 ] || exit 0
    fi
    logger -t "$LOG_TAG" "Interface ${system_name:-} down, detaching rules"
    "$HOOK_DIR/detach-rules.sh"
    ;;
esac

exit 0

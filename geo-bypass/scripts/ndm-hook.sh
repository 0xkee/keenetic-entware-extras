#!/opt/bin/sh
# NDM ifstatechanged hook for geo-bypass.
# Reacts to VPN/ISP interface up/down events.
# Installed as symlink: /opt/etc/ndm/ifstatechanged.d/geo-bypass-hook
# shellcheck disable=SC1091  # sourced files resolved at runtime on router
set -eu

LOG_TAG="geo-bypass-hook"

# Resolve symlink to find real script location
REAL_PATH="$(readlink -f "$0" 2>/dev/null || readlink "$0")"
HOOK_DIR="$(dirname "$REAL_PATH")"
CONFIG="$HOOK_DIR/../config/config.sh"

[ -f "$CONFIG" ] || exit 0

# Extract only needed variables from config
# (faster than full source — only simple vars, no path computation)
eval "$(grep -E '^(ROUTE_MODE|ISP_INTERFACE|VPN_INTERFACE|ROUTE_TABLE|RULE_PRIORITY|LAN_INTERFACES)=' "$CONFIG")"

# NDM hook filter
[ "${1:-}" != "hook" ] && exit 0

# Determine which interface to listen for
TARGET_IFACE=""
case "$ROUTE_MODE" in
  bypass|auto)
    TARGET_IFACE="${ISP_INTERFACE:-}"
    ;;
  vpn)
    TARGET_IFACE="$VPN_INTERFACE"
    ;;
  *)
    exit 0
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
    logger -t "$LOG_TAG" "Interface ${system_name:-} up, attaching rules"
    "$HOOK_DIR/attach-rules.sh" &
    ;;
  no-down-*)
    # In auto mode (empty TARGET_IFACE), only react if our route table uses this interface
    if [ -z "$TARGET_IFACE" ]; then
      ip route show table "$ROUTE_TABLE" 2>/dev/null | grep -q "dev ${system_name:-}" || exit 0
    fi
    logger -t "$LOG_TAG" "Interface ${system_name:-} down, detaching rules"
    "$HOOK_DIR/detach-rules.sh"
    ;;
esac

exit 0

#!/opt/bin/sh
# Toggle smartdns-conf-ru-split between split-DNS and default (simple forwarder).
# Usage: toggle.sh {enable|disable|status}
#
# enable  — activate split-DNS config (.ru→Yandex, *→Google/CF)
# disable — activate default config (all→Google/CF, no split)
# status  — print "enabled" or "disabled"
#
# Both modes keep SmartDNS running on same ports (:6053, :6153),
# so smartdns-redirect and geo-split continue to work.
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
# shellcheck disable=SC1091  # sourced files resolved at runtime on router
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
_CONFIG_DIR="${SCRIPT_DIR%/*}/config"
. "$_CONFIG_DIR/config.sh"

case "${1:-}" in
  enable)
    if [ ! -f "$CONF_SPLIT" ]; then
      echo "ERROR: split-DNS config not found: $CONF_SPLIT" >&2
      exit 1
    fi
    cp "$CONF_SPLIT" "$CONF"
    mkdir -p "$(dirname "$STATE_FILE")"
    echo "enabled" > "$STATE_FILE"
    # Background restart: config swap + state file are sync (instant),
    # S38 restart is async (SmartDNS startup: DoH/DoT + cache = 5-10s).
    # Same pattern as geo-split update backgrounding in api-router.
    if [ -x "$S38" ]; then
      ("$S38" restart >/dev/null 2>&1 &)
    fi
    echo "SmartDNS: split-DNS enabled"
    ;;
  disable)
    if [ ! -f "$CONF_DEFAULT" ]; then
      echo "ERROR: default config not found: $CONF_DEFAULT" >&2
      exit 1
    fi
    cp "$CONF_DEFAULT" "$CONF"
    rm -f "$STATE_FILE"
    # Background restart (same reason as enable)
    if [ -x "$S38" ]; then
      ("$S38" restart >/dev/null 2>&1 &)
    fi
    echo "SmartDNS: switched to default (simple forwarder)"
    ;;
  status)
    if [ -f "$STATE_FILE" ]; then
      echo "enabled"
    else
      echo "disabled"
    fi
    ;;
  *)
    echo "Usage: $0 {enable|disable|status}" >&2
    exit 1
    ;;
esac

#!/opt/bin/sh
# DEPRECATED: use /opt/etc/init.d/S37smartdns-conf {enable|disable|status} directly.
# This wrapper will be removed in a future version.
#
# Toggle smartdns-geo-conf between split-DNS and default (simple forwarder).
# Usage: toggle.sh {enable|disable|status}
# shellcheck disable=SC1091
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
S37="${SCRIPT_DIR%/*}/init.d/S37smartdns-conf"

# Also check installed location
[ -x "$S37" ] || S37="/opt/etc/init.d/S37smartdns-conf"

if [ ! -x "$S37" ]; then
  echo "ERROR: S37smartdns-conf not found" >&2
  exit 1
fi

case "${1:-}" in
  enable|disable|status)
    exec "$S37" "$1"
    ;;
  *)
    echo "Usage: $0 {enable|disable|status}" >&2
    exit 1
    ;;
esac

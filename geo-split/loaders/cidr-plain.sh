#!/opt/bin/sh
# Loader: plain CIDR text format (one CIDR per line).
# Filters out comments, blank lines, and IPv6 entries.
# Usage: cidr-plain.sh <URL> [interface]
# Output: IPv4 CIDR lines to stdout
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
# shellcheck disable=SC1091  # sourced files resolved at runtime on router
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
. "$SCRIPT_DIR/../../lib/lists.sh"

url="${1:?Usage: cidr-plain.sh <URL> [interface]}"
iface="${2:-}"

iface_arg=""
if [ -n "$iface" ]; then
  iface_arg="--interface $iface"
fi

# Filter: remove IPv6 (grep -v ':'), then strip comments/blanks (list_strip)
# shellcheck disable=SC2086  # iface_arg intentionally unquoted (may be empty)
curl -sS --max-time 30 $iface_arg "$url" | grep -v ':' | list_strip

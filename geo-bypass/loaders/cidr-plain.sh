#!/opt/bin/sh
# Loader: plain CIDR text format (one CIDR per line).
# Filters out comments, blank lines, and IPv6 entries.
# Usage: cidr-plain.sh <URL> [interface]
# Output: IPv4 CIDR lines to stdout
set -eu

url="${1:?Usage: cidr-plain.sh <URL> [interface]}"
iface="${2:-}"

iface_arg=""
if [ -n "$iface" ]; then
  iface_arg="--interface $iface"
fi

# shellcheck disable=SC2086  # iface_arg intentionally unquoted (may be empty)
curl -sS --max-time 30 $iface_arg "$url" | grep -v ':' | grep -v '^#' | grep -v '^$'

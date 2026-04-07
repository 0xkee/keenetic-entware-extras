#!/opt/bin/sh
# Loader: RIPE stat JSON format.
# Parses JSON response from stat.ripe.net to extract IPv4 CIDR blocks.
# Requires: jq (opkg install jq)
# Usage: ripe-json.sh <URL> [interface]
# Output: CIDR lines to stdout
set -eu

url="${1:?Usage: ripe-json.sh <URL> [interface]}"
iface="${2:-}"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required for ripe-json loader (opkg install jq)" >&2
  exit 1
fi

iface_arg=""
if [ -n "$iface" ]; then
  iface_arg="--interface $iface"
fi

# shellcheck disable=SC2086  # iface_arg intentionally unquoted (may be empty)
curl -sS --max-time 60 $iface_arg "$url" | jq -r '.data.resources.ipv4[]'

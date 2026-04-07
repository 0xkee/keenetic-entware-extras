#!/opt/bin/sh
# Loader: RIPE stat JSON format.
# Parses JSON response from stat.ripe.net to extract IPv4 CIDR blocks.
# Requires: jq (opkg install jq)
# Usage: ripe-json.sh <URL>
# Output: CIDR lines to stdout
set -eu

url="${1:?Usage: ripe-json.sh <URL>}"

if ! command -v jq >/dev/null 2>&1; then
  echo "ERROR: jq required for ripe-json loader (opkg install jq)" >&2
  exit 1
fi

curl -sS --max-time 60 "$url" | jq -r '.data.resources.ipv4[]'

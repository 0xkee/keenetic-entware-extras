#!/opt/bin/sh
# Loader: plain CIDR text format (one CIDR per line).
# Usage: cidr-plain.sh <URL>
# Output: CIDR lines to stdout
set -eu

url="${1:?Usage: cidr-plain.sh <URL>}"
curl -sS --max-time 30 "$url"

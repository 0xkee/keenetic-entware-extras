#!/opt/bin/sh
# Shortcut: net-check deep single-resource check.
# Usage: domain-check.sh <domain|url>
# Equivalent to: net-check.sh check <domain|url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/net-check.sh" check "$@"

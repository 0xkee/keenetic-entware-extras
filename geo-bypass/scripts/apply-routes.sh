#!/opt/bin/sh
# Apply GEO routing: load ipset data + attach rules.
# Orchestrator — delegates to load-ipset.sh and attach-rules.sh.
# For init.d start and manual invocation.
# shellcheck disable=SC1091
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"

log "Applying geo-bypass routes..."
"$SCRIPT_DIR/load-ipset.sh"
"$SCRIPT_DIR/attach-rules.sh"
log "geo-bypass routes applied successfully"

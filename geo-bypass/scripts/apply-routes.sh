#!/opt/bin/sh
# Apply GEO routing: attach rules.
# Orchestrator — delegates to attach-rules.sh.
# For init.d start and manual invocation.
# shellcheck disable=SC1091
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"

t_start=$(date +%s)
log "Applying geo-bypass routes..."
"$SCRIPT_DIR/attach-rules.sh"
t_end=$(date +%s)
log "geo-bypass routes applied successfully (total: $((t_end - t_start))s)"

#!/opt/bin/sh
# Patch set v8 — dashboard card integration for ENTWARE_EXTRAS
# Family: signal (order signal / templateMap().get)
# Detection key: content-based enum lookup in the stock bundle.
# shellcheck disable=SC2034,SC1091  # SC2034: PATCH_ENUM read by caller; SC1091: source resolved at runtime
PATCH_ENUM="zo"
#
# Verified against stock bundles:
#   5.2 Beta 2   KN-3810  main-2258318.js  styles-2258318.css
#
# Difference from v7: Enum renamed jo → zo (minifier rename)
#   - Same signal-based architecture as v3/v4/v5/v6/v7
#   - NdwDragPanel: `order=V([])` writable signal (unchanged)
#   - `getTemplate` uses signal call: `this.templateMap().get(e)??null`
#   - Default card layout split into desktop/mobile sub-arrays

# Source family logic (PATCHES_DIR set by patch-stock-ui.sh before sourcing)
: "${PATCHES_DIR:=$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=families/signal.sh
. "$PATCHES_DIR/families/signal.sh"

apply_patches() {
    _apply_signal_patches "$PATCH_ENUM" "$1"
}

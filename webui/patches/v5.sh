#!/opt/bin/sh
# Patch set v5 — dashboard card integration for ENTWARE_EXTRAS
# Family: signal (order signal / templateMap().get)
# Detection key: content-based enum lookup in the stock bundle.
# shellcheck disable=SC2034,SC1091  # SC2034: PATCH_ENUM read by caller; SC1091: source resolved at runtime
PATCH_ENUM="Lo"
#
# Verified against stock bundles:
#   5.2.5-alpha  mipsel  main-2CA2915.js  styles-2CA2915.css  (KN-3811)
#
# Difference from v4: Enum renamed Oo → Lo
#   - Same signal-based architecture as v3/v4
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

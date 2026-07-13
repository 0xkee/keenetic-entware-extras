#!/opt/bin/sh
# Patch set v4 — dashboard card integration for ENTWARE_EXTRAS
# Family: signal (order signal / templateMap().get)
# Detection key: content-based enum lookup in the stock bundle.
# shellcheck disable=SC2034,SC1091  # SC2034: PATCH_ENUM read by caller; SC1091: source resolved at runtime
PATCH_ENUM="Oo"
#
# Verified against stock bundles:
#   5.2.x  mipsel  main-553997B.js  styles-553997B.css
#
# Difference from v3: Enum renamed Mo → Oo
#   - Same signal-based architecture as v3
#   - NdwDragPanel: `order=V([])` writable signal (unchanged)
#   - `getTemplate` uses signal call: `this.templateMap().get(e)??null`
#   - Default card layout split into desktop/mobile sub-arrays
#   - __ewLastOrder now set as side-effect in getTemplate (was in setter)

# Source family logic (PATCHES_DIR set by patch-stock-ui.sh before sourcing)
: "${PATCHES_DIR:=$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=families/signal.sh
. "$PATCHES_DIR/families/signal.sh"

apply_patches() {
    _apply_signal_patches "$PATCH_ENUM" "$1"
}

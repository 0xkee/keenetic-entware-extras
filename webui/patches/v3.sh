#!/opt/bin/sh
# Patch set v3 — dashboard card integration for ENTWARE_EXTRAS
# Family: signal (order signal / templateMap().get)
# Detection key: grep for .values(<PATCH_ENUM>)) in the stock bundle.
# shellcheck disable=SC2034,SC1091  # SC2034: PATCH_ENUM read by caller; SC1091: source resolved at runtime
PATCH_ENUM="Mo"
#
# Verified against stock bundles:
#   5.1.0  mipsel  main-8787931.js  styles-8787931.css
#
# Difference from v2: Angular moved to signal-based architecture in 5.1.0.
#   - Enum renamed Vo → Mo
#   - NdwDragPanel: `set order(e){this.elementsOrder=e}` removed
#     (order is now a writable signal: `order=V([])`)
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

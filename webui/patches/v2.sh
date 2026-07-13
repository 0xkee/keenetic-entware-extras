#!/opt/bin/sh
# Patch set v2 — dashboard card integration for ENTWARE_EXTRAS
# Family: setter (set order / templateMap.get)
# Detection key: grep for .values(<PATCH_ENUM>)) in the stock bundle.
# shellcheck disable=SC2034,SC1091  # SC2034: PATCH_ENUM read by caller; SC1091: source resolved at runtime
PATCH_ENUM="Vo"
#
# Verified against stock bundles:
#   5.1 Beta 3  mipsel  main-3FF05DF.js  styles-3FF05DF.css
#
# Difference from v1: Angular minifier renamed enum Po → Vo in 5.1.
# The patch LOGIC is identical to v1.

# Source family logic (PATCHES_DIR set by patch-stock-ui.sh before sourcing)
: "${PATCHES_DIR:=$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=families/setter.sh
. "$PATCHES_DIR/families/setter.sh"

apply_patches() {
    _apply_setter_patches "$PATCH_ENUM" "$1"
}

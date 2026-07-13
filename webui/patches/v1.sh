#!/opt/bin/sh
# Patch set v1 — dashboard card integration for ENTWARE_EXTRAS
# Family: setter (set order / templateMap.get)
# Detection key: grep for .values(<PATCH_ENUM>)) in the stock bundle.
# shellcheck disable=SC2034,SC1091  # SC2034: PATCH_ENUM read by caller; SC1091: source resolved at runtime
PATCH_ENUM="Po"
#
# Verified against stock bundles:
#   5.0.4  mipsel  main-ZYVOXYLQ.js  styles-AVEVNDW4.css
#   5.0.8  aarch64 main-XXXXXXXX.js  styles-J4CVWJOW.css
#   5.0.8  mipsel  main-4QPHZXFY.js  styles-D5VNMMPD.css
#   5.0.10 mipsel  main-TXLLNFBH.js  styles-DKYWR66I.css

# Source family logic (PATCHES_DIR set by patch-stock-ui.sh before sourcing)
: "${PATCHES_DIR:=$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=families/setter.sh
. "$PATCHES_DIR/families/setter.sh"

apply_patches() {
    _apply_setter_patches "$PATCH_ENUM" "$1"
}

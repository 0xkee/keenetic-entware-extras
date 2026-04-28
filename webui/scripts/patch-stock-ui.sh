#!/opt/bin/sh
# patch-stock-ui.sh -- copy stock UI to tmpfs and apply version-specific patches.
# Called by S80nginx-webui before starting nginx.
# Result: /tmp/ew-webui/ with patched index.html + main-*.js bundle.
#
# Multi-version support:
#   Patch sets live in webui/patches/<HASH>.sh (one file per firmware bundle).
#   Different routers may run different firmware versions -- each needs its own
#   patch file matching main-<HASH>.js from that firmware.
#   After firmware upgrade: identify new hash, create patch file, test, deploy.
#   If no matching patch file -- fallback to unpatched stock UI + inject.js only.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATCHES_DIR="$PROJECT_DIR/webui/patches"

# Source webui config
_CONFIG_DIR="$PROJECT_DIR/webui/config"
# shellcheck source=/dev/null
. "$_CONFIG_DIR/config.sh"

HTDOCS="/usr/share/htdocs_"
CACHE="/tmp/ew-webui"

log() { logger -t "ew-patch" "$*"; printf "%s\n" "$*"; }

# Clean up partial cache on unexpected error
cleanup() { [ -d "$CACHE" ] && rm -rf "$CACHE"; }
trap cleanup EXIT

# -- Pre-flight checks -------------------------------------------------
[ -d "$HTDOCS" ] || { log "ERROR: stock htdocs not found: $HTDOCS"; exit 1; }
[ -f "$HTDOCS/index.html" ] || { log "ERROR: index.html not found in $HTDOCS"; exit 1; }

# -- Copy stock UI to tmpfs (cp -a follows symlinks for dynamic JS) ----
rm -rf "$CACHE"
cp -a "$HTDOCS" "$CACHE"

# -- Detect JS bundle hash ---------------------------------------------
BUNDLE=""
for f in "$CACHE"/main-*.js; do
    [ -f "$f" ] && BUNDLE="$f" && break
done
[ -z "$BUNDLE" ] && { log "ERROR: main-*.js not found in $CACHE"; exit 1; }
JS_HASH=$(basename "$BUNDLE" | sed 's/main-\(.*\)\.js/\1/')

# -- Detect CSS bundle hash (for diagnostics) --------------------------
CSS_HASH="none"
for f in "$CACHE"/styles-*.css; do
    [ -f "$f" ] && CSS_HASH=$(basename "$f" | sed 's/styles-\(.*\)\.css/\1/') && break
done

log "Firmware: JS=main-${JS_HASH}.js CSS=styles-${CSS_HASH}.css"

# -- Patch index.html (version-agnostic: </body> and </head> stable) ---
sed -i "s|</body>|<script>window.__ewConfig={injectSidebar:${INJECT_SIDEBAR:-0},pollInterval:${DASH_POLL_INTERVAL:-30000}}</script><script src=\"/custom/shared.js\"></script><script src=\"/custom/inject.js\"></script></body>|" "$CACHE/index.html"
sed -i 's|</head>|<link rel="stylesheet" href="/custom/inject.css"></head>|' "$CACHE/index.html"

if ! grep -q 'inject.js' "$CACHE/index.html"; then
    log "ERROR: inject.js not found in patched index.html"
    exit 1
fi

# -- Apply version-specific bundle patches -----------------------------
HASH_MAP="$PATCHES_DIR/hash-map.conf"
PATCH_VER=""

# Look up JS hash in hash-map.conf
if [ -f "$HASH_MAP" ]; then
    PATCH_VER=$(grep -v '^#' "$HASH_MAP" | grep -v '^$' | awk -v h="$JS_HASH" '$1 == h { print $2 }')
fi

# Fallback: use the latest patch version (last entry in hash-map)
if [ -z "$PATCH_VER" ]; then
    if [ -f "$HASH_MAP" ]; then
        PATCH_VER=$(grep -v '^#' "$HASH_MAP" | grep -v '^$' | awk '{ v=$2 } END { print v }')
        log "WARN: JS hash '${JS_HASH}' not in hash-map.conf -- falling back to ${PATCH_VER}"
    fi
fi

PATCH_FILE="$PATCHES_DIR/${PATCH_VER}.sh"

if [ -n "$PATCH_VER" ] && [ -f "$PATCH_FILE" ]; then
    log "Applying patches: ${PATCH_VER}.sh (JS=main-${JS_HASH}.js)"
    # shellcheck source=/dev/null
    . "$PATCH_FILE"
    # apply_patches is defined in the sourced file
    apply_patches "$BUNDLE"

    # -- Verify critical patches ----------------------------------------
    OK=0
    FAIL=0
    for pat in 'ENTWARE_EXTRAS:"ENTWARE_EXTRAS"' 'ENTWARE_EXTRAS:"ENTWARE EXTRAS"' '__ewLastOrder'; do
        if grep -q "$pat" "$BUNDLE"; then
            OK=$((OK + 1))
        else
            FAIL=$((FAIL + 1))
            log "WARN: missing after patch: $pat"
        fi
    done

    if [ "$FAIL" -gt 0 ]; then
        log "WARN: $FAIL/$((OK + FAIL)) critical patches failed (${PATCH_VER}, JS=main-${JS_HASH}.js)"
    else
        log "OK: $OK/$((OK + FAIL)) verified (${PATCH_VER}, JS=main-${JS_HASH}.js)"
    fi
else
    log "WARN: no patch set available -- serving stock UI + inject.js only"
    log "WARN: add JS hash '${JS_HASH}' to $PATCHES_DIR/hash-map.conf to enable full integration"
fi

# Success: disable cleanup trap (keep cache)
trap - EXIT

#!/opt/bin/sh
# patch-stock-ui.sh -- copy stock UI to tmpfs and apply version-specific patches.
# Called by S80nginx-webui before starting nginx.
# Result: /tmp/ew-webui/ with patched index.html + main-*.js bundle.
#
# Multi-version support:
#   Patch sets live in webui/patches/v<N>.sh (one per firmware branch).
#   Mapping in webui/patches/hash-map.conf via DEFAULT:<fw_version> entries.
#   Lookup: DEFAULT:<full_version> → DEFAULT:<major.minor> → fallback (no patches).
#   After firmware upgrade: test existing patches against new bundle,
#   create new vN.sh + DEFAULT entry only if DOM changed.
# shellcheck disable=SC1091  # sourced files resolved at runtime on router
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PATCHES_DIR="$PROJECT_DIR/webui/patches"

# Source webui config
_CONFIG_DIR="$PROJECT_DIR/webui/config"
# shellcheck source=/dev/null
. "$_CONFIG_DIR/defaults.conf"
[ -f "$_CONFIG_DIR/config.conf" ] && . "$_CONFIG_DIR/config.conf"

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

# Detect firmware version via ndmc (e.g. "5.0.11", "5.1")
FW_TITLE=""
FW_VER=""
if command -v ndmc >/dev/null 2>&1; then
    FW_TITLE=$(ndmc -c "show version" 2>/dev/null | awk '/title:/ { print $2; exit }')
    FW_VER=$(printf '%s' "$FW_TITLE" | sed 's/^\([0-9]*\.[0-9]*\).*/\1/')
fi

# Look up patch set from hash-map.conf using firmware version cascade:
#   1. DEFAULT:<full_version>  (e.g. DEFAULT:5.0.11)
#   2. DEFAULT:<major.minor>   (e.g. DEFAULT:5.0)
if [ -f "$HASH_MAP" ] && [ -n "$FW_TITLE" ]; then
    # Try exact version first (e.g. DEFAULT:5.0.11)
    PATCH_VER=$(grep -v '^#' "$HASH_MAP" | grep -v '^$' | awk -v d="DEFAULT:$FW_TITLE" '$1 == d { print $2 }')
    # Fallback to major.minor (e.g. DEFAULT:5.0)
    if [ -z "$PATCH_VER" ] && [ -n "$FW_VER" ]; then
        PATCH_VER=$(grep -v '^#' "$HASH_MAP" | grep -v '^$' | awk -v d="DEFAULT:$FW_VER" '$1 == d { print $2 }')
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

# -- Pre-compress large assets for gzip_static -------------------------
# nginx gzip_static serves .gz companion if present, avoiding on-the-fly
# compression of 6MB+ JS bundle on MIPS (saves 20s+ cold start).
# Level 6 (default): best size/speed ratio. -9 saves only ~3% more but
# takes 2-3x longer on MIPS. One-time cost at service start, not per-request.
# -k: keep original (nginx falls back to uncompressed for clients without gzip).
# -f: overwrite existing .gz (safe for restart/reboot).

# Stock UI: only large bundle files (main-*, polyfills-*, styles-*)
GZ_COUNT=0
for f in "$CACHE"/main-*.js "$CACHE"/polyfills-*.js "$CACHE"/styles-*.css; do
    [ -f "$f" ] || continue
    gzip -6 -k -f "$f"
    GZ_COUNT=$((GZ_COUNT + 1))
done

# Custom dashboard: all JS/CSS in webui/static/
STATIC_DIR="$PROJECT_DIR/webui/static"
for f in "$STATIC_DIR"/*.js "$STATIC_DIR"/*.css; do
    [ -f "$f" ] || continue
    gzip -6 -k -f "$f"
    GZ_COUNT=$((GZ_COUNT + 1))
done
log "gzip_static: pre-compressed $GZ_COUNT files"

# Success: disable cleanup trap (keep cache)
trap - EXIT

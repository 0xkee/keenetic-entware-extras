#!/opt/bin/sh
# patch-stock-ui.sh -- copy stock UI bundles and apply version-specific patches.
# Called by S80nginx-webui before starting nginx.
# Result: webui/htdocs-cache/ with patched index.html + main-*.js bundle + .gz.
# Unpatched files served by nginx @stock fallback from /usr/share/htdocs_.
#
# Patch detection:
#   Auto-detects patch set by scanning the stock Angular bundle for the
#   DashboardSection enum name: Po → v1, Vo → v2, Mo → v3.
#   Works regardless of firmware version string or architecture.
#   Writes result to webui/htdocs-cache/.patch-state for status.sh.
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
CACHE="$PROJECT_DIR/webui/htdocs-cache"

log() { logger -t "ew-patch" "$*"; printf "%s\n" "$*"; }

# Clean up partial cache on unexpected error
cleanup() { [ -d "$CACHE" ] && rm -rf "$CACHE"; }
trap cleanup EXIT

# -- Pre-flight checks -------------------------------------------------
[ -d "$HTDOCS" ] || { log "ERROR: stock htdocs not found: $HTDOCS"; exit 1; }
[ -f "$HTDOCS/index.html" ] || { log "ERROR: index.html not found in $HTDOCS"; exit 1; }

# -- Copy only patched/compressed bundles to cache (not full htdocs_) ---
# Unpatched files (assets/, wizards/, ndm*.js etc.) served by nginx @stock
# fallback directly from flash /usr/share/htdocs_ — saves ~4 MB I/O.
rm -rf "$CACHE"
mkdir -p "$CACHE"
cp "$HTDOCS/index.html" "$CACHE/"
for _src in "$HTDOCS"/main-*.js "$HTDOCS"/polyfills-*.js "$HTDOCS"/styles-*.css; do
    [ -f "$_src" ] && cp "$_src" "$CACHE/"
done

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
sed -i "s|</body>|<script>window.__ewConfig={injectSidebar:${INJECT_SIDEBAR:-0},pollInterval:${DASH_POLL_INTERVAL:-30000}}</script><script src=\"/custom/shared.js\"></script><script src=\"/custom/detail-render.js\"></script><script src=\"/custom/inject-dashboard.js\"></script><script src=\"/custom/inject.js\"></script></body>|" "$CACHE/index.html"
sed -i 's|</head>|<link rel="stylesheet" href="/custom/inject.css"></head>|' "$CACHE/index.html"

if ! grep -q 'inject.js' "$CACHE/index.html"; then
    log "ERROR: inject.js not found in patched index.html"
    exit 1
fi

# -- Apply version-specific bundle patches -----------------------------
PATCH_VER=""

# Auto-detect patch set from bundle DashboardSection enum.
# Each vN.sh declares PATCH_ENUM="<EnumName>" (e.g. Po, Vo, Mo, Oo).
# Content-based detection: find `Xx={INTERNET:"INTERNET"` — the unique
# DashboardSection enum pattern. Avoids ambiguous .values(Xx)) grep.
BUNDLE_ENUM=$(grep -o '[A-Za-z][A-Za-z0-9]*={INTERNET:"INTERNET"' "$BUNDLE" \
    | head -1 | sed 's/=.*//')
if [ -n "$BUNDLE_ENUM" ]; then
    for _pf in "$PATCHES_DIR"/v*.sh; do
        [ -f "$_pf" ] || continue
        _enum=$(sed -n 's/^PATCH_ENUM="\([^"]*\)"/\1/p' "$_pf")
        if [ "$_enum" = "$BUNDLE_ENUM" ]; then
            PATCH_VER=$(basename "$_pf" .sh)
            break
        fi
    done
fi

PATCH_FILE="$PATCHES_DIR/${PATCH_VER}.sh"

# Detect firmware version for diagnostics (state file, logs)
FW_TITLE=""
if command -v ndmc >/dev/null 2>&1; then
    FW_TITLE=$(ndmc -c "show version" 2>/dev/null | awk '/title:/ { print $2; exit }')
fi

# Combined sed + verify helper (called by vN.sh for each patch).
# Usage: patch_sed <label> <expected_fixed_string> <sed_expression> <file>
# Runs sed -i, then checks that <expected_fixed_string> exists in <file>.
_PATCH_OK=0
_PATCH_FAIL=0
patch_sed() {
    _ps_label="$1"; _ps_check="$2"; _ps_expr="$3"; _ps_file="$4"
    sed -i "$_ps_expr" "$_ps_file"
    if grep -qF "$_ps_check" "$_ps_file"; then
        _PATCH_OK=$((_PATCH_OK + 1))
    else
        _PATCH_FAIL=$((_PATCH_FAIL + 1))
        log "WARN: patch $_ps_label did not apply"
    fi
}

if [ -n "$PATCH_VER" ] && [ -f "$PATCH_FILE" ]; then
    log "Applying patches: ${PATCH_VER}.sh (JS=main-${JS_HASH}.js)"
    # shellcheck source=/dev/null
    . "$PATCH_FILE"
    # apply_patches is defined in the sourced file;
    # it calls verify_patch() after each sed for per-patch diagnostics
    apply_patches "$BUNDLE"

    # -- Summary --------------------------------------------------------
    if [ "$_PATCH_FAIL" -gt 0 ]; then
        log "WARN: $_PATCH_FAIL/$((_PATCH_OK + _PATCH_FAIL)) patches failed (${PATCH_VER}, JS=main-${JS_HASH}.js)"
    else
        log "OK: $_PATCH_OK/$((_PATCH_OK + _PATCH_FAIL)) patches verified (${PATCH_VER}, JS=main-${JS_HASH}.js)"
    fi

    # Write state file for status.sh (sourced as key=value)
    printf 'PATCH_SET=%s\nFW_VERSION=%s\nJS_HASH=%s\nCSS_HASH=%s\nPATCH_OK=%s\nPATCH_FAIL=%s\n' \
        "$PATCH_VER" "$FW_TITLE" "$JS_HASH" "$CSS_HASH" "$_PATCH_OK" "$_PATCH_FAIL" \
        > "$CACHE/.patch-state"
else
    log "WARN: unknown bundle enum — no matching patch set (JS=main-${JS_HASH}.js)"
    log "WARN: serving stock UI + inject.js only; create new vN.sh if this is a new firmware"
    printf 'PATCH_SET=\nFW_VERSION=%s\nJS_HASH=%s\nCSS_HASH=%s\nPATCH_OK=0\nPATCH_FAIL=0\n' \
        "$FW_TITLE" "$JS_HASH" "$CSS_HASH" \
        > "$CACHE/.patch-state"
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

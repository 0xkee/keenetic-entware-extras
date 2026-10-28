#!/opt/bin/sh
# patch-stock-ui.sh -- copy stock UI bundles and apply auto-detected patches.
# Called by S80nginx-webui before starting nginx.
# Result: webui/htdocs-cache/ with patched index.html + main-*.js bundle + .gz.
# Unpatched files served by nginx @stock fallback from /usr/share/htdocs_.
#
# Auto-patch detection:
#   1. Extracts DashboardSection enum name from the stock Angular bundle
#      (e.g. Po, Mo, zo — changes on each minifier rename)
#   2. Detects patch family from architecture markers:
#      - signal: templateMap().get (KeeneticOS 5.1.0+)
#      - setter: set order(e) (KeeneticOS 5.0.x)
#   3. Sources families/<family>.sh and applies patches with the detected enum
#   4. On any patch failure: rolls back to clean stock bundle
#   Works regardless of firmware version string, architecture, or enum name.
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

# -- Auto-detect and apply bundle patches ------------------------------

# Extract DashboardSection enum name from bundle.
# Pattern: `Xx={INTERNET:"INTERNET"` — unique enum definition.
BUNDLE_ENUM=$(grep -o '[A-Za-z][A-Za-z0-9]*={INTERNET:"INTERNET"' "$BUNDLE" \
    | head -1 | sed 's/=.*//')

# Detect patch family from architecture markers in the bundle.
# signal: KeeneticOS 5.1.0+ (order=V([]) writable signal, templateMap().get)
# setter: KeeneticOS 5.0.x  (set order(e){...}, templateMap.get — no signal call)
DETECTED_FAMILY=""
if grep -qF 'this.templateMap().get' "$BUNDLE"; then
    DETECTED_FAMILY="signal"
elif grep -qF 'set order(e){this.elementsOrder=e}' "$BUNDLE"; then
    DETECTED_FAMILY="setter"
fi

# Detect firmware version for diagnostics (state file, logs)
FW_TITLE=""
if command -v ndmc >/dev/null 2>&1; then
    FW_TITLE=$(ndmc -c "show version" 2>/dev/null | awk '/title:/ { print $2; exit }')
fi

# Combined sed + verify helper (called by family patches).
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

FAMILY_FILE="$PATCHES_DIR/families/${DETECTED_FAMILY}.sh"

if [ -n "$BUNDLE_ENUM" ] && [ -n "$DETECTED_FAMILY" ] && [ -f "$FAMILY_FILE" ]; then
    log "Auto-patching: family=$DETECTED_FAMILY enum=$BUNDLE_ENUM (JS=main-${JS_HASH}.js)"

    # Backup bundle for rollback on partial failure
    cp "$BUNDLE" "$BUNDLE.orig"

    # Source family and apply patches with detected enum
    # shellcheck source=/dev/null
    . "$FAMILY_FILE"
    case "$DETECTED_FAMILY" in
        signal) _apply_signal_patches "$BUNDLE_ENUM" "$BUNDLE" ;;
        setter) _apply_setter_patches "$BUNDLE_ENUM" "$BUNDLE" ;;
    esac

    # -- Summary & rollback on failure ----------------------------------
    _PATCH_TOTAL=$((_PATCH_OK + _PATCH_FAIL))
    if [ "$_PATCH_FAIL" -gt 0 ]; then
        log "WARN: $_PATCH_FAIL/$_PATCH_TOTAL patches failed — rolling back to stock bundle"
        cp "$BUNDLE.orig" "$BUNDLE"
        printf 'PATCH_SET=\nPATCH_ENUM=%s\nPATCH_FAMILY=%s\nFW_VERSION=%s\nJS_HASH=%s\nCSS_HASH=%s\nPATCH_OK=0\nPATCH_FAIL=%s\n' \
            "$BUNDLE_ENUM" "$DETECTED_FAMILY" "$FW_TITLE" "$JS_HASH" "$CSS_HASH" "$_PATCH_FAIL" \
            > "$CACHE/.patch-state"
    else
        log "OK: $_PATCH_OK/$_PATCH_TOTAL patches applied (family=$DETECTED_FAMILY, enum=$BUNDLE_ENUM)"
        printf 'PATCH_SET=auto-%s\nPATCH_ENUM=%s\nPATCH_FAMILY=%s\nFW_VERSION=%s\nJS_HASH=%s\nCSS_HASH=%s\nPATCH_OK=%s\nPATCH_FAIL=0\n' \
            "$DETECTED_FAMILY" "$BUNDLE_ENUM" "$DETECTED_FAMILY" "$FW_TITLE" "$JS_HASH" "$CSS_HASH" "$_PATCH_OK" \
            > "$CACHE/.patch-state"
    fi
    rm -f "$BUNDLE.orig"
else
    if [ -z "$BUNDLE_ENUM" ]; then
        log "WARN: DashboardSection enum not found in bundle (JS=main-${JS_HASH}.js)"
    elif [ -z "$DETECTED_FAMILY" ]; then
        log "WARN: unknown architecture — no matching family (enum=$BUNDLE_ENUM, JS=main-${JS_HASH}.js)"
    fi
    log "WARN: serving stock UI + inject.js only"
    printf 'PATCH_SET=\nPATCH_ENUM=%s\nPATCH_FAMILY=\nFW_VERSION=%s\nJS_HASH=%s\nCSS_HASH=%s\nPATCH_OK=0\nPATCH_FAIL=0\n' \
        "${BUNDLE_ENUM:-}" "$FW_TITLE" "$JS_HASH" "$CSS_HASH" \
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

# Custom dashboard: JS/CSS/HTML in webui/static/.
# .gz companions may already be shipped in the .ipk package (build-time
# compression at -9). Skip files that already have a .gz companion —
# avoids redundant gzip on slow MIPS and preserves build-time -9 quality.
STATIC_DIR="$PROJECT_DIR/webui/static"
GZ_SHIPPED=0
for f in "$STATIC_DIR"/*.js "$STATIC_DIR"/*.css "$STATIC_DIR"/*.html; do
    [ -f "$f" ] || continue
    if [ -f "$f.gz" ]; then
        GZ_SHIPPED=$((GZ_SHIPPED + 1))
        continue
    fi
    gzip -6 -k "$f"
    GZ_COUNT=$((GZ_COUNT + 1))
done
log "gzip_static: compressed $GZ_COUNT files, $GZ_SHIPPED already shipped"

# Success: disable cleanup trap (keep cache)
trap - EXIT

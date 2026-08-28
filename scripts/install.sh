#!/opt/bin/sh
# kee-install — bootstrap installer for keenetic-entware-extras opkg feed
# Usage:
#   Interactive:  curl -fsSL https://0xkee.github.io/keenetic-entware-extras/install.sh | sh
#   With args:    curl -fsSL ... | sh -s -- geo-split webui
#   All packages: curl -fsSL ... | sh -s -- --all
#   Stable channel: curl -fsSL ... | sh -s -- --stable --all
#   Dev channel:    curl -fsSL ... | sh -s -- --dev --all
#   Force reinstall: curl -fsSL ... | sh -s -- --force --all
#   Direct:       sh install.sh [--force] [--stable|--dev] [--all | package-names...]
set -eu

FEED_BASE="https://0xkee.github.io/keenetic-entware-extras"
FEED_NAME="kee"
CHANNEL=""
FORCE=false

# ── Output helpers ───────────────────────────────────────────────
die()  { echo "❌ $*" >&2; exit 1; }
info() { echo "→ $*"; }
warn() { echo "⚠️  $*" >&2; }

# Indent opkg output for readability (line-buffered for real-time streaming)
indent() { while IFS= read -r line; do printf '     %s\n' "$line"; done; }

# ── Counters ─────────────────────────────────────────────────────
INSTALLED=0
UPGRADED=0
SKIPPED=0
FAILED=0

# ── Package catalog ──────────────────────────────────────────────
# Format: name|description (one entry per line)
# Note: geo-split-data is a dependency of geo-split, pulled automatically
CATALOG="keenetic-entware-extras|shared libraries, kee-status CLI
geo-split|split routing by GeoIP & domains
smartdns-geo-conf|SmartDNS config for DNS geo-splitting
smartdns-redirect|DNS DNAT to local resolver
net-check|network diagnostics toolkit
webui|web dashboard (port 8080)"

PKG_COUNT=$(printf '%s\n' "$CATALOG" | wc -l)
ALL_PKGS=$(printf '%s\n' "$CATALOG" | cut -d'|' -f1 | tr '\n' ' ')

# Get package name by 1-based index (empty if out of range)
pkg_name() {
    printf '%s\n' "$CATALOG" | sed -n "${1}p" | cut -d'|' -f1
}

# Get package description by 1-based index
pkg_desc() {
    printf '%s\n' "$CATALOG" | sed -n "${1}p" | cut -d'|' -f2
}

# ── Header ───────────────────────────────────────────────────────
header() {
    echo ""
    echo "╔══════════════════════════════════════════════╗"
    echo "║   📦 keenetic-entware-extras · installer     ║"
    echo "║   github.com/0xkee/keenetic-entware-extras   ║"
    echo "╚══════════════════════════════════════════════╝"
    echo ""
}

# ── Preflight checks ────────────────────────────────────────────
check_entware() {
    if [ ! -d /opt/bin ] || [ ! -f /opt/bin/opkg ]; then
        die "Entware not found. Install Entware first:
    https://help.keenetic.com/hc/ru/articles/360021214160"
    fi
    echo "  ✅ Entware detected"
}

check_root() {
    if [ "$(id -u)" != "0" ]; then
        die "Root privileges required. Run: su -c 'sh install.sh'"
    fi
}

# ── wget-ssl (HTTPS prerequisite) ────────────────────────────────
ensure_wget_ssl() {
    # Check if current wget supports HTTPS
    if /opt/bin/wget --help 2>&1 | grep -qi 'https'; then
        echo "  ✅ wget with HTTPS support"
        fix_wget_path
        return 0
    fi

    info "Installing wget-ssl (required for HTTPS feeds)..."
    opkg update >/dev/null 2>&1 || true
    opkg install wget-ssl 2>&1 | indent
    echo "  ✅ wget-ssl installed"

    fix_wget_path
}

fix_wget_path() {
    # BusyBox wget at /opt/usr/bin/wget may shadow /opt/bin/wget (wget-ssl)
    # in PATH. Fix by replacing the BusyBox symlink.
    if [ -L /opt/usr/bin/wget ]; then
        real_path=$(readlink -f /opt/usr/bin/wget 2>/dev/null || echo "")
        case "$real_path" in
            *busybox*)
                ln -sf /opt/bin/wget /opt/usr/bin/wget
                info "Fixed wget PATH priority (BusyBox → wget-ssl)"
                ;;
        esac
    fi
}

# ── Channel selection ────────────────────────────────────────────
# Resolve channel: CLI flag > existing feed > default (stable)
choose_channel() {
    # Already set via --stable or --dev flag
    if [ -n "$CHANNEL" ]; then
        return 0
    fi

    # Detect existing channel from opkg.conf
    existing=$(sed -n "s|^src/gz ${FEED_NAME} ${FEED_BASE}/\(.*\)|\1|p" \
        /opt/etc/opkg.conf 2>/dev/null || true)
    if [ -n "$existing" ]; then
        CHANNEL="$existing"
        return 0
    fi

    # Default to stable
    CHANNEL="stable"
}

# Interactive channel switcher (called from menu)
prompt_channel() {
    echo ""
    echo "  Select update channel:"
    echo ""
    echo "  1)  stable   — recommended, tested releases"
    echo "  2)  dev      — bleeding edge, latest builds"
    echo ""
    printf "  Current: %s. Choose [1/2]: " "$CHANNEL" >&2
    if [ -t 0 ]; then
        read -r ch_choice
    else
        read -r ch_choice </dev/tty
    fi

    case "$ch_choice" in
        2|[Dd]|[Dd][Ee][Vv])  CHANNEL="dev" ;;
        1|[Ss]|*)             CHANNEL="stable" ;;
    esac
    echo ""
    add_feed
    update_index force
}

# ── Feed configuration ──────────────────────────────────────────
add_feed() {
    feed_url="${FEED_BASE}/${CHANNEL}"

    # Check if feed exists with any channel
    if grep -q "^src/gz ${FEED_NAME} " /opt/etc/opkg.conf 2>/dev/null; then
        cur_url=$(sed -n "s|^src/gz ${FEED_NAME} ||p" /opt/etc/opkg.conf)
        if [ "$cur_url" = "$feed_url" ]; then
            echo "  ✅ Feed '${FEED_NAME}' already configured (${CHANNEL})"
            return 0
        fi
        # Channel changed — update in-place
        sed -i "s|^src/gz ${FEED_NAME} .*|src/gz ${FEED_NAME} ${feed_url}|" \
            /opt/etc/opkg.conf
        echo "  🔄 Feed updated: ${FEED_NAME} → ${feed_url}"
        return 0
    fi

    printf "src/gz %s %s\n" "$FEED_NAME" "$feed_url" >> /opt/etc/opkg.conf
    echo "  ✅ Feed added: ${FEED_NAME} → ${feed_url}"
}

update_index() {
    # Skip if index exists and is fresh (< 10 min old)
    # $1 = "force" to skip freshness check (e.g. after channel change)
    idx_file="/opt/var/opkg-lists/${FEED_NAME}"
    if [ "${1-}" != "force" ] && [ -f "$idx_file" ] && ! $FORCE; then
        age=$(( $(date +%s) - $(date -r "$idx_file" +%s 2>/dev/null || echo 0) ))
        if [ "$age" -lt 600 ]; then
            echo "  ⏭  Package index is fresh ($(( age / 60 ))m ago)"
            return 0
        fi
    fi

    info "Updating package index..."
    if opkg update 2>&1 | tail -5 | grep -q "Updated.*${FEED_NAME}"; then
        echo "  ✅ Package index updated"
    elif [ -f "$idx_file" ]; then
        echo "  ✅ Package index updated"
    else
        die "Failed to update package index. Check network connectivity."
    fi
}

# ── Package installation ────────────────────────────────────────
install_pkg() {
    pkg="$1"
    _tmp="/tmp/kee-install-$$-${pkg}"

    if $FORCE; then
        echo "  📦 $pkg (--force-reinstall)"
        opkg install --force-reinstall "$pkg" 2>&1 | tee "$_tmp" | indent
        if grep -q "Collected errors" "$_tmp" 2>/dev/null; then
            echo "  ❌ $pkg — reinstall failed"
            FAILED=$((FAILED + 1)); rm -f "$_tmp"; return 1
        fi
        rm -f "$_tmp"
        echo "  ✅ $pkg — reinstalled"
        INSTALLED=$((INSTALLED + 1))
        return 0
    fi

    # Normal: stream install output, check result after
    opkg install "$pkg" 2>&1 | tee "$_tmp" | indent

    if grep -q "Collected errors" "$_tmp" 2>/dev/null; then
        echo "  ❌ $pkg — install failed"
        FAILED=$((FAILED + 1)); rm -f "$_tmp"; return 1
    fi

    if grep -q "up to date" "$_tmp" 2>/dev/null; then
        rm -f "$_tmp"
        echo "  ⏭  $pkg — already up to date"
        SKIPPED=$((SKIPPED + 1))
    elif grep -q "Upgrading" "$_tmp" 2>/dev/null; then
        rm -f "$_tmp"
        echo "  ✅ $pkg — upgraded"
        UPGRADED=$((UPGRADED + 1))
    else
        rm -f "$_tmp"
        echo "  ✅ $pkg — installed"
        INSTALLED=$((INSTALLED + 1))
    fi
}

install_packages() {
    echo ""
    $FORCE && echo "🔄 FORCE — reinstalling all packages from feed" && echo ""
    info "Installing packages..."
    echo ""
    for pkg in $1; do
        install_pkg "$pkg" || true
    done
}

# ── TTY detection ────────────────────────────────────────────────
# Check if interactive input is possible.
# stdin may be a pipe (curl|sh) — fall back to /dev/tty.
# /dev/tty may exist but not be functional (ssh without -t flag).
has_tty() {
    [ -t 0 ] && return 0
    # Actually try opening /dev/tty in a subshell
    (exec 0</dev/tty) 2>/dev/null
}

# ── Interactive menu ─────────────────────────────────────────────
show_menu() {
    echo ""
    echo "  📡 Channel: $CHANNEL"
    echo ""
    echo "  Available packages:"
    echo ""
    i=1
    while [ "$i" -le "$PKG_COUNT" ]; do
        name=$(pkg_name "$i")
        desc=$(pkg_desc "$i")
        printf "  %d)  %-26s — %s\n" "$i" "$name" "$desc"
        i=$((i + 1))
    done
    echo ""
    echo "  A)  Install all packages"
    echo "  F)  Force reinstall all packages"
    echo "  C)  Change channel (stable/dev)"
    echo "  Q)  Quit"
    echo ""
}

read_choice() {
    # Prompt goes to stderr so it is not captured by $()
    printf "  Choose packages (e.g. 1 3 5, a=all, f=force, c=channel, q=quit): " >&2
    if [ -t 0 ]; then
        read -r choice
    else
        read -r choice </dev/tty
    fi
    echo "$choice"
}

parse_choice() {
    choice="$1"
    case "$choice" in
        [Aa]|[Aa][Ll][Ll]|--all)
            echo "$ALL_PKGS"
            ;;
        [Qq]|"")
            echo ""
            ;;
        *)
            pkgs=""
            for token in $choice; do
                # Validate token is a number before looking up
                case "$token" in
                    [1-9]|[1-9][0-9])
                        p=$(pkg_name "$token")
                        if [ -n "$p" ]; then
                            pkgs="$pkgs $p"
                        else
                            warn "Unknown package number: $token (skipping)"
                        fi
                        ;;
                    *)
                        warn "Unknown option: $token (skipping)"
                        ;;
                esac
            done
            echo "$pkgs"
            ;;
    esac
}

# ── Summary ──────────────────────────────────────────────────────
show_summary() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    summary="✅ $INSTALLED installed"
    if [ "$UPGRADED" -gt 0 ]; then
        summary="$summary | 🔄 $UPGRADED upgraded"
    fi
    summary="$summary | ⏭  $SKIPPED up to date | ❌ $FAILED failed"
    echo "📊 Done: $summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Run kee-status to check service status."
    echo "  Docs: https://github.com/0xkee/keenetic-entware-extras"
    echo ""
}

# ── Main ─────────────────────────────────────────────────────────
main() {
    # Parse flags, collect remaining args
    remaining=""
    for arg in "$@"; do
        case "$arg" in
            --force)   FORCE=true ;;
            --stable)  CHANNEL="stable" ;;
            --dev)     CHANNEL="dev" ;;
            *)         remaining="${remaining:+$remaining }$arg" ;;
        esac
    done

    header
    check_root
    check_entware
    ensure_wget_ssl
    choose_channel
    add_feed
    update_index

    # Non-interactive: packages passed as arguments
    if [ -n "$remaining" ]; then
        pkgs=$(parse_choice "$remaining")
        if [ -z "$pkgs" ]; then
            info "Nothing to install"
            exit 0
        fi
        install_packages "$pkgs"
        show_summary
        exit 0
    fi

    # Interactive mode requires a terminal
    if ! has_tty; then
        show_menu
        die "No terminal for interactive input.
    Use:  curl ... | sh -s -- --all
    Or:   curl ... | sh -s -- 1 3 5"
    fi

    # Interactive: show menu and prompt (loop for channel change)
    while true; do
        show_menu
        choice=$(read_choice)

        # Handle C (channel) and F (force) in parent shell
        case "$choice" in
            [Cc]) prompt_channel; continue ;;
            [Ff]) FORCE=true; choice="A" ;;
        esac

        pkgs=$(parse_choice "$choice")

        if [ -z "$pkgs" ]; then
            info "Nothing to install. Bye!"
            exit 0
        fi

        install_packages "$pkgs"
        show_summary
        break
    done
}

main "$@"

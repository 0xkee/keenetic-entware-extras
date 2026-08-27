#!/opt/bin/sh
# kee-install — bootstrap installer for keenetic-entware-extras opkg feed
# Usage:
#   Interactive:  curl -fsSL https://0xkee.github.io/keenetic-entware-extras/install.sh | sh
#   With args:    curl -fsSL ... | sh -s -- geo-split webui
#   All packages: curl -fsSL ... | sh -s -- --all
#   Force reinstall: curl -fsSL ... | sh -s -- --force --all
#   Direct:       sh install.sh [--force] [--all | package-names...]
set -eu

FEED_URL="https://0xkee.github.io/keenetic-entware-extras/stable"
FEED_NAME="kee"
FORCE=false

# ── Output helpers (deploy.sh style) ─────────────────────────────
die()  { echo "❌ $*" >&2; exit 1; }
info() { echo "→ $*"; }
warn() { echo "⚠️  $*" >&2; }

# Indent opkg output for readability
indent() { sed 's/^/     /'; }

# ── Counters ─────────────────────────────────────────────────────
INSTALLED=0
MIGRATED=0
FAILED=0

# ── Packages catalog ────────────────────────────────────────────
# Note: geo-split-data is a dependency of geo-split, pulled automatically
PKG_1="keenetic-entware-extras"
PKG_2="geo-split"
PKG_3="smartdns-geo-conf"
PKG_4="smartdns-redirect"
PKG_5="net-check"
PKG_6="webui"

DESC_1="shared libraries, kee-status CLI"
DESC_2="split routing by GeoIP & domains"
DESC_3="SmartDNS config for DNS geo-splitting"
DESC_4="DNS DNAT to local resolver"
DESC_5="network diagnostics toolkit"
DESC_6="web dashboard (port 8080)"

ALL_PKGS="$PKG_1 $PKG_2 $PKG_3 $PKG_4 $PKG_5 $PKG_6"

pkg_by_num() {
    case "$1" in
        1) echo "$PKG_1" ;; 2) echo "$PKG_2" ;; 3) echo "$PKG_3" ;;
        4) echo "$PKG_4" ;; 5) echo "$PKG_5" ;; 6) echo "$PKG_6" ;;
        *) echo "" ;;
    esac
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

# ── Feed configuration ──────────────────────────────────────────
add_feed() {
    if grep -q "^src/gz ${FEED_NAME} " /opt/etc/opkg.conf 2>/dev/null; then
        echo "  ✅ Feed '${FEED_NAME}' already configured"
        return 0
    fi

    printf "src/gz %s %s\n" "$FEED_NAME" "$FEED_URL" >> /opt/etc/opkg.conf
    echo "  ✅ Feed added: ${FEED_NAME} → ${FEED_URL}"
}

update_index() {
    # Skip if index exists and is fresh (< 10 min old)
    idx_file="/opt/var/opkg-lists/${FEED_NAME}"
    if [ -f "$idx_file" ] && ! $FORCE; then
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

    # --force: always reinstall from feed
    if $FORCE; then
        echo "  📦 $pkg (--force-reinstall)"
        opkg install --force-reinstall "$pkg" 2>&1 | indent || {
            echo "  ❌ $pkg — reinstall failed"
            FAILED=$((FAILED + 1))
            return 1
        }
        INSTALLED=$((INSTALLED + 1))
        echo "  ✅ $pkg — reinstalled"
        return 0
    fi

    # Normal: try install, migrate if already present
    output=$(opkg install "$pkg" 2>&1) || {
        echo "  ❌ $pkg — install failed"
        echo "$output" | indent
        FAILED=$((FAILED + 1))
        return 1
    }
    case "$output" in
        *"up to date"*)
            # Package exists (possibly installed manually via .ipk file).
            # Force-reinstall from feed to ensure proper opkg tracking.
            echo "  🔄 $pkg (migrating to feed)"
            opkg install --force-reinstall "$pkg" 2>&1 | indent || {
                echo "  ❌ $pkg — migration failed"
                FAILED=$((FAILED + 1))
                return 1
            }
            echo "  ✅ $pkg — migrated to feed"
            MIGRATED=$((MIGRATED + 1))
            ;;
        *)
            echo "  📦 $pkg (new)"
            echo "$output" | indent
            echo "  ✅ $pkg — installed"
            INSTALLED=$((INSTALLED + 1))
            ;;
    esac
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

# ── Interactive menu ─────────────────────────────────────────────
show_menu() {
    echo "  Available packages:"
    echo ""
    echo "  1)  $PKG_1               — $DESC_1"
    echo "  2)  $PKG_2                        — $DESC_2"
    echo "  3)  $PKG_3              — $DESC_3"
    echo "  4)  $PKG_4             — $DESC_4"
    echo "  5)  $PKG_5                       — $DESC_5"
    echo "  6)  $PKG_6                          — $DESC_6"
    echo ""
    echo "  A)  Install all packages"
    echo "  Q)  Quit"
    echo ""
}

read_choice() {
    # Works both with direct execution and curl|sh (reads from /dev/tty)
    printf "  Choose packages (e.g. 1 3 5, A=all, Q=quit): "
    if [ -t 0 ]; then
        read -r choice
    elif [ -e /dev/tty ]; then
        read -r choice < /dev/tty
    else
        die "No terminal available for interactive input. Use: sh -s -- --all"
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
                p=$(pkg_by_num "$token")
                if [ -n "$p" ]; then
                    pkgs="$pkgs $p"
                else
                    warn "Unknown option: $token (skipping)"
                fi
            done
            echo "$pkgs"
            ;;
    esac
}

# ── Summary ──────────────────────────────────────────────────────
show_summary() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📊 Done: ✅ $INSTALLED installed | 🔄 $MIGRATED migrated | ❌ $FAILED failed"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Run kee-status to check service status."
    echo "  Docs: https://github.com/0xkee/keenetic-entware-extras"
    echo ""
}

# ── Main ─────────────────────────────────────────────────────────
main() {
    # Parse --force flag, collect remaining args
    remaining=""
    for arg in "$@"; do
        case "$arg" in
            --force)  FORCE=true ;;
            *)        remaining="${remaining:+$remaining }$arg" ;;
        esac
    done

    header
    check_root
    check_entware
    ensure_wget_ssl
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

    # Interactive: show menu
    show_menu
    choice=$(read_choice)
    pkgs=$(parse_choice "$choice")

    if [ -z "$pkgs" ]; then
        info "Nothing to install. Bye!"
        exit 0
    fi

    install_packages "$pkgs"
    show_summary
}

main "$@"

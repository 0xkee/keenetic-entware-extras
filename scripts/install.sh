#!/opt/bin/sh
# kee-install — bootstrap installer for keenetic-entware-extras opkg feed
# Usage:
#   Interactive:  curl -fsSL https://0xkee.github.io/keenetic-entware-extras/install.sh | sh
#   With args:    curl -fsSL ... | sh -s -- geo-split webui
#   All packages: curl -fsSL ... | sh -s -- --all
#   Direct:       sh install.sh [--all | package-names...]
set -eu

FEED_URL="https://0xkee.github.io/keenetic-entware-extras/stable"
FEED_NAME="kee"

# ── Colors ──────────────────────────────────────────────────────────
if [ -t 1 ] || [ -t 2 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' NC=''
fi

# ── Output helpers ──────────────────────────────────────────────────
info()  { printf "%b▸%b %s\n" "$BLUE" "$NC" "$*"; }
ok()    { printf "%b✓%b %s\n" "$GREEN" "$NC" "$*"; }
warn()  { printf "%b⚠%b %s\n" "$YELLOW" "$NC" "$*"; }
fail()  { printf "%b✗%b %s\n" "$RED" "$NC" "$*"; }
die()   { fail "$*"; exit 1; }

header() {
    printf "\n"
    printf "%b" "$BOLD$CYAN"
    printf "  ┌───────────────────────────────────────────────┐\n"
    printf "  │                                               │\n"
    printf "  │   keenetic-entware-extras  ·  installer       │\n"
    printf "  │   github.com/0xkee/keenetic-entware-extras    │\n"
    printf "  │                                               │\n"
    printf "  └───────────────────────────────────────────────┘\n"
    printf "%b" "$NC"
    printf "\n"
}

# ── Packages catalog ───────────────────────────────────────────────
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

# ── Preflight checks ──────────────────────────────────────────────
check_entware() {
    if [ ! -d /opt/bin ] || [ ! -f /opt/bin/opkg ]; then
        fail "Entware not found"
        printf "\n"
        printf "  Install Entware first:\n"
        printf "  %bhttps://help.keenetic.com/hc/ru/articles/360021214160%b\n" "$CYAN" "$NC"
        printf "\n"
        exit 1
    fi
    ok "Entware detected"
}

check_root() {
    if [ "$(id -u)" != "0" ]; then
        die "Root privileges required. Run: su -c 'sh install.sh'"
    fi
}

# ── wget-ssl (HTTPS prerequisite) ─────────────────────────────────
ensure_wget_ssl() {
    # Check if current wget supports HTTPS
    if /opt/bin/wget --help 2>&1 | grep -qi 'https'; then
        ok "wget with HTTPS support"
        fix_wget_path
        return 0
    fi

    info "Installing wget-ssl (required for HTTPS feeds)..."
    opkg update >/dev/null 2>&1 || true
    if opkg install wget-ssl 2>&1 | grep -qE 'Installing|Configuring|already'; then
        ok "wget-ssl installed"
    else
        die "Failed to install wget-ssl"
    fi

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
                ok "Fixed wget PATH priority (BusyBox → wget-ssl)"
                ;;
        esac
    fi
}

# ── Feed configuration ────────────────────────────────────────────
add_feed() {
    if grep -q "^src/gz ${FEED_NAME} " /opt/etc/opkg.conf 2>/dev/null; then
        ok "Feed '$FEED_NAME' already configured"
        return 0
    fi

    printf "src/gz %s %s\n" "$FEED_NAME" "$FEED_URL" >> /opt/etc/opkg.conf
    ok "Feed added: $FEED_NAME → $FEED_URL"
}

update_index() {
    info "Updating package index..."
    if opkg update 2>&1 | tail -5 | grep -q "Updated.*${FEED_NAME}"; then
        ok "Package index updated"
    elif [ -f "/opt/var/opkg-lists/${FEED_NAME}" ]; then
        ok "Package index updated"
    else
        die "Failed to update package index. Check network connectivity."
    fi
}

# ── Package installation ──────────────────────────────────────────
install_pkg() {
    pkg="$1"
    info "Installing ${BOLD}${pkg}${NC}..."
    if opkg install "$pkg" 2>&1 | grep -qE 'Installing|Configuring|already installed'; then
        ok "${pkg} installed"
    else
        fail "Failed to install ${pkg}"
        return 1
    fi
}

install_packages() {
    printf "\n"
    info "Installing packages..."
    printf "\n"
    errors=0
    for pkg in $1; do
        install_pkg "$pkg" || errors=$((errors + 1))
    done
    return "$errors"
}

# ── Interactive menu ──────────────────────────────────────────────
show_menu() {
    printf "  %bAvailable packages:%b\n" "$BOLD" "$NC"
    printf "\n"
    printf "  %b1%b)  %-25s %b%s%b\n" "$CYAN" "$NC" "$PKG_1" "$DIM" "$DESC_1" "$NC"
    printf "  %b2%b)  %-25s %b%s%b\n" "$CYAN" "$NC" "$PKG_2" "$DIM" "$DESC_2" "$NC"
    printf "  %b3%b)  %-25s %b%s%b\n" "$CYAN" "$NC" "$PKG_3" "$DIM" "$DESC_3" "$NC"
    printf "  %b4%b)  %-25s %b%s%b\n" "$CYAN" "$NC" "$PKG_4" "$DIM" "$DESC_4" "$NC"
    printf "  %b5%b)  %-25s %b%s%b\n" "$CYAN" "$NC" "$PKG_5" "$DIM" "$DESC_5" "$NC"
    printf "  %b6%b)  %-25s %b%s%b\n" "$CYAN" "$NC" "$PKG_6" "$DIM" "$DESC_6" "$NC"
    printf "\n"
    printf "  %bA%b)  Install all packages\n" "$CYAN" "$NC"
    printf "  %bQ%b)  Quit\n" "$CYAN" "$NC"
    printf "\n"
}

read_choice() {
    # Works both with direct execution and curl|sh (reads from /dev/tty)
    printf "  %bChoose packages (e.g. 1 3 5, A=all, Q=quit):%b " "$BOLD" "$NC"
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

# ── Finish ────────────────────────────────────────────────────────
show_done() {
    printf "\n"
    printf "  %b%b┌─────────────────────────────────────────┐%b\n" "$BOLD" "$GREEN" "$NC"
    printf "  %b%b│  Installation complete!                  │%b\n" "$BOLD" "$GREEN" "$NC"
    printf "  %b%b└─────────────────────────────────────────┘%b\n" "$BOLD" "$GREEN" "$NC"
    printf "\n"
    printf "  Run %bkee-status%b to check service status.\n" "$CYAN" "$NC"
    printf "  Docs: %bhttps://github.com/0xkee/keenetic-entware-extras%b\n" "$DIM" "$NC"
    printf "\n"
}

# ── Main ──────────────────────────────────────────────────────────
main() {
    header
    check_root
    check_entware
    ensure_wget_ssl
    add_feed
    update_index

    # Non-interactive: packages passed as arguments
    if [ $# -gt 0 ]; then
        pkgs=$(parse_choice "$*")
        if [ -z "$pkgs" ]; then
            info "Nothing to install"
            exit 0
        fi
        install_packages "$pkgs"
        show_done
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
    show_done
}

main "$@"

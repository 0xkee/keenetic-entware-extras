#!/opt/bin/sh
# kee-install — bootstrap installer for keenetic-entware-extras opkg feed
# Usage:
#   Interactive:  curl -fsSL https://0xkee.github.io/keenetic-entware-extras/install.sh | sh
#   With args:    curl -fsSL ... | sh -s -- geo-split webui
#   All packages: curl -fsSL ... | sh -s -- --all
#   Stable channel: curl -fsSL ... | sh -s -- --stable --all
#   Dev channel:    curl -fsSL ... | sh -s -- --dev --all
#   Force reinstall: curl -fsSL ... | sh -s -- --force --all
#   Uninstall:    curl -fsSL ... | sh -s -- --uninstall
#   Direct:       sh install.sh [--force] [--stable|--dev] [--all | --uninstall | package-names...]
set -eu

FEED_BASE="https://0xkee.github.io/keenetic-entware-extras"
FEED_NAME="kee"
AGGR6_FEED_BASE="https://0xkee.github.io/aggregate6"
AGGR6_FEED_NAME="aggr6"
CHANNEL=""
FORCE=false
UNINSTALL=false

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
REMOVED=0

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

# ── Version helpers (batch-optimized) ─────────────────────────────
# Caches: populated once by cache_version_info(), reused per menu line
_feed_versions=""
_installed_versions=""
_upgradable_cache=""

# Populate all version caches in 2 opkg calls + 1 file parse
cache_version_info() {
    printf "→ Checking installed packages..." >&2
    local idx="/opt/var/opkg-lists/${FEED_NAME}"
    if [ -f "$idx" ]; then
        _feed_versions=$(awk '/^Package:/{p=$2} /^Version:/{print p" "$2}' "$idx")
    fi
    _installed_versions=$(opkg list-installed 2>/dev/null || true)
    _upgradable_cache=$(opkg list-upgradable 2>/dev/null || true)
    printf "\r                                  \r" >&2
}

# Feed version for a package (from cached index)
pkg_feed_ver() {
    echo "$_feed_versions" | awk -v p="$1" '$1==p {print $2; exit}'
}

# Installed version for a package (from cached list)
# opkg list-installed format: "name - version"
pkg_installed_ver() {
    echo "$_installed_versions" | awk -v p="$1" '$1==p {print $3; exit}'
}

# Upgrade target version (from cached upgradable list, empty if none)
pkg_upgrade_ver() {
    echo "$_upgradable_cache" | awk -v p="$1" '$1==p {print $5; exit}'
}

# Upgradable catalog package names only (space-separated)
upgradable_pkgs() {
    for pkg in $ALL_PKGS; do
        echo "$_upgradable_cache" | grep -q "^${pkg} " && printf "%s " "$pkg"
    done
    return 0
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
    _add_extra_feed
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

# Add aggregate6 opkg feed (separate repository for aggregate6 binary)
# Uses per-architecture subdirectories: .../stable/mipsel-3.4/, .../dev/aarch64-3.10/ etc.
_add_extra_feed() {
    local name="$AGGR6_FEED_NAME"

    # Detect Entware architecture (e.g. mipsel-3.4, aarch64-3.10)
    local entware_arch
    entware_arch=$(opkg print-architecture 2>/dev/null | awk '$3 == 150 {print $2}')
    if [ -z "$entware_arch" ]; then
        warn "Cannot detect Entware architecture, skipping aggregate6 feed"
        return 0
    fi

    local feed_url="${AGGR6_FEED_BASE}/${CHANNEL}/${entware_arch}"

    if grep -q "^src/gz ${name} " /opt/etc/opkg.conf 2>/dev/null; then
        cur_url=$(sed -n "s|^src/gz ${name} ||p" /opt/etc/opkg.conf)
        if [ "$cur_url" = "$feed_url" ]; then
            return 0
        fi
        sed -i "s|^src/gz ${name} .*|src/gz ${name} ${feed_url}|" /opt/etc/opkg.conf
        echo "  🔄 Feed updated: ${name} → ${feed_url}"
        return 0
    fi

    printf "src/gz %s %s\n" "$name" "$feed_url" >> /opt/etc/opkg.conf
    echo "  ✅ Feed added: ${name} → ${feed_url}"
}

# ── Network helpers (opkg update fallbacks) ──────────────────────

# Run opkg update with a timeout (BusyBox has no timeout binary).
# Returns 0 on success, 1 on timeout/failure.
_opkg_update_with_timeout() {
    local secs="$1" tmp_out pid elapsed
    tmp_out="/tmp/kee-opkg-update-$$"

    opkg update > "$tmp_out" 2>&1 &
    pid=$!
    elapsed=0
    while [ "$elapsed" -lt "$secs" ]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" && { rm -f "$tmp_out"; return 0; }
            rm -f "$tmp_out"
            return 1
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done

    # Still running after timeout — kill it
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
    rm -f "$tmp_out" /opt/tmp/opkg.lock
    return 1
}

# Find a tunnel interface IP that can reach bin.entware.net.
# Prints the working IP and returns 0, or returns 1 if none found.
_find_tunnel_ip() {
    local ifaces iface ip test_url spider_pid elapsed
    ifaces=$(ip link show up 2>/dev/null \
        | grep -oE '(nwg|awg|ovpn|wg)[0-9]+' || true)
    [ -z "$ifaces" ] && return 1

    test_url=$(sed -n 's|^src/gz [^ ]* \(http://bin\.entware\.net/[^ ]*\)|\1|p' \
        /opt/etc/opkg.conf | head -1)
    [ -z "$test_url" ] && return 1

    for iface in $ifaces; do
        ip=$(ip addr show "$iface" 2>/dev/null \
            | grep -oE 'inet [0-9.]+' | head -1 | cut -d' ' -f2)
        [ -z "$ip" ] && continue
        # Hard 8s timeout: GNU wget -T is per-operation, not total;
        # with default 20 retries a throttled host takes minutes.
        wget --bind-address="$ip" -T 5 --tries=1 -q --spider \
            "${test_url}/Packages.gz" >/dev/null 2>&1 &
        spider_pid=$!
        elapsed=0
        while [ "$elapsed" -lt 8 ]; do
            if ! kill -0 "$spider_pid" 2>/dev/null; then
                wait "$spider_pid" && { echo "$ip"; return 0; }
                break  # spider failed, try next iface
            fi
            sleep 1
            elapsed=$((elapsed + 1))
        done
        if kill -0 "$spider_pid" 2>/dev/null; then
            kill "$spider_pid" 2>/dev/null
            wait "$spider_pid" 2>/dev/null || true
        fi
    done
    return 1
}

# Download a single feed index: Packages.gz → gunzip → /opt/var/opkg-lists/<name>
# Usage: _download_feed <name> <url> [bind_ip]
_download_feed() {
    local name="$1" url="$2" bind_ip="${3:-}"
    local dest="/opt/var/opkg-lists/$name"
    local rc=0

    if [ -n "$bind_ip" ]; then
        wget --bind-address="$bind_ip" -T 10 --tries=2 -q -O - \
            "${url}/Packages.gz" 2>/dev/null \
            | gunzip > "${dest}.tmp" 2>/dev/null || rc=1
    else
        wget -T 10 --tries=2 -q -O - "${url}/Packages.gz" 2>/dev/null \
            | gunzip > "${dest}.tmp" 2>/dev/null || rc=1
    fi

    if [ "$rc" -ne 0 ] || [ ! -s "${dest}.tmp" ]; then
        rm -f "${dest}.tmp"
        return 1
    fi
    mv "${dest}.tmp" "$dest"
}

# Download ALL feed indices via a tunnel (bind to tunnel IP).
_download_all_feeds_via_tunnel() {
    local bind_ip="$1" ok=0 fname furl line
    while IFS= read -r line; do
        fname=$(echo "$line" | awk '{print $2}')
        furl=$(echo "$line" | awk '{print $3}')
        [ -z "$fname" ] || [ -z "$furl" ] && continue
        if _download_feed "$fname" "$furl" "$bind_ip"; then
            ok=$((ok + 1))
            echo "     ✅ $fname"
        else
            echo "     ❌ $fname"
        fi
    done <<EOF
$(grep '^src/gz ' /opt/etc/opkg.conf)
EOF
    [ "$ok" -gt 0 ]
}

# Download only kee + aggr6 feeds directly (GitHub Pages — works without tunnel).
_download_kee_feeds_direct() {
    local name furl ok=0
    for name in "$FEED_NAME" "$AGGR6_FEED_NAME"; do
        furl=$(sed -n "s|^src/gz ${name} ||p" /opt/etc/opkg.conf)
        [ -z "$furl" ] && continue
        if _download_feed "$name" "$furl"; then
            ok=$((ok + 1))
            echo "     ✅ $name"
        else
            echo "     ❌ $name"
        fi
    done
    [ "$ok" -gt 0 ]
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

    # Strategy 1: try normal opkg update with 30s timeout
    if _opkg_update_with_timeout 15; then
        echo "  ✅ Package index updated"
        return 0
    fi

    # opkg update failed or timed out — try fallback downloads
    warn "opkg update failed (bin.entware.net may be unreachable)"
    info "Trying alternative download methods (this may take a while)..."

    # Strategy 2: find a working tunnel and download all feeds through it
    echo "  🔍 Looking for a working tunnel..."
    tunnel_ip=$(_find_tunnel_ip || true)
    if [ -n "$tunnel_ip" ]; then
        info "Downloading all feeds via tunnel ($tunnel_ip)..."
        if _download_all_feeds_via_tunnel "$tunnel_ip"; then
            echo "  ✅ Package indices downloaded via tunnel"
            return 0
        fi
    fi

    # Strategy 3: no tunnel — download only kee + aggr6 directly (GitHub Pages works)
    warn "No working tunnel found"
    info "Downloading kee feeds directly (GitHub Pages)..."
    if _download_kee_feeds_direct; then
        echo "  ✅ kee package indices downloaded"
        warn "Entware indices (bin.entware.net) not updated — route bin.entware.net through a tunnel to update"
        return 0
    fi

    # All strategies failed
    if [ -f "$idx_file" ]; then
        warn "Using stale package index"
        return 0
    fi
    die "Failed to update package index. Check network connectivity."
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
        # Non-fatal: opkg configured the package despite warnings
        # (e.g. remove_obsolesced_files for already-deleted files)
        if grep -q "Configuring ${pkg}\." "$_tmp" 2>/dev/null; then
            echo "  ⚠️  $pkg — installed with warnings"
            INSTALLED=$((INSTALLED + 1)); rm -f "$_tmp"; return 0
        fi
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

# ── Package removal ──────────────────────────────────────────────
# Removal order: reverse of catalog (webui first, base last)
# geo-split-data is added explicitly since it's not in the menu catalog
UNINSTALL_ORDER="webui net-check smartdns-redirect smartdns-geo-conf geo-split geo-split-data keenetic-entware-extras"

remove_pkg() {
    pkg="$1"
    if ! opkg status "$pkg" 2>/dev/null | grep -q "^Status:.*installed"; then
        echo "  ⏭  $pkg — not installed"
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi

    echo "  🗑  $pkg"
    if opkg remove "$pkg" 2>&1 | indent; then
        echo "  ✅ $pkg — removed"
        REMOVED=$((REMOVED + 1))
    else
        echo "  ❌ $pkg — removal failed"
        FAILED=$((FAILED + 1))
    fi
}

remove_feed() {
    if grep -q "^src/gz ${FEED_NAME} " /opt/etc/opkg.conf 2>/dev/null; then
        sed -i "/^src\/gz ${FEED_NAME} /d" /opt/etc/opkg.conf
        echo "  ✅ Feed '${FEED_NAME}' removed from opkg.conf"
    else
        echo "  ⏭  Feed '${FEED_NAME}' not found in opkg.conf"
    fi
    sed -i "/^src\/gz ${AGGR6_FEED_NAME} /d" /opt/etc/opkg.conf
}

do_uninstall() {
    echo ""
    echo "🗑  Uninstalling keenetic-entware-extras..."
    echo ""

    for pkg in $UNINSTALL_ORDER; do
        remove_pkg "$pkg"
    done

    echo ""
    remove_feed

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📊 Done: ✅ $REMOVED removed | ⏭  $SKIPPED skipped | ❌ $FAILED failed"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
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
    _menu_upgr_count=0
    _menu_new_count=0
    while [ "$i" -le "$PKG_COUNT" ]; do
        name=$(pkg_name "$i")
        desc=$(pkg_desc "$i")
        feed_ver=$(pkg_feed_ver "$name")
        inst_ver=$(pkg_installed_ver "$name")
        upgr_ver=$(pkg_upgrade_ver "$name")

        if [ -n "$upgr_ver" ]; then
            icon="🔄"
            ver_text="${inst_ver} -> ${upgr_ver}"
            _menu_upgr_count=$((_menu_upgr_count + 1))
        elif [ -n "$inst_ver" ]; then
            icon="✅"
            ver_text="${inst_ver}"
        else
            icon="· "
            ver_text="${feed_ver} new"
            _menu_new_count=$((_menu_new_count + 1))
        fi

        # icon is always 2 visual columns; ver_text is ASCII — %-18s pads reliably
        printf "  %d)  %-24s %s %-18s %s\n" "$i" "$name" "$icon" "$ver_text" "$desc"
        i=$((i + 1))
    done

    # Summary hint for updates/new packages
    if [ "$_menu_upgr_count" -gt 0 ] || [ "$_menu_new_count" -gt 0 ]; then
        echo ""
        hint="  💡"
        if [ "$_menu_upgr_count" -gt 0 ]; then
            hint="$hint ${_menu_upgr_count} update(s)"
        fi
        if [ "$_menu_new_count" -gt 0 ]; then
            [ "$_menu_upgr_count" -gt 0 ] && hint="$hint,"
            hint="$hint ${_menu_new_count} new"
        fi
        echo "${hint} — choose packages or press A to install all"
    fi

    echo ""
    echo "  A)  Install all packages"
    if [ "$_menu_upgr_count" -gt 0 ]; then
        echo "  P)  Upgrade ${_menu_upgr_count} package(s)"
    fi
    echo "  F)  Force reinstall all packages"
    echo "  C)  Change channel (stable/dev)"
    echo "  U)  Uninstall all packages"
    echo "  Q)  Quit"
    echo ""
}

read_choice() {
    # Prompt goes to stderr so it is not captured by $()
    printf "  Choose packages (e.g. 1 3 5, a=all, p=upgrade, f=force, u=uninstall, q=quit): " >&2
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
    parts=""
    [ "$INSTALLED" -gt 0 ] && parts="✅ $INSTALLED installed"
    [ "$UPGRADED" -gt 0 ]  && parts="${parts:+$parts | }🔄 $UPGRADED upgraded"
    [ "$SKIPPED" -gt 0 ]   && parts="${parts:+$parts | }⏭  $SKIPPED up to date"
    [ "$FAILED" -gt 0 ]    && parts="${parts:+$parts | }❌ $FAILED failed"
    echo "📊 Done: ${parts:-nothing to do}"
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
            --force)     FORCE=true ;;
            --stable)    CHANNEL="stable" ;;
            --dev)       CHANNEL="dev" ;;
            --uninstall) UNINSTALL=true ;;
            *)           remaining="${remaining:+$remaining }$arg" ;;
        esac
    done

    header
    check_root
    check_entware

    # Non-interactive uninstall
    if $UNINSTALL; then
        do_uninstall
        exit 0
    fi

    ensure_wget_ssl
    choose_channel
    add_feed
    _add_extra_feed
    update_index
    cache_version_info

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

        # Handle menu actions in parent shell
        case "$choice" in
            [Cc]) prompt_channel; cache_version_info; continue ;;
            [Ff]) FORCE=true; choice="A" ;;
            [Pp])
                pkgs=$(upgradable_pkgs)
                if [ -z "$(echo "$pkgs" | tr -d ' ')" ]; then
                    info "All packages are up to date"
                    continue
                fi
                install_packages "$pkgs"
                show_summary
                break
                ;;
            [Uu]) do_uninstall; exit 0 ;;
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

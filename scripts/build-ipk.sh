#!/bin/bash
# Build .ipk packages for keenetic-entware-extras.
# Usage: ./scripts/build-ipk.sh [keenetic-entware-extras|geo-split|smartdns-geo-conf|smartdns-redirect|net-check|webui|all]
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$PROJECT_ROOT/dist"

# ---------------------------------------------------------------------------
# Package contents (dirs auto-detected → cp -r, files → cp)
# ---------------------------------------------------------------------------

# keenetic-entware-extras → /opt/keenetic-entware-extras/
BASE_DATA=(lib/common.sh lib/geo.sh lib/zones.sh lib/lists.sh lib/ip.sh lib/privacy.sh lib/status.sh scripts/kee-status.sh scripts/bug-report.sh README.md CHANGELOG.md LICENSE)

# geo-split → /opt/keenetic-entware-extras/geo-split/
GEO_DATA=(config init.d loaders scripts docs/user-manual.ru.md README.md CHANGELOG.md)

# geo-split-data → /opt/keenetic-entware-extras/geo-split-data/
GEO_DATA_DATA=(lists/domains.txt lists/ru-whitelist.txt lists/geoip docs/user-manual.ru.md README.md CHANGELOG.md)

# smartdns-geo-conf → /opt/keenetic-entware-extras/smartdns-geo-conf/
SMARTDNS_DATA=(config init.d scripts/generate-conf.sh scripts/status.sh scripts/toggle.sh scripts/dns-check.sh docs/user-manual.ru.md README.md CHANGELOG.md)

# smartdns-redirect → /opt/keenetic-entware-extras/smartdns-redirect/
SMARTDNS_REDIRECT_DATA=(init.d scripts config docs/user-manual.ru.md README.md CHANGELOG.md)

# net-check → /opt/keenetic-entware-extras/net-check/
NET_CHECK_DATA=(config scripts README.md CHANGELOG.md)

# webui → /opt/keenetic-entware-extras/webui/
WEBUI_DATA=(config init.d lua patches static scripts docs/user-manual.ru.md README.md CHANGELOG.md)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

pkg_version() {
    grep '^Version:' "$PROJECT_ROOT/packaging/$1/control" | cut -d' ' -f2
}

# Assemble .ipk (tar.gz container expected by Entware opkg).
assemble_ipk() {
    local build_dir="$1" pkg="$2" version="$3"
    echo "2.0" > "$build_dir/debian-binary"
    local output="$DIST_DIR/${pkg}_${version}_all.ipk"
    (cd "$build_dir" && tar czf "$output" --owner=0 --group=0 \
        ./debian-binary ./control.tar.gz ./data.tar.gz)
    echo "Built: $output"
}

# Copy list items: directories get cp -r, files get cp.
# Usage: copy_list <src_base> <dest_dir> item1 item2 ...
copy_list() {
    local src_base="$1" dest="$2"; shift 2
    local item
    for item in "$@"; do
        local src="$src_base/$item"
        if [ -d "$src" ]; then
            mkdir -p "$dest/$(dirname "$item")"
            cp -r "$src" "$dest/$(dirname "$item")/"
        elif [ -f "$src" ]; then
            mkdir -p "$dest/$(dirname "$item")"
            cp "$src" "$dest/$item"
        fi
    done
}

# ---------------------------------------------------------------------------
# Build: keenetic-entware-extras
# ---------------------------------------------------------------------------
build_keenetic_entware_extras() {
    local pkg="keenetic-entware-extras"
    local version
    version="$(pkg_version "$pkg")"
    local build_dir
    build_dir="$(mktemp -d)"
    trap 'rm -rf "$build_dir"' RETURN

    # data.tar.gz
    local data_dir="$build_dir/data"
    mkdir -p "$data_dir/opt/keenetic-entware-extras/lib"
    copy_list "$PROJECT_ROOT" "$data_dir/opt/keenetic-entware-extras" "${BASE_DATA[@]}"
    (cd "$data_dir" && tar czf "$build_dir/data.tar.gz" --owner=0 --group=0 .)

    # control.tar.gz
    local ctrl_dir="$build_dir/control"
    mkdir -p "$ctrl_dir"
    cp "$PROJECT_ROOT/packaging/$pkg/"* "$ctrl_dir/"
    (cd "$ctrl_dir" && tar czf "$build_dir/control.tar.gz" --owner=0 --group=0 .)

    assemble_ipk "$build_dir" "$pkg" "$version"
}

# ---------------------------------------------------------------------------
# Build: geo-split
# ---------------------------------------------------------------------------
build_geo_split() {
    local pkg="geo-split"
    local version
    version="$(pkg_version "$pkg")"
    local build_dir
    build_dir="$(mktemp -d)"
    trap 'rm -rf "$build_dir"' RETURN

    local data_dir="$build_dir/data"
    local pkg_dir="$data_dir/opt/keenetic-entware-extras/geo-split"
    mkdir -p "$pkg_dir"

    # Data: directories + files from list
    copy_list "$PROJECT_ROOT/geo-split" "$pkg_dir" "${GEO_DATA[@]}"
    cp "$PROJECT_ROOT/LICENSE" "$pkg_dir/LICENSE"

    (cd "$data_dir" && tar czf "$build_dir/data.tar.gz" --owner=0 --group=0 .)

    # control.tar.gz — all files from packaging dir
    local ctrl_dir="$build_dir/control"
    mkdir -p "$ctrl_dir"
    cp "$PROJECT_ROOT/packaging/$pkg/"* "$ctrl_dir/"
    (cd "$ctrl_dir" && tar czf "$build_dir/control.tar.gz" --owner=0 --group=0 .)

    assemble_ipk "$build_dir" "$pkg" "$version"
}

# ---------------------------------------------------------------------------
# Build: geo-split-data
# ---------------------------------------------------------------------------
build_geo_split_data() {
    local pkg="geo-split-data"

    # Fetch/update zone files (skip if fresh)
    "$PROJECT_ROOT/geo-split-data/scripts/fetch-zones.sh"

    local version
    version="$(pkg_version "$pkg")"
    local build_dir
    build_dir="$(mktemp -d)"
    trap 'rm -rf "$build_dir"' RETURN

    local data_dir="$build_dir/data"
    local pkg_dir="$data_dir/opt/keenetic-entware-extras/geo-split-data"
    mkdir -p "$pkg_dir"
    copy_list "$PROJECT_ROOT/geo-split-data" "$pkg_dir" "${GEO_DATA_DATA[@]}"
    cp "$PROJECT_ROOT/LICENSE" "$pkg_dir/LICENSE"
    (cd "$data_dir" && tar czf "$build_dir/data.tar.gz" --owner=0 --group=0 .)

    local ctrl_dir="$build_dir/control"
    mkdir -p "$ctrl_dir"
    cp "$PROJECT_ROOT/packaging/$pkg/"* "$ctrl_dir/"
    (cd "$ctrl_dir" && tar czf "$build_dir/control.tar.gz" --owner=0 --group=0 .)

    assemble_ipk "$build_dir" "$pkg" "$version"
}

# ---------------------------------------------------------------------------
# Build: smartdns-geo-conf
# ---------------------------------------------------------------------------
build_smartdns_geo_conf() {
    local pkg="smartdns-geo-conf"
    local version
    version="$(pkg_version "$pkg")"
    local build_dir
    build_dir="$(mktemp -d)"
    trap 'rm -rf "$build_dir"' RETURN

    local data_dir="$build_dir/data"
    local pkg_dir="$data_dir/opt/keenetic-entware-extras/smartdns-geo-conf"
    mkdir -p "$pkg_dir"

    # Data: directories + files from list
    copy_list "$PROJECT_ROOT/smartdns-geo-conf" "$pkg_dir" "${SMARTDNS_DATA[@]}"
    cp "$PROJECT_ROOT/LICENSE" "$pkg_dir/LICENSE"


    # Config → /opt/etc/smartdns/ deployed by postinst + S37 init (not in data.tar.gz).
    # Avoids check_data_file_clashes with upstream smartdns package which owns
    # /opt/etc/smartdns/smartdns.conf via conffiles.

    (cd "$data_dir" && tar czf "$build_dir/data.tar.gz" --owner=0 --group=0 .)

    # control.tar.gz — all files from packaging dir
    local ctrl_dir="$build_dir/control"
    mkdir -p "$ctrl_dir"
    cp "$PROJECT_ROOT/packaging/$pkg/"* "$ctrl_dir/"
    (cd "$ctrl_dir" && tar czf "$build_dir/control.tar.gz" --owner=0 --group=0 .)

    assemble_ipk "$build_dir" "$pkg" "$version"
}

# ---------------------------------------------------------------------------
# Build: smartdns-redirect
# ---------------------------------------------------------------------------
build_smartdns_redirect() {
    local pkg="smartdns-redirect"
    local version
    version="$(pkg_version "$pkg")"
    local build_dir
    build_dir="$(mktemp -d)"
    trap 'rm -rf "$build_dir"' RETURN

    local data_dir="$build_dir/data"
    local pkg_dir="$data_dir/opt/keenetic-entware-extras/smartdns-redirect"
    mkdir -p "$pkg_dir"

    # Data: scripts + config directories
    copy_list "$PROJECT_ROOT/smartdns-redirect" "$pkg_dir" "${SMARTDNS_REDIRECT_DATA[@]}"
    cp "$PROJECT_ROOT/LICENSE" "$pkg_dir/LICENSE"
    # README copied if exists (not yet created — no-op if absent)
    [ -f "$PROJECT_ROOT/smartdns-redirect/README.md" ] \
        && cp "$PROJECT_ROOT/smartdns-redirect/README.md" "$pkg_dir/README.md"

    (cd "$data_dir" && tar czf "$build_dir/data.tar.gz" --owner=0 --group=0 .)

    # control.tar.gz — all files from packaging dir
    local ctrl_dir="$build_dir/control"
    mkdir -p "$ctrl_dir"
    cp "$PROJECT_ROOT/packaging/$pkg/"* "$ctrl_dir/"
    (cd "$ctrl_dir" && tar czf "$build_dir/control.tar.gz" --owner=0 --group=0 .)

    assemble_ipk "$build_dir" "$pkg" "$version"
}

# ---------------------------------------------------------------------------
# Build: webui
# ---------------------------------------------------------------------------
build_webui() {
    local pkg="webui"
    local version
    version="$(pkg_version "$pkg")"
    local build_dir
    build_dir="$(mktemp -d)"
    trap 'rm -rf "$build_dir"' RETURN

    local data_dir="$build_dir/data"
    local pkg_dir="$data_dir/opt/keenetic-entware-extras/webui"
    mkdir -p "$pkg_dir"

    # Data: config, lua, static, scripts, rootfs, README
    copy_list "$PROJECT_ROOT/webui" "$pkg_dir" "${WEBUI_DATA[@]}"
    cp "$PROJECT_ROOT/LICENSE" "$pkg_dir/LICENSE"

    # Pre-compress static files for nginx gzip_static.
    # -9: best compression (build machine is fast, unlike MIPS router).
    # -k: keep originals for clients that don't accept gzip.
    local gz_count=0
    for f in "$pkg_dir"/static/*.js "$pkg_dir"/static/*.css "$pkg_dir"/static/*.html; do
        [ -f "$f" ] || continue
        gzip -9 -k "$f"
        gz_count=$((gz_count + 1))
    done
    echo "  gzip_static: pre-compressed $gz_count files in static/"

    (cd "$data_dir" && tar czf "$build_dir/data.tar.gz" --owner=0 --group=0 .)

    # control.tar.gz — all files from packaging dir
    local ctrl_dir="$build_dir/control"
    mkdir -p "$ctrl_dir"
    cp "$PROJECT_ROOT/packaging/$pkg/"* "$ctrl_dir/"
    (cd "$ctrl_dir" && tar czf "$build_dir/control.tar.gz" --owner=0 --group=0 .)

    assemble_ipk "$build_dir" "$pkg" "$version"
}

# ---------------------------------------------------------------------------
# Build: net-check
# ---------------------------------------------------------------------------
build_net_check() {
    local pkg="net-check"
    local version
    version="$(pkg_version "$pkg")"
    local build_dir
    build_dir="$(mktemp -d)"
    trap 'rm -rf "$build_dir"' RETURN

    local data_dir="$build_dir/data"
    local pkg_dir="$data_dir/opt/keenetic-entware-extras/net-check"
    mkdir -p "$pkg_dir"

    # Data: config + scripts + docs
    copy_list "$PROJECT_ROOT/net-check" "$pkg_dir" "${NET_CHECK_DATA[@]}"
    cp "$PROJECT_ROOT/LICENSE" "$pkg_dir/LICENSE"

    (cd "$data_dir" && tar czf "$build_dir/data.tar.gz" --owner=0 --group=0 .)

    # control.tar.gz — all files from packaging dir
    local ctrl_dir="$build_dir/control"
    mkdir -p "$ctrl_dir"
    cp "$PROJECT_ROOT/packaging/$pkg/"* "$ctrl_dir/"
    (cd "$ctrl_dir" && tar czf "$build_dir/control.tar.gz" --owner=0 --group=0 .)

    assemble_ipk "$build_dir" "$pkg" "$version"
}

# ---------------------------------------------------------------------------
mkdir -p "$DIST_DIR"

case "${1:-all}" in
    keenetic-entware-extras) build_keenetic_entware_extras ;;
    geo-split-data) build_geo_split_data ;;
    geo-split) build_geo_split ;;
    smartdns-geo-conf) build_smartdns_geo_conf ;;
    smartdns-redirect) build_smartdns_redirect ;;
    net-check) build_net_check ;;
    webui) build_webui ;;
    all) build_keenetic_entware_extras; build_geo_split_data; build_geo_split; build_smartdns_geo_conf; build_smartdns_redirect; build_net_check; build_webui ;;
    *) echo "Usage: $0 [keenetic-entware-extras|geo-split-data|geo-split|smartdns-geo-conf|smartdns-redirect|net-check|webui|all]"; exit 1 ;;
esac

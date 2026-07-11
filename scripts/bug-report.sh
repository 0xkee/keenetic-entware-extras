#!/opt/bin/sh
# bug-report.sh — collect diagnostics for forum bug reports
# Output is safe to post publicly (no passwords, keys, or WAN IPs).
set -eu

BASE="/opt/keenetic-entware-extras"
# shellcheck disable=SC1091
. "$BASE/lib/ip.sh"
SEP="──────────────────────────────────────────────"

section() {
    printf "\n%s\n  %s\n%s\n" "$SEP" "$1" "$SEP"
}

# ─── Helper: pick dynamic test targets from user's geo-split data ─────────────
# Sets: _GEO_IP, _GEO_DOMAIN, _NON_GEO_IP, _NON_GEO_DOMAIN
# Uses actual lists/caches — no hardcoded zones.

_GEO_IP="" _GEO_DOMAIN="" _NON_GEO_IP="1.1.1.1" _NON_GEO_DOMAIN="one.one.one.one"

_pick_geo_targets() {
    _domain_cache="$BASE/geo-split-data/lists/domains-resolved.txt"

    # GEO target: first IP+domain from domain cache (format: "IP # domain.com")
    if [ -f "$_domain_cache" ]; then
        _first_line=$(grep -v '^#' "$_domain_cache" | grep -v '^$' | head -1)
        if [ -n "$_first_line" ]; then
            _GEO_IP=$(echo "$_first_line" | awk '{print $1}')
            _GEO_DOMAIN=$(echo "$_first_line" | awk '{print $3}')
        fi
    fi

    # Fallback: first route in table 1000 (live kernel)
    if [ -z "$_GEO_IP" ] && command -v ip >/dev/null 2>&1; then
        _GEO_IP=$(ip route show table 1000 2>/dev/null | head -1 | awk '{print $1}' | sed 's|/32||')
    fi

    # Last fallback: first route in table 1001 (subnet CIDR — use network address)
    if [ -z "$_GEO_IP" ] && command -v ip >/dev/null 2>&1; then
        _cidr=$(ip route show table 1001 2>/dev/null | head -1 | awk '{print $1}')
        if [ -n "$_cidr" ]; then
            _GEO_IP=$(echo "$_cidr" | sed 's|/.*||')
        fi
    fi

    # GEO domain fallback: first domain from domains.txt (if cache was empty)
    if [ -z "$_GEO_DOMAIN" ]; then
        _domains_list="$BASE/geo-split-data/lists/domains.txt"
        if [ -f "$_domains_list" ]; then
            _GEO_DOMAIN=$(grep -v '^#' "$_domains_list" | grep -v '^@' | grep -v '^$' | head -1)
        fi
    fi

    # NON-GEO target: verify 1.1.1.1 is not in geo tables (edge case: user routes ALL)
    if command -v ip >/dev/null 2>&1; then
        for _candidate in 1.1.1.1 8.8.4.4 208.67.222.222; do
            if ! ip route show table 1001 match "$_candidate" 2>/dev/null | grep -q .; then
                _NON_GEO_IP="$_candidate"
                break
            fi
        done
    fi
}

_pick_geo_targets


# ─── 1. System info ──────────────────────────────────────────────────────────

section "System"

printf "Date: %s\n" "$(date '+%Y-%m-%d %H:%M:%S %Z')"

if command -v ndmc >/dev/null 2>&1; then
    printf "\nFirmware:\n"
    ndmc -c "show version" 2>/dev/null \
        | grep -E "^\s+(title|release|arch|cores|model|hw_id|hw_version|sandbox)" \
        | head -10 || echo "  (ndmc unavailable)"
else
    echo "ndmc: not found"
fi

printf "\nKernel: %s\n" "$(uname -r 2>/dev/null || echo 'unknown')"
printf "Arch:   %s\n" "$(uname -m 2>/dev/null || echo 'unknown')"
printf "FIB trie stats: %s\n" "$([ -f /proc/net/fib_triestat ] && echo 'available' || echo 'not available (old kernel)')"

# ─── 2. Memory & disk ────────────────────────────────────────────────────────

section "Memory & disk"

printf "Memory:\n"
if [ -f /proc/meminfo ]; then
    mem_total="$(grep MemTotal /proc/meminfo | awk '{print $2}')"
    mem_avail="$(grep MemAvailable /proc/meminfo | awk '{print $2}')"
    if [ -n "$mem_total" ] && [ -n "$mem_avail" ]; then
        mem_used=$((mem_total - mem_avail))
        printf "  Total: %d kB, Used: %d kB, Available: %d kB (%d%% used)\n" \
            "$mem_total" "$mem_used" "$mem_avail" \
            "$((mem_used * 100 / mem_total))"
    else
        head -5 /proc/meminfo
    fi
else
    free 2>/dev/null || echo "  (unavailable)"
fi

printf "\nDisk (/opt):\n"
df -h /opt 2>/dev/null | tail -1 | awk '{printf "  Size: %s, Used: %s, Avail: %s (%s used)\n", $2, $3, $4, $5}' \
    || echo "  (unavailable)"

# ─── 3. Installed packages ───────────────────────────────────────────────────

section "Installed packages (related)"

if command -v opkg >/dev/null 2>&1; then
    opkg list-installed 2>/dev/null \
        | grep -E "geo-split|smartdns|webui|keenetic-entware|nginx|^cron |^aggregate |^bind-dig |^ca-certificates |^coreutils-touch |^curl |^ip-full |^iptables |^logrotate " \
        || echo "  (none found)"
else
    echo "opkg: not found"
fi

# ─── 4. Service state (enabled/disabled) ─────────────────────────────────────

section "Service state (enabled/disabled)"

for init_name in S99geo-split S39smartdns-redirect S80nginx-webui; do
    if [ -L "/opt/etc/init.d/$init_name" ]; then
        printf "  %-26s ENABLED (symlink)\n" "$init_name"
    elif [ -f "$BASE/geo-split/init.d/$init_name" ] \
      || [ -f "$BASE/smartdns-redirect/init.d/$init_name" ] \
      || [ -f "$BASE/webui/init.d/$init_name" ]; then
        printf "  %-26s DISABLED (no symlink)\n" "$init_name"
    else
        printf "  %-26s not installed\n" "$init_name"
    fi
done

# ─── 5. User configs ─────────────────────────────────────────────────────────

section "User configs (config.conf)"

for pkg in geo-split smartdns-redirect smartdns-geo-conf webui; do
    conf="$BASE/$pkg/config/config.conf"
    if [ -f "$conf" ]; then
        printf "  %-28s EXISTS (%d lines)\n" "$pkg/config.conf" "$(wc -l < "$conf")"
    elif [ -d "$BASE/$pkg/config" ]; then
        printf "  %-28s (defaults only)\n" "$pkg/config.conf"
    fi
done

# ─── 6. geo-split config ─────────────────────────────────────────────────────

section "geo-split config (effective)"

_gs_conf="$BASE/geo-split/config"
if [ -d "$_gs_conf" ]; then
    # Run in subshell to avoid polluting our environment
    (
        _CONFIG_DIR="$_gs_conf"
        # shellcheck disable=SC1091
        . "$_gs_conf/defaults.conf"
        # shellcheck disable=SC1091
        [ -f "$_gs_conf/config.conf" ] && . "$_gs_conf/config.conf"
        printf "  ROUTE_OUT:             %s\n" "${ROUTE_OUT:-auto}"
        printf "  ROUTE_GW:              %s\n" "${ROUTE_GW:-auto}"
        printf "  ROUTE_IN:              %s\n" "${ROUTE_IN:-br0}"
        printf "  DOMAIN_ROUTE_TABLE:    %s\n" "${DOMAIN_ROUTE_TABLE:-1000}"
        printf "  SUBNET_ROUTE_TABLE:    %s\n" "${SUBNET_ROUTE_TABLE:-1001}"
        printf "  DOWNLOAD_INTERFACES:   %s\n" "${DOWNLOAD_INTERFACES:-default *}"
        printf "  DOMAINS_UPDATE_INTERVAL: %ss\n" "${DOMAINS_UPDATE_INTERVAL:-3600}"
    )
else
    echo "  (geo-split not installed)"
fi

# ─── 7. Service status ───────────────────────────────────────────────────────

section "Service status"

if [ -x "$BASE/scripts/kee-status.sh" ]; then
    "$BASE/scripts/kee-status.sh" -d -n 2>&1 | head -200 || true
elif [ -x /opt/bin/kee-status ]; then
    /opt/bin/kee-status -d -n 2>&1 | head -200 || true
else
    echo "kee-status.sh not found, running individual status scripts..."
    for script in "$BASE"/*/scripts/status.sh; do
        [ -x "$script" ] || continue
        pkg="$(echo "$script" | sed "s|$BASE/||;s|/scripts/status.sh||")"
        printf "\n--- %s ---\n" "$pkg"
        "$script" 2>&1 | head -50 || true
    done
fi

# ─── 8. DNS check ────────────────────────────────────────────────────────────

section "DNS check"

printf "Test targets (from your config/lists):\n"
printf "  GEO domain:    %s\n" "${_GEO_DOMAIN:-(none — no domains configured)}"
printf "  GEO IP:        %s\n" "${_GEO_IP:-(none — tables empty)}"
printf "  Non-GEO:       %s (%s)\n" "$_NON_GEO_DOMAIN" "$_NON_GEO_IP"

# SmartDNS direct (port 6053)
printf "\nSmartDNS direct (:6053):\n"
if command -v dig >/dev/null 2>&1; then
    if [ -n "$_GEO_DOMAIN" ]; then
        printf "  %s: " "$_GEO_DOMAIN"
        dig "$_GEO_DOMAIN" @127.0.0.1 -p 6053 +short +nocookie +time=3 2>&1 | head -1 || echo "FAILED"
    fi
    printf "  %s: " "$_NON_GEO_DOMAIN"
    dig "$_NON_GEO_DOMAIN" @127.0.0.1 -p 6053 +short +nocookie +time=3 2>&1 | head -1 || echo "FAILED"
elif command -v nslookup >/dev/null 2>&1; then
    if [ -n "$_GEO_DOMAIN" ]; then
        printf "  %s: " "$_GEO_DOMAIN"
        nslookup "$_GEO_DOMAIN" 127.0.0.1#6053 2>/dev/null | grep "Address" | tail -1 | awk '{print $2}' || echo "FAILED"
    fi
    printf "  %s: " "$_NON_GEO_DOMAIN"
    nslookup "$_NON_GEO_DOMAIN" 127.0.0.1#6053 2>/dev/null | grep "Address" | tail -1 | awk '{print $2}' || echo "FAILED"
else
    echo "  dig/nslookup: not installed"
fi

# System resolver (end-to-end)
printf "\nSystem resolver (end-to-end):\n"
if command -v dig >/dev/null 2>&1; then
    if [ -n "$_GEO_DOMAIN" ]; then
        printf "  %s: " "$_GEO_DOMAIN"
        dig "$_GEO_DOMAIN" +short +nocookie +time=3 2>&1 | head -1 || echo "FAILED"
    fi
    printf "  %s: " "$_NON_GEO_DOMAIN"
    dig "$_NON_GEO_DOMAIN" +short +nocookie +time=3 2>&1 | head -1 || echo "FAILED"
elif command -v nslookup >/dev/null 2>&1; then
    if [ -n "$_GEO_DOMAIN" ]; then
        printf "  %s: " "$_GEO_DOMAIN"
        nslookup "$_GEO_DOMAIN" 2>/dev/null | grep "Address" | tail -1 | awk '{print $2}' || echo "FAILED"
    fi
    printf "  %s: " "$_NON_GEO_DOMAIN"
    nslookup "$_NON_GEO_DOMAIN" 2>/dev/null | grep "Address" | tail -1 | awk '{print $2}' || echo "FAILED"
else
    echo "  (no DNS tools available)"
fi

printf "\nndnproxy config (ISP DNS):\n"
if [ -f /tmp/ndnproxymain.conf ]; then
    # Show dns_server lines; mask public IPs for privacy (private ranges shown as-is)
    grep '^dns_server' /tmp/ndnproxymain.conf | while IFS= read -r _line; do
        _masked="$(echo "$_line" | sed -E \
            -e 's/= (10\.[0-9]+\.[0-9]+\.[0-9]+)/= \1/g' \
            -e 's/= (172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+)/= \1/g' \
            -e 's/= (192\.168\.[0-9]+\.[0-9]+)/= \1/g' \
            -e 's/= ([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+/= \1.xxx/g')"
        printf "  %s\n" "$_masked"
    done
else
    echo "  (not found)"
fi

# SmartDNS upstream servers (from live config)
_smartdns_conf="/opt/etc/smartdns/smartdns.conf"
if [ -f "$_smartdns_conf" ]; then
    printf "\nSmartDNS upstreams:\n"
    # Extract unique server URLs/IPs with protocol type, strip multi-line markers
    grep -h "^server" "$_smartdns_conf" /opt/etc/smartdns/dns-servers-*.conf 2>/dev/null \
        | sed 's/ *\\$//' \
        | awk '{print $1, $2}' \
        | sort -u \
        | sed 's/^/  /' | head -15
    _srv_count=$(grep -hc "^server" "$_smartdns_conf" /opt/etc/smartdns/dns-servers-*.conf 2>/dev/null \
        | awk '{s+=$1}END{print s}')
    [ -n "$_srv_count" ] && printf "  (%s server entries total)\n" "$_srv_count"
fi

# ─── 9. Connectivity ─────────────────────────────────────────────────────────

section "Connectivity"

check_url() {
    url="$1"
    label="$2"
    if command -v curl >/dev/null 2>&1; then
        code="$(curl -so /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$url" 2>/dev/null)" || code="000"
        printf "  %s → %s\n" "$label" "$code"
    elif command -v wget >/dev/null 2>&1; then
        if wget -q --spider --timeout=5 "$url" 2>/dev/null; then
            printf "  %s → OK\n" "$label"
        else
            printf "  %s → FAIL\n" "$label"
        fi
    fi
}

printf "HTTP reachability:\n"
if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
    if [ -n "$_GEO_DOMAIN" ]; then
        check_url "http://$_GEO_DOMAIN" "$_GEO_DOMAIN (GEO)"
    fi
    check_url "http://$_NON_GEO_DOMAIN" "$_NON_GEO_DOMAIN (non-GEO)"
else
    echo "  curl/wget: not installed"
fi

# WebUI upstream (stock httpd) probe
printf "\nWebUI upstream (stock Keenetic httpd):\n"
if [ -f "$BASE/webui/config/listen.conf" ]; then
    _upstream=$(sed -n 's|.*stock_httpd *http://\([^;]*\);|\1|p' "$BASE/webui/config/listen.conf")
    if [ -n "$_upstream" ] && command -v curl >/dev/null 2>&1; then
        _code=$(curl -so /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 3 "http://$_upstream/" 2>/dev/null) || _code="000"
        printf "  %s → %s\n" "$_upstream" "$_code"
    else
        printf "  upstream: %s (not probed)\n" "${_upstream:-(unknown)}"
    fi
else
    printf "  (webui not configured)\n"
fi

# ─── 10. Routes & rules (geo-split) ──────────────────────────────────────────

section "Routes & rules"

if command -v ip >/dev/null 2>&1; then
    printf "ip rules (geo-split):\n"
    ip rule show 2>/dev/null | grep -E "1000|1001" | head -10 || echo "  (no geo-split rules)"

    printf "\nRoute counts:\n"
    printf "  table 1000 (domains):  %s routes\n" \
        "$(table_route_count 1000)"
    printf "  table 1001 (subnets):  %s routes\n" \
        "$(table_route_count 1001)"

    # ISP interface and gateway (auto-detected)
    printf "\nISP detection (auto):\n"
    _out_iface=$(detect_out_iface)
    if [ -n "$_out_iface" ]; then
        _gw=$(detect_gateway "$_out_iface")
        printf "  Interface: %s\n" "$_out_iface"
        printf "  Gateway:   %s\n" "${_gw:-(none — point-to-point/LTE)}"
    else
        printf "  (no ISP interface detected)\n"
    fi

    # Default route (what non-geo traffic hits)
    printf "\nDefault route (non-geo traffic):\n"
    _main_def=$(ip route show default 2>/dev/null | head -3)
    if [ -n "$_main_def" ]; then
        echo "$_main_def" | sed 's/^/  /'
    else
        printf "  (no default route in main table)\n"
    fi

    # Keenetic policy rules (non-geo-split, prio > 100)
    printf "\nKeenetic policy rules (VPN/other, prio>100):\n"
    _policy_rules=$(ip rule show 2>/dev/null | grep -vE "^(0:|50:|51:|32[67])" | head -15)
    if [ -n "$_policy_rules" ]; then
        echo "$_policy_rules" | sed 's/^/  /'
    else
        printf "  (none — only default rules)\n"
    fi

    # Effectiveness check: geo-split ROUTE_OUT vs default route
    _def_iface=$(ip route | grep "^default" | sed -n 's/.*dev \([^ ]*\).*/\1/p' | head -1)
    _geo_iface=""
    _geo_iface=$(ip route show table 1001 2>/dev/null | head -1 | sed -n 's/.*dev \([^ ]*\).*/\1/p')
    _vpn_up=$(ip -brief link show 2>/dev/null | grep -E "^(nwg|awg|ovpn|tun|tap|wg)" | grep -v "DOWN" | awk '{print $1}' | tr '\n' ' ')

    printf "\nRouting effectiveness:\n"
    if [ -n "$_geo_iface" ] && [ -n "$_def_iface" ]; then
        if [ "$_geo_iface" = "$_def_iface" ]; then
            if [ -n "$_vpn_up" ] && [ -z "$_policy_rules" ]; then
                printf "  ⚠ geo-split routes through %s = same as default route!\n" "$_geo_iface"
                printf "    VPN interfaces UP: %s\n" "$_vpn_up"
                printf "    No Keenetic policy rules found → non-geo traffic stays on ISP.\n"
                printf "    Fix: configure VPN routing in Keenetic (per-device or global policy).\n"
            elif [ -n "$_vpn_up" ] && [ -n "$_policy_rules" ]; then
                printf "  ✓ geo-split: %s (= default), Keenetic policy rules active\n" "$_geo_iface"
                printf "    VPN interfaces UP: %s\n" "$_vpn_up"
                printf "    Non-geo traffic handled by Keenetic fwmark policy (prio 100+).\n"
            else
                printf "  ℹ geo-split routes through %s (= default). No VPN detected.\n" "$_geo_iface"
            fi
        else
            printf "  ✓ geo-split: %s, default: %s (split active)\n" "$_geo_iface" "$_def_iface"
        fi
    elif [ -z "$_geo_iface" ]; then
        printf "  — geo-split tables empty (not running?)\n"
    fi

    # Actual route type in tables
    printf "\nRoute type in tables:\n"
    _sample=$(ip route show table 1001 2>/dev/null | head -1)
    if [ -n "$_sample" ]; then
        if echo "$_sample" | grep -q "via "; then
            _rgw=$(echo "$_sample" | sed -n 's/.*via \([^ ]*\).*/\1/p')
            printf "  table 1001: via %s (gateway mode)\n" "$_rgw"
        else
            printf "  table 1001: dev-only (scope link, no gateway)\n"
        fi
    else
        printf "  table 1001: (empty)\n"
    fi
    _sample=$(ip route show table 1000 2>/dev/null | head -1)
    if [ -n "$_sample" ]; then
        if echo "$_sample" | grep -q "via "; then
            _rgw=$(echo "$_sample" | sed -n 's/.*via \([^ ]*\).*/\1/p')
            printf "  table 1000: via %s (gateway mode)\n" "$_rgw"
        else
            printf "  table 1000: dev-only (scope link, no gateway)\n"
        fi
    else
        printf "  table 1000: (empty)\n"
    fi

    printf "\nSample routes (table 1000, first 3):\n"
    ip route show table 1000 2>/dev/null | head -3 | sed 's/^/  /'

    # ROUTE_OUT interface stats (TX/RX — shows if VPN/tunnel transmits)
    if [ -n "$_geo_iface" ] && [ "$_geo_iface" != "$_def_iface" ]; then
        printf "\nROUTE_OUT interface stats (%s):\n" "$_geo_iface"
        _stats=$(ip -s link show "$_geo_iface" 2>/dev/null | grep -A1 "RX:\|TX:" | head -6)
        if [ -n "$_stats" ]; then
            echo "$_stats" | sed 's/^/  /'
        else
            printf "  (interface stats unavailable)\n"
        fi
    fi

    # Routing validation (ip route get — proves policy routing works)
    printf "\nRouting validation (ip route get %s):\n" "${_GEO_IP:-<no target>}"
    if [ -n "$_GEO_IP" ]; then
        _rget=$(ip route get "$_GEO_IP" 2>&1 | head -2)
        if [ -n "$_rget" ]; then
            echo "$_rget" | sed 's/^/  /'
        else
            printf "  (route get failed)\n"
        fi
        # Also test with fibmatch for table lookup visibility (kernel 4.4+)
        _rget_fib=$(ip route get fibmatch "$_GEO_IP" 2>/dev/null | head -3)
        if [ -n "$_rget_fib" ]; then
            printf "  fibmatch:\n"
            echo "$_rget_fib" | sed 's/^/    /'
        fi
    else
        printf "  (no GEO target available — tables empty?)\n"
    fi

    # rp_filter (reverse path filtering — can break policy routing)
    printf "\nReverse path filter (rp_filter):\n"
    for _rpf_iface in all br0; do
        _rpf_val=""
        [ -f "/proc/sys/net/ipv4/conf/$_rpf_iface/rp_filter" ] && \
            _rpf_val=$(cat "/proc/sys/net/ipv4/conf/$_rpf_iface/rp_filter" 2>/dev/null)
        printf "  %s: %s\n" "$_rpf_iface" "${_rpf_val:-(not available)}"
    done
    if [ -n "$_geo_iface" ]; then
        _rpf_val=""
        [ -f "/proc/sys/net/ipv4/conf/$_geo_iface/rp_filter" ] && \
            _rpf_val=$(cat "/proc/sys/net/ipv4/conf/$_geo_iface/rp_filter" 2>/dev/null)
        printf "  %s: %s\n" "$_geo_iface" "${_rpf_val:-(not available)}"
    fi
else
    echo "ip: not found"
fi

# ─── 11. Client-path verification ────────────────────────────────────────────

section "Client-path verification"

if command -v ip >/dev/null 2>&1 && [ -n "$_GEO_IP" ]; then
    # Determine ROUTE_IN from config (first interface)
    _route_in="br0"
    if [ -d "$_gs_conf" ]; then
        _route_in=$(
            _CONFIG_DIR="$_gs_conf"
            # shellcheck disable=SC1091
            . "$_gs_conf/defaults.conf"
            # shellcheck disable=SC1091
            [ -f "$_gs_conf/config.conf" ] && . "$_gs_conf/config.conf"
            echo "${ROUTE_IN:-br0}" | awk '{print $1}'
        )
    fi

    # Get a client IP for simulation (NOT the router itself — kernel rejects local src with iif)
    # Strategy: ARP table (real connected client) → fallback: derive .100 from router IP
    _lan_ip=""
    _real_client=$(ip neigh show dev "$_route_in" 2>/dev/null \
        | grep -v "FAILED\|INCOMPLETE" | awk '{print $1}' | grep -v ':' | head -1)
    if [ -n "$_real_client" ]; then
        _lan_ip="$_real_client"
    else
        # Fallback: take router's IP, replace last octet with 100
        _router_ip=$(ip -4 addr show "$_route_in" 2>/dev/null | grep -o 'inet [^ /]*' | awk '{print $2}' | head -1)
        if [ -n "$_router_ip" ]; then
            _lan_ip=$(echo "$_router_ip" | sed 's/\.[0-9]*$/.100/')
        fi
    fi

    printf "Simulating client traffic (iif %s, src %s):\n\n" "$_route_in" "${_lan_ip:-(unknown)}"

    if [ -n "$_lan_ip" ]; then
        # GEO target (should go through geo-split table → ROUTE_OUT interface)
        _client_geo=$(ip route get "$_GEO_IP" from "$_lan_ip" iif "$_route_in" 2>&1 | head -1)
        printf "  GEO target %s" "$_GEO_IP"
        [ -n "$_GEO_DOMAIN" ] && printf " (%s)" "$_GEO_DOMAIN"
        printf ":\n    %s\n" "$_client_geo"

        # NON-GEO target (should go through default route, NOT geo-split)
        _client_nongeo=$(ip route get "$_NON_GEO_IP" from "$_lan_ip" iif "$_route_in" 2>&1 | head -1)
        printf "  Non-GEO target %s (%s):\n    %s\n" "$_NON_GEO_IP" "$_NON_GEO_DOMAIN" "$_client_nongeo"

        # Extract interfaces and tables
        _geo_client_dev=$(echo "$_client_geo" | sed -n 's/.*dev \([^ ]*\).*/\1/p')
        _nongeo_client_dev=$(echo "$_client_nongeo" | sed -n 's/.*dev \([^ ]*\).*/\1/p')
        _geo_client_table=$(echo "$_client_geo" | sed -n 's/.*table \([^ ]*\).*/\1/p')

        # Check Keenetic fwmark VPN routing (stock policy for non-GEO traffic)
        # Iterate fwmark rules to find one that routes through a VPN interface
        _kee_fwmark="" _kee_vpn_dev=""
        _fwmarks=$(ip rule show 2>/dev/null | grep "fwmark" \
            | sed -n 's/.*fwmark \([^ ]*\).*/\1/p')
        for _fm in $_fwmarks; do
            _fm_route=$(ip route get "$_NON_GEO_IP" mark "$_fm" 2>/dev/null | head -1)
            _fm_dev=$(echo "$_fm_route" | sed -n 's/.*dev \([^ ]*\).*/\1/p')
            # Check if this routes through a VPN/tunnel interface
            if echo "$_fm_dev" | grep -qE "^(nwg|awg|ovpn|tun|tap|wg|l2tp|pptp|sstp)"; then
                _kee_fwmark="$_fm"
                _kee_vpn_dev="$_fm_dev"
                break
            fi
        done

        printf "\n  Split-routing verdict (client perspective):\n"
        if [ -n "$_geo_client_dev" ] && [ -n "$_nongeo_client_dev" ]; then
            if [ "$_geo_client_dev" != "$_nongeo_client_dev" ]; then
                # Case 1: Different interfaces (e.g. GEO→VPN, non-GEO→ISP via default)
                printf "    ✓ GEO → %s, non-GEO → %s (split ACTIVE — different interfaces)\n" \
                    "$_geo_client_dev" "$_nongeo_client_dev"
            elif [ -n "$_geo_client_table" ] && echo "$_geo_client_table" | grep -qE "^(1000|1001)$"; then
                # Case 2: Same interface but GEO hits geo-split table (e.g. both→ISP, VPN via fwmark)
                printf "    ✓ GEO → %s (table %s), non-GEO → %s (default route)\n" \
                    "$_geo_client_dev" "$_geo_client_table" "$_nongeo_client_dev"
                printf "      geo-split policy routing active (GEO hits table %s).\n" "$_geo_client_table"
                if [ -n "$_kee_vpn_dev" ]; then
                    printf "    ✓ Keenetic VPN policy: non-GEO → %s (fwmark %s)\n" \
                        "$_kee_vpn_dev" "$_kee_fwmark"
                elif [ -n "$_fwmarks" ]; then
                    printf "    ℹ Keenetic fwmark policies exist but no VPN interface found.\n"
                    printf "      Non-GEO traffic goes via default route (%s).\n" "$_nongeo_client_dev"
                else
                    printf "    ℹ No Keenetic fwmark policy. Non-GEO via default route (%s).\n" \
                        "$_nongeo_client_dev"
                fi
            else
                # Case 3: Same interface, no geo-split table hit
                printf "    ⚠ GEO → %s, non-GEO → %s (SAME path, no geo-split table hit!)\n" \
                    "$_geo_client_dev" "$_nongeo_client_dev"
                if [ -n "$_kee_vpn_dev" ]; then
                    printf "    ℹ Keenetic VPN policy active: fwmark %s → %s\n" "$_kee_fwmark" "$_kee_vpn_dev"
                fi
            fi
        else
            printf "    ? Could not determine interfaces (route get parse failed)\n"
            printf "      geo raw: %s\n" "$_client_geo"
            printf "      non-geo raw: %s\n" "$_client_nongeo"
        fi

        # Reachability checks — run both ICMP (ping) and HTTP (curl) probes.
        # Use source IP for ping -I to leverage Keenetic policy routing rules.
        # ping -I <dev> uses SO_BINDTODEVICE which fails when the default route
        # points to a different interface (e.g. VPN-as-default + ISP for geo).
        # ping -I <src_ip> triggers "from <ip> lookup <table>" rules correctly.
        printf "\n  Reachability:\n"

        # GEO target through geo-split interface
        if [ -n "$_geo_client_dev" ]; then
            _geo_src=$(ip -4 addr show dev "$_geo_client_dev" 2>/dev/null \
                | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)
            _geo_ping_src="${_geo_src:-$_geo_client_dev}"
            _cr_ping="FAIL"; _cr_http=""
            ping -I "$_geo_ping_src" -c 1 -W 3 "$_GEO_IP" >/dev/null 2>&1 && _cr_ping="OK"
            if [ -n "$_GEO_DOMAIN" ] && command -v curl >/dev/null 2>&1; then
                _cr_http=$(curl -so /dev/null -w '%{http_code}' \
                    --interface "$_geo_client_dev" \
                    --connect-timeout 5 --max-time 10 \
                    "http://$_GEO_DOMAIN" 2>/dev/null) || _cr_http="000"
                [ "$_cr_http" = "000" ] && _cr_http="FAIL"
            fi
            printf "    GEO  (%s → %s): " "$_geo_client_dev" "$_GEO_IP"
            if [ "$_cr_ping" = "OK" ] && [ -n "$_cr_http" ] && [ "$_cr_http" != "FAIL" ]; then
                printf "✓ ping OK, HTTP %s\n" "$_cr_http"
            elif [ "$_cr_ping" = "OK" ]; then
                printf "✓ ping OK\n"
            elif [ -n "$_cr_http" ] && [ "$_cr_http" != "FAIL" ]; then
                printf "⚠ ping FAIL, HTTP %s (route works; ICMP blocked?)\n" "$_cr_http"
            else
                printf "✗ FAIL (interface down? no NAT?)\n"
            fi
        fi

        # Non-GEO target — through VPN if found, otherwise through default
        _nongeo_ping_dev="${_kee_vpn_dev:-$_nongeo_client_dev}"
        if [ -n "$_nongeo_ping_dev" ]; then
            _nongeo_src=$(ip -4 addr show dev "$_nongeo_ping_dev" 2>/dev/null \
                | sed -n 's/.*inet \([0-9.]*\).*/\1/p' | head -1)
            _nongeo_ping_src="${_nongeo_src:-$_nongeo_ping_dev}"
            _cr_ping="FAIL"; _cr_http=""
            ping -I "$_nongeo_ping_src" -c 1 -W 3 "$_NON_GEO_IP" >/dev/null 2>&1 && _cr_ping="OK"
            if command -v curl >/dev/null 2>&1; then
                _cr_http=$(curl -so /dev/null -w '%{http_code}' \
                    --interface "$_nongeo_ping_dev" \
                    --connect-timeout 5 --max-time 10 \
                    "http://$_NON_GEO_DOMAIN" 2>/dev/null) || _cr_http="000"
                [ "$_cr_http" = "000" ] && _cr_http="FAIL"
            fi
            printf "    non-GEO (%s → %s): " "$_nongeo_ping_dev" "$_NON_GEO_IP"
            if [ "$_cr_ping" = "OK" ] && [ -n "$_cr_http" ] && [ "$_cr_http" != "FAIL" ]; then
                printf "✓ ping OK, HTTP %s\n" "$_cr_http"
            elif [ "$_cr_ping" = "OK" ]; then
                printf "✓ ping OK\n"
            elif [ -n "$_cr_http" ] && [ "$_cr_http" != "FAIL" ]; then
                printf "⚠ ping FAIL, HTTP %s (route works; ICMP blocked?)\n" "$_cr_http"
            else
                printf "✗ FAIL"
                if echo "$_nongeo_ping_dev" | grep -qE "^(nwg|awg|ovpn|tun|tap|wg)"; then
                    printf " (VPN tunnel down? no connectivity?)"
                fi
                printf "\n"
            fi
        fi

        # NAT check for client traffic through geo-split interface
        if [ -n "$_geo_client_dev" ] && command -v iptables >/dev/null 2>&1; then
            printf "\n  NAT for client traffic via %s:\n" "$_geo_client_dev"
            _nat_match=$(iptables -t nat -L POSTROUTING -n -v 2>/dev/null \
                | grep -i "masq\|snat" | grep "$_geo_client_dev" || true)
            if [ -n "$_nat_match" ]; then
                echo "$_nat_match" | sed 's/^/    /'
            else
                # Check for blanket MASQUERADE (common on Keenetic — covers all)
                _nat_all=$(iptables -t nat -L POSTROUTING -n -v 2>/dev/null \
                    | grep -i "masq" | grep "0.0.0.0/0.*0.0.0.0/0" || true)
                if [ -n "$_nat_all" ]; then
                    printf "    ✓ Blanket MASQUERADE detected (covers all interfaces)\n"
                else
                    printf "    ⚠ No MASQUERADE/SNAT for %s — return traffic may fail!\n" "$_geo_client_dev"
                fi
            fi
        fi
    else
        printf "  (cannot determine LAN IP for interface %s)\n" "$_route_in"
    fi
elif [ -z "$_GEO_IP" ]; then
    printf "  (no GEO targets found — tables empty, domain cache missing)\n"
    printf "  Hint: run '/opt/etc/init.d/S99geo-split start' to populate routes.\n"
else
    printf "  (ip command not found)\n"
fi

# ─── 12. Netfilter rules (smartdns-redirect) ─────────────────────────────────

section "Netfilter (DNS redirect)"

if command -v iptables >/dev/null 2>&1; then
    printf "iptables NAT (DNAT/REDIRECT :53):\n"
    iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null \
        | grep -E "53|smartdns|REDIRECT|DNAT" | head -20 || echo "  (no DNS redirect rules)"

    # POSTROUTING NAT (MASQUERADE/SNAT for VPN — critical for tunnel routing)
    printf "\niptables NAT (POSTROUTING, VPN/tunnel):\n"
    _postrouting=$(iptables -t nat -L POSTROUTING -n -v 2>/dev/null \
        | grep -E "MASQ|SNAT|nwg|awg|ovpn|gre|tun|tap" | head -10)
    if [ -n "$_postrouting" ]; then
        echo "$_postrouting" | sed 's/^/  /'
    else
        printf "  (no VPN MASQUERADE/SNAT rules)\n"
    fi
else
    echo "iptables: not found"
fi

# ─── 13. Network interfaces ──────────────────────────────────────────────────

section "Network interfaces (UP only, no IPs)"

if command -v ip >/dev/null 2>&1; then
    # Show interface names & state only (no addresses = no leaks)
    ip -brief link show 2>/dev/null | grep -v "DOWN" | awk '{printf "%-16s %s\n", $1, $2}' | head -30

    # Show only private (safe) LAN assignments for key bridges
    printf "\nLAN assignments:\n"
    ip -brief addr show 2>/dev/null \
        | grep -E "^(br|lo)" \
        | awk '{printf "  %-16s", $1; for(i=3;i<=NF;i++){if($i~/^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|127\.|fe80:|fd)/)printf " %s",$i}; printf "\n"}' \
        | head -10

    # VPN/tunnel interfaces (critical for geo-split routing)
    printf "\nVPN/tunnel interfaces:\n"
    _vpn_ifaces=$(ip -brief link show 2>/dev/null \
        | grep -E "^(nwg|awg|ovpn|l2tp|pptp|tun|tap|wg)" \
        | awk '{printf "  %-16s %s\n", $1, $2}')
    if [ -n "$_vpn_ifaces" ]; then
        echo "$_vpn_ifaces"
    else
        echo "  (none detected)"
    fi
else
    echo "  (ip command not found)"
fi

# ─── 14. Edge-case diagnostics ───────────────────────────────────────────────

section "Edge-case diagnostics"

if command -v ip >/dev/null 2>&1; then
    # IPv6 leak: if IPv6 default route exists, geo-split (IPv4-only) is bypassed
    _v6_def=$(ip -6 route show default 2>/dev/null | head -2)
    printf "IPv6 default route:\n"
    if [ -n "$_v6_def" ]; then
        echo "$_v6_def" | sed 's/^/  /'
        printf "  ⚠ IPv6 is active — dual-stack sites may bypass geo-split (IPv4-only).\n"
    else
        printf "  (none — IPv6 not routed, no leak risk)\n"
    fi

    # Full ip rule (priority conflicts, other policy routing)
    printf "\nFull ip rule show:\n"
    ip rule show 2>/dev/null | head -25 | sed 's/^/  /'

    # MTU on VPN/tunnel interfaces (reduced MTU — expected, shown for TCP MSS diagnostics)
    printf "\nVPN interface MTU:\n"
    _shown_mtu=0
    ip -brief link show 2>/dev/null | grep -E "^(nwg|awg|ovpn|tun|tap|wg|l2tp|pptp|ngre|gre)" | while IFS= read -r _line; do
        _if_name=$(echo "$_line" | awk '{print $1}')
        _mtu=$(ip link show "$_if_name" 2>/dev/null | sed -n 's/.*mtu \([0-9]*\).*/\1/p')
        if [ -n "$_mtu" ]; then
            printf "  %-16s MTU %s\n" "$_if_name" "$_mtu"
        fi
    done
    _def_mtu=$(ip link show br0 2>/dev/null | sed -n 's/.*mtu \([0-9]*\).*/\1/p')
    printf "  br0 (reference): MTU %s\n" "${_def_mtu:-unknown}"

    # Multiple default routes (dual-WAN / bonding)
    _def_count=$(ip route | grep -c "^default" 2>/dev/null) || _def_count=0
    if [ "$_def_count" -gt 1 ]; then
        printf "\n⚠ Multiple default routes (%s):\n" "$_def_count"
        ip route | grep "^default" | sed 's/^/  /'
    fi
fi

# Keenetic DNS interception (OUTPUT chain — may conflict with smartdns-redirect)
if command -v iptables >/dev/null 2>&1; then
    _out_dns=$(iptables -t nat -L OUTPUT -n 2>/dev/null | grep -E "53|DNS" | head -5)
    if [ -n "$_out_dns" ]; then
        printf "\niptables OUTPUT DNS (Keenetic filter profiles):\n"
        echo "$_out_dns" | sed 's/^/  /'
    fi
fi

# ROUTE_OUT interface health checks
_gs_conf_dir="$BASE/geo-split/config"
if [ -d "$_gs_conf_dir" ]; then
    (
        _CONFIG_DIR="$_gs_conf_dir"
        # shellcheck disable=SC1091
        . "$_gs_conf_dir/defaults.conf"
        # shellcheck disable=SC1091
        [ -f "$_gs_conf_dir/config.conf" ] && . "$_gs_conf_dir/config.conf"
        _cfg_out="${ROUTE_OUT:-auto}"

        # Check: explicit ROUTE_OUT interface exists and is UP
        if [ "$_cfg_out" != "auto" ] && [ -n "$_cfg_out" ]; then
            printf "\nROUTE_OUT interface check (%s):\n" "$_cfg_out"
            if ! ip link show "$_cfg_out" >/dev/null 2>&1; then
                printf "  ✗ Interface '%s' does not exist! (renamed after fw update?)\n" "$_cfg_out"
            elif ip link show "$_cfg_out" 2>/dev/null | grep -q "state DOWN"; then
                printf "  ⚠ Interface '%s' is DOWN — routes exist but traffic won't flow.\n" "$_cfg_out"
            else
                printf "  ✓ Interface '%s' exists and not DOWN.\n" "$_cfg_out"
            fi
        fi
    )
fi

# crond health (geo-split relies on cron for cache refresh)
printf "\nCron daemon:\n"
if pidof crond >/dev/null 2>&1; then
    printf "  ✓ crond running (pid %s)\n" "$(pidof crond)"
elif pidof cron >/dev/null 2>&1; then
    printf "  ✓ cron running (pid %s)\n" "$(pidof cron)"
else
    printf "  ✗ crond NOT running — geo-split subnets/domains won't auto-refresh!\n"
fi

# ─── 15. Logs (tail) ─────────────────────────────────────────────────────────

section "Logs (tail)"

if [ -f /tmp/smartdns.log ]; then
    printf "\n--- /tmp/smartdns.log (last 15 errors) ---\n"
    grep -i "error\|fail\|warn" /tmp/smartdns.log 2>/dev/null | tail -15 || echo "  (no errors)"
fi

if [ -f /tmp/nginx-webui-error.log ]; then
    printf "\n--- /tmp/nginx-webui-error.log (last 10) ---\n"
    tail -10 /tmp/nginx-webui-error.log 2>/dev/null || true
fi

if [ -f /opt/var/log/geo-split.log ]; then
    printf "\n--- /opt/var/log/geo-split.log (last 10) ---\n"
    tail -10 /opt/var/log/geo-split.log 2>/dev/null || true
fi

if command -v logread >/dev/null 2>&1; then
    printf "\n--- logread (geo-split|smartdns|nginx-webui|watchdog, last 20) ---\n"
    logread 2>/dev/null | grep -E "geo-split|smartdns|nginx-webui|watchdog" | tail -20 || echo "  (nothing)"
fi

# ─── Footer ──────────────────────────────────────────────────────────────────

printf "\n%s\n" "$SEP"
echo "Bug report collected. Copy everything above and paste into the forum topic."
echo "No passwords, WAN IPs, or private keys are included in this output."
echo "If you see any info you consider private, replace it with *** before posting."
printf "%s\n" "$SEP"

#!/opt/bin/sh
# Show net-check diagnostic status (brief dashboard view).
# Output format matches kee-status.sh expectations:
#   First line: "net-check status: ✓ Alive" / "✗ Fail"
#   Body: status_section / status_line / status_emit_text (lib/status.sh)
# shellcheck disable=SC1091
# shellcheck disable=SC3043
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
. "$SCRIPT_DIR/../../lib/status.sh"
. "$SCRIPT_DIR/../../lib/ip.sh"
. "$SCRIPT_DIR/lib/geo-cache.sh"
. "$SCRIPT_DIR/lib/wan.sh"
_CONFIG_DIR="${SCRIPT_DIR%/*}/config"
. "$_CONFIG_DIR/defaults.conf"
[ -f "$_CONFIG_DIR/config.conf" ] && . "$_CONFIG_DIR/config.conf"

# Enable colors for text output (auto = TTY-aware, --color/--no-color override)
status_setup_colors "$(_status_parse_color_arg "$@")"

STATUS_OK=0
_FAIL_REASONS=""
OUTPUT_JSON=0

# Parse args
for _arg in "$@"; do
  case "$_arg" in
    --json) OUTPUT_JSON=1 ;;
  esac
done

# ─── Check functions ─────────────────────────────────────────────────────────

# Sets: _ck_version
check_version() {
  status_check_version "net-check"
  _ck_version="${_st_version:-0.1.0}"
}

# Sets: _ck_ifaces (space-separated WAN interfaces)
check_interfaces() {
  _ck_ifaces=$(get_wan_interfaces)
  if [ -z "$_ck_ifaces" ]; then
    STATUS_OK=1
  fi
}

# Sets: _ck_ping_results (iface:latency_ms per line)
check_ping() {
  _ck_ping_results=""
  local iface ping_out latency
  for iface in $_ck_ifaces; do
    ping_out=$(ping -I "$iface" -c 1 -W "$PROBE_TIMEOUT" "$CONNECTIVITY_TARGET" 2>/dev/null | \
      sed -n 's/.*time=\([0-9.]*\).*/\1/p') || ping_out=""
    if [ -n "$ping_out" ]; then
      latency=$(printf '%.0f' "$ping_out" 2>/dev/null || printf '%s' "$ping_out")
      _ck_ping_results="${_ck_ping_results}${iface}:${latency}
"
    else
      _ck_ping_results="${_ck_ping_results}${iface}:—
"
      STATUS_OK=1
      _FAIL_REASONS="${_FAIL_REASONS:+${_FAIL_REASONS}, }${iface} unreachable"
    fi
  done
}

# Sets: _ck_geo_info (newline-separated "iface|ext_ip|cc" lines)
check_geo_info() {
  _ck_geo_info=""
  local iface _json _ip _cc
  for iface in $_ck_ifaces; do
    _json=""
    _json=$(geo_read_cache "$iface" 2>/dev/null) || \
      _json=$(geo_read_stale "$iface" 2>/dev/null) || _json=""
    _ip="—"
    _cc="—"
    if [ -n "$_json" ]; then
      parse_geo_json "$_json"
      [ -n "$_geo_ip" ] && _ip="$_geo_ip"
      [ -n "$_geo_country" ] && _cc="$_geo_country"
    fi
    _ck_geo_info="${_ck_geo_info}${iface}|${_ip}|${_cc}
"
  done
}

# Sets: _ck_cache_age, _ck_cache_data (from cached results)
check_cache() {
  _ck_cache_age=""
  _ck_cache_data=""
  if [ -f "$CACHE_FILE" ]; then
    local mtime now age
    mtime=$(file_mtime "$CACHE_FILE")
    now=$(date +%s)
    age=$((now - mtime))
    _ck_cache_age="$age"
    _ck_cache_data=$(cat "$CACHE_FILE" 2>/dev/null) || _ck_cache_data=""
  fi
}

# Flatten cache JSON into "target|dev|verdict" lines for easy grep.
# Sets: _ck_flat_cache (newline-separated "target|dev|verdict" lines)
flatten_cache() {
  _ck_flat_cache=""
  [ -z "$_ck_cache_data" ] && return 0

  # Split on '{' to get one JSON fragment per line, then extract
  # target (remembered across fragments) + dev + verdict per path entry.
  _ck_flat_cache=$(printf '%s' "$_ck_cache_data" | tr '{' '\n' | awk -F'"' '
    /"target":/ {
      for (i=1; i<=NF; i++) if ($i == "target") { target = $(i+2); break }
    }
    /"dev":/ && /"verdict":/ {
      dev = ""; verd = ""
      for (i=1; i<=NF; i++) {
        if ($i == "dev" && dev == "") dev = $(i+2)
        if ($i == "verdict" && verd == "") { verd = $(i+2); break }
      }
      if (target != "" && dev != "" && verd != "") print target "|" dev "|" verd
    }
  ')
}

# Sets: _ck_path_ok_N, _ck_path_total_N (per iface, via _ck_flat_cache)
check_cached_results() {
  _ck_has_cache=0
  [ -z "$_ck_flat_cache" ] && return 0
  _ck_has_cache=1
}

# Quick DNS leak probe: query whoami.akamai.net to see which resolver is used.
# Enriches with provider name (from dns-providers.conf) and CC (from ipgeo cache).
# Sets: _ck_dns_leak ("resolver: <IP>"|"<IP> (<CC>, <provider>)"|"skipped"|"query failed")
check_dns_leak() {
  _ck_dns_leak="skipped (no dig)"
  command -v dig >/dev/null 2>&1 || return 0

  local resolver_ip
  resolver_ip=$(dig +short +time=2 +tries=1 "$DNS_LEAK_CHECK_DOMAIN" 2>/dev/null | head -1) || resolver_ip=""

  if [ -n "$resolver_ip" ]; then
    local _provider="" _prefix _name
    if [ -f "${_CONFIG_DIR}/dns-providers.conf" ]; then
      while IFS='|' read -r _prefix _name; do
        case "$_prefix" in \#*|""|AS*) continue ;; esac
        # shellcheck disable=SC2254
        case "$resolver_ip" in $_prefix) _provider="$_name"; break ;; esac
      done < "${_CONFIG_DIR}/dns-providers.conf"
    fi
    # Try ipgeo cache for CC
    local _leak_cc=""
    local _ipgeo_file="${DATA_DIR}/ipgeo-${resolver_ip}.json"
    if [ -f "$_ipgeo_file" ]; then
      _leak_cc=$(sed -n 's/.*"cc"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_ipgeo_file")
    fi
    # Build display string
    local _extra=""
    [ -n "$_leak_cc" ] && _extra="$_leak_cc"
    [ -n "$_provider" ] && _extra="${_extra:+${_extra}, }${_provider}"
    if [ -n "$_extra" ]; then
      _ck_dns_leak="${resolver_ip} (${_extra})"
    else
      _ck_dns_leak="resolver: ${resolver_ip}"
    fi
  else
    _ck_dns_leak="query failed"
  fi
}

# IPv6 leak check: attempt IPv6 connection to detect leaks.
# Sets: _ck_ipv6_leak ("none"|"<ipv6_addr>"|"skipped")
check_ipv6_leak() {
  _ck_ipv6_leak="skipped"
  local _v6_addr
  _v6_addr=$(curl -6 -sS --max-time 2 -H "User-Agent: $CURL_UA" "$IPV6_CHECK_URL" 2>/dev/null) || _v6_addr=""
  if [ -n "$_v6_addr" ]; then
    _ck_ipv6_leak="$_v6_addr"
    STATUS_OK=1
    _FAIL_REASONS="${_FAIL_REASONS:+${_FAIL_REASONS}, }IPv6 leak"
  else
    _ck_ipv6_leak="none"
  fi
}

# Detect SmartDNS and geo-split status for context section.
# Sets: _ck_smartdns_status, _ck_geosplit_status
check_context() {
  _ck_smartdns_status=""
  _ck_geosplit_status=""

  # SmartDNS: check if running
  local _sd_pid=""
  _sd_pid=$(pidof smartdns 2>/dev/null) || _sd_pid=""
  if [ -n "$_sd_pid" ]; then
    local _sd_port="6053"
    # Try to detect actual port from config
    local _sd_conf="/opt/etc/smartdns/smartdns.conf"
    if [ -f "$_sd_conf" ]; then
      local _p
      _p=$(grep -m1 '^bind.*:' "$_sd_conf" 2>/dev/null | sed -n 's/.*:\([0-9]*\).*/\1/p') || _p=""
      [ -n "$_p" ] && _sd_port="$_p"
    fi
    _ck_smartdns_status="running, port ${_sd_port}"
  fi

  # Geo-split: check route tables
  local _gs_conf="$SCRIPT_DIR/../../geo-split/config/defaults.conf"
  if [ -f "$_gs_conf" ]; then
    local _sub_table _dom_table _zone _sub_count _dom_count _total
    _sub_table=$(grep '^SUBNET_ROUTE_TABLE=' "$_gs_conf" | tail -1 | sed "s/^SUBNET_ROUTE_TABLE=//;s/[\"']//g") || _sub_table=""
    _dom_table=$(grep '^DOMAIN_ROUTE_TABLE=' "$_gs_conf" | tail -1 | sed "s/^DOMAIN_ROUTE_TABLE=//;s/[\"']//g") || _dom_table=""
    # Override from user config
    local _gs_user="$SCRIPT_DIR/../../geo-split/config/config.conf"
    if [ -f "$_gs_user" ]; then
      local _ov
      _ov=$(grep '^SUBNET_ROUTE_TABLE=' "$_gs_user" 2>/dev/null | tail -1 | sed "s/^SUBNET_ROUTE_TABLE=//;s/[\"']//g") || true
      [ -n "$_ov" ] && _sub_table="$_ov"
      _ov=$(grep '^DOMAIN_ROUTE_TABLE=' "$_gs_user" 2>/dev/null | tail -1 | sed "s/^DOMAIN_ROUTE_TABLE=//;s/[\"']//g") || true
      [ -n "$_ov" ] && _dom_table="$_ov"
    fi
    _zone=$(grep '^GEO_ZONE=' "$_gs_conf" | tail -1 | sed "s/^GEO_ZONE=//;s/[\"']//g") || _zone=""
    if [ -f "$_gs_user" ]; then
      local _zov
      _zov=$(grep '^GEO_ZONE=' "$_gs_user" 2>/dev/null | tail -1 | sed "s/^GEO_ZONE=//;s/[\"']//g") || true
      [ -n "$_zov" ] && _zone="$_zov"
    fi
    _sub_count=0; _dom_count=0
    [ -n "$_sub_table" ] && _sub_count=$(ip route show table "$_sub_table" 2>/dev/null | wc -l) || true
    [ -n "$_dom_table" ] && _dom_count=$(ip route show table "$_dom_table" 2>/dev/null | wc -l) || true
    _total=$((_sub_count + _dom_count))
    if [ "$_total" -gt 0 ]; then
      # Format count: 12345 → "12K"
      local _display
      if [ "$_total" -ge 1000 ]; then
        _display="$((_total / 1000))K"
      else
        _display="$_total"
      fi
      _ck_geosplit_status="zone ${_zone:-?}, ${_display} routes"
    fi
  fi
}

# ─── Text output ─────────────────────────────────────────────────────────────

# Get ok/total counts for an interface from flat cache.
# Args: $1 - iface
# stdout: "ok_count total" (space-separated)
cache_counts_for_iface() {
  local iface="$1"
  if [ -z "$_ck_flat_cache" ]; then
    printf '? ?'
    return
  fi
  local ok_count total
  total=$(printf '%s\n' "$_ck_flat_cache" | grep -c "|${iface}|" 2>/dev/null) || total=0
  ok_count=$(printf '%s\n' "$_ck_flat_cache" | grep -c "|${iface}|ok$" 2>/dev/null) || ok_count=0
  printf '%s %s' "$ok_count" "$total"
}

# Get failure lines for an interface from flat cache.
# Args: $1 - iface
# stdout: "target → reason" per line (max 5)
cache_failures_for_iface() {
  local iface="$1"
  [ -z "$_ck_flat_cache" ] && return 0
  printf '%s\n' "$_ck_flat_cache" | grep "|${iface}|" | grep -v "|ok$" | \
    sed 's/|\([^|]*\)$/ → \1/; s/|.*//' | head -5
}

# Get detailed interface type label.
# Args: $1 - interface name
# stdout: "isp", "wireguard", "openvpn", "gre", "l2tp", "pptp", "sstp", "ipsec", "tunnel"
iface_type_label() {
  case "$1" in
    nwg*|awg*|wg*)       printf 'wireguard' ;;
    ovpn*|tun[0-9]*)     printf 'openvpn' ;;
    gre*|vti*)           printf 'gre' ;;
    l2tp*)               printf 'l2tp' ;;
    pptp*)               printf 'pptp' ;;
    sstp*)               printf 'sstp' ;;
    ipsec*|xfrm*)        printf 'ipsec' ;;
    tap*|sit*|ip6tnl*)   printf 'tunnel' ;;
    *)                    printf 'isp' ;;
  esac
}

show_text() {
  # Header line matching kee-status.sh pattern
  local _status_word="✓ Alive"
  if [ "$STATUS_OK" -ne 0 ]; then
    _status_word="✗ Fail"
    [ -n "$_FAIL_REASONS" ] && _status_word="✗ Fail (${_FAIL_REASONS})"
  fi

  _text_buf="net-check status: ${_status_word}
"

  # --- Paths section ---
  status_section "Paths"

  if [ -z "$_ck_ifaces" ]; then
    status_line "Interfaces" "none detected" "fail"
  else
    local iface ping_line latency itype
    local ok_count total path_status path_value counts
    local ext_ip ext_cc geo_line latency_display

    for iface in $_ck_ifaces; do
      # Get ping for this iface
      latency="—"
      ping_line=$(printf '%s' "$_ck_ping_results" | grep "^${iface}:" | head -1)
      if [ -n "$ping_line" ]; then
        latency="${ping_line#*:}"
      fi

      itype=$(iface_type_label "$iface")

      # Get ext IP + CC from geo info
      ext_ip="—"
      ext_cc="—"
      geo_line=$(printf '%s' "$_ck_geo_info" | grep "^${iface}|" | head -1)
      if [ -n "$geo_line" ]; then
        ext_ip=$(printf '%s' "$geo_line" | cut -d'|' -f2)
        ext_cc=$(printf '%s' "$geo_line" | cut -d'|' -f3)
      fi

      # Build formatted path value with printf alignment
      if [ "$latency" = "—" ]; then
        latency_display="—"
        path_status="fail"
      else
        latency_display="${latency}ms"
        path_status="ok"
      fi
      path_value=$(printf '%-10s %-16s %-3s ping %-6s' "$itype" "$ext_ip" "$ext_cc" "$latency_display")

      # Append cached results: N/M targets (only when cache available)
      counts=$(cache_counts_for_iface "$iface")
      ok_count="${counts% *}"
      total="${counts#* }"
      if [ "$ok_count" != "?" ] && [ "$total" != "?" ]; then
        path_value="${path_value} ${ok_count}/${total} targets"
      fi

      # Determine mark: ✓ all ok, ⚠ partial, ✗ none/ping fail
      if [ "$ok_count" != "?" ] && [ "$total" != "?" ]; then
        if [ "$ok_count" = "$total" ] && [ "$path_status" != "fail" ]; then
          path_status="ok"
        elif [ "$ok_count" -gt 0 ] 2>/dev/null && [ "$path_status" != "fail" ]; then
          path_status="warn"
        else
          path_status="fail"
        fi
      fi

      status_line "$iface" "$path_value" "$path_status"

      # Show failures indented
      local failures
      failures=$(cache_failures_for_iface "$iface")
      if [ -n "$failures" ]; then
        printf '%s\n' "$failures" | while IFS= read -r fail_line; do
          [ -z "$fail_line" ] && continue
          status_line_cont "$fail_line" "fail"
        done
      fi
    done
  fi

  # --- Context section (only if any context available) ---
  if [ -n "$_ck_smartdns_status" ] || [ -n "$_ck_geosplit_status" ]; then
    status_blank
    status_section "Context"
    if [ -n "$_ck_smartdns_status" ]; then
      status_line "SmartDNS" "$_ck_smartdns_status" "ok"
    fi
    if [ -n "$_ck_geosplit_status" ]; then
      status_line "Geo-split" "$_ck_geosplit_status" "ok"
    fi
  fi

  # --- System section ---
  status_blank
  status_section "System"

  case "$_ck_dns_leak" in
    query*)     status_line "DNS leak" "$_ck_dns_leak" "fail" ;;
    skipped*)   status_line "DNS leak" "$_ck_dns_leak" ;;
    *)          status_line "DNS leak" "$_ck_dns_leak" "ok" ;;
  esac

  case "$_ck_ipv6_leak" in
    none)    status_line "IPv6 leak" "none" "ok" ;;
    skipped) status_line "IPv6 leak" "skipped" ;;
    *)       status_line "IPv6 leak" "$_ck_ipv6_leak" "fail" ;;
  esac

  if [ -n "$_ck_cache_age" ]; then
    status_line "Last check" "$(format_age "$_ck_cache_age") ago"
  fi

  status_show_version

  status_emit_text
}

# ─── JSON output ─────────────────────────────────────────────────────────────

show_json() {
  status_detail "version" "$_ck_version"

  if [ -n "$_ck_cache_age" ]; then
    status_detail "last_check_age" "$_ck_cache_age" "num"
  fi

  status_detail "dns_leak" "$_ck_dns_leak"
  status_detail "ipv6_leak" "$_ck_ipv6_leak"

  # Paths array
  local json_paths="" first_path=1
  local iface ping_line latency itype counts ok_count total
  local ext_ip ext_cc geo_line
  for iface in $_ck_ifaces; do
    latency="0"
    ping_line=$(printf '%s' "$_ck_ping_results" | grep "^${iface}:" | head -1)
    if [ -n "$ping_line" ]; then
      local raw_lat="${ping_line#*:}"
      [ "$raw_lat" != "—" ] && latency="$raw_lat"
    fi

    itype=$(iface_type_label "$iface")

    # Get ext IP + CC from geo info
    ext_ip=""
    ext_cc=""
    geo_line=$(printf '%s' "$_ck_geo_info" | grep "^${iface}|" | head -1)
    if [ -n "$geo_line" ]; then
      ext_ip=$(printf '%s' "$geo_line" | cut -d'|' -f2)
      ext_cc=$(printf '%s' "$geo_line" | cut -d'|' -f3)
      [ "$ext_ip" = "—" ] && ext_ip=""
      [ "$ext_cc" = "—" ] && ext_cc=""
    fi

    counts=$(cache_counts_for_iface "$iface")
    ok_count="${counts% *}"
    total="${counts#* }"
    [ "$ok_count" = "?" ] && ok_count="0"
    [ "$total" = "?" ] && total="0"

    local path_json
    path_json=$(printf '{%s,%s,%s,%s,%s,%s,%s}' \
      "$(json_kv "dev" "$iface")" \
      "$(json_kv "iface_type" "$itype")" \
      "$(json_kv "ext_ip" "$ext_ip")" \
      "$(json_kv "cc" "$ext_cc")" \
      "$(json_kv_num "ping_ms" "$latency")" \
      "$(json_kv_num "ok" "$ok_count")" \
      "$(json_kv_num "total" "$total")")

    if [ "$first_path" = 1 ]; then
      json_paths="$path_json"
      first_path=0
    else
      json_paths="${json_paths},${path_json}"
    fi
  done

  status_extra "paths" "[${json_paths}]"
  status_check_result "interfaces" "$([ -n "$_ck_ifaces" ] && echo ok || echo fail)"

  local enabled_val=0 running_val=0
  status_emit_json "$enabled_val" "$running_val" "$STATUS_OK"
  printf '\n'
}

# ─── Main ────────────────────────────────────────────────────────────────────

check_version
check_interfaces
check_ping
check_geo_info
check_cache
flatten_cache
check_cached_results
check_dns_leak
check_ipv6_leak
check_context

if [ "$OUTPUT_JSON" = 1 ]; then
  show_json
else
  show_text
fi

exit "$STATUS_OK"

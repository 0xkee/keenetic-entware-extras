# net-check: DNS leak test — discover which recursive DNS resolvers handle queries.
# 3-level service fallback: dnscheck.tools → bash.ws → whoami queries.
# Detects leaks when ISP DNS appears in resolver chain while SmartDNS/DoH is configured.
# Tunnel-aware: resolvers at known tunnel exit countries are expected, not leaks.
#
# Dependencies: lib/output.sh (emit_error, section_title, tbl_header, tbl_row, tbl_cell,
#     status_mark, color_status, summary_line, is_quiet),
#   lib/cmd-dns.sh (identify_dns_provider, _get_isp_dns),
#   lib/geoip.sh (geolocate_ip, geoip_read_full),
#   lib/ip.sh (detect_dns_port, is_tunnel_iface),
#   lib/wan.sh (load_zone_context, ensure_geo_cache, geo_cached_cc),
#   lib/common.sh (json_kv, json_kv_bool, json_arr_add, require_cmd)
# Globals used: OUTPUT_JSON, VERBOSITY, _EXIT_CODE, PRIVACY_MODE,
#   DNS_LEAK_PROBE_COUNT, DNS_LEAK_WAIT, DNS_LEAK_TIMEOUT, DNS_TIMEOUT,
#   CURL_UA, _RUN_DIR, DATA_DIR, SMARTDNS_PORT,
#   _NON_GEO_SEGMENTS,
#   C_GREEN, C_RED, C_YELLOW, C_DIM, C_RST, C_BOLD, C_CYAN
# shellcheck disable=SC3043,SC2154,SC2086

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Deduplicate space-separated IP list, preserve order.
# Args: stdin or $1 - space-separated IPs
# stdout: space-separated unique IPs
_dns_leak_uniq() {
  printf '%s' "$1" | tr ' ' '\n' | awk '!seen[$0]++ && NF' | tr '\n' ' ' | sed 's/ $//'
}

# Check if IP is in a space-separated list.
# Args: $1 - IP, $2 - space-separated list
# Returns: 0 if found, 1 otherwise
_dns_leak_ip_in_list() {
  local _ip="$1" _list="$2" _item
  for _item in $_list; do
    [ "$_ip" = "$_item" ] && return 0
  done
  return 1
}

# Check if resolver belongs to a known public DNS provider.
# Uses IP prefix matching + ASN matching from dns-providers.conf.
# IP globs match well-known anycast IPs; AS* lines match PoP ASNs.
# Args: $1 - resolver IP, $2 - resolver ASN (optional, e.g. "AS13335")
# Returns: 0 if known provider, 1 otherwise
_is_known_dns_provider() {
  local _ip="$1" _asn="${2:-}" _prefix _name
  [ ! -f "${DNS_PROVIDERS_FILE:-}" ] && return 1
  while IFS='|' read -r _prefix _name; do
    case "$_prefix" in \#*|"") continue ;; esac
    case "$_prefix" in
      AS*)
        # ASN match (for dns-leak PoP detection)
        [ -n "$_asn" ] && [ "$_asn" = "$_prefix" ] && return 0
        ;;
      *)
        # IP glob match (well-known anycast IPs)
        # shellcheck disable=SC2254
        case "$_ip" in $_prefix) return 0 ;; esac
        ;;
    esac
  done < "$DNS_PROVIDERS_FILE"
  return 1
}

# Extract JSON string value by key (simple flat JSON).
# Args: $1 - key name, stdin - JSON text
# stdout: value (unquoted)
_dns_leak_json_val() {
  sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1
}

# Extract JSON array of objects — get field from each object.
# Handles simple flat JSON arrays like [{"ip":"1.2.3.4","cc":"US"},...]
# Args: $1 - field name, stdin - JSON text
# stdout: one value per line
_dns_leak_json_arr_field() {
  local _key="$1"
  sed 's/},{/}\n{/g' | sed -n "s/.*\"${_key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

# ─── Level 1: dnscheck.tools ─────────────────────────────────────────────────

# DNS leak test via dnscheck.tools API.
# 1. POST to get test ID
# 2. dig unique subdomains to trigger resolver discovery
# 3. GET results with resolver list
# Sets: _leak_source, _leak_resolvers (newline-separated "ip|provider|cc|asn")
# Returns: 0 on success, 1 on failure
_dns_leak_dnscheck() {
  local _resp _test_id _i _probe_domain _results _http_code

  # Step 1: get test ID
  _resp=$(curl -sS --max-time "$DNS_LEAK_TIMEOUT" \
    -H "User-Agent: ${CURL_UA}" \
    "https://www.dnscheck.tools/api/v1/check" 2>/dev/null) || return 1
  [ -z "$_resp" ] && return 1

  _test_id=$(printf '%s' "$_resp" | _dns_leak_json_val "id")
  [ -z "$_test_id" ] && return 1

  # Step 2: send DNS probes (unique subdomains)
  # Subshell isolates background jobs so `wait` doesn't block on spinner.
  # $_dns_leak_dig_extra routes probes via SmartDNS when active (set by cmd_dns_leak).
  (
    _i=1
    while [ "$_i" -le "$DNS_LEAK_PROBE_COUNT" ]; do
      dig +short "${_test_id}-${_i}.dnscheck.tools" +time="$DNS_TIMEOUT" +tries=1 $_dns_leak_dig_extra >/dev/null 2>&1 &
      _i=$((_i + 1))
    done
    wait
  )

  # Step 3: wait for results to propagate
  sleep "$DNS_LEAK_WAIT"

  # Step 4: fetch results
  _results=$(curl -sS --max-time "$DNS_LEAK_TIMEOUT" \
    -H "User-Agent: ${CURL_UA}" \
    "https://www.dnscheck.tools/api/v1/check/${_test_id}" 2>/dev/null) || return 1
  [ -z "$_results" ] && return 1

  # Parse resolver IPs from JSON response
  # Response format: {"id":"...","resolvers":[{"ip":"8.8.8.8","cc":"US","asn":{"number":15169,"org":"GOOGLE"}},...]}
  local _resolver_ips
  _resolver_ips=$(printf '%s' "$_results" | _dns_leak_json_arr_field "ip")
  [ -z "$_resolver_ips" ] && return 1

  _leak_source="dnscheck.tools"
  _leak_resolvers=""

  local _rip _rcc _rasn _rprov _rcc_cached
  for _rip in $_resolver_ips; do
    [ -z "$_rip" ] && continue
    _rprov=$(identify_dns_provider "$_rip") || _rprov=""
    _rcc_cached=0
    if is_cache_fresh "$(ipgeo_cache_file "$_rip")" "${IPGEO_CACHE_TTL:-86400}"; then
      _rcc_cached=1
    fi
    _rcc=$(geolocate_ip "$_rip") || _rcc="??"
    _rasn=""
    if geoip_read_full "$_rip"; then
      _rasn="$_enrich_asn"
      [ -z "$_rprov" ] && [ -n "$_enrich_org" ] && _rprov="$_enrich_org"
    fi
    _leak_resolvers="${_leak_resolvers}${_rip}|${_rprov}|${_rcc}|${_rasn}|${_rcc_cached}
"
  done
  [ -z "$_leak_resolvers" ] && return 1
  return 0
}

# ─── Level 2: bash.ws ─────────────────────────────────────────────────────────

# DNS leak test via bash.ws API.
# 1. GET test ID (plain text)
# 2. dig unique subdomains
# 3. GET JSON results
# Sets: _leak_source, _leak_resolvers
# Returns: 0 on success, 1 on failure
_dns_leak_bashws() {
  local _test_id _i _probe_domain _results

  # Step 1: get test ID (plain text number)
  _test_id=$(curl -sS --max-time "$DNS_LEAK_TIMEOUT" \
    -H "User-Agent: ${CURL_UA}" \
    "https://bash.ws/id" 2>/dev/null) || return 1
  _test_id=$(printf '%s' "$_test_id" | tr -cd '0-9')
  [ -z "$_test_id" ] && return 1

  # Step 2: send DNS probes
  # Subshell isolates background jobs so `wait` doesn't block on spinner.
  # $_dns_leak_dig_extra routes probes via SmartDNS when active (set by cmd_dns_leak).
  (
    _i=1
    while [ "$_i" -le 10 ]; do
      dig +short "${_i}.${_test_id}.bash.ws" +time="$DNS_TIMEOUT" +tries=1 $_dns_leak_dig_extra >/dev/null 2>&1 &
      _i=$((_i + 1))
    done
    wait
  )

  # Step 3: wait for results
  sleep "$DNS_LEAK_WAIT"

  # Step 4: fetch results
  _results=$(curl -sS --max-time "$DNS_LEAK_TIMEOUT" \
    -H "User-Agent: ${CURL_UA}" \
    "https://bash.ws/dnsleak/test/${_test_id}?json" 2>/dev/null) || return 1
  [ -z "$_results" ] && return 1

  # Parse: array of {"ip":"1.2.3.4","country_name":"US","asn":"AS15169","type":"dns",...}
  # Filter out "type":"conclusion" (summary) and "type":"ip" (client public IP, not a resolver).
  local _resolver_ips
  _resolver_ips=$(printf '%s' "$_results" | sed 's/},{/}\n{/g' | \
    grep -v '"type"[[:space:]]*:[[:space:]]*"conclusion"' | \
    grep -v '"type"[[:space:]]*:[[:space:]]*"ip"' | \
    sed -n 's/.*"ip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  [ -z "$_resolver_ips" ] && return 1

  _leak_source="bash.ws"
  _leak_resolvers=""

  local _rip _rcc _rasn _rprov _rcc_cached
  for _rip in $_resolver_ips; do
    [ -z "$_rip" ] && continue
    _rprov=$(identify_dns_provider "$_rip") || _rprov=""
    _rcc_cached=0
    if is_cache_fresh "$(ipgeo_cache_file "$_rip")" "${IPGEO_CACHE_TTL:-86400}"; then
      _rcc_cached=1
    fi
    _rcc=$(geolocate_ip "$_rip") || _rcc="??"
    _rasn=""
    if geoip_read_full "$_rip"; then
      _rasn="$_enrich_asn"
      [ -z "$_rprov" ] && [ -n "$_enrich_org" ] && _rprov="$_enrich_org"
    fi
    _leak_resolvers="${_leak_resolvers}${_rip}|${_rprov}|${_rcc}|${_rasn}|${_rcc_cached}
"
  done
  [ -z "$_leak_resolvers" ] && return 1
  return 0
}

# ─── Level 3: whoami queries (offline fallback) ──────────────────────────────

# DNS leak test via direct whoami queries (no HTTP needed, dig only).
# Queries multiple "what is my resolver IP" services.
# Sets: _leak_source, _leak_resolvers
# Returns: 0 on success, 1 on failure
_dns_leak_whoami() {
  local _ips="" _ip

  # whoami.akamai.net — returns resolver IP (routed via SmartDNS when active)
  _ip=$(dig +short whoami.akamai.net $_dns_leak_dig_extra +time="$DNS_TIMEOUT" +tries=1 2>/dev/null | \
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  [ -n "$_ip" ] && _ips="${_ips} ${_ip}"

  # Queries 2 & 3 bypass SmartDNS (@specific_server) — they return the router's
  # own WAN IP, not a DNS resolver. With SmartDNS active, skip them to avoid
  # false leak detection (ISP WAN IP ≠ leak when SmartDNS routes all DNS).
  if [ -z "$_dns_leak_dig_extra" ]; then
    # myip.opendns.com via OpenDNS — returns client IP as seen by OpenDNS
    _ip=$(dig +short myip.opendns.com @resolver1.opendns.com \
      +time="$DNS_TIMEOUT" +tries=1 2>/dev/null | \
      grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [ -n "$_ip" ] && _ips="${_ips} ${_ip}"

    # o-o.myaddr.l.google.com via Google NS — returns client IP as TXT
    _ip=$(dig +short -t TXT o-o.myaddr.l.google.com @ns1.google.com \
      +time="$DNS_TIMEOUT" +tries=1 2>/dev/null | \
      tr -d '"' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    [ -n "$_ip" ] && _ips="${_ips} ${_ip}"
  fi

  _ips=$(printf '%s' "$_ips" | sed 's/^ //')
  [ -z "$_ips" ] && return 1

  # Deduplicate
  _ips=$(_dns_leak_uniq "$_ips")

  _leak_source="whoami queries"
  _leak_resolvers=""

  local _rip _rcc _rasn _rprov _rcc_cached
  for _rip in $_ips; do
    [ -z "$_rip" ] && continue
    _rprov=$(identify_dns_provider "$_rip") || _rprov=""
    _rcc_cached=0
    if is_cache_fresh "$(ipgeo_cache_file "$_rip")" "${IPGEO_CACHE_TTL:-86400}"; then
      _rcc_cached=1
    fi
    _rcc=$(geolocate_ip "$_rip") || _rcc="??"
    _rasn=""
    if geoip_read_full "$_rip"; then
      _rasn="$_enrich_asn"
      [ -z "$_rprov" ] && [ -n "$_enrich_org" ] && _rprov="$_enrich_org"
    fi
    _leak_resolvers="${_leak_resolvers}${_rip}|${_rprov}|${_rcc}|${_rasn}|${_rcc_cached}
"
  done
  [ -z "$_leak_resolvers" ] && return 1
  return 0
}

# ─── Command: dns-leak ────────────────────────────────────────────────────────

# Detect SmartDNS, set up dig routing, build tunnel/ISP CC sets.
# Sets: _has_smartdns, _smartdns_port, _dns_leak_dig_extra, _tunnel_ccs, _isp_ccs
_dns_leak_setup_context() {
  # Detect SmartDNS before probes — determines both dig routing and leak logic.
  # On the router, port 53 = ndnproxy; iptables DNAT only intercepts LAN (br0)
  # traffic, not local processes. Without explicit port, dig hits ndnproxy and
  # tests the wrong resolver chain.
  _has_smartdns=0
  _smartdns_port=""
  local _dns_info
  _dns_info=$(detect_dns_port 2>/dev/null) || _dns_info=""
  case "$_dns_info" in
    6053*|6153*)
      _has_smartdns=1
      _smartdns_port="${_dns_info%% *}"
      ;;
  esac

  # When SmartDNS is active, route dig probes through it.
  # Variable is read by _dns_leak_dnscheck/_bashws/_whoami via dynamic scoping.
  _dns_leak_dig_extra=""
  if [ "$_has_smartdns" = 1 ] && [ -n "$_smartdns_port" ]; then
    _dns_leak_dig_extra="@127.0.0.1 -p ${_smartdns_port}"
  fi

  # Tunnel exit CC set + ISP CC: for tunnel-aware leak classification.
  # When SmartDNS routes DoH through tunnels, resolvers at tunnel exits
  # (or nearby anycast backends) are expected — not leaks.
  # Real leak = ISP DNS resolver appearing (CC matches ISP country).
  _tunnel_ccs=""
  _isp_ccs=""
  if [ "$_has_smartdns" = 1 ]; then
    load_zone_context
    ensure_geo_cache
    local _tdev _tcc
    for _tdev in $_NON_GEO_SEGMENTS; do
      _tcc=$(geo_cached_cc "$_tdev" | tr '[:upper:]' '[:lower:]')
      [ -z "$_tcc" ] && continue
      if is_tunnel_iface "$_tdev"; then
        case " $_tunnel_ccs " in *" $_tcc "*) continue ;; esac
        _tunnel_ccs="${_tunnel_ccs:+${_tunnel_ccs} }${_tcc}"
      else
        case " $_isp_ccs " in *" $_tcc "*) continue ;; esac
        _isp_ccs="${_isp_ccs:+${_isp_ccs} }${_tcc}"
      fi
    done
  fi
}

# Classify each resolver as expected/tunnel/leak; build display and JSON data.
# Reads: _leak_resolvers, _has_smartdns, _tunnel_ccs, _isp_ccs
# Sets: _resolver_count, _leak_count, _tunnel_count, _leak_ips,
#       _display_lines, _json_resolvers
_dns_leak_classify_resolvers() {
  local _isp_dns=""
  _isp_dns=$(_get_isp_dns)

  # _is_expected: 1=known provider, 2=tunnel exit resolver, 0=leak
  _resolver_count=0
  _leak_count=0
  _tunnel_count=0
  _leak_ips=""
  _display_lines=""
  _json_resolvers=""
  local _all_expected=1
  local _rip _rprov _rcc _rasn _rcc_cached _is_expected

  while IFS='|' read -r _rip _rprov _rcc _rasn _rcc_cached; do
    [ -z "$_rip" ] && continue
    _resolver_count=$((_resolver_count + 1))

    # Check if this resolver is expected or a leak.
    # Classification (SmartDNS active):
    #   1. Known DNS provider (IP glob / ASN match)           → expected (1)
    #   2. Tunnel-related resolver:                            → expected (2)
    #      a) CC matches a tunnel exit country
    #      b) Tunnels exist AND CC ≠ ISP country (anycast backend near tunnel)
    #   3. CC matches ISP country (or no tunnels configured)   → leak    (0)
    # Without SmartDNS: ISP DNS is the expected resolver.
    _is_expected=1
    if [ "$_has_smartdns" = 1 ]; then
      if _is_known_dns_provider "$_rip" "$_rasn"; then
        # Known provider — also count as tunnel if CC matches a tunnel exit
        if [ -n "$_tunnel_ccs" ] && [ -n "$_rcc" ] && [ "$_rcc" != "??" ]; then
          local _kcc
          _kcc=$(printf '%s' "$_rcc" | tr '[:upper:]' '[:lower:]')
          case " $_tunnel_ccs " in *" $_kcc "*) _tunnel_count=$((_tunnel_count + 1)) ;; esac
        fi
      else
        local _rcc_lower=""
        [ -n "$_rcc" ] && [ "$_rcc" != "??" ] && \
          _rcc_lower=$(printf '%s' "$_rcc" | tr '[:upper:]' '[:lower:]')
        if [ -n "$_tunnel_ccs" ] && [ -n "$_rcc_lower" ]; then
          # Check tunnel exit CC match (exact) or non-ISP foreign resolver
          local _is_isp_cc=0
          case " $_isp_ccs " in *" $_rcc_lower "*) _is_isp_cc=1 ;; esac
          if [ "$_is_isp_cc" = 0 ]; then
            # Foreign resolver (not ISP country) — tunnel exit or nearby backend
            _is_expected=2
            _tunnel_count=$((_tunnel_count + 1))
          else
            # Resolver in ISP country but not a known provider — real leak
            _is_expected=0
            _leak_count=$((_leak_count + 1))
            _leak_ips="${_leak_ips} ${_rip}"
            _all_expected=0
          fi
        else
          # No tunnels or unknown CC — conservative: flag as leak
          _is_expected=0
          _leak_count=$((_leak_count + 1))
          _leak_ips="${_leak_ips} ${_rip}"
          _all_expected=0
        fi
      fi
    elif [ -n "$_isp_dns" ]; then
      # Without SmartDNS: ISP DNS is expected. Only flag unknown non-ISP
      # resolvers AND known providers as potential leaks (uncommon scenario).
      if ! _dns_leak_ip_in_list "$_rip" "$_isp_dns" && \
         ! _is_known_dns_provider "$_rip" "$_rasn"; then
        _is_expected=0
        _leak_count=$((_leak_count + 1))
        _leak_ips="${_leak_ips} ${_rip}"
        _all_expected=0
      fi
    fi

    _display_lines="${_display_lines}${_rip}|${_rprov}|${_rcc}|${_rasn}|${_rcc_cached}|${_is_expected}
"

    # JSON resolver entry
    if [ "$OUTPUT_JSON" = 1 ]; then
      local _j_expected="true" _j_reason="known_provider"
      if [ "$_is_expected" = 2 ]; then
        _j_reason="tunnel_exit"
      elif [ "$_is_expected" = 0 ]; then
        _j_expected="false"
        _j_reason="unknown"
      fi
      local _entry
      _entry=$(printf '{%s,%s,%s,%s,"expected":%s,%s}' \
        "$(json_kv "ip" "$_rip")" \
        "$(json_kv "provider" "${_rprov:-unknown}")" \
        "$(json_kv "cc" "$_rcc")" \
        "$(json_kv "asn" "${_rasn:-}")" \
        "$_j_expected" \
        "$(json_kv "reason" "$_j_reason")")
      json_arr_add _json_resolvers "$_entry"
    fi
  done <<EOF
$(printf '%s' "$_leak_resolvers")
EOF

  _leak_ips=$(printf '%s' "$_leak_ips" | sed 's/^ //')
}

# Render DNS leak results as text table + verdict.
# Reads: _leak_source, _has_smartdns, _smartdns_port, _tunnel_ccs,
#         _display_lines, _resolver_count, _leak_count, _tunnel_count,
#         _leak_ips, _verdict
_dns_leak_render_text() {
  section_title "$_TITLE_DNS_LEAK"

  if ! is_quiet; then
    printf 'Discovers which recursive DNS resolvers handle your queries.\n'
    printf 'Source: %s%s%s' "$C_BOLD" "$_leak_source" "$C_RST"
    if [ "$_has_smartdns" = 1 ]; then
      printf '  (via SmartDNS :%s)' "$_smartdns_port"
    else
      printf '  (via system resolver :53)'
    fi
    if [ -n "$_tunnel_ccs" ]; then
      printf '  tunnels: %s%s%s' "$C_DIM" "$_tunnel_ccs" "$C_RST"
    fi
    printf '\n\n'

    tbl_header "Resolver IP:24" "CC:4" "ASN:10" "Provider:50" "Status"

    printf '%s' "$_display_lines" | while IFS='|' read -r _rip _rprov _rcc _rasn _rcc_cached _is_expected; do
      [ -z "$_rip" ] && continue
      local _st="ok" _status_cell
      if [ "$_is_expected" = 0 ]; then
        _st="fail"
        _status_cell="LEAK $(status_mark fail)"
      elif [ "$_is_expected" = 2 ]; then
        _status_cell="tunnel $(status_mark ok)"
      else
        local _dcc=""
        [ -n "$_rcc" ] && [ "$_rcc" != "??" ] && \
          _dcc=$(printf '%s' "$_rcc" | tr '[:upper:]' '[:lower:]')
        case " $_tunnel_ccs " in
          *" $_dcc "*) _status_cell="tunnel $(status_mark ok)" ;;
          *)           _status_cell="direct $(status_mark ok)" ;;
        esac
      fi
      [ "$_rcc_cached" = 1 ] && _status_cell="${_status_cell} $(cache_mark)"
      tbl_row "$(tbl_cell 24 "$_rip" "$_st")" "${_rcc:-—}" "${_rasn:-—}" "$(tbl_cell 50 "${_rprov:-—}")" "$_status_cell"
    done

    # Verdict line
    if [ "$_verdict" = "leak" ]; then
      printf '→ %s%s DNS leak detected!%s (%s resolver(s), %s leaked: %s)\n' \
        "$C_RED" "$(status_mark fail)" "$C_RST" \
        "$_resolver_count" "$_leak_count" "$_leak_ips"
    else
      local _extra=""
      [ "$_tunnel_count" -gt 0 ] && _extra=", ${_tunnel_count} via tunnel"
      printf '→ %sNo DNS leak%s %s (%s resolver(s), all expected%s)\n' \
        "$C_GREEN" "$C_RST" "$(status_mark ok)" "$_resolver_count" "$_extra"
    fi
  else
    # Quiet mode: single-line summary
    if [ "$_verdict" = "leak" ]; then
      printf 'dns-leak: %s leak (%s resolver(s))\n' "$(status_mark fail)" "$_leak_count"
    else
      printf 'dns-leak: no leak %s\n' "$(status_mark ok)"
    fi
  fi
}

# Render DNS leak results as JSON.
# Reads: _leak_source, _has_smartdns, _smartdns_port, _resolver_count,
#         _tunnel_count, _json_resolvers, _verdict, _leak_ips
_dns_leak_render_json() {
  local _ok_val=0
  [ "$_verdict" = "leak" ] && _ok_val=1
  local _j_resolver="system:53"
  [ "$_has_smartdns" = 1 ] && _j_resolver="smartdns:${_smartdns_port}"
  printf '{%s,%s,%s,%s,%s,"resolvers":[%s],%s,%s}\n' \
    "$(json_kv_bool "ok" "$_ok_val")" \
    "$(json_kv "source" "$_leak_source")" \
    "$(json_kv "probe_resolver" "$_j_resolver")" \
    "$(json_kv_num "resolver_count" "$_resolver_count")" \
    "$(json_kv_num "tunnel_resolver_count" "$_tunnel_count")" \
    "$_json_resolvers" \
    "$(json_kv "verdict" "$_verdict")" \
    "$(json_kv "leak_ips" "$_leak_ips")"
}

# DNS leak test: discover which recursive DNS resolvers handle queries.
# Uses 3-level fallback: dnscheck.tools API → bash.ws API → whoami dig queries.
# Detects leak when ISP DNS resolvers appear while SmartDNS/DoH is active.
cmd_dns_leak() {
  require_cmd dig

  # Phase 1: Detect SmartDNS, build tunnel/ISP CC sets
  local _has_smartdns _smartdns_port _dns_leak_dig_extra
  local _tunnel_ccs _isp_ccs
  _dns_leak_setup_context

  # Phase 2: Run probe with 3-level fallback
  local _leak_source="" _leak_resolvers=""
  _dns_leak_dnscheck || _dns_leak_bashws || _dns_leak_whoami || {
    emit_error "All DNS leak test services unreachable"
    return 1
  }

  # Phase 3: Classify each resolver as expected/tunnel/leak
  local _resolver_count _leak_count _tunnel_count _leak_ips
  local _display_lines _json_resolvers
  _dns_leak_classify_resolvers

  # Phase 4: Determine verdict
  local _verdict="no_leak"
  if [ "$_leak_count" -gt 0 ]; then
    _verdict="leak"
    [ "$_EXIT_CODE" -lt 1 ] && _EXIT_CODE=1
  fi

  # Phase 5: Render output
  if [ "$OUTPUT_JSON" = 1 ]; then
    _dns_leak_render_json
  else
    _dns_leak_render_text
  fi
}

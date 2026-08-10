# net-check: TLS certificate verification across WAN paths.
# Per-interface: resolve target IP via dig, then curl --interface + %{certs} to fetch
# the server certificate through each WAN path. openssl x509 parses issuer + fingerprint.
# Compares SHA-256 fingerprints across paths to detect MITM certificate substitution.
# Checks issuer against known MITM/interception proxy CA list.
#
# Dependencies: lib/output.sh (emit_error, section_title, color_status, status_mark,
#     summary_line, is_quiet, tbl_header, tbl_row, tbl_cell),
#   lib/wan.sh (get_wan_interfaces, iface_type, geo_cached_cc),
#   lib/cmd-dns.sh (_resolve_a, _get_isp_dns),
#   lib/ip.sh (is_tunnel_iface),
#   lib/common.sh (json_kv, json_kv_num, json_kv_bool)
# Globals used: OUTPUT_JSON, VERBOSITY, _EXIT_CODE, DNS_TIMEOUT, _CONFIG_DIR, DATA_DIR,
#   MITM_ISSUERS_FILE, KNOWN_CAS_FILE, CONNECT_TIMEOUT, HTTP_TIMEOUT,
#   C_GREEN, C_RED, C_YELLOW, C_DIM, C_RST, C_BOLD, C_CYAN
# shellcheck disable=SC3043

# ─── TLS Probe Helper ─────────────────────────────────────────────────────────

# Probe TLS certificate for a host via specific resolved IP and WAN interface.
# Uses curl --interface for per-path binding, %{certs} to retrieve PEM chain,
# then openssl x509 to extract issuer + SHA-256 fingerprint of leaf cert.
# Args: $1 - host (SNI), $2 - connect target (ip:443 or host:443),
#        $3 - output file, $4 - interface name (optional)
# Output file format: issuer|fingerprint (pipe-separated, single line)
_tls_probe() {
  local _host="$1" _target="$2" _out="$3" _iface="${4:-}"

  local _ip="${_target%:*}"
  local _issuer="" _fp=""

  # Build curl flags: interface binding + optional IP resolve
  local _curl_iface="" _curl_resolve=""
  [ -n "$_iface" ] && _curl_iface="--interface $_iface"

  # If target has a resolved IP (not hostname), pin via --resolve
  case "$_ip" in
    [0-9]*.[0-9]*.[0-9]*.[0-9]*)
      _curl_resolve="--resolve ${_host}:443:${_ip}" ;;
  esac

  # Fetch server certificate chain via curl %{certs} (curl >= 7.85).
  # -k: accept any cert — we inspect it ourselves for MITM detection.
  # -b "": empty cookie jar to avoid cookie-based redirect loops.
  local _pem=""
  # shellcheck disable=SC2086
  _pem=$(curl -sk $_curl_iface $_curl_resolve \
    --connect-timeout "${CONNECT_TIMEOUT:-5}" \
    --max-time "${HTTP_TIMEOUT:-10}" \
    -b "" \
    -w '%{certs}' -o /dev/null \
    "https://${_host}" 2>/dev/null) || _pem=""

  if [ -n "$_pem" ]; then
    # Extract leaf (first) certificate for issuer + fingerprint
    local _leaf
    _leaf=$(printf '%s\n' "$_pem" | awk '/-----BEGIN CERTIFICATE-----/{n++} n==1')

    _issuer=$(printf '%s\n' "$_leaf" \
      | openssl x509 -noout -issuer 2>/dev/null \
      | sed 's/^issuer= *//') || _issuer=""

    _fp=$(printf '%s\n' "$_leaf" \
      | openssl x509 -noout -fingerprint -sha256 2>/dev/null \
      | sed 's/.*=//; s/://g') || _fp=""
  fi

  printf '%s|%s\n' "${_issuer:-unknown}" "${_fp:-unknown}" > "$_out"
}

# Extract short issuer name from full issuer string.
# Prefers CN=, falls back to O=, then first RDN value.
# Args: $1 - full issuer (e.g. "C=US, O=Google Trust Services, CN=GTS CA 1C3")
# stdout: short name (e.g. "GTS CA 1C3")
_issuer_short() {
  local _full="$1"
  local _short=""

  # Try CN= first
  _short=$(printf '%s' "$_full" | sed -n 's/.*CN *= *\([^,]*\).*/\1/p' | head -1)
  if [ -n "$_short" ]; then
    printf '%s' "$_short"
    return 0
  fi

  # Try O=
  _short=$(printf '%s' "$_full" | sed -n 's/.*O *= *\([^,]*\).*/\1/p' | head -1)
  if [ -n "$_short" ]; then
    printf '%s' "$_short"
    return 0
  fi

  # Fallback: first value after last /
  _short=$(printf '%s' "$_full" | sed 's/.*\///' | sed 's/ *= */=/g')
  printf '%s' "${_short:-unknown}"
}

# Check issuer against known MITM/interception proxy CAs.
# Args: $1 - full issuer string
# stdout: matched marker or empty
# Returns: 0 if MITM issuer found, 1 if clean
_check_mitm_issuer() {
  local _issuer="$1"
  [ -z "$_issuer" ] && return 1
  [ ! -f "${MITM_ISSUERS_FILE:-}" ] && return 1

  local _marker
  while IFS= read -r _marker; do
    case "$_marker" in
      "#"*|"") continue ;;
    esac
    # Case-insensitive match
    if printf '%s' "$_issuer" | grep -qi "$_marker" 2>/dev/null; then
      printf '%s' "$_marker"
      return 0
    fi
  done < "$MITM_ISSUERS_FILE"
  return 1
}

# ─── Command: tls-check (certificate check for single host) ──────────────────
# Args: $1 - hostname

cmd_tls_check() {
  local host="${1:-}"
  if [ -z "$host" ]; then
    emit_error "Usage: net-check.sh tls-check <host>"
    return 1
  fi

  check_cmd openssl "opkg install openssl-util" || return 1

  local ifaces
  ifaces=$(require_wan_ifaces) || return 1

  local has_dig=0
  command -v dig >/dev/null 2>&1 && has_dig=1

  local json_results=""
  local all_fingerprints="" all_issuers=""

  # Cache ISP DNS once before the loop
  local _cached_isp_dns=""
  if [ "$has_dig" = 1 ]; then
    _cached_isp_dns=$(_get_isp_dns | awk '{print $1}') || _cached_isp_dns=""
  fi

  section_title "${_TITLE_TLS}: $host"
  if [ "$OUTPUT_JSON" = 0 ] && ! is_quiet; then
    printf 'Compares certificate fingerprints across WAN paths.\n'
    printf 'Detects MITM proxy CAs and certificate substitution by middlebox.\n\n'
  fi
  tbl_header "Path:14" "CC:4" "Resolved IP:24" "Issuer:30" "Fingerprint:20" "Status"

  local iface
  for iface in $ifaces; do
    local issuer="" fingerprint="" tls_status="ok" resolved_ip=""
    local itype cc
    itype=$(iface_type "$iface")
    cc=$(geo_cached_cc "$iface")
    [ -z "$cc" ] && cc="—"

    # Per-path DNS resolution: ISP → ISP upstream DNS, tunnel → system DNS
    if [ "$has_dig" = 1 ]; then
      if [ "$itype" = "isp" ]; then
        # ISP interface: use ISP upstream DNS to see actual ISP view
        local _isp_dns_ip="$_cached_isp_dns"
        if [ -n "$_isp_dns_ip" ]; then
          resolved_ip=$(_resolve_a "$host" "$_isp_dns_ip") || resolved_ip=""
        fi
      fi
      # Fallback / tunnel: system DNS
      if [ -z "$resolved_ip" ]; then
        resolved_ip=$(_resolve_a "$host") || resolved_ip=""
      fi
    fi

    local _tls_target=""
    if [ -n "$resolved_ip" ]; then
      _tls_target="${resolved_ip}:443"
    else
      resolved_ip="(system)"
      _tls_target="${host}:443"
    fi

    # Probe TLS
    local _probe_out="${_RUN_DIR}/tls-probe-${iface}"
    _tls_probe "$host" "$_tls_target" "$_probe_out" "$iface"

    if [ -f "$_probe_out" ]; then
      issuer=$(cut -d'|' -f1 "$_probe_out")
      fingerprint=$(cut -d'|' -f2 "$_probe_out")
      rm -f "$_probe_out"
    fi

    issuer="${issuer:-unknown}"
    fingerprint="${fingerprint:-unknown}"

    # Determine status
    if [ "$issuer" = "unknown" ] || [ "$fingerprint" = "unknown" ]; then
      tls_status="error"
    else
      # Check for known MITM issuer first, then known national CA
      local _mitm_match=""
      _mitm_match=$(_check_mitm_issuer "$issuer") || true
      if [ -n "$_mitm_match" ]; then
        tls_status="mitm_proxy"
      else
        local _known_ca_match=""
        _known_ca_match=$(_check_known_ca "$issuer") || true
        [ -n "$_known_ca_match" ] && tls_status="known_ca"
      fi
    fi

    all_fingerprints="${all_fingerprints}${iface}:${fingerprint}
"
    all_issuers="${all_issuers}${iface}:${issuer}
"

    if [ "$OUTPUT_JSON" = 1 ]; then
      local entry_json
      entry_json=$(printf '{"dev":"%s","type":"%s","cc":"%s","resolved_ip":"%s","issuer":"%s","fingerprint":"%s","status":"%s"}' \
        "$iface" "$itype" "$cc" "$resolved_ip" \
        "$(json_escape_val "$issuer")" "$fingerprint" "$tls_status")
      json_arr_add json_results "$entry_json"
    else
      local _st="ok"
      case "$tls_status" in
        error) _st="fail" ;;
        mitm_proxy) _st="warn" ;;
      esac

      local _iss_short _fp_short
      _iss_short=$(_issuer_short "$issuer")
      # Truncate issuer for display
      if [ ${#_iss_short} -gt 28 ]; then
        _iss_short=$(printf '%.25s...' "$_iss_short")
      fi
      # Show first 16 chars of fingerprint
      _fp_short=$(printf '%.16s' "$fingerprint")
      [ "$fingerprint" != "unknown" ] && _fp_short="${_fp_short}..."

      tbl_cell_v 18 "$resolved_ip" dim; local _c1="$_CELL"
      tbl_cell_v 20 "$_fp_short" "$_st"; local _c2="$_CELL"
      tbl_row "$iface" "$cc" "$_c1" "$_iss_short" "$_c2" \
        "$(status_mark "$_st")"
    fi
  done

  # Summary: compare fingerprints across paths
  if [ "$OUTPUT_JSON" = 0 ]; then
    local unique_fps
    unique_fps=$(printf '%s' "$all_fingerprints" | sed 's/^[^:]*://' | grep -v '^$' | sort -u | grep -c '.' 2>/dev/null) || unique_fps=0
    local unknown_fps
    unknown_fps=$(printf '%s' "$all_fingerprints" | grep -c ':unknown$' 2>/dev/null) || unknown_fps=0
    # Check MITM issuers
    local mitm_found=0
    local _ai_line _ai_issuer
    printf '%s' "$all_issuers" | while IFS=: read -r _ _ai_issuer; do
      [ -z "$_ai_issuer" ] && continue
      if _check_mitm_issuer "$_ai_issuer" >/dev/null 2>&1; then
        printf 'mitm'
        break
      fi
    done | grep -q 'mitm' && mitm_found=1

    if is_quiet; then
      if [ "$mitm_found" = 1 ]; then
        printf 'tls-check: %s known MITM proxy CA detected for %s\n' "$(status_mark warn)" "$host"
      elif [ "$unique_fps" -le 1 ] && [ "$unknown_fps" = 0 ]; then
        printf 'tls-check: same cert %s (%s)\n' "$(status_mark ok)" "$host"
      elif [ "$unknown_fps" -gt 0 ]; then
        printf 'tls-check: %s some paths failed for %s\n' "$(status_mark fail)" "$host"
      else
        printf 'tls-check: %s %s different certs for %s — possible MITM\n' "$(status_mark warn)" "$unique_fps" "$host"
      fi
    else
      if [ "$mitm_found" = 1 ]; then
        printf '→ %s%s Known MITM/interception proxy CA detected%s\n' \
          "$C_RED" "$(status_mark warn)" "$C_RST"
        [ "$_EXIT_CODE" -lt 1 ] && _EXIT_CODE=1
      elif [ "$unique_fps" -le 1 ] && [ "$unknown_fps" = 0 ]; then
        printf '→ %sSame certificate across all paths%s %s\n' "$C_GREEN" "$C_RST" "$(status_mark ok)"
      elif [ "$unknown_fps" -gt 0 ]; then
        printf '→ %sSome paths failed to retrieve certificate%s %s\n' \
          "$C_YELLOW" "$C_RST" "$(status_mark fail)"
      else
        printf '→ %s%s Different certificates detected (%s unique) — possible MITM%s\n' \
          "$C_RED" "$(status_mark warn)" "$unique_fps" "$C_RST"
        [ "$_EXIT_CODE" -lt 1 ] && _EXIT_CODE=1
      fi
    fi
  fi

  if [ "$OUTPUT_JSON" = 1 ]; then
    local _ok_val=0 _verdict="same_cert"
    local _ufp
    _ufp=$(printf '%s' "$all_fingerprints" | sed 's/^[^:]*://' | grep -v '^$' | sort -u | grep -c '.' 2>/dev/null) || _ufp=0
    if [ "$_ufp" -gt 1 ]; then
      _ok_val=1
      _verdict="different_certs"
    fi
    printf '%s' "$all_issuers" | while IFS=: read -r _ _ai_issuer; do
      [ -z "$_ai_issuer" ] && continue
      _check_mitm_issuer "$_ai_issuer" >/dev/null 2>&1 && printf 'mitm'
    done | grep -q 'mitm' && { _ok_val=1; _verdict="mitm_proxy"; }
    printf '{%s,%s,%s,"results":[%s]}\n' \
      "$(json_kv_bool "ok" "$_ok_val")" \
      "$(json_kv "host" "$host")" \
      "$(json_kv "verdict" "$_verdict")" \
      "$json_results"
  fi
}

# ─── Command: tls-check-targets (batch — single table like compare) ───────────

# Run TLS certificate check for all HTTPS hosts in check-targets.conf.
# Output format: single comparison table with interface columns (like cmd_compare).
# Compares SHA-256 fingerprints; flags known MITM proxy CAs.
cmd_tls_check_targets() {
  check_cmd openssl "opkg install openssl-util" || return 1

  if [ $# -eq 0 ] && [ ! -f "$_CONFIG_DIR/check-targets.conf" ]; then
    emit_error "Targets file not found: check-targets.conf"
    return 1
  fi

  local ifaces
  ifaces=$(require_wan_ifaces) || return 1

  local has_dig=0
  command -v dig >/dev/null 2>&1 && has_dig=1

  load_zone_context

  # Warm geo cache for accurate CC in comparison table headers
  ensure_geo_cache
  precache_geo_cc

  section_title "$_TITLE_TLS"
  if [ "$OUTPUT_JSON" = 0 ] && ! is_quiet; then
    printf 'Compares certificate fingerprints across WAN paths per target.\n'
    printf 'Detects MITM proxy CAs and certificate substitution by middlebox.\n\n'
  fi

  local json_results=""
  local _tls_ok=0 _tls_total=0 _tls_mitm=0

  # Cache ISP DNS once (shared across all hosts)
  local _cached_isp_dns=""
  if [ "$has_dig" = 1 ]; then
    _cached_isp_dns=$(_get_isp_dns | awk '{print $1}') || _cached_isp_dns=""
  fi

  # ── Phase 1: Read all HTTPS hosts (from arguments or config) ──
  local _tls_hosts="" url check_type _category _description _expected host
  if [ $# -gt 0 ]; then
    # Deep check mode: use passed domains
    for url in "$@"; do
      host=$(url_to_host "$url")
      [ -z "$host" ] && continue
      _tls_total=$((_tls_total + 1))
      _tls_hosts="${_tls_hosts} ${host}"
      printf '%s' "check" > "${_RUN_DIR}/tls-cat-${host}"
    done
  else
    # Default: load from check-targets.conf (zone-filtered by _cat_config)
    while IFS='|' read -r url check_type _category _description _expected; do
      case "$url" in "#"*|"") continue ;; esac
      [ "$check_type" = "geo" ] && continue
      host="${url#https://}"; host="${host#http://}"; host="${host%%/*}"; host="${host%%:*}"
      [ -z "$host" ] && continue
      _tls_total=$((_tls_total + 1))
      _tls_hosts="${_tls_hosts} ${host}"
      printf '%s' "${_category:-global}" > "${_RUN_DIR}/tls-cat-${host}"
    done <<EOF
$(_cat_config check-targets)
EOF
  fi

  # Auto-width first column
  local _label_w
  _label_w=$(auto_label_width "$_tls_hosts")
  cmp_header "Host" "$ifaces" "" "$_label_w"
  tbl_group_reset

  # ── Phase 2: Batched parallel TLS probes ──
  # shellcheck disable=SC2329
  _tls_run_batch() {
    local _hosts="$1"
    local _bh
    for _bh in $_hosts; do
      for iface in $ifaces; do
        (
          _resolved=""
          if [ "$has_dig" = 1 ]; then
            if ! is_tunnel_iface "$iface"; then
              if [ -n "$_cached_isp_dns" ]; then
                _resolved=$(_resolve_a "$_bh" "$_cached_isp_dns") || _resolved=""
              fi
            fi
            [ -z "$_resolved" ] && { _resolved=$(_resolve_a "$_bh") || _resolved=""; }
          fi
          if [ -n "$_resolved" ]; then _tgt="${_resolved}:443"
          else _resolved="(system)"; _tgt="${_bh}:443"; fi

          _probe_out="${_RUN_DIR}/tls-par-${_bh}-${iface}"
          _tls_probe "$_bh" "$_tgt" "$_probe_out" "$iface"
          printf '%s\n' "$_resolved" >> "$_probe_out"
        ) &
      done
    done
  }
  batch_run_parallel "TLS" "$PARALLEL_BATCH_SIZE" "$_tls_hosts" _tls_run_batch

  # ── Phase 3: Collect results and render table (in original host order) ──
  for host in $_tls_hosts; do
    # Category group separator
    local _tls_cat="global"
    if [ -f "${_RUN_DIR}/tls-cat-${host}" ]; then
      _tls_cat=$(cat "${_RUN_DIR}/tls-cat-${host}")
      rm -f "${_RUN_DIR}/tls-cat-${host}"
    fi
    tbl_group_sep "$_tls_cat"

    local _host_fps="" _host_mitm=0 _host_known_ca=0 _host_error=0
    local _host_json_paths=""

    # Determine active route device for this host (for cell marker).
    # TLS targets don't carry check-targets category — falls back to kernel FIB.
    local _active_route_dev=""
    local _resolved_ip=""
    _resolved_ip=$(_resolve_a_cached "$host" 2>/dev/null) || _resolved_ip=""
    _active_route_dev=$(active_dev_for_target "$_resolved_ip" "")

    # Pre-scan: collect healthy fingerprints and pick recommended iface
    local _recommended_dev="" _rec_ok_n=0 _ri _pre_fps=""
    for _ri in $ifaces; do
      local _rpf="${_RUN_DIR}/tls-par-${host}-${_ri}"
      [ -f "$_rpf" ] || continue
      local _r_line1 _r_issuer _r_fp
      _r_line1=$(sed -n '1p' "$_rpf")
      _r_issuer=$(printf '%s' "$_r_line1" | cut -d'|' -f1)
      _r_fp=$(printf '%s' "$_r_line1" | cut -d'|' -f2)
      { [ -z "$_r_issuer" ] || [ "$_r_issuer" = "unknown" ]; } && continue
      { [ -z "$_r_fp" ] || [ "$_r_fp" = "unknown" ]; } && continue
      # Skip MITM paths
      _check_mitm_issuer "$_r_issuer" >/dev/null 2>&1 && continue
      _rec_ok_n=$((_rec_ok_n + 1))
      _pre_fps="${_pre_fps}${_r_fp}
"
      _recommended_dev="$_ri"
    done
    # No ★ when single iface (no choice to show)
    local _n_ifc
    _n_ifc=$(printf '%s' "$ifaces" | wc -w | tr -d ' ')
    [ "$_n_ifc" -le 1 ] && _recommended_dev=""
    # No ★ when all fingerprints identical (nothing to recommend)
    local _pre_unique_fps
    _pre_unique_fps=$(printf '%s' "$_pre_fps" | grep -v '^$' | sort -u | grep -c '.' 2>/dev/null) || _pre_unique_fps=0
    [ "$_pre_unique_fps" -le 1 ] && _recommended_dev=""

    cmp_row_start "$host"

    for iface in $ifaces; do
      local _pf="${_RUN_DIR}/tls-par-${host}-${iface}"
      local _issuer="unknown" _fp="unknown" _resolved="(system)"

      if [ -f "$_pf" ]; then
        _issuer=$(sed -n '1p' "$_pf" | cut -d'|' -f1)
        _fp=$(sed -n '1p' "$_pf" | cut -d'|' -f2)
        _resolved=$(sed -n '2p' "$_pf")
        rm -f "$_pf"
      fi

      _issuer="${_issuer:-unknown}"
      _fp="${_fp:-unknown}"
      _resolved="${_resolved:-(system)}"

      # Determine per-path status
      local _path_st="ok"
      if [ "$_issuer" = "unknown" ] || [ "$_fp" = "unknown" ]; then
        _path_st="error"
        _host_error=$((_host_error + 1))
      else
        local _mitm_match=""
        _mitm_match=$(_check_mitm_issuer "$_issuer") || true
        if [ -n "$_mitm_match" ]; then
          _path_st="mitm_proxy"
          _host_mitm=1
        else
          local _known_ca_match=""
          _known_ca_match=$(_check_known_ca "$_issuer") || true
          if [ -n "$_known_ca_match" ]; then
            _path_st="known_ca"
            _host_known_ca=1
          fi
        fi
      fi

      _host_fps="${_host_fps}${_fp}
"

      # JSON path entry
      local _itype
      _itype=$(iface_type "$iface")
      local _path_json
      _path_json=$(printf '{"dev":"%s","type":"%s","resolved_ip":"%s","issuer":"%s","fingerprint":"%s","status":"%s"}' \
        "$iface" "$_itype" "$_resolved" \
        "$(json_escape_val "$_issuer")" "$_fp" "$_path_st")
      json_arr_add _host_json_paths "$_path_json"

      # Table cell (text markers like cmd_compare for alignment)
      if [ "$OUTPUT_JSON" = 0 ] && ! is_quiet; then
        local _cell_st="ok" _short_st="ok"
        case "$_path_st" in
          error)      _cell_st="fail"; _short_st="ERR" ;;
          mitm_proxy) _cell_st="warn"; _short_st="MIM" ;;
          known_ca)   _cell_st="dim";  _short_st="NCA" ;;
        esac

        local _iss_s _iss_w=$((_CMP_COL_W - 4))
        _iss_s=$(_issuer_short "$_issuer")
        if [ ${#_iss_s} -gt "$_iss_w" ]; then
          _iss_s=$(printf '%.*s..' "$((_iss_w - 2))" "$_iss_s")
        fi

        tbl_cell_v 3 "$_short_st" "$_cell_st"; local _c1="$_CELL"
        tbl_cell_v "$_iss_w" "$_iss_s"; local _c2="$_CELL"
        local _cell
        _cell=$(printf '%s %s' "$_c1" "$_c2")
        local _is_active=0 _is_recommended=0
        [ "$iface" = "$_active_route_dev" ] && _is_active=1
        [ "$iface" = "$_recommended_dev" ] && _is_recommended=1
        cmp_cell "$_cell" "$_is_active" "$_is_recommended"
      fi
    done

    # ── Per-host verdict ──
    # Count unique VALID fingerprints (excluding "unknown" from failed/blocked paths)
    local _unique_valid_fps _total_paths _verdict="same_cert"
    _unique_valid_fps=$(printf '%s' "$_host_fps" | grep -v '^$' | grep -v '^unknown$' | sort -u | grep -c '.' 2>/dev/null) || _unique_valid_fps=0
    _total_paths=$(printf '%s' "$_host_fps" | grep -v '^$' | grep -c '.' 2>/dev/null) || _total_paths=0

    if [ "$_host_mitm" = 1 ]; then
      _verdict="mitm_proxy"
      _tls_mitm=$((_tls_mitm + 1))
    elif [ "$_total_paths" -gt 0 ] && [ "$_total_paths" -eq "$_host_error" ]; then
      # All paths failed — no cert data at all
      _verdict="all_error"
    elif [ "$_unique_valid_fps" -gt 1 ]; then
      # Multiple different valid fingerprints — real MITM suspected
      _verdict="different_certs"
      _tls_mitm=$((_tls_mitm + 1))
    elif [ "$_host_known_ca" = 1 ]; then
      # National/regional CA — not MITM, but not in standard trust store
      _verdict="known_ca"
      _tls_ok=$((_tls_ok + 1))
    else
      # Same valid FP across working paths (blocked paths don't count as MITM)
      _tls_ok=$((_tls_ok + 1))
    fi

    # Build host JSON
    local _host_ok_val=0
    case "$_verdict" in
      different_certs|mitm_proxy) _host_ok_val=1 ;;
    esac
    local _host_json _ok_jv="false"
    [ "$_host_ok_val" = 0 ] && _ok_jv="true"
    _host_json=$(printf '{"ok":%s,"target":"%s","verdict":"%s","paths":[%s]}' \
      "$_ok_jv" "$host" "$_verdict" "$_host_json_paths")
    json_arr_add json_results "$_host_json"

    local _vst="ok"
    local _vtext="same"
    case "$_verdict" in
      same_cert)        _vst="ok";   _vtext="same" ;;
      known_ca)         _vst="dim";  _vtext="NatCA" ;;
      mitm_proxy)       _vst="warn"; _vtext="MITM" ;;
      different_certs)  _vst="warn"; _vtext="differ" ;;
      all_error)        _vst="fail"; _vtext="error" ;;
    esac
    # Annotate with blocked path count when some paths failed but cert matches
    if [ "$_host_error" -gt 0 ] && [ "$_verdict" != "all_error" ]; then
      _vtext="${_vtext} (${_host_error} blocked)"
    fi
    cmp_row_end "$(color_status "$_vst" "$_vtext")"
  done

  # ── Summary ──
  if [ "$OUTPUT_JSON" = 0 ]; then
    if is_quiet; then
      if [ "$_tls_mitm" -gt 0 ]; then
        printf 'tls: %s %s/%s hosts have cert issues\n' "$(status_mark warn)" "$_tls_mitm" "$_tls_total"
      else
        printf 'tls: %s/%s hosts same cert %s\n' "$_tls_ok" "$_tls_total" "$(status_mark ok)"
      fi
    else
      if [ "$_tls_mitm" -gt 0 ]; then
        printf '→ %s%s %s/%s hosts have certificate discrepancies%s\n' \
          "$C_RED" "$(status_mark warn)" "$_tls_mitm" "$_tls_total" "$C_RST"
        [ "$_EXIT_CODE" -lt 1 ] && _EXIT_CODE=1
      fi
      summary_line "$_tls_ok" "$_tls_total" "hosts"
    fi
  fi

  if [ "$OUTPUT_JSON" = 1 ]; then
    local ok_val=0
    [ "$_tls_mitm" -gt 0 ] && ok_val=1
    printf '{%s,%s,%s,"hosts":[%s]}\n' \
      "$(json_kv_bool "ok" "$ok_val")" \
      "$(json_kv_num "total" "$_tls_total")" \
      "$(json_kv_num "mitm_count" "$_tls_mitm")" \
      "$json_results"
  fi
}

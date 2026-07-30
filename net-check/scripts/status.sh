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
    fi
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
# Sets: _ck_dns_leak ("resolver: <IP>"|"skipped"|"query failed")
check_dns_leak() {
  _ck_dns_leak="skipped (no dig)"
  command -v dig >/dev/null 2>&1 || return 0

  local resolver_ip
  resolver_ip=$(dig +short +time=2 +tries=1 "$DNS_LEAK_CHECK_DOMAIN" 2>/dev/null | head -1) || resolver_ip=""

  if [ -n "$resolver_ip" ]; then
    _ck_dns_leak="resolver: ${resolver_ip}"
  else
    _ck_dns_leak="query failed"
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

show_text() {
  # Header line matching kee-status.sh pattern
  local _status_word="✓ Alive"
  [ "$STATUS_OK" -ne 0 ] && _status_word="✗ Fail"

  _text_buf="net-check status: ${_status_word}
"

  # --- Paths section ---
  status_section "Paths"

  if [ -z "$_ck_ifaces" ]; then
    status_line "Interfaces" "none detected" "fail"
  else
    local iface ping_line latency itype
    local ok_count total path_status path_value counts

    for iface in $_ck_ifaces; do
      # Get ping for this iface
      latency="—"
      ping_line=$(printf '%s' "$_ck_ping_results" | grep "^${iface}:" | head -1)
      if [ -n "$ping_line" ]; then
        latency="${ping_line#*:}"
      fi

      itype="isp"
      is_tunnel_iface "$iface" && itype="tunnel"

      # Build value string: "tunnel, ping 153ms | 7/9"
      if [ "$latency" = "—" ]; then
        path_value="${itype}, ping —"
        path_status="fail"
      else
        path_value="${itype}, ping ${latency}ms"
        path_status="ok"
      fi

      # Append cached results: | ok/total (or ?/? when no cache)
      counts=$(cache_counts_for_iface "$iface")
      ok_count="${counts% *}"
      total="${counts#* }"
      path_value="${path_value} | ${ok_count}/${total}"

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

  # --- System section ---
  status_blank
  status_section "System"

  case "$_ck_dns_leak" in
    resolver:*) status_line "DNS leak" "$_ck_dns_leak" "ok" ;;
    query*)     status_line "DNS leak" "$_ck_dns_leak" "fail" ;;
    *)          status_line "DNS leak" "$_ck_dns_leak" ;;
  esac

  if [ -n "$_ck_cache_age" ]; then
    status_line "Last check" "$(format_age "$_ck_cache_age") ago"
  else
    status_line "Last check" "never"
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

  # Paths array
  local json_paths="" first_path=1
  local iface ping_line latency itype counts ok_count total
  for iface in $_ck_ifaces; do
    latency="0"
    ping_line=$(printf '%s' "$_ck_ping_results" | grep "^${iface}:" | head -1)
    if [ -n "$ping_line" ]; then
      local raw_lat="${ping_line#*:}"
      [ "$raw_lat" != "—" ] && latency="$raw_lat"
    fi

    itype="isp"
    is_tunnel_iface "$iface" && itype="tunnel"

    counts=$(cache_counts_for_iface "$iface")
    ok_count="${counts% *}"
    total="${counts#* }"
    [ "$ok_count" = "?" ] && ok_count="0"
    [ "$total" = "?" ] && total="0"

    local path_json
    path_json=$(printf '{%s,%s,%s,%s,%s}' \
      "$(json_kv "dev" "$iface")" \
      "$(json_kv "type" "$itype")" \
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
check_cache
flatten_cache
check_cached_results
check_dns_leak

if [ "$OUTPUT_JSON" = 1 ]; then
  show_json
else
  show_text
fi

exit "$STATUS_OK"

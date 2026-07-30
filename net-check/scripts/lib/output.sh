# net-check: UI output — colors, spinner, banners, error/warning emitters, usage.
# Dependencies: json_kv, json_kv_bool from lib/common.sh
# Globals used: OUTPUT_JSON, USE_COLOR, VERBOSITY,
#   C_RST, C_BOLD, C_DIM, C_GREEN, C_RED, C_YELLOW, C_CYAN, _spinner_pid
# shellcheck disable=SC2034
# shellcheck disable=SC2153
# shellcheck disable=SC3043

# ─── Section Titles (single source of truth) ─────────────────────────────────
# Used by both section_title() (standalone) and section_banner() (cmd_all).
_TITLE_GEO="Egress Point Verification (Layers 3+7)"
_TITLE_CONN="Basic Connectivity (Layers 3–7)"
_TITLE_IPV6="IPv6 Leak Test (Layers 3+7)"
_TITLE_DNS="DNS Resolution & ISP Filtering (Layer 7)"
_TITLE_DNS_LEAK="DNS Leak Test (Layer 7)"
_TITLE_COMPARE="HTTP Target Comparison (Layers 4–7)"
_TITLE_CDN="CDN Geo-Steering Analysis (Layers 3+7)"
_TITLE_TLS="TLS Certificate Check (Layers 5–7)"
_TITLE_SPEED="Throughput Test (Layers 4+7)"
_TITLE_CHECK="Deep Resource Check"

# Set up terminal color escape codes.
# Delegates to lib/status.sh status_setup_colors(), then aliases C_* from _SC_*.
# Respects --no-color flag, NO_COLOR env, and non-tty output.
setup_colors() {
  status_setup_colors "$USE_COLOR"
  C_RST="$_SC_RST"
  C_BOLD="$_SC_BOLD"
  C_DIM="$_SC_DIM"
  C_GREEN="$_SC_GREEN"
  C_RED="$_SC_RED"
  C_YELLOW="$_SC_YELLOW"
  C_CYAN="$_SC_CYAN"
}

# ─── Data Directory ───────────────────────────────────────────────────────────

# Ensure persistent data directory exists (lazy safety net for dev deploys).
# Production install creates it via postinst.
ensure_data_dir() {
  [ -d "$DATA_DIR" ] || mkdir -p "$DATA_DIR"
}

# ─── Spinner ──────────────────────────────────────────────────────────────────

# Start a background spinner on stderr (text mode + tty only).
# Args: $1 - status message
start_spinner() {
  [ "$OUTPUT_JSON" = 1 ] && return 0
  [ ! -t 2 ] && return 0
  (
    trap 'exit 0' TERM
    _i=0
    while true; do
      # shellcheck disable=SC1003
      case $((_i % 4)) in
        0) _c='|' ;; 1) _c='/' ;; 2) _c='-' ;; *) _c='\' ;;
      esac
      printf '\r  %s %s' "$_c" "$1" >&2
      _i=$((_i + 1))
      usleep 50000 2>/dev/null || sleep 1
    done
  ) &
  _spinner_pid=$!
}

# Stop background spinner and clear its line.
stop_spinner() {
  if [ -n "${_spinner_pid:-}" ]; then
    kill "$_spinner_pid" 2>/dev/null
    wait "$_spinner_pid" 2>/dev/null || true
    _spinner_pid=""
  fi
  printf '\r\033[2K' >&2
}

# Ensure spinner cleanup on script interrupt or exit.
# INT/TERM handlers call exit so the script actually stops on Ctrl+C.
cleanup_exit() {
  stop_spinner
  rm -rf "${_RUN_DIR:-}" 2>/dev/null || true
}
cleanup_int() {
  stop_spinner
  # Kill all child processes (parallel subshells, openssl, curl, etc.)
  # so Ctrl+C takes effect immediately even during long-running operations.
  kill 0 2>/dev/null || true
  exit 130
}
trap 'cleanup_exit' EXIT
trap 'cleanup_int' INT TERM

# ─── Color Helpers ────────────────────────────────────────────────────────────

# Colorize text based on status.
# Args: $1 - "ok"|"warn"|"fail", $2 - text
# stdout: colored text (or plain if no color)
color_status() {
  local _st="$1" _txt="$2"
  case "$_st" in
    ok)   printf '%s%s%s' "$C_GREEN" "$_txt" "$C_RST" ;;
    warn) printf '%s%s%s' "$C_YELLOW" "$_txt" "$C_RST" ;;
    fail) printf '%s%s%s' "$C_RED" "$_txt" "$C_RST" ;;
    dim)  printf '%s%s%s' "$C_DIM" "$_txt" "$C_RST" ;;
    *)    printf '%s' "$_txt" ;;
  esac
}

# Check if emoji are explicitly disabled (--no-color / NO_COLOR env).
# Emoji are inherently colored and work without ANSI codes;
# only explicit --no-color replaces them with b/w Unicode.
_no_emoji() {
  [ "$USE_COLOR" = "never" ] || [ "${NO_COLOR:-}" = 1 ]
}

# Status mark: ✅ / ⚠️ / ❌ (emoji); ✓/!/✗ (--no-color).
# Args: $1 - "ok"|"warn"|"fail"|"skip"|"dim"
# stdout: emoji or b/w Unicode mark
status_mark() {
  if _no_emoji; then
    case "$1" in
      ok)   printf '✓' ;;
      warn) printf '!' ;;
      fail) printf '✗' ;;
      *)    printf '-' ;;
    esac
  else
    # Trailing space after emoji prevents terminal glyph-width eating next char.
    # ⚠️ (U+26A0+U+FE0F) is especially prone to this with variation selector.
    case "$1" in
      ok)   printf '%s✅ %s' "$C_GREEN" "$C_RST" ;;
      warn) printf '%s⚠️ %s'  "$C_YELLOW" "$C_RST" ;;
      fail) printf '%s❌ %s' "$C_RED" "$C_RST" ;;
      skip|dim) printf '%s— %s'  "$C_DIM" "$C_RST" ;;
      *)    printf '— ' ;;
    esac
  fi
}

# Cache indicator: ℹ️ cached (emoji) or 🛈 cached (--no-color).
# stdout: cache mark with label
cache_mark() {
  if _no_emoji; then
    printf '🛈 cached'
  else
    printf '%sℹ️  cached%s' "$C_DIM" "$C_RST"
  fi
}

# Print a colored summary line: "→ N ok, M failed"
# Args: $1 - ok count, $2 - total count, $3 - label (optional, default "checks")
summary_line() {
  local _ok="$1" _total="$2" _label="${3:-checks}"
  local _fail=$((_total - _ok))
  if [ "$_fail" -eq 0 ]; then
    printf '→ %s%s/%s %s passed%s %s\n' "$C_GREEN" "$_ok" "$_total" "$_label" "$C_RST" \
      "$(status_mark ok)"
  elif [ "$_ok" -eq 0 ]; then
    printf '→ %s0/%s %s passed%s %s\n' "$C_RED" "$_total" "$_label" "$C_RST" \
      "$(status_mark fail)"
  else
    printf '→ %s%s/%s%s %s passed, %s%s failed%s\n' \
      "$C_YELLOW" "$_ok" "$_total" "$C_RST" "$_label" \
      "$C_RED" "$_fail" "$C_RST"
  fi
}

# Print unified summary footer (used by both cmd_all and single commands).
# Args: $1 - elapsed seconds, $2 - ok count, $3 - total count
# Respects: OUTPUT_JSON, is_quiet
print_summary_footer() {
  [ "$OUTPUT_JSON" = 1 ] && return 0
  is_quiet && return 0
  local _elapsed="$1" _ok="$2" _total="$3"
  local _sc="$C_GREEN" _sm _label="OK"
  _sm="$(status_mark ok)"
  if [ "$_ok" -lt "$_total" ]; then
    _sc="$C_RED"
    _sm="$(status_mark fail)"
    _label="FAIL"
  fi
  printf '\n%s══════════════════════════════════════════════════════════%s\n' "$C_CYAN" "$C_RST"
  printf '  %s%sDone in %ss.%s %s/%s sections %s %s\n' \
    "$C_BOLD" "$_sc" "$_elapsed" "$C_RST" "$_ok" "$_total" "$_label" "$_sm"
  printf '%s══════════════════════════════════════════════════════════%s\n' "$C_CYAN" "$C_RST"
}

# Print verbose timing waterfall (DNS→TCP→TLS→TTFB→Total).
# Only shown when VERBOSITY >= 2.
# Args: $1 - time_namelookup, $2 - time_connect, $3 - time_appconnect,
#       $4 - time_starttransfer, $5 - time_total, $6 - label prefix
verbose_timing() {
  [ "${VERBOSITY:-1}" -lt 2 ] && return 0
  [ "$OUTPUT_JSON" = 1 ] && return 0
  local _dns="$1" _tcp="$2" _tls="$3" _ttfb="$4" _total="$5" _pfx="${6:-  }"
  local _dns_ms _tcp_ms _tls_ms _ttfb_ms _total_ms
  _dns_ms=$(to_ms "$_dns")
  _tcp_ms=$(to_ms "$_tcp")
  _tls_ms=$(to_ms "$_tls")
  _ttfb_ms=$(to_ms "$_ttfb")
  _total_ms=$(to_ms "$_total")
  printf '%s%s  DNS %sms → TCP %sms → TLS %sms → TTFB %sms → Total %sms%s\n' \
    "$_pfx" "$C_DIM" "$_dns_ms" "$_tcp_ms" "$_tls_ms" "$_ttfb_ms" "$_total_ms" "$C_RST"
}

# ─── Helpers ──────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
net-check — network diagnostics for multi-WAN routers

Usage:
  net-check.sh [options] <command> [args]

Per-interface diagnostics:
  geo              External IP, country, ASN per WAN path (L3+7)
  conn             TCP/TLS timing, traceroute, packet loss, MTU (L3–7)
  ipv6             Detect IPv6 traffic leaking outside tunnel (L3+7)
  speed            Download/upload throughput per WAN interface (L4+7)

Bulk checks (all targets from config):
  comp             HTTP reachability table across WAN paths + diff (L4–7)
  dns              DNS resolution & ISP filtering detection (L7)
  dns-leak         DNS leak test — resolver chain discovery (L7)
  cdn              CDN edge geo-steering for cdn-domains.conf (L3+7)
  tls              TLS certificate MITM detection (L5–7)

Single/multi target:
  check <url> ...  Deep check: HTTP + DNS + TLS + CDN (L3–7)

Full suite:
  all              Run everything: geo → conn → ipv6 → dns → dns-leak → comp → cdn → tls → speed

Options:
  --json           JSON output
  --privacy        Mask IPs, ASN, geo, org in output
  --iface <dev>    Limit to one WAN interface
  --no-color       Disable ANSI colors
  --quiet          One-line pass/fail summary per command

Exit codes: 0 = ok, 1 = degraded, 2 = critical

Config: ${_CONFIG_DIR}/
  defaults.conf, config.conf, check-targets.conf, cdn-domains.conf,
  anomaly-markers.conf, mitm-issuers.conf, privacy-providers.conf
EOF
}

# Check if a command is available; emit error and return 1 if not.
# Unlike require_cmd from lib/common.sh, this does NOT exit the script.
# Args: $1 - command name, $2 - optional install hint
# Returns: 0 if found, 1 if missing
check_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    emit_error "$1 not installed${2:+ ($2)}"
    return 1
  fi
}

# Emit error in text or JSON format.
# Args: $1 - error message
emit_error() {
  local msg="$1"
  if [ "$OUTPUT_JSON" = 1 ]; then
    printf '{%s,%s}\n' "$(json_kv_bool "ok" 1)" "$(json_kv "error" "$msg")"
  else
    printf '%sError: %s%s\n' "$C_RED" "$msg" "$C_RST" >&2
  fi
  return 1
}

# Emit warning to stderr (text mode only).
# Args: $1 - warning message
emit_warn() {
  [ "$OUTPUT_JSON" = 1 ] && return 0
  printf '%s%s %s%s\n' "$C_YELLOW" "$(status_mark warn)" "$1" "$C_RST" >&2
}

# Print section banner with step counter (text mode only, used by cmd_all).
# Args: $1 - step number, $2 - total steps, $3 - title
section_banner() {
  [ "$OUTPUT_JSON" = 1 ] && return 0
  printf '%s══════════════════════════════════════════════════════════%s\n' "$C_CYAN" "$C_RST"
  printf '  %s[%s/%s] %s%s\n' "$C_BOLD" "$1" "$2" "$3" "$C_RST"
  printf '%s══════════════════════════════════════════════════════════%s\n' "$C_CYAN" "$C_RST"
}

# Print section title without step counter (text mode only, used by single commands).
# Suppressed when _IN_BATCH=1 (cmd_all uses section_banner with same title instead).
# Stores title in _LAST_SECTION_TITLE for potential reuse.
# Args: $1 - title
section_title() {
  _LAST_SECTION_TITLE="$1"
  [ "$OUTPUT_JSON" = 1 ] && return 0
  is_quiet && return 0
  [ "${_IN_BATCH:-0}" = 1 ] && return 0
  printf '%s══════════════════════════════════════════════════════════%s\n' "$C_CYAN" "$C_RST"
  printf '  %s%s%s\n' "$C_BOLD" "$1" "$C_RST"
  printf '%s══════════════════════════════════════════════════════════%s\n' "$C_CYAN" "$C_RST"
}

# Check if in quiet mode (VERBOSITY=0).
is_quiet() {
  [ "${VERBOSITY:-1}" -eq 0 ]
}

# Check if in verbose mode (VERBOSITY=2).
is_verbose() {
  [ "${VERBOSITY:-1}" -ge 2 ]
}

# ─── Table Helpers ────────────────────────────────────────────────────────────
# Simple table generator: header + separator + rows with consistent format.
# Globals set: _TBL_FMT (printf format string, reused by tbl_row)
#   _TBL_GROUP_PREV (previous group for tbl_group_sep)

# Print table header + separator. Stores printf format for tbl_row.
# Args: "Name:width" ... (last column without :width → unbounded)
# Skips output in JSON or quiet mode.
tbl_header() {
  [ "$OUTPUT_JSON" = 1 ] && return 0
  is_quiet && return 0
  local _fmt="" _hdr="" _total_w=0 _spec _name _w
  for _spec in "$@"; do
    case "$_spec" in
      *:*) _name="${_spec%%:*}"; _w="${_spec#*:}" ;;
      *)   _name="$_spec"; _w=0 ;;
    esac
    if [ "$_w" -gt 0 ]; then
      _fmt="${_fmt}%-${_w}s "
      _hdr="${_hdr}$(printf "%-${_w}s " "$_name")"
      _total_w=$((_total_w + _w + 1))
    else
      _fmt="${_fmt}%s"
      _hdr="${_hdr}${_name}"
      _total_w=$((_total_w + ${#_name}))
    fi
  done
  _TBL_FMT="$_fmt"
  printf '%s\n' "$_hdr"
  printf '%*s\n' "$_total_w" '' | tr ' ' '-'
}

# Print table data row using stored _TBL_FMT from tbl_header.
# Args: cell values (same count as tbl_header columns)
# Skips output in JSON or quiet mode.
tbl_row() {
  [ "$OUTPUT_JSON" = 1 ] && return 0
  is_quiet && return 0
  # shellcheck disable=SC2059
  printf "${_TBL_FMT}\n" "$@"
}

# Pad text to exact visual width, then wrap in color.
# Fixes ANSI escape codes breaking printf %-Ns alignment.
# Use for colored cells in non-last columns.
# Args: $1 - width (0 = no pad), $2 - text, $3 - color status (ok/warn/fail/dim; empty = plain)
# stdout: padded text optionally wrapped in color
tbl_cell() {
  local _w="$1" _text="$2" _st="${3:-}"
  local _padded
  if [ "$_w" -gt 0 ] 2>/dev/null; then
    _padded=$(printf "%-${_w}s" "$_text")
  else
    _padded="$_text"
  fi
  if [ -n "$_st" ]; then
    color_status "$_st" "$_padded"
  else
    printf '%s' "$_padded"
  fi
}

# Print category group separator inside a table (e.g. "── Global ──").
# Tracks previous group via _TBL_GROUP_PREV global; prints separator only on group change.
# Call tbl_group_reset() before each new table to reset tracking.
# Args: $1 - category from check-targets.conf (e.g. "global", "zone-ru", "intl-streaming")
# Skips output in JSON or quiet mode.
# Depends: _ZONE_LABEL from wan.sh load_zone_context()
tbl_group_sep() {
  [ "$OUTPUT_JSON" = 1 ] && return 0
  is_quiet && return 0
  local _cat="$1"
  local _cur="${_cat%%-*}"
  [ "$_cur" = "${_TBL_GROUP_PREV:-}" ] && return 0
  [ -z "$_cur" ] && return 0
  local _label
  case "$_cur" in
    global) _label="Global" ;;
    zone)   _label="Zone (${_ZONE_LABEL:-})" ;;
    intl)   _label="International" ;;
    check)  return 0 ;;
    *)      _label="$_cur" ;;
  esac
  printf '%s── %s ──%s\n' "$C_DIM" "$_label" "$C_RST"
  _TBL_GROUP_PREV="$_cur"
}

# Reset group separator tracking for a new table.
tbl_group_reset() {
  _TBL_GROUP_PREV=""
}

# ─── Comparison Table ─────────────────────────────────────────────────────────
# Multi-interface comparison table: rows = targets, columns = WAN interfaces.
# Used by: compare, tls, cdn-all.
# Globals set: _CMP_COL_W (per-interface column width)

# Print comparison table header + separator line.
# Args: $1 - first column label (e.g., "Resource", "Host", "Domain")
#       $2 - WAN interfaces list (space-separated)
#       $3 - column width (optional, default 19)
# Skips output in JSON or quiet mode.
cmp_header() {
  [ "$OUTPUT_JSON" = 1 ] && return 0
  is_quiet && return 0
  local _label="$1" _ifaces="$2" _col_w="${3:-19}"
  _CMP_COL_W="$_col_w"
  printf '%-20s' "$_label"
  local _hdr_iface _hdr_cc
  for _hdr_iface in $_ifaces; do
    _hdr_cc=$(geo_cached_cc "$_hdr_iface")
    [ -z "$_hdr_cc" ] && _hdr_cc="-"
    printf ' |  %-*s' "$_col_w" "${_hdr_iface} (${_hdr_cc})"
  done
  printf ' | %s\n' "Verdict"
  local _n_ifaces _sep_len
  _n_ifaces=$(printf '%s' "$_ifaces" | wc -w | tr -d ' ')
  _sep_len=$((20 + (_col_w + 4) * _n_ifaces + 12))
  printf '%*s\n' "$_sep_len" "" | tr ' ' '-'
}

# Print first cell of a comparison row.
# Args: $1 - row label (e.g., hostname)
# Skips output in JSON or quiet mode.
cmp_row_start() {
  [ "$OUTPUT_JSON" = 1 ] && return 0
  is_quiet && return 0
  printf '%-20s' "$1"
}

# Print one interface cell in the current row.
# Args: $1 - pre-formatted cell content,
#        $2 - "1" to mark as active route (►),
#        $3 - "1" to mark as recommended/best path (★) (optional)
# Marker combos: ►★ active+best, ►  active,  ★ best only, (none).
# Skips output in JSON or quiet mode.
cmp_cell() {
  [ "$OUTPUT_JSON" = 1 ] && return 0
  is_quiet && return 0
  local _active="${2:-0}" _rec="${3:-0}"
  if _no_emoji; then
    if [ "$_active" = "1" ] && [ "$_rec" = "1" ]; then
      printf ' |>*%s' "$1"
    elif [ "$_active" = "1" ]; then
      printf ' |> %s' "$1"
    elif [ "$_rec" = "1" ]; then
      printf ' | *%s' "$1"
    else
      printf ' |  %s' "$1"
    fi
  else
    if [ "$_active" = "1" ] && [ "$_rec" = "1" ]; then
      printf ' |%s►%s%s★%s%s' "$C_CYAN" "$C_RST" "$C_YELLOW" "$C_RST" "$1"
    elif [ "$_active" = "1" ]; then
      printf ' |%s►%s %s' "$C_CYAN" "$C_RST" "$1"
    elif [ "$_rec" = "1" ]; then
      printf ' | %s★%s%s' "$C_YELLOW" "$C_RST" "$1"
    else
      printf ' |  %s' "$1"
    fi
  fi
}

# End row with verdict column + newline.
# Args: $1 - pre-formatted verdict text
# Skips output in JSON or quiet mode.
cmp_row_end() {
  [ "$OUTPUT_JSON" = 1 ] && return 0
  is_quiet && return 0
  printf ' | %s\n' "$1"
}

# ─── Exit Code & Section Helpers ──────────────────────────────────────────────

# Update global _EXIT_CODE based on ok/total counts.
# 0 ok out of N → critical (2); partial ok → degraded (1); all ok → no change.
# Args: $1 - ok count, $2 - total count
update_exit_code() {
  local _ok="$1" _total="$2"
  if [ "$_ok" -eq 0 ] && [ "$_total" -gt 0 ]; then
    _EXIT_CODE=2
  elif [ "$_ok" -lt "$_total" ]; then
    [ "$_EXIT_CODE" -lt 1 ] && _EXIT_CODE=1
  fi
}

# Output section data: apply privacy filter if active, or plain cat.
# Reads from stdin. Used by cmd_all per-section and _priv_run wrapper.
_out_section() {
  if [ "$PRIVACY_MODE" = 1 ]; then
    privacy_filter
  else
    cat
  fi
}

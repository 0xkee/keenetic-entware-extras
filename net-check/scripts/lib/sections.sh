# net-check: Section UI — spinner, banners, verbosity, exit code management.
# Dependencies: colors.sh (C_*, status_mark), http-core.sh (to_ms)
# Globals used: OUTPUT_JSON, VERBOSITY, _IN_BATCH, _spinner_pid,
#   _EXIT_CODE, PRIVACY_MODE, _RUN_DIR, _LAST_SECTION_TITLE
# shellcheck disable=SC2034
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

# ─── Summary & Verbosity ─────────────────────────────────────────────────────

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

# ─── Section Banners ──────────────────────────────────────────────────────────

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

# ─── Exit Code & Section Output ───────────────────────────────────────────────

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

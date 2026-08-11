#!/opt/bin/sh
# net-check — Network connectivity diagnostics and degradation control.
# End-to-end reachability verification across WAN interfaces,
# MITM/DPI anomaly detection, CDN geo-steering analysis,
# DNS leak testing, path quality comparison.
# shellcheck disable=SC1090,SC1091
# shellcheck disable=SC2034
# shellcheck disable=SC3043
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── Configuration ───────────────────────────────────────────────────────────
# Must be loaded before lib/*.sh — some libs reference config vars at source time.
_CONFIG_DIR="${SCRIPT_DIR%/*}/config"
. "$_CONFIG_DIR/defaults.conf"
[ -f "$_CONFIG_DIR/config.conf" ] && . "$_CONFIG_DIR/config.conf"

# ─── Shared project libraries ────────────────────────────────────────────────
. "$SCRIPT_DIR/../../lib/common.sh"
. "$SCRIPT_DIR/../../lib/status.sh"
. "$SCRIPT_DIR/../../lib/ip.sh"

# ─── Local libraries (load order matters) ────────────────────────────────────
. "$SCRIPT_DIR/lib/colors.sh"        # colors, marks, emoji
. "$SCRIPT_DIR/lib/table.sh"         # tbl_*, cmp_* table framework
. "$SCRIPT_DIR/lib/sections.sh"      # spinner, banners, verbosity, exit code
. "$SCRIPT_DIR/lib/output.sh"        # errors, usage, config reader
. "$SCRIPT_DIR/lib/batch.sh"         # adaptive batch sizing, parallel runner
. "$SCRIPT_DIR/lib/wan.sh"           # WAN discovery, iface_type
. "$SCRIPT_DIR/lib/geo-cache.sh"     # geo cache operations + lookups
. "$SCRIPT_DIR/lib/geoip.sh"         # IP geolocation API
. "$SCRIPT_DIR/lib/zone.sh"          # geo-zone context, routing, zone header
. "$SCRIPT_DIR/lib/http-core.sh"     # curl, content check, metrics, utilities
. "$SCRIPT_DIR/lib/verdict.sh"       # failure classification, reason labels, verdict
. "$SCRIPT_DIR/lib/privacy.sh"       # privacy filter

# ─── Command modules (order irrelevant) ──────────────────────────────────────
for _f in "$SCRIPT_DIR"/lib/cmd-*.sh; do
  . "$_f"
done
unset _f

# ─── Re-exec with nice if configured ─────────────────────────────────────────
if [ "${NICE_ADJUST:-0}" != "0" ] && [ "${_NICED:-}" != 1 ]; then
  export _NICED=1
  exec nice -n "$NICE_ADJUST" "$0" "$@"
fi

# ─── Global State ────────────────────────────────────────────────────────────
OUTPUT_JSON=0
USE_COLOR=auto
PRIVACY_MODE=0
_IN_BATCH=0

# Global state: geo ext_ip cache (populated by cmd_geo, reused by cmd_cdn).
# Format: "iface:ext_ip\n..." (newline-separated)
_GEO_EXT_IPS=""

# Color support — initialized by setup_colors().
C_RST="" C_BOLD="" C_DIM="" C_GREEN="" C_RED="" C_YELLOW="" C_CYAN=""

# Spinner PID — managed by start_spinner/stop_spinner in lib/sections.sh.
_spinner_pid=""

# Exit code tracking for machine-readable exit codes.
# 0 = all ok, 1 = degraded (some failed), 2 = critical failure
_EXIT_CODE=0

# ─── Command Dispatch ─────────────────────────────────────────────────────────

# Dispatch command by name.
# Args: $1 - command name, $2+ - command arguments
_dispatch() {
  local _cmd="$1"
  shift
  case "$_cmd" in
    geo)     cmd_geo ;;
    conn)    cmd_connectivity ;;
    ipv6)    cmd_ipv6_leak ;;
    dns)     cmd_dns ;;
    dns-leak) cmd_dns_leak ;;
    comp)    cmd_compare ;;
    cdn)     cmd_cdn_all ;;
    tls)     cmd_tls_check_targets ;;
    speed)   cmd_speed "$@" ;;
    check)   cmd_check "$@" ;;
    *)       emit_error "unknown command: $_cmd"; usage >&2; return 2 ;;
  esac
}

# Dispatch a single command with optional privacy wrapping.
# For PRIVACY_MODE=1: stdout → temp file → privacy_filter → real stdout.
# Args: $1 - command name, $2+ - command arguments
# shellcheck disable=SC3043
_priv_run() {
  if [ "$PRIVACY_MODE" = 1 ]; then
    local _ptmp="${_RUN_DIR}/priv-cmd.tmp"
    _dispatch "$@" > "$_ptmp"
    privacy_filter < "$_ptmp"
    rm -f "$_ptmp"
  else
    _dispatch "$@"
  fi
}

# ─── Main Dispatcher ─────────────────────────────────────────────────────────

main() {
  # Parse global options
  while [ $# -gt 0 ]; do
    case "$1" in
      --json)
        OUTPUT_JSON=1
        shift
        ;;
      --privacy)
        PRIVACY_MODE=1
        shift
        ;;
      --iface)
        [ $# -lt 2 ] && { emit_error "--iface requires an interface name" || true; exit 2; }
        CHECK_INTERFACES="$2"
        shift 2
        ;;
      --no-color)
        USE_COLOR="never"
        shift
        ;;
      --verbose)
        VERBOSITY=2
        shift
        ;;
      --quiet)
        VERBOSITY=0
        shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        emit_error "Unknown option: $1" || true
        usage >&2
        exit 2
        ;;
      *)
        break
        ;;
    esac
  done

  # Initialize colors after parsing flags (--no-color must be processed first)
  setup_colors

  # Resolve "auto" batch sizes based on CPU load
  _resolve_batch_sizes

  # Ensure data directory exists
  ensure_data_dir

  # Per-instance temp directory for parallel-safe execution.
  # Temp files go here; persistent caches stay in DATA_DIR.
  _RUN_DIR="${DATA_DIR}/run-$$"
  mkdir -p "$_RUN_DIR"

  if [ $# -eq 0 ]; then
    usage >&2
    exit 2
  fi

  local cmd="$1"
  shift

  # Privacy: cmd_all handles per-section filtering internally via _out_section.
  # Other commands: wrap with spinner + buffered output (same UX as cmd_all steps).
  case "$cmd" in
    all)
      cmd_all
      ;;
    *)
      # Zone context header (idempotent via _ZONE_HEADER_PRINTED guard)
      print_zone_header_once
      local _t_start _elapsed
      _t_start=$(date +%s)
      _priv_run "$cmd" "$@" || true
      _elapsed=$(( $(date +%s) - _t_start ))
      local _s_ok=1
      [ "$_EXIT_CODE" -gt 0 ] && _s_ok=0
      print_summary_footer "$_elapsed" "$_s_ok" 1
      ;;
  esac

  exit "${_EXIT_CODE:-0}"
}

main "$@"

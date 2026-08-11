# net-check: Batch execution — adaptive batch sizing, parallel batch runner.
# Dependencies: none (self-contained leaf module)
# Globals used: PARALLEL_BATCH_SIZE, CDN_BATCH_SIZE, OUTPUT_JSON
# shellcheck disable=SC3043

# ─── Adaptive Batch Size ──────────────────────────────────────────────────────

# Compute adaptive batch size based on CPU load and available memory.
# Called once at startup when PARALLEL_BATCH_SIZE or CDN_BATCH_SIZE is "auto".
# Uses /proc/loadavg + /proc/cpuinfo for CPU pressure, /proc/meminfo for RAM.
# NOTE: Router load averages are inflated by kernel SoftIRQ (NAT, routing,
# iptables) — a 2-core router with load 10+ is normal. Thresholds are set
# high to avoid over-throttling; net-check is I/O-bound (curl), not CPU-bound.
# Memory boost: when free memory > 10%, batch gets +1 (I/O-bound tasks benefit
# from extra parallelism if RAM permits). When memory < 10%, no boost applied.
# Args: $1 - default base batch size (used as max when idle)
# stdout: computed batch size (integer >= 1)
_auto_batch_size() {
  local _base="$1" _ncpu _load _pressure _batch _mem_ok

  # --- CPU pressure → baseline batch ---
  _ncpu=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null) || _ncpu=2
  _load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null) || _load="0"
  # Pressure ratio: load / ncpu. Router-aware thresholds (high load is normal).
  _pressure=$(awk "BEGIN {
    r = ${_load} / ${_ncpu}
    if (r < 4.0) print 0
    else if (r < 10.0) print 1
    else print 2
  }")
  case "$_pressure" in
    0) _batch="$_base" ;;                                           # normal: full batch
    1) _batch="$(( _base > 2 ? _base - 1 : _base ))" ;;           # elevated: slightly reduced
    *) _batch="$(( _base > 2 ? _base / 2 : 1 ))" ;;              # extreme: half batch
  esac

  # --- Memory boost: +1 if free memory > 10% ---
  # MemAvailable is the best metric (includes reclaimable caches).
  # Fallback to MemFree if MemAvailable is absent (older kernels).
  _mem_ok=$(awk '
    /^MemTotal:/     { total = $2 }
    /^MemAvailable:/ { avail = $2 }
    /^MemFree:/      { free  = $2 }
    END {
      a = (avail > 0) ? avail : free
      if (total > 0 && (a / total) > 0.10) print 1; else print 0
    }
  ' /proc/meminfo 2>/dev/null) || _mem_ok=0

  if [ "$_mem_ok" = 1 ]; then
    _batch=$((_batch + 1))
  fi

  printf '%s' "$_batch"
}

# Resolve "auto" batch sizes to concrete numbers.
# Called once from main() after config loading.
_resolve_batch_sizes() {
  if [ "$PARALLEL_BATCH_SIZE" = "auto" ]; then
    PARALLEL_BATCH_SIZE=$(_auto_batch_size 3)
  fi
  if [ "$CDN_BATCH_SIZE" = "auto" ]; then
    CDN_BATCH_SIZE=$(_auto_batch_size 2)
  fi
}

# ─── Batch Runner ─────────────────────────────────────────────────────────────

# Run items in parallel batches, showing progress with section label.
# Wraps callback in ( trap ... ; callback ; wait ) subshell.
# Args: $1 - progress label (e.g. "DNS", "HTTP", "CDN", "TLS")
#        $2 - batch size (e.g. $PARALLEL_BATCH_SIZE)
#        $3 - space-separated item list
#        $4 - callback function name (receives one arg: space-separated batch items)
# The callback function MUST background its work items with & (no wait inside).
# batch_run_parallel handles the subshell trap + wait.
# Globals: OUTPUT_JSON (for progress suppression)
batch_run_parallel() {
  local _brl="$1" _brs="$2" _brit="$3" _brcb="$4"
  local _brt=0 _brn=0 _brb="" _brd=0 _bri
  for _bri in $_brit; do _brt=$((_brt + 1)); done
  [ "$_brt" = 0 ] && return 0
  for _bri in $_brit; do
    _brb="${_brb} ${_bri}"
    _brn=$((_brn + 1))
    if [ "$_brn" -ge "$_brs" ]; then
      ( trap 'kill 0 2>/dev/null; exit 130' INT TERM
        $_brcb "$_brb"
        wait )
      _brd=$((_brd + _brn))
      if [ "$OUTPUT_JSON" = 0 ] && [ -t 2 ]; then
        printf '\r  %s: %d/%d...' "$_brl" "$_brd" "$_brt" >&2
      fi
      _brn=0; _brb=""
    fi
  done
  if [ -n "$_brb" ]; then
    ( trap 'kill 0 2>/dev/null; exit 130' INT TERM
      $_brcb "$_brb"
      wait )
    _brd=$((_brd + _brn))
    if [ "$OUTPUT_JSON" = 0 ] && [ -t 2 ]; then
      printf '\r  %s: %d/%d...' "$_brl" "$_brd" "$_brt" >&2
    fi
  fi
  if [ "$OUTPUT_JSON" = 0 ] && [ -t 2 ]; then
    printf '\r\033[2K' >&2
  fi
}

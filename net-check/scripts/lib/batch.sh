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
# Memory cap: mem_cap = floor(MemAvailable_MB / 15), min 1.
# Each batch slot spawns curl+TLS per interface (~15MB combined).
# If CPU-batch > mem_cap → capped (prevents OOM on low-RAM devices).
# If mem_cap > CPU-batch → boost +1 (I/O-bound tasks benefit from parallelism).
# Args: $1 - default base batch size (used as max when idle)
# stdout: computed batch size (integer >= 1)
_auto_batch_size() {
  local _base="$1" _ncpu _load _pressure _batch _mem_avail_mb _mem_cap

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

  # --- Memory cap & boost (single formula, no hard thresholds) ---
  # ~15MB per batch slot (curl + TLS per interface, conservative estimate).
  # mem_cap = how many slots available RAM can sustain (minimum 1).
  # Cap prevents OOM on low-RAM (e.g. KN-2310 124MB); boost helps on high-RAM.
  _mem_avail_mb=$(awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null) || _mem_avail_mb=0
  [ -z "$_mem_avail_mb" ] && _mem_avail_mb=0
  _mem_cap=$(( _mem_avail_mb / 15 ))
  [ "$_mem_cap" -lt 1 ] && _mem_cap=1

  if [ "$_batch" -gt "$_mem_cap" ]; then
    _batch="$_mem_cap"                                                # cap: not enough RAM
  elif [ "$_mem_cap" -gt "$_batch" ]; then
    _batch=$((_batch + 1))                                            # boost: RAM headroom
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

# net-check: Infrastructure output — error/warning emitters, usage text,
#   config reader, data directory.
# Dependencies: colors.sh (C_*, status_mark), lib/common.sh (json_kv, json_kv_bool)
# Globals used: OUTPUT_JSON, C_RST, C_RED, C_YELLOW,
#   _CONFIG_DIR, _ZONE_CC_LIST, DATA_DIR
# shellcheck disable=SC2153
# shellcheck disable=SC3043

# ─── Data Directory ───────────────────────────────────────────────────────────

# Ensure persistent data directory exists (lazy safety net for dev deploys).
# Production install creates it via postinst.
ensure_data_dir() {
  [ -d "$DATA_DIR" ] || mkdir -p "$DATA_DIR"
}

# Output zone-filtered content of a config file + optional custom overlay.
# For pipe-delimited configs (check-targets, cdn-domains): filters zone-XX
# entries by active _ZONE_CC_LIST. Non-zone lines (global, intl-*) always included.
# Appends user custom file if present (${name}-custom.conf).
# Args: $1 - config name (e.g. "check-targets", "cdn-domains")
# stdout: combined content (comments and blank lines stripped)
_cat_config() {
  local _file="$_CONFIG_DIR/${1}.conf"
  [ -f "$_file" ] || return 0

  if [ -n "${_ZONE_CC_LIST:-}" ]; then
    # Build zone pattern: zone-ru|zone-by|zone-kz...
    local _zpat="" _cc
    for _cc in $_ZONE_CC_LIST; do
      _zpat="${_zpat:+${_zpat}|}zone-${_cc}"
    done
    # Non-zone lines (global, intl-*)
    grep -v '^#' "$_file" | grep -v '^$' | grep -v '|zone-'
    # Matching zone-CC lines
    grep -E "\|(${_zpat})\|" "$_file" 2>/dev/null || true
  else
    # No zone — skip all zone-XX entries, keep global + intl
    grep -v '^#' "$_file" | grep -v '^$' | grep -v '|zone-'
  fi

  # Append user custom file (optional, conffile)
  if [ -f "$_CONFIG_DIR/${1}-custom.conf" ]; then
    grep -v '^#' "$_CONFIG_DIR/${1}-custom.conf" | grep -v '^$' || true
  fi
}

# ─── Error / Warning Emitters ─────────────────────────────────────────────────

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

# ─── Usage ────────────────────────────────────────────────────────────────────

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
  cdn              CDN edge geo-steering analysis (L3+7)
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
  defaults.conf, config.conf,
  check-targets.conf, cdn-domains.conf, dns-providers.conf,
  anomaly-markers.conf, mitm-issuers.conf, known-cas.conf,
  privacy-providers.conf, wellknown-ips.conf
EOF
}


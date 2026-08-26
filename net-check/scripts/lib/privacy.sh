# net-check: Privacy filter — post-processing anonymization of sensitive data.
# Replaces external IPs, ASN, country, city, org with fake values.
# Dependencies: lib/privacy.sh (priv_mask_ip_asn, priv_mask_ipv6),
#   lib/common.sh (is_cache_fresh), lib/output.sh (emit_warn)
# Globals used: PRIVACY_MODE, DATA_DIR, _CONFIG_DIR, WELLKNOWN_IPS_FILE, SCRIPT_DIR
# shellcheck disable=SC3043

# Source shared privacy library (basic IP/ASN/IPv6 masking).
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../../lib/privacy.sh"

# ─── Privacy Data ─────────────────────────────────────────────────────────────

# Planet/moon names for city replacement (14 entries, indexed by position).
_PRIV_PLANETS="Mercury Venus Mars Jupiter Saturn Uranus Neptune Pluto Ceres Titan Europa Io Ganymede Callisto"

# Load well-known DNS IPs from config file (one IP per line, # comments).
_PRIV_WELLKNOWN_IPS=""
if [ -f "$WELLKNOWN_IPS_FILE" ]; then
  _PRIV_WELLKNOWN_IPS=$(grep -v '^#' "$WELLKNOWN_IPS_FILE" | grep -v '^$' | tr '\n' ' ')
fi

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Pick planet name by 1-based index (wraps around).
# Args: $1 - index (1-based)
# stdout: planet name
_priv_planet() {
  local idx="$1" total=14
  local n=$(( ((idx - 1) % total) + 1 ))
  printf '%s' "$_PRIV_PLANETS" | awk -v n="$n" '{print $n}'
}

# Pick provider name from privacy-providers.conf by 1-based index (wraps).
# Args: $1 - index (1-based)
# stdout: provider name
_priv_provider() {
  local idx="$1"
  local prov_file="${_CONFIG_DIR}/privacy-providers.conf"
  if [ -f "$prov_file" ]; then
    local total
    total=$(grep -c '^[^#]' "$prov_file" 2>/dev/null) || total=0
    if [ "$total" -gt 0 ]; then
      local n=$(( ((idx - 1) % total) + 1 ))
      grep '^[^#]' "$prov_file" | sed -n "${n}p"
      return 0
    fi
  fi
  printf 'Redacted ISP #%d' "$idx"
}

# Pick random 2-letter country code from zones.sh by index (wraps).
# Skips comment and empty lines.
# Args: $1 - index (1-based)
# stdout: uppercase 2-letter CC (e.g. "JP")
_priv_country() {
  local idx="$1"
  local zones_file="${SCRIPT_DIR}/../../lib/zones.sh"
  if [ -f "$zones_file" ]; then
    local total
    total=$(grep -v '^#' "$zones_file" | grep -vc '^$') || total=0
    if [ "$total" -gt 0 ]; then
      local n=$(( ((idx - 1) % total) + 1 ))
      grep -v '^#' "$zones_file" | grep -v '^$' | sed -n "${n}p" | awk '{print toupper($1)}'
      return 0
    fi
  fi
  printf 'XX'
}

# Escape string for safe use as sed pattern (LHS).
# Args: $1 - raw string
# stdout: sed-escaped string
_sed_escape_pattern() {
  printf '%s' "$1" | sed 's/[][\\/.*^$&]/\\&/g'
}

# Escape string for safe use as sed replacement (RHS).
# Args: $1 - raw string
# stdout: sed-escaped string
_sed_escape_replace() {
  printf '%s' "$1" | sed 's/[&\\/]/\\&/g'
}

# Generate width-preserving sed replacement for table columns.
# If replacement is shorter → pad replacement with spaces.
# If replacement is longer → extend pattern with trailing spaces
# (consumes %-Ns column padding that always exists in table output).
# Args: $1 - original string, $2 - replacement string
# Writes: sed 's/pattern/replacement/g' line to stdout
_priv_sed_eq() {
  local _orig="$1" _repl="$2"
  # Equalize: pad whichever is shorter
  while [ ${#_repl} -lt ${#_orig} ]; do _repl="${_repl} "; done
  while [ ${#_orig} -lt ${#_repl} ]; do _orig="${_orig} "; done
  printf 's/%s/%s/g\n' \
    "$(_sed_escape_pattern "$_orig")" \
    "$(_sed_escape_replace "$_repl")"
}

# Generate sed rules to replace a 2-letter country code in all output contexts.
# Args: $1 - original CC, $2 - replacement CC
# stdout: sed rules (one per line)
_priv_cc_rules() {
  local _gcc="$1" _fake_cc="$2"
  local _esc
  _esc=$(printf '\033')
  # JSON: "country":"NL" / "cc":"NL" / "edge_cc":"NL"
  printf 's/"country":"%s"/"country":"%s"/g\n' "$_gcc" "$_fake_cc"
  printf 's/"cc":"%s"/"cc":"%s"/g\n' "$_gcc" "$_fake_cc"
  printf 's/"edge_cc":"%s"/"edge_cc":"%s"/g\n' "$_gcc" "$_fake_cc"
  # Table cell: " CC " (space-bounded, CC:4 columns in tbl_row)
  printf 's/ %s / %s /g\n' "$_gcc" "$_fake_cc"
  # ANSI-colored CC in tbl_cell: \033[32mCC  \033[0m → match mCC(spaces)\033
  # CC is between ANSI color-start ("m") and reset (ESC). Padding spaces preserved.
  printf 's/m%s\\( *\\)%s/m%s\\1%s/g\n' "$_gcc" "$_esc" "$_fake_cc" "$_esc"
  # --no-color mode: ★CC or *CC (star directly before CC in comparison cells)
  printf 's/★%s /★%s /g\n' "$_gcc" "$_fake_cc"
  printf 's/\\*%s /\\*%s /g\n' "$_gcc" "$_fake_cc"
  # Table header: "(CC)" — cmp_header "iface (CC)" and CDN "→ IP (CC)"
  printf 's/(%s)/(%s)/g\n' "$_gcc" "$_fake_cc"
  # Multi-CC in parens: "(CC1 CC2)" / "( CC2)"
  printf 's/(%s /(%s /g\n' "$_gcc" "$_fake_cc"
  printf 's/ %s)/ %s)/g\n' "$_gcc" "$_fake_cc"
  # Comma-separated CC lists: "CC1,CC2" in CDN verdict
  printf 's/%s,/%s,/g\n' "$_gcc" "$_fake_cc"
  printf 's/,%s/,%s/g\n' "$_gcc" "$_fake_cc"
  # End of line: "same_edge CC" or "... CC" at line end (no trailing space)
  printf 's/ %s$/ %s/g\n' "$_gcc" "$_fake_cc"
}

# ─── Main Filter ──────────────────────────────────────────────────────────────

# Build targeted sed script for City/Org/CC replacements from geo cache.
# Must be called AFTER stdin is fully consumed (geo cache ready).
# Args: $1 - sed script output path
_priv_build_sed_script() {
  local _sed_script="$1"
  : > "$_sed_script"

  local _n=0
  local _replaced_ccs=""

  # Per-interface geo cache (geo-eth3.json, geo-nwg0.json, ...)
  for _gf in "${DATA_DIR}"/geo-*.json; do
    [ -f "$_gf" ] || continue
    _n=$((_n + 1))

    local _gcity="" _gorg="" _gcc=""
    _gcity=$(sed -n 's/.*"city"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_gf")
    _gorg=$(sed 's/\\"/§/g' < "$_gf" | sed -n 's/.*"org"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed 's/§/"/g')
    _gcc=$(sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_gf")

    # City → planet name (width-preserving)
    if [ -n "$_gcity" ] && [ "$_gcity" != "—" ] && [ "$_gcity" != "-" ]; then
      _priv_sed_eq "$_gcity" "$(_priv_planet "$_n")" >> "$_sed_script"
    fi

    # Org → provider name (width-preserving)
    if [ -n "$_gorg" ] && [ "$_gorg" != "—" ] && [ "$_gorg" != "-" ]; then
      _priv_sed_eq "$_gorg" "$(_priv_provider "$_n")" >> "$_sed_script"
    fi

    # Country code → random CC (JSON + text table + headers + CDN)
    if [ -n "$_gcc" ] && [ ${#_gcc} -eq 2 ]; then
      local _fake_cc
      _fake_cc=$(_priv_country "$_n")
      _priv_cc_rules "$_gcc" "$_fake_cc" >> "$_sed_script"
      _replaced_ccs="${_replaced_ccs} ${_gcc}"
    fi
  done

  # Per-IP geo cache (ipgeo-1.2.3.4.json) — CC/Org/City from DNS/CDN resolved IPs.
  # Track already-replaced Org names to avoid duplicate sed rules.
  local _replaced_orgs=""
  for _cf in "${DATA_DIR}"/ipgeo-*.json; do
    [ -f "$_cf" ] || continue
    _n=$((_n + 1))

    # CC replacement (skip if already covered by step 1a)
    local _gip_cc
    _gip_cc=$(sed -n 's/.*"cc":"\([^"]*\)".*/\1/p' "$_cf" 2>/dev/null) || _gip_cc=""
    if [ -n "$_gip_cc" ] && [ ${#_gip_cc} -eq 2 ]; then
      case "$_replaced_ccs" in *" $_gip_cc"*) ;; *)
        local _fake_cc
        _fake_cc=$(_priv_country "$_n")
        _priv_cc_rules "$_gip_cc" "$_fake_cc" >> "$_sed_script"
        _replaced_ccs="${_replaced_ccs} ${_gip_cc}"
      ;; esac
    fi

    # Org replacement (width-preserving, skip duplicates)
    local _gip_org
    _gip_org=$(sed 's/\\"/§/g' < "$_cf" | sed -n 's/.*"org"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | sed 's/§/"/g') || _gip_org=""
    if [ -n "$_gip_org" ] && [ "$_gip_org" != "—" ] && [ "$_gip_org" != "-" ]; then
      case "$_replaced_orgs" in *"|$_gip_org|"*) ;; *)
        _priv_sed_eq "$_gip_org" "$(_priv_provider "$_n")" >> "$_sed_script"
        _replaced_orgs="${_replaced_orgs}|${_gip_org}|"
      ;; esac
    fi

    # City replacement (width-preserving, skip duplicates — reuse _replaced_orgs trick)
    local _gip_city
    _gip_city=$(sed -n 's/.*"city"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$_cf" 2>/dev/null) || _gip_city=""
    if [ -n "$_gip_city" ] && [ "$_gip_city" != "—" ] && [ "$_gip_city" != "-" ]; then
      case "$_replaced_orgs" in *"|$_gip_city|"*) ;; *)
        _priv_sed_eq "$_gip_city" "$(_priv_planet "$_n")" >> "$_sed_script"
        _replaced_orgs="${_replaced_orgs}|${_gip_city}|"
      ;; esac
    fi
  done
}

# Post-processing privacy filter.
# Reads full command output from stdin, applies anonymization, writes to stdout.
# Buffers stdin first so the producing command (e.g. cmd_geo) finishes and
# writes geo cache before we read it for City/Org/CC targeted replacements.
privacy_filter() {
  # Buffer stdin — ensures producing command finishes (geo cache ready).
  local _buf="${_RUN_DIR}/priv-buf.tmp"
  cat > "$_buf"

  # Build targeted sed script from geo cache (now guaranteed to exist).
  local _sed_script="${_RUN_DIR}/priv-sed.tmp"
  _priv_build_sed_script "$_sed_script"

  # Pipeline: IPv4+ASN masking (padded) → IPv6 masking (padded) → targeted sed
  priv_mask_ip_asn "$_PRIV_WELLKNOWN_IPS" "pad" < "$_buf" | priv_mask_ipv6 "pad" | sed -f "$_sed_script"

  rm -f "$_buf" "$_sed_script" 2>/dev/null
}

#!/opt/bin/sh
# DNS zone check diagnostic tool for smartdns-geo-conf.
# Determines which DNS zone/group a domain belongs to and which upstream resolves it.
# Usage: dns-check.sh [--json] <domain>
# shellcheck disable=SC1091
# shellcheck disable=SC3043
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
. "$SCRIPT_DIR/../../lib/ip.sh"
. "$SCRIPT_DIR/../../lib/geo.sh"

_CONFIG_DIR="${SCRIPT_DIR%/*}/config"
# shellcheck source=/dev/null
. "$_CONFIG_DIR/defaults.conf"
[ -f "$_CONFIG_DIR/config.conf" ] && . "$_CONFIG_DIR/config.conf"

# --- Constants ---
DNS_HOST="127.0.0.1"
DNS_PORT="${SMARTDNS_PORT:-6053}"
DNS_TIMEOUT="3"

# --- Helpers ---

# Print JSON error and exit.
# Args: $1 - error code, $2 - query, $3 - human message
emit_error_json() {
  printf '{%s,%s,%s,%s}\n' \
    "$(json_kv_bool "ok" 1)" \
    "$(json_kv "error" "$1")" \
    "$(json_kv "query" "$2")" \
    "$(json_kv "message" "$3")"
  exit 0
}

# Print text error and exit.
# Args: $1 - error code, $2 - query, $3 - human message
emit_error_text() {
  printf 'ERROR [%s]: %s\n' "$1" "$3" >&2
  exit 1
}

# Emit error in current mode and exit.
# Args: $1 - error code, $2 - query, $3 - human message
emit_error() {
  if [ "$JSON_MODE" = "1" ]; then
    emit_error_json "$1" "$2" "$3"
  else
    emit_error_text "$1" "$2" "$3"
  fi
}

# Build a JSON array string from a space-separated list.
# Args: $1 - space-separated list
# Echoes: '["a","b"]'
json_arr_space() {
  local list="$1" out="" item
  for item in $list; do
    out="${out:+${out},}\"$(json_escape_val "$item")\""
  done
  printf '[%s]' "$out"
}

# Build a JSON array string from a comma-separated list (e.g. UP_SERVERS).
# Args: $1 - comma-separated list ("ip:port, ip:port")
# Echoes: '["ip:port","ip:port"]'
json_arr_csv() {
  local list="$1" out="" old_ifs item
  old_ifs="$IFS"
  IFS=","
  for item in $list; do
    item=$(printf '%s' "$item" | sed 's/^ *//')
    if [ -n "$item" ]; then
      out="${out:+${out},}\"$(json_escape_val "$item")\""
    fi
  done
  IFS="$old_ifs"
  printf '[%s]' "$out"
}

# Match domain against zone-routing-rules.conf.
# Sets: MATCH_CC, MATCH_RULE, MATCH_TYPE
# Returns: 0 if matched, 1 if fallback to default
match_domain_zone() {
  local domain="$1"
  local rules_file="$ZONE_ROUTING_RULES"

  MATCH_CC=""
  MATCH_RULE=""
  MATCH_TYPE=""

  if [ ! -f "$rules_file" ]; then
    return 1
  fi

  # 1) Check explicit domain rules (<cc>+ lines) — exact match
  local cc domains
  while IFS= read -r line; do
    # Skip comments and empty lines
    case "$line" in
      "#"*|"") continue ;;
    esac
    # Only process <cc>+ lines (explicit domains)
    cc="${line%%+*}"
    case "$line" in
      *"+"*)
        # Strip the "cc+" prefix to get domain list
        domains="${line#*+ }"
        # Trim leading/trailing spaces from cc
        cc=$(printf '%s' "$cc" | tr -d ' ')
        for d in $domains; do
          if [ "$domain" = "$d" ]; then
            MATCH_CC="$cc"
            MATCH_RULE="$d"
            MATCH_TYPE="domain"
            return 0
          fi
        done
        ;;
    esac
  done < "$rules_file"

  # 2) Check TLD rules (<cc> <tld1> [<tld2> ...]) — suffix match
  while IFS= read -r line; do
    # Skip comments and empty lines
    case "$line" in
      "#"*|"") continue ;;
    esac
    # Skip <cc>+ lines (already processed)
    case "$line" in
      *"+"*) continue ;;
    esac
    # Parse: first field is cc, rest are TLDs
    cc=$(printf '%s' "$line" | awk '{print $1}')
    # Get all TLD fields
    local tlds
    tlds=$(printf '%s' "$line" | awk '{$1=""; print}' | sed 's/^ *//')
    for tld in $tlds; do
      # Match domain ending with this TLD
      case "$domain" in
        *"$tld")
          # TLDs in config have leading dots (e.g. ".ru"), so "ozon.ru" matches *".ru"
          MATCH_CC="$cc"
          MATCH_RULE="/$tld/"
          MATCH_TYPE="ccTLD"
          return 0
          ;;
      esac
    done
  done < "$rules_file"

  return 1
}

# Check if country code is in the active DNS zone.
# Args: $1 - country code
# Returns: 0 if in zone, 1 otherwise
is_in_active_zone() {
  local cc="$1"
  local zone_countries
  zone_countries=$(resolve_geo_zone "$DNS_ZONE")
  case " $zone_countries " in
    *" $cc "*) return 0 ;;
  esac
  return 1
}

# Get upstream provider labels and servers for a group.
# Args: $1 - "zone" or "other"
# Sets: UP_PROVIDERS (labels), UP_SERVERS (ip:port pairs), UP_INTERFACE
get_upstream_info() {
  local group="$1"
  local provider_list iface

  UP_PROVIDERS=""
  UP_SERVERS=""
  UP_HOSTNAMES=""
  UP_INTERFACE="direct"

  if [ "$group" = "zone" ]; then
    provider_list="$ZONE_DNS_PROVIDER"
    iface="${ZONE_DNS_INTERFACE:-}"
  else
    provider_list="$OTHER_DNS_PROVIDER"
    iface="${OTHER_DNS_INTERFACES:-}"
  fi

  if [ -n "$iface" ]; then
    UP_INTERFACE="$iface"
  fi

  # Source dns-providers.conf for variable access
  # (already sourced via defaults.conf DNS_PROVIDERS_CONF path, but we need the vars)
  if [ -f "$DNS_PROVIDERS_CONF" ]; then
    # shellcheck source=/dev/null
    . "$DNS_PROVIDERS_CONF"
  fi

  local prefix label_var label ip1_var ip1 ip2_var ip2 proto_var proto port
  for prov in $provider_list; do
    # Skip "system" — dynamic, no fixed IPs
    if [ "$prov" = "system" ]; then
      UP_PROVIDERS="${UP_PROVIDERS:+${UP_PROVIDERS}, }System"
      continue
    fi

    if [ "$group" = "zone" ]; then
      prefix="ZONE_${prov}"
    else
      prefix="OTHER_${prov}"
    fi

    label_var="${prefix}_LABEL"
    ip1_var="${prefix}_IP1"
    ip2_var="${prefix}_IP2"
    proto_var="${prefix}_PROTO"

    eval "label=\"\${${label_var}:-$prov}\""
    eval "ip1=\"\${${ip1_var}:-}\""
    eval "ip2=\"\${${ip2_var}:-}\""
    eval "proto=\"\${${proto_var}:-udp}\""

    # Collect TLS hostname (for dot/doh providers)
    local tls_host_var="${prefix}_TLS_HOST"
    local doh_url_var="${prefix}_DOH_URL"
    local tls_host="" doh_url="" hostname=""
    eval "tls_host=\"\${${tls_host_var}:-}\""
    eval "doh_url=\"\${${doh_url_var}:-}\""
    case "$proto" in
      dot) hostname="$tls_host" ;;
      doh) hostname=$(printf '%s' "${doh_url:-$tls_host}" | sed 's|https\{0,1\}://\([^/]*\).*|\1|') ;;
    esac
    UP_HOSTNAMES="${UP_HOSTNAMES:+${UP_HOSTNAMES}, }${hostname}"

    UP_PROVIDERS="${UP_PROVIDERS:+${UP_PROVIDERS}, }${label}"

    # Determine port from protocol
    case "$proto" in
      dot) port="853" ;;
      doh) port="443" ;;
      *) port="53" ;;
    esac

    if [ -n "$ip1" ]; then
      UP_SERVERS="${UP_SERVERS:+${UP_SERVERS}, }${ip1}:${port}"
    fi
    if [ -n "$ip2" ]; then
      UP_SERVERS="${UP_SERVERS:+${UP_SERVERS}, }${ip2}:${port}"
    fi
  done
}

# --- Argument parsing ---
JSON_MODE=0
QUERY=""

while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON_MODE=1; shift ;;
    --help|-h)
      echo "Usage: dns-check.sh [--json] <domain>"
      echo ""
      echo "Determine which DNS zone/group a domain belongs to."
      echo ""
      echo "Options:"
      echo "  --json    Output in JSON format (for webui API)"
      echo "  --help    Show this help"
      echo ""
      echo "Arguments:"
      echo "  domain    Target domain name (not IP)"
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      echo "Usage: dns-check.sh [--json] <domain>" >&2
      exit 1
      ;;
    *)
      if [ -z "$QUERY" ]; then
        QUERY="$1"
      fi
      shift
      ;;
  esac
done

# Validate query
if [ -z "$QUERY" ]; then
  emit_error "invalid_input" "" "No domain provided"
fi

# Check configs exist
if [ ! -f "$ZONE_ROUTING_RULES" ]; then
  emit_error "config_missing" "$QUERY" "Zone routing rules not found: $ZONE_ROUTING_RULES"
fi

if [ ! -f "$DNS_PROVIDERS_CONF" ]; then
  emit_error "config_missing" "$QUERY" "DNS providers config not found: $DNS_PROVIDERS_CONF"
fi

# Reject IPs — only domains accepted
if is_ipv4 "$QUERY"; then
  emit_error "invalid_input" "$QUERY" "Only domain names accepted, not IP addresses"
fi

# Validate domain format
if ! is_domain "$QUERY"; then
  emit_error "invalid_input" "$QUERY" "Not a valid domain name"
fi

# --- Zone matching ---
ZONE_GROUP="default"

if match_domain_zone "$QUERY"; then
  # Check if this CC is in the active DNS zone
  if is_in_active_zone "$MATCH_CC"; then
    ZONE_GROUP="zone"
  else
    ZONE_GROUP="default"
    # Still matched a country, but not in active zone
  fi
else
  MATCH_CC=""
  MATCH_RULE=""
  MATCH_TYPE="none"
  ZONE_GROUP="default"
fi

# Human-readable group name
if [ "$ZONE_GROUP" = "zone" ]; then
  GROUP_NAME="$MATCH_CC"
else
  GROUP_NAME="default"
fi

# --- Upstream identification ---
# Compute upstream info for BOTH groups ("zone" and "other") so the diagram
# can always show all configured DNS paths, not just the one matched by
# the current query (mirrors geo-split route-check's all_paths behavior).
get_upstream_info "zone"
ZG_PROVIDER_LIST="$ZONE_DNS_PROVIDER"
ZG_SERVERS="$UP_SERVERS"
ZG_HOSTNAMES="$UP_HOSTNAMES"
ZG_INTERFACE="$UP_INTERFACE"

get_upstream_info "other"
OG_PROVIDER_LIST="$OTHER_DNS_PROVIDER"
OG_SERVERS="$UP_SERVERS"
OG_HOSTNAMES="$UP_HOSTNAMES"
OG_INTERFACE="$UP_INTERFACE"

# Restore matched group's info (used by legacy "upstream" field + text output)
get_upstream_info "$ZONE_GROUP"

# --- DNS resolution ---
dig_ips=""
dig_ttl=""
dig_time_ms=0

local_t1=$(get_ms)
dig_output=$(dig "@${DNS_HOST}" -p "$DNS_PORT" "$QUERY" +time="$DNS_TIMEOUT" +tries=1 2>/dev/null) || dig_output=""
local_t2=$(get_ms)
dig_time_ms=$((local_t2 - local_t1))

if [ -n "$dig_output" ]; then
  # Extract A record IPs from ANSWER section
  dig_ips=$(printf '%s\n' "$dig_output" | awk '/^[^;]/ && $4=="A" {print $5}' | tr '\n' ' ' | sed 's/ $//')
  # Extract TTL (first A record)
  dig_ttl=$(printf '%s\n' "$dig_output" | awk '/^[^;]/ && $4=="A" {print $2; exit}')
  # Extract query time from stats
  local_query_time=$(printf '%s\n' "$dig_output" | awk '/Query time:/ {print $4}')
  if [ -n "$local_query_time" ]; then
    dig_time_ms="$local_query_time"
  fi
fi

if [ -z "$dig_ips" ]; then
  emit_error "dns_failed" "$QUERY" "No A records from ${DNS_HOST}:${DNS_PORT}"
fi

# --- Output ---
if [ "$JSON_MODE" = "1" ]; then
  # Build IPs JSON array
  ips_json=""
  for ip in $dig_ips; do
    ips_json="${ips_json:+${ips_json},}\"$(json_escape_val "$ip")\""
  done

  # Legacy "upstream" field — matched group's providers/servers (kept for
  # backward compat with any consumer reading data.upstream directly).
  if [ "$ZONE_GROUP" = "zone" ]; then
    prov_list="$ZONE_DNS_PROVIDER"
  else
    prov_list="$OTHER_DNS_PROVIDER"
  fi
  providers_json=$(json_arr_space "$prov_list")
  servers_json=$(json_arr_csv "$UP_SERVERS")

  # "groups" array — BOTH DNS groups always present, regardless of which one
  # matched the current query. Mirrors geo-split route-check's all_paths:
  # the diagram always shows every configured path, highlighting the active one.
  zg_providers_json=$(json_arr_space "$ZG_PROVIDER_LIST")
  zg_servers_json=$(json_arr_csv "$ZG_SERVERS")
  zg_hostnames_json=$(json_arr_csv "$ZG_HOSTNAMES")
  og_providers_json=$(json_arr_space "$OG_PROVIDER_LIST")
  og_servers_json=$(json_arr_csv "$OG_SERVERS")
  og_hostnames_json=$(json_arr_csv "$OG_HOSTNAMES")
  hostnames_json=$(json_arr_csv "$UP_HOSTNAMES")

  # json_kv_bool convention: "0" => true, non-zero => false
  zg_matched=1; og_matched=1
  if [ "$ZONE_GROUP" = "zone" ]; then zg_matched=0; else og_matched=0; fi

  groups_json=$(printf '{%s,%s,"providers":%s,"servers":%s,"hostnames":%s,%s,%s},{%s,%s,"providers":%s,"servers":%s,"hostnames":%s,%s,%s}' \
    "$(json_kv "group" "zone")" \
    "$(json_kv "label" "$DNS_ZONE")" \
    "$zg_providers_json" "$zg_servers_json" "$zg_hostnames_json" \
    "$(json_kv "interface" "$ZG_INTERFACE")" \
    "$(json_kv_bool "matched" "$zg_matched")" \
    "$(json_kv "group" "other")" \
    "$(json_kv "label" "default")" \
    "$og_providers_json" "$og_servers_json" "$og_hostnames_json" \
    "$(json_kv "interface" "$OG_INTERFACE")" \
    "$(json_kv_bool "matched" "$og_matched")")

  # Output JSON
  printf '{%s,%s,"zone":{%s,%s,%s},"upstream":{%s,%s,"hostnames":%s,%s},"groups":[%s],"result":{%s,%s,%s}}\n' \
    "$(json_kv_bool "ok" 0)" \
    "$(json_kv "query" "$QUERY")" \
    "$(json_kv "group" "$GROUP_NAME")" \
    "$(json_kv "match_rule" "$MATCH_RULE")" \
    "$(json_kv "match_type" "$MATCH_TYPE")" \
    "\"providers\":$providers_json" \
    "\"servers\":$servers_json" \
    "$hostnames_json" \
    "$(json_kv "interface" "$UP_INTERFACE")" \
    "$groups_json" \
    "\"ips\":[$ips_json]" \
    "$(json_kv_num "ttl" "${dig_ttl:-0}")" \
    "$(json_kv_num "time_ms" "$dig_time_ms")"
else
  # Human-readable text output
  printf 'DNS Zone Check: %s\n\n' "$QUERY"

  # Zone match info
  if [ -n "$MATCH_CC" ]; then
    printf '  Zone:       %s (match: %s, type: %s)\n' "$GROUP_NAME" "$MATCH_RULE" "$MATCH_TYPE"
  else
    printf '  Zone:       default (no zone match)\n'
  fi

  # Show BOTH groups with active marker
  printf '\n'
  if [ "$ZONE_GROUP" = "zone" ]; then
    printf '  \342\234\223 %s:  %s\n' "$DNS_ZONE" "$ZG_PROVIDER_LIST"
    if [ -n "$ZG_HOSTNAMES" ]; then
      printf '             %s\n' "$ZG_HOSTNAMES"
    fi
    printf '    %s:  %s\n' "default" "$OG_PROVIDER_LIST"
  else
    printf '    %s:  %s\n' "$DNS_ZONE" "$ZG_PROVIDER_LIST"
    printf '  \342\234\223 %s:  %s\n' "default" "$OG_PROVIDER_LIST"
    if [ -n "$OG_HOSTNAMES" ]; then
      printf '             %s\n' "$OG_HOSTNAMES"
    fi
  fi

  # Upstream detail (matched group)
  printf '\n'
  printf '  Upstream:   %s\n' "$UP_PROVIDERS"
  if [ -n "$UP_HOSTNAMES" ]; then
    printf '  Hostnames:  %s\n' "$UP_HOSTNAMES"
  fi
  printf '  Servers:    %s\n' "$UP_SERVERS"
  printf '  Interface:  %s\n' "$UP_INTERFACE"

  # Result with IP count
  ip_count=0
  for _ip in $dig_ips; do ip_count=$((ip_count + 1)); done
  printf '\n'
  if [ "$ip_count" -gt 1 ]; then
    printf '  Result:     %s (%d IPs, TTL %s, %dms)\n' "$dig_ips" "$ip_count" "${dig_ttl:-?}" "$dig_time_ms"
  else
    printf '  Result:     %s (TTL %s, %dms)\n' "$dig_ips" "${dig_ttl:-?}" "$dig_time_ms"
  fi
fi

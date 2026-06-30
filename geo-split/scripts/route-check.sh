#!/opt/bin/sh
# Route check diagnostic tool for geo-split.
# Determines where traffic to a given host/IP will be routed.
# Usage: route-check.sh [--json] <domain-or-ip> [iif]
# shellcheck disable=SC1091
# shellcheck disable=SC3043
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
. "$SCRIPT_DIR/../../lib/ip.sh"
_CONFIG_DIR="$(cd "$SCRIPT_DIR/../config" && pwd)"
. "$_CONFIG_DIR/defaults.conf"
[ -f "$_CONFIG_DIR/config.conf" ] && . "$_CONFIG_DIR/config.conf"

# --- Constants ---
DNS_HOST="127.0.0.1"
DNS_TIMEOUT="3"

# Auto-detect SmartDNS no-speed-check (port 6153); fallback to system resolver.
# Port 6153 hex = 1809. Check /proc/net/tcp (in-memory, no network I/O).
if grep -q ":1809 " /proc/net/tcp 2>/dev/null; then
  DNS_PORT="6153"
else
  DNS_PORT="53"
fi

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

# Resolve table number to human-readable name.
# Args: $1 - table number or "main"
# stdout: table name
table_name_for() {
  case "$1" in
    "$DOMAIN_ROUTE_TABLE") echo "domains" ;;
    "$SUBNET_ROUTE_TABLE") echo "subnets" ;;
    main) echo "main" ;;
    *)
      # Keenetic policy tables are 4096+; label them as "policy"
      if [ "$1" -ge 4096 ] 2>/dev/null; then
        echo "policy"
      else
        echo "main"
      fi
      ;;
  esac
}

# Determine match type from table.
# Args: $1 - table number or "main"
# stdout: match type
match_type_for() {
  case "$1" in
    "$DOMAIN_ROUTE_TABLE") echo "host" ;;
    "$SUBNET_ROUTE_TABLE") echo "subnet" ;;
    *)
      if [ -n "$FWMARK" ] && [ "$1" -ge 4096 ] 2>/dev/null; then
        echo "policy"
      else
        echo "default"
      fi
      ;;
  esac
}

# Get matching prefix from routing table for a given IP.
# Args: $1 - IP, $2 - table number or "main"
# stdout: prefix (e.g. "5.5.5.5/32" or "5.0.0.0/8")
get_match_prefix() {
  local ip="$1" table="$2" prefix=""
  if [ "$table" = "main" ]; then
    prefix=$(ip route show match "$ip" 2>/dev/null | head -1 | awk '{print $1}')
  else
    prefix=$(ip route show table "$table" match "$ip" 2>/dev/null | head -1 | awk '{print $1}')
  fi
  # If nothing found, just report "default"
  if [ -z "$prefix" ] || [ "$prefix" = "default" ]; then
    echo "default"
  else
    echo "$prefix"
  fi
}

# --- Argument parsing ---
JSON_MODE=0
QUERY=""
IIF=""
FROM_MAC=""
FWMARK=""

while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON_MODE=1; shift ;;
    --from)
      shift
      FROM_MAC="${1:-}"
      shift
      ;;
    --help|-h)
      echo "Usage: route-check.sh [--json] [--from <MAC>] <domain-or-ip> [iif]"
      echo ""
      echo "Determine where traffic to a given host/IP will be routed."
      echo ""
      echo "Options:"
      echo "  --json         Output in JSON format (for webui API)"
      echo "  --from <MAC>   Check as client with this MAC address."
      echo "                 Resolves MAC to fwmark via iptables mangle."
      echo "                 Sets iif to br0 if not specified."
      echo "  --help         Show this help"
      echo ""
      echo "Arguments:"
      echo "  domain-or-ip   Target hostname or IPv4 address"
      echo "  iif            Source interface (default: ${ROUTE_IN%% *})"
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      echo "Usage: route-check.sh [--json] [--from <MAC>] <domain-or-ip> [iif]" >&2
      exit 1
      ;;
    *)
      if [ -z "$QUERY" ]; then
        QUERY="$1"
      elif [ -z "$IIF" ]; then
        IIF="$1"
      fi
      shift
      ;;
  esac
done

# Validate query
if [ -z "$QUERY" ]; then
  emit_error "invalid_input" "" "No host or IP provided"
fi

# --- Resolve --from MAC → fwmark + client name ---
# Looks up the client's fwmark from iptables mangle HOTSPOT chain.
# If client has VPN policy: fwmark is set (0xffff...).
# If client has no VPN policy (default/conform): FWMARK stays empty → no fwmark used.
FROM_NAME=""
if [ -n "$FROM_MAC" ]; then
  # Default iif to br0 for LAN clients (can be overridden by explicit iif arg)
  if [ -z "$IIF" ]; then
    IIF="br0"
  fi
  # Resolve MAC → client name via ndmc hotspot (best-effort, non-critical).
  # ndmc format: right-aligned keys with ": value". Client fields before "interface:" line.
  # Once "interface:" is seen → stop looking for name (avoid sub-block "name: Home").
  FROM_NAME=$(ndmc -c "show ip hotspot" 2>/dev/null \
    | awk -v mac="$FROM_MAC" '
      BEGIN { found=0; in_iface=0; name="" }
      /[[:space:]]mac:/ { if (tolower($NF) == tolower(mac)) { found=1; in_iface=0; name="" } else { if (found) exit; found=0 } }
      found && /[[:space:]]interface:[[:space:]]*$/ { in_iface=1 }
      found && !in_iface && /[[:space:]]name:/ { name=substr($0, index($0,"name:") + 5); gsub(/^[[:space:]]+/, "", name) }
      found && !in_iface && name=="" && /[[:space:]]hostname:/ { name=substr($0, index($0,"hostname:") + 9); gsub(/^[[:space:]]+/, "", name) }
      END { if (name != "") print name }
    ')
  # Fallback: use MAC as name if ndmc didn't return a name
  if [ -z "$FROM_NAME" ]; then
    FROM_NAME="$FROM_MAC"
  fi
  # Resolve MAC → fwmark via iptables mangle chain
  FWMARK=$(iptables -t mangle -S _NDM_HOTSPOT_PREROUTING_MANGL 2>/dev/null \
    | grep -i "$FROM_MAC" \
    | grep 'MARK --set-xmark 0xffff' \
    | sed -n 's/.*--set-xmark \(0x[0-9a-f]*\).*/\1/p' \
    | head -1)
  # FWMARK may be empty if client has no VPN mark — that's correct (default policy)
else
  # No --from: use default iif from config
  if [ "$IIF" = "local" ]; then
    IIF=""
  elif [ -z "$IIF" ]; then
    # ROUTE_IN may be space-separated; take the first interface
    IIF="${ROUTE_IN%% *}"
  fi

  # Legacy auto-detect fwmark (CLI without --from): find first VPN tunnel fwmark.
  # This shows the real routing path for VPN-policy clients. Geo-split rules (prio 50-51)
  # are checked BEFORE fwmark rules (prio 100+), so geo-split IPs still show geo-split verdict.
  if [ -n "$IIF" ]; then
    FWMARK=$(ip rule show 2>/dev/null | sed -n 's/.*fwmark \(0x[0-9a-f]*\) lookup \([0-9]*\).*/\1 \2/p' | while read -r m t; do
      _dev=$(ip route show table "$t" 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
      if is_tunnel_iface "$_dev"; then echo "$m"; break; fi
    done)
  fi
fi

# Validate input format
if ! is_ipv4 "$QUERY" && ! is_domain "$QUERY"; then
  emit_error "invalid_input" "$QUERY" "Not a valid domain or IPv4 address"
fi

# --- DNS resolution ---
DNS_JSON="null"
RESOLVED_IPS=""
dns_time_ms=0

if is_ipv4 "$QUERY"; then
  # Skip DNS, use IP directly
  RESOLVED_IPS="$QUERY"
else
  # Resolve domain via SmartDNS
  local_t1=$(get_ms)
  dig_output=$(dig "@${DNS_HOST}" -p "$DNS_PORT" +short +time="$DNS_TIMEOUT" "$QUERY" 2>/dev/null) || dig_output=""
  local_t2=$(get_ms)
  dns_time_ms=$((local_t2 - local_t1))

  # Filter only IPv4 addresses from dig output (may contain CNAMEs)
  RESOLVED_IPS=""
  for line in $dig_output; do
    if is_ipv4 "$line"; then
      RESOLVED_IPS="${RESOLVED_IPS:+${RESOLVED_IPS} }${line}"
    fi
  done

  if [ -z "$RESOLVED_IPS" ]; then
    emit_error "dns_failed" "$QUERY" "No A records from ${DNS_HOST}:${DNS_PORT}"
  fi

  # Build DNS JSON: ips array (only if JSON mode)
  if [ "$JSON_MODE" = "1" ]; then
    dns_ips_json=""
    for ip in $RESOLVED_IPS; do
      dns_ips_json="${dns_ips_json:+${dns_ips_json},}\"$(json_escape_val "$ip")\""
    done
    DNS_JSON=$(printf '{"resolver":"%s:%s","ips":[%s],"time_ms":%d}' \
      "$DNS_HOST" "$DNS_PORT" "$dns_ips_json" "$dns_time_ms")
  fi
fi

# --- Route lookup ---
# Detect a fake client source address from the iif subnet (needed for forwarding route lookup).
# "ip route get <DST> iif <IFACE>" requires "from <SRC>" on many kernels.
# IMPORTANT: Must NOT be the router's own IP (local addresses skip ip rules).
# We derive a client IP by incrementing the last octet of the interface address.
IIF_SRC=$(ip -4 addr show "$IIF" 2>/dev/null | awk '/inet /{split($2,a,"/"); split(a[1],b,"."); printf "%s.%s.%s.%d", b[1],b[2],b[3],(b[4]%254)+1; exit}')

# Collect route data into positional records (space-delimited within newline-separated entries)
ROUTES_JSON=""
ROUTES_TEXT=""
OVERALL_VERDICT="default"
TUNNEL_DEV=""
verdicts_seen=""
devs_seen=""

for ip in $RESOLVED_IPS; do
  # Get route for this IP (forwarding lookup with iif + from + optional fwmark)
  route_output=""
  if [ -n "$IIF_SRC" ] && [ -n "$FWMARK" ]; then
    route_output=$(ip route get "$ip" mark "$FWMARK" from "$IIF_SRC" iif "$IIF" 2>/dev/null) || route_output=""
  elif [ -n "$IIF_SRC" ]; then
    route_output=$(ip route get "$ip" from "$IIF_SRC" iif "$IIF" 2>/dev/null) || route_output=""
  fi
  if [ -z "$route_output" ]; then
    route_output=$(ip route get "$ip" 2>/dev/null) || route_output=""
  fi

  if [ -z "$route_output" ]; then
    # Skip this IP if route get fails
    continue
  fi

  # Parse fields from ip route get output (pure shell, no forks)
  # Example: "5.5.5.5 via 192.168.1.1 dev lte_br1 table 1000 src 192.168.1.100"
  r_dev=""; r_via=""; r_table=""
  # shellcheck disable=SC2086
  set -- $route_output
  while [ $# -gt 1 ]; do
    case "$1" in
      dev)   r_dev="$2" ;;
      via)   r_via="$2" ;;
      table) r_table="$2" ;;
    esac
    shift
  done

  # If table is empty, it's the main table
  if [ -z "$r_table" ]; then
    r_table="main"
  fi

  r_table_name=$(table_name_for "$r_table")
  r_match_type=$(match_type_for "$r_table")
  r_match_prefix=$(get_match_prefix "$ip" "$r_table")

  # Determine per-IP verdict: geo-split / tunnel / default
  ip_verdict="default"
  if [ "$r_table" = "$DOMAIN_ROUTE_TABLE" ] || [ "$r_table" = "$SUBNET_ROUTE_TABLE" ]; then
    ip_verdict="geo-split"
  elif [ -n "$FWMARK" ] && is_tunnel_iface "$r_dev"; then
    ip_verdict="tunnel"
    TUNNEL_DEV="$r_dev"
  fi

  # Track unique verdicts and devices for mixed detection
  case "$verdicts_seen" in *"|${ip_verdict}|"*) ;; *)
    verdicts_seen="${verdicts_seen}|${ip_verdict}|" ;; esac
  case "$devs_seen" in *"|${r_dev}|"*) ;; *)
    devs_seen="${devs_seen}|${r_dev}|" ;; esac

  if [ "$JSON_MODE" = "1" ]; then
    # Build route JSON object (inline, no subshell forks)
    route_entry="{\"ip\":\"${ip}\",\"dev\":\"${r_dev}\",\"via\":\"${r_via}\",\"table\":\"${r_table}\",\"table_name\":\"${r_table_name}\",\"match_type\":\"${r_match_type}\",\"match_prefix\":\"${r_match_prefix}\",\"verdict\":\"${ip_verdict}\"}"
    ROUTES_JSON="${ROUTES_JSON:+${ROUTES_JSON},}${route_entry}"
  else
    # Build text route entry
    via_str=""
    if [ -n "$r_via" ]; then
      via_str=" via ${r_via}"
    fi
    ROUTES_TEXT="${ROUTES_TEXT}    ${ip} → dev ${r_dev}${via_str} [${ip_verdict}, table ${r_table} (${r_table_name}), ${r_match_type}: ${r_match_prefix}]
"
  fi
done

# --- Compute overall verdict (mixed if multiple unique per-IP verdicts) ---
v_count=0
v_list=""
tmp="${verdicts_seen#|}"
while [ -n "$tmp" ]; do
  item="${tmp%%|*}"
  tmp="${tmp#*|}"
  [ -z "$item" ] && continue
  v_count=$((v_count + 1))
  v_list="${v_list:+${v_list},}${item}"
done

if [ "$v_count" -gt 1 ]; then
  OVERALL_VERDICT="mixed"
elif [ "$v_count" -eq 1 ]; then
  OVERALL_VERDICT="$item"
fi

# Build unique devs comma-list for display
d_list=""
tmp="${devs_seen#|}"
while [ -n "$tmp" ]; do
  item="${tmp%%|*}"
  tmp="${tmp#*|}"
  [ -z "$item" ] && continue
  d_list="${d_list:+${d_list},}${item}"
done

# --- Default route ---
default_route_output=$(ip route show default 2>/dev/null | head -1) || default_route_output=""
dr_dev=""; dr_via=""
# shellcheck disable=SC2086
set -- $default_route_output
while [ $# -gt 1 ]; do
  case "$1" in
    dev) dr_dev="$2" ;;
    via) dr_via="$2" ;;
  esac
  shift
done

# --- Tunnel route (client's VPN policy path, even when geo-split wins) ---
TUNNEL_ROUTE_DEV=""
if [ -n "$FWMARK" ]; then
  # Resolve fwmark → table → default route dev
  tun_table=$(ip rule show 2>/dev/null | sed -n "s/.*fwmark ${FWMARK} lookup \([0-9]*\).*/\1/p" | head -1)
  if [ -n "$tun_table" ]; then
    TUNNEL_ROUTE_DEV=$(ip route show table "$tun_table" 2>/dev/null | awk '/^default/{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  fi
fi

# --- Output ---
if [ "$JSON_MODE" = "1" ]; then
  # JSON output (inline, no subshell forks)
  fwmark_json=""
  if [ -n "$FWMARK" ]; then
    fwmark_json=",\"fwmark\":\"${FWMARK}\""
  fi
  from_json=""
  if [ -n "$FROM_MAC" ]; then
    from_json=",\"from_mac\":\"${FROM_MAC}\",\"from_name\":\"$(json_escape_val "$FROM_NAME")\""
  fi
  tunnel_json=""
  if [ -n "$TUNNEL_ROUTE_DEV" ]; then
    tunnel_json=",\"tunnel_route\":{\"dev\":\"${TUNNEL_ROUTE_DEV}\"}"
  fi
  # Build verdict_details JSON array: ["geo-split","tunnel"]
  vd_json=""
  vd_tmp="$v_list"
  while [ -n "$vd_tmp" ]; do
    vd_item="${vd_tmp%%,*}"
    vd_json="${vd_json:+${vd_json},}\"${vd_item}\""
    case "$vd_tmp" in *,*) vd_tmp="${vd_tmp#*,}" ;; *) vd_tmp="" ;; esac
  done
  # Build verdict_devs JSON array: ["nwg0","lte_br1"]
  dd_json=""
  dd_tmp="$d_list"
  while [ -n "$dd_tmp" ]; do
    dd_item="${dd_tmp%%,*}"
    dd_json="${dd_json:+${dd_json},}\"${dd_item}\""
    case "$dd_tmp" in *,*) dd_tmp="${dd_tmp#*,}" ;; *) dd_tmp="" ;; esac
  done
  printf '{"ok":true,"query":"%s","source_iface":"%s"%s%s,"dns":%s,"routes":[%s],"default_route":{"dev":"%s","via":"%s"}%s,"verdict":"%s","verdict_details":[%s],"verdict_devs":[%s]}\n' \
    "$QUERY" "$IIF" "$fwmark_json" "$from_json" "$DNS_JSON" "$ROUTES_JSON" "$dr_dev" "$dr_via" "$tunnel_json" "$OVERALL_VERDICT" "$vd_json" "$dd_json"
else
  # Human-readable text output
  printf 'Route Check: %s\n' "$QUERY"
  if [ -n "$FROM_MAC" ]; then
    printf '  From client:  %s [%s] (iif %s)\n' "$FROM_NAME" "$FROM_MAC" "$IIF"
  else
    printf '  Source iface: %s\n' "$IIF"
  fi

  # DNS section
  if is_ipv4 "$QUERY"; then
    printf '  DNS:          skipped (direct IP)\n'
  else
    printf '  DNS:          %s:%s → %s (%d ms)\n' \
      "$DNS_HOST" "$DNS_PORT" "$RESOLVED_IPS" "$dns_time_ms"
  fi

  # Routes
  printf '  Routes:\n'
  printf '%s' "$ROUTES_TEXT"

  # Default route
  dr_str="dev ${dr_dev}"
  if [ -n "$dr_via" ]; then
    dr_str="${dr_str} via ${dr_via}"
  fi
  printf '  Default route: %s\n' "$dr_str"

  # Verdict
  if [ "$OVERALL_VERDICT" = "mixed" ]; then
    printf '  Verdict:       ⚠ mixed (%s)\n' "$d_list"
  elif [ "$OVERALL_VERDICT" = "geo-split" ]; then
    printf '  Verdict:       ★ geo-split (custom table routing)\n'
  elif [ "$OVERALL_VERDICT" = "tunnel" ]; then
    printf '  Verdict:       = tunnel %s (policy routing)\n' "${TUNNEL_DEV:-}"
  else
    printf '  Verdict:       ⇒ default (main table)\n'
  fi
fi

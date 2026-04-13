#!/opt/bin/sh
# Resolve domains from list via dig, cache IPs, and fill routing table.
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
# shellcheck disable=SC1091  # sourced files resolved at runtime on router
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
. "$SCRIPT_DIR/../../lib/lists.sh"
. "$SCRIPT_DIR/../../lib/ip.sh"
_CONFIG_DIR="$(cd "$SCRIPT_DIR/../config" && pwd)"
. "$_CONFIG_DIR/config.sh"

# Filter out private/special IPs from stdin
filter_private_ips() {
  grep -vE \
    -e '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' \
    -e '^(0\.|127\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|255\.255\.255\.255)'
}

# Detect best DNS resolver for full A-record resolution.
# Sets DNS_ARGS for dig commands. Uses detect_dns_port() from lib/ip.sh.
detect_dns_resolver() {
  local result port label
  result=$(detect_dns_port)
  port="${result%% *}"
  label="${result#* }"

  if [ "$port" = "0" ]; then
    DNS_ARGS=""
    log "Using system DNS resolver"
  else
    DNS_ARGS="@localhost -p $port"
    log "Using DNS resolver: localhost:$port ($label)"
  fi
}

# Resolve all domains and update cache
resolve_domains() {
  require_cmd dig

  if [ ! -f "$DOMAINS_LIST_FILE" ]; then
    log "No domains list file: $DOMAINS_LIST_FILE"
    return 0
  fi

  local tmp_cache ip _counts
  tmp_cache="${DOMAINS_CACHE_FILE}.tmp"

  : > "$tmp_cache"

  # Pipe through list_read (strips comments, trims, resolves @includes).
  # Counters collected inside { } group and echoed to stdout at the end.
  _counts=$(list_read "$DOMAINS_LIST_FILE" | {
    _dc=0; _ic=0; _pc=0
    while IFS= read -r line; do
      _dc=$((_dc + 1))

      # Resolve domain via detected DNS resolver
      # shellcheck disable=SC2086  # intentional: DNS_ARGS must word-split
      for ip in $(dig +short "$line" $DNS_ARGS 2>/dev/null); do
        # Skip non-IPv4 (CNAMEs, AAAA, etc.)
        case "$ip" in
          *[!0-9.]*) continue ;;
        esac

        # Skip private/special IPs
        if ! echo "$ip" | filter_private_ips >/dev/null 2>&1; then
          _pc=$((_pc + 1))
          continue
        fi

        echo "$ip # $line" >> "$tmp_cache"
        _ic=$((_ic + 1))
      done
    done
    echo "$_dc $_ic $_pc"
  })

  # Parse counters from subshell output
  local domain_count ip_count private_count
  domain_count="${_counts%% *}"
  _counts="${_counts#* }"
  ip_count="${_counts% *}"
  private_count="${_counts#* }"

  # Deduplicate by IP (first field); keep first occurrence with its domain comment
  # BusyBox sort ignores -k3,3 — extract domain as sort key, then strip it
  awk -F' # ' '!seen[$1]++ {print $2 "\t" $0}' "$tmp_cache" | sort | cut -f2- > "$DOMAINS_CACHE_FILE"
  rm -f "$tmp_cache"
  local unique_count
  unique_count=$(wc -l < "$DOMAINS_CACHE_FILE")
  log "Resolved $domain_count domains: $unique_count unique IPs ($ip_count total, $private_count private skipped)"
}

# Fill domain routing table from cached resolved IPs
_fill_domain_table() {
  local dev
  dev=$(resolve_target_interface) || {
    log "No target interface, domain table fill deferred"
    return 0
  }
  log "Route out: $dev"
  fill_routes_batch "$DOMAIN_ROUTE_TABLE" "$DOMAINS_CACHE_FILE" "$dev" host
}

# --- main ---
main() {
  local arg="${1:-}"
  local update_interval="${DOMAINS_UPDATE_INTERVAL:-3600}"

  # --refill: fill table from existing cache (no resolve, for NDM hook UP)
  if [ "$arg" = "--refill" ]; then
    _fill_domain_table
    return 0
  fi

  # 0 = domain updates disabled
  if [ "$update_interval" = "0" ]; then
    log "Domain updates disabled (DOMAINS_UPDATE_INTERVAL=0)"
    return 10
  fi

  if [ "$arg" = "--force" ] || ! is_cache_fresh "$DOMAINS_CACHE_FILE" "$update_interval"; then
    local t_start t_end
    t_start=$(date +%s)
    detect_dns_resolver
    resolve_domains
    t_end=$(date +%s)
    log "Domain update completed ($((t_end - t_start))s)"
    _fill_domain_table
    return 0  # resolved + table filled
  fi
  # Cache fresh — still fill the table (may be empty after restart)
  _fill_domain_table
  log "Domain cache is fresh, skipping update"
  return 0
}

main "$@"

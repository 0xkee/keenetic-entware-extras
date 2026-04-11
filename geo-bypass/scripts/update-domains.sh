#!/opt/bin/sh
# Resolve domains from list via dig and cache resulting IPs into ipset.
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
# shellcheck disable=SC1091  # sourced files resolved at runtime on router
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
. "$SCRIPT_DIR/../../lib/lists.sh"
_CONFIG_DIR="$SCRIPT_DIR/../config"
. "$_CONFIG_DIR/config.sh"

# Filter out private/special IPs from stdin
filter_private_ips() {
  grep -vE \
    -e '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' \
    -e '^(0\.|127\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|255\.255\.255\.255)'
}

# Detect best DNS resolver for full A-record resolution
detect_dns_resolver() {
  # Explicit override from config
  if [ -n "${DNS_FULL_RESOLVER_PORT:-}" ]; then
    DNS_ARGS="@localhost -p $DNS_FULL_RESOLVER_PORT"
    log "Using configured DNS resolver: localhost:$DNS_FULL_RESOLVER_PORT"
    return
  fi

  # Auto-detect: probe SmartDNS no-speed-check port (6153)
  if dig +short +time=1 +tries=1 localhost @localhost -p 6153 >/dev/null 2>&1; then
    DNS_ARGS="@localhost -p 6153"
    log "Auto-detected DNS resolver: localhost:6153 (SmartDNS no-speed-check)"
    return
  fi

  # Fallback: probe SmartDNS main port (6053)
  if dig +short +time=1 +tries=1 localhost @localhost -p 6053 >/dev/null 2>&1; then
    DNS_ARGS="@localhost -p 6053"
    log "Auto-detected DNS resolver: localhost:6053 (SmartDNS)"
    return
  fi

  # Last resort: system resolver
  DNS_ARGS=""
  log "Using system DNS resolver"
}

# Resolve all domains and update cache + ipset
resolve_domains() {
  require_cmd dig
  require_cmd ipset

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
        ipset add "$IPSET_NAME" "$ip" -exist 2>/dev/null || true
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

# --- main ---
main() {
  local force="${1:-}"
  local update_interval="${DOMAINS_UPDATE_INTERVAL:-3600}"

  # 0 = domain updates disabled
  if [ "$update_interval" = "0" ]; then
    log "Domain updates disabled (DOMAINS_UPDATE_INTERVAL=0)"
    exit 0
  fi

  if [ "$force" = "--force" ] || ! is_cache_fresh "$DOMAINS_CACHE_FILE" "$update_interval"; then
    local t_start t_end old_cache
    old_cache="${DOMAINS_CACHE_FILE}.old"

    # Save old cache for comparison
    if [ -f "$DOMAINS_CACHE_FILE" ]; then
      cp "$DOMAINS_CACHE_FILE" "$old_cache"
    fi

    t_start=$(date +%s)
    detect_dns_resolver
    resolve_domains
    t_end=$(date +%s)
    log "Domain update completed ($((t_end - t_start))s)"

    # Activate routes only if resolved IPs changed
    if [ ! -f "$old_cache" ] || ! cmp -s "$old_cache" "$DOMAINS_CACHE_FILE"; then
      log "Domain cache changed, activating routes..."
      "$SCRIPT_DIR/attach-rules.sh"
    else
      log "Domain cache unchanged, skipping route reload"
    fi
    rm -f "$old_cache"
  else
    log "Domain cache is fresh, skipping update"
  fi
}

main "$@"

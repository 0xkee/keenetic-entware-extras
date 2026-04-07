#!/opt/bin/sh
# Resolve domains from list via dig and cache resulting IPs into ipset.
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
# shellcheck disable=SC1091  # sourced files resolved at runtime on router
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
_CONFIG_DIR="$SCRIPT_DIR/../config"
. "$_CONFIG_DIR/config.sh"

# Check if file is fresh (younger than max_age seconds)
# Args: $1 - file path, $2 - max age in seconds
is_cache_fresh() {
  local file="$1" max_age="$2"
  [ -f "$file" ] || return 1
  local file_age
  file_age=$(( $(date +%s) - $(stat -c %Y "$file") ))
  [ "$file_age" -le "$max_age" ]
}

# Filter out private/special IPs from stdin
filter_private_ips() {
  grep -vE \
    -e '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' \
    -e '^(0\.|127\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|255\.255\.255\.255)'
}

# Resolve all domains and update cache + ipset
resolve_domains() {
  require_cmd dig
  require_cmd ipset

  if [ ! -f "$DOMAINS_LIST_FILE" ]; then
    log "No domains list file: $DOMAINS_LIST_FILE"
    return 0
  fi

  local tmp_cache domain_count ip_count private_count ip
  tmp_cache="${DOMAINS_CACHE_FILE}.tmp"
  domain_count=0
  ip_count=0
  private_count=0

  : > "$tmp_cache"

  while IFS= read -r line; do
    # Trim leading/trailing whitespace
    line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # Skip empty lines and comments
    case "$line" in
      ""|\#*) continue ;;
    esac

    domain_count=$((domain_count + 1))

    # Resolve domain via local DNS
    for ip in $(dig +short "$line" @localhost 2>/dev/null); do
      # Skip non-IPv4 (CNAMEs, AAAA, etc.)
      case "$ip" in
        *[!0-9.]*) continue ;;
      esac

      # Skip private/special IPs
      if ! echo "$ip" | filter_private_ips >/dev/null 2>&1; then
        private_count=$((private_count + 1))
        continue
      fi

      echo "$ip" >> "$tmp_cache"
      ipset add "$IPSET_NAME" "$ip" -exist 2>/dev/null || true
      ip_count=$((ip_count + 1))
    done
  done < "$DOMAINS_LIST_FILE"

  mv "$tmp_cache" "$DOMAINS_CACHE_FILE"
  log "Resolved $domain_count domains: $ip_count IPs added, $private_count private skipped"
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
    resolve_domains
  else
    log "Domain cache is fresh, skipping update"
  fi
}

main "$@"

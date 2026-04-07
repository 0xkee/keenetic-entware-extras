#!/opt/bin/bash
# Fetch and update Russian IP subnet list for direct routing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
. "$SCRIPT_DIR/../config/config.sh"

# Check if cached list is fresh enough
is_cache_fresh() {
  if [[ ! -f "$SUBNET_LIST_FILE" ]]; then
    return 1
  fi

  local file_age
  file_age=$(( $(date +%s) - $(stat -c %Y "$SUBNET_LIST_FILE") ))

  if (( file_age > MAX_CACHE_AGE )); then
    return 1
  fi

  log "Cached list is fresh (${file_age}s old, max ${MAX_CACHE_AGE}s)"
  return 0
}

# Download fresh subnet list
download_subnets() {
  require_cmd curl

  local tmp_file
  tmp_file="${SUBNET_LIST_FILE}.tmp"

  log "Downloading RU subnets from: $SUBNET_URL"

  if ! curl -sS --max-time 30 -o "$tmp_file" "$SUBNET_URL"; then
    log_error "Failed to download subnet list"
    rm -f "$tmp_file"
    return 1
  fi

  local count
  count=$(wc -l < "$tmp_file")

  if (( count < 100 )); then
    log_error "Downloaded list too small ($count lines), possible error"
    rm -f "$tmp_file"
    return 1
  fi

  mv "$tmp_file" "$SUBNET_LIST_FILE"
  log "Updated subnet list: $count subnets"
}

# --- main ---
main() {
  local force="${1:-}"

  if [[ "$force" == "--force" ]] || ! is_cache_fresh; then
    download_subnets
  fi
}

main "$@"

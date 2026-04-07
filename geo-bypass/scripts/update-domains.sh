#!/opt/bin/sh
# Fetch and update GEO IP subnet list for selective routing.
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
# shellcheck disable=SC1091  # sourced files resolved at runtime on router
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
_CONFIG_DIR="$SCRIPT_DIR/../config"
. "$_CONFIG_DIR/config.sh"

# Check if cached list is fresh enough
is_cache_fresh() {
  if [ ! -f "$SUBNET_LIST_FILE" ]; then
    return 1
  fi

  local file_age
  file_age=$(( $(date +%s) - $(stat -c %Y "$SUBNET_LIST_FILE") ))

  if [ "$file_age" -gt "$MAX_CACHE_AGE" ]; then
    return 1
  fi

  log "Cached list is fresh (${file_age}s old, max ${MAX_CACHE_AGE}s)"
  return 0
}

# Download fresh subnet list with retry
download_subnets() {
  require_cmd curl

  local tmp_file attempt retries delay
  tmp_file="${SUBNET_LIST_FILE}.tmp"
  retries="${DOWNLOAD_RETRIES:-3}"
  delay="${DOWNLOAD_RETRY_DELAY:-5}"
  attempt=1

  while [ "$attempt" -le "$retries" ]; do
    log "Downloading GEO subnets (attempt ${attempt}/${retries}): $SUBNET_URL"

    if curl -sS --max-time 30 -o "$tmp_file" "$SUBNET_URL"; then
      local count
      count=$(wc -l < "$tmp_file")

      if [ "$count" -lt 100 ]; then
        log_error "Downloaded list too small ($count lines), possible error"
        rm -f "$tmp_file"
      else
        mv "$tmp_file" "$SUBNET_LIST_FILE"
        log "Updated subnet list: $count subnets"
        return 0
      fi
    else
      log_error "Download failed (attempt ${attempt}/${retries})"
      rm -f "$tmp_file"
    fi

    if [ "$attempt" -lt "$retries" ]; then
      log "Retrying in ${delay}s..."
      sleep "$delay"
    fi
    attempt=$((attempt + 1))
  done

  log_error "All $retries download attempts failed"
  return 1
}

# --- main ---
main() {
  local force="${1:-}"

  if [ "$force" = "--force" ] || ! is_cache_fresh; then
    download_subnets
  fi
}

main "$@"

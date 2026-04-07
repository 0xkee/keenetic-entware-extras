#!/opt/bin/sh
# Fetch and update GEO IP subnet list for selective routing.
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

# Resolve loader script path and verify it exists
resolve_loader() {
  local loader="$SCRIPT_DIR/../loaders/${SUBNET_LOADER}.sh"
  if [ ! -x "$loader" ]; then
    log_error "Loader not found or not executable: $loader"
    log_error "Available loaders: $(ls "$SCRIPT_DIR/../loaders/")"
    return 1
  fi
  echo "$loader"
}

# Download fresh subnet list with retry
download_subnets() {
  local loader
  loader=$(resolve_loader) || return 1

  local tmp_file attempt retries delay
  tmp_file="${SUBNET_LIST_FILE}.tmp"
  retries="${DOWNLOAD_RETRIES:-3}"
  delay="${DOWNLOAD_RETRY_DELAY:-5}"
  attempt=1

  while [ "$attempt" -le "$retries" ]; do
    log "Downloading GEO subnets (attempt ${attempt}/${retries}): $SUBNET_URL"

    if "$loader" "$SUBNET_URL" > "$tmp_file"; then
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

  if [ "$force" = "--force" ] || ! is_cache_fresh "$SUBNET_LIST_FILE" "$MAX_CACHE_AGE"; then
    download_subnets
  fi
}

main "$@"

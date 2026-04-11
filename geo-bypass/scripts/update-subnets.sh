#!/opt/bin/sh
# Fetch and update GEO IP subnet list for selective routing.
# Supports multi-interface failover: tries each configured interface.
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
# shellcheck disable=SC1091  # sourced files resolved at runtime on router
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
. "$SCRIPT_DIR/../../lib/lists.sh"
_CONFIG_DIR="$SCRIPT_DIR/../config"
. "$_CONFIG_DIR/config.sh"

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

# Expand DOWNLOAD_INTERFACES config to actual active interface names.
# Resolves globs (nwg*, ovpn_br*) against currently active interfaces.
# "default" token is passed through as-is.
resolve_download_interfaces() {
  local active_ifaces token iface result=""
  active_ifaces=$(ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//')

  for token in $DOWNLOAD_INTERFACES; do
    case "$token" in
      default)
        result="$result default"
        ;;
      *\**)
        # Glob pattern — expand against active interfaces
        for iface in $active_ifaces; do
          # shellcheck disable=SC2254  # glob in case pattern is intentional
          case "$iface" in
            $token) result="$result $iface" ;;
          esac
        done
        ;;
      *)
        # Exact interface name — check if active
        for iface in $active_ifaces; do
          if [ "$iface" = "$token" ]; then
            result="$result $token"
            break
          fi
        done
        ;;
    esac
  done

  echo "$result"
}

# Try downloading via a specific interface.
# Args: $1 - loader path, $2 - interface ("default" = no --interface)
# Returns: 0 on success (data in tmp_file), 1 on failure
try_download() {
  local loader="$1" iface="$2"
  local iface_arg=""
  [ "$iface" != "default" ] && iface_arg="$iface"

  local attempt=1
  local retries="${DOWNLOAD_RETRIES:-2}"
  local delay="${DOWNLOAD_RETRY_DELAY:-3}"
  local tmp_file="${SUBNET_LIST_FILE}.tmp"

  while [ "$attempt" -le "$retries" ]; do
    log "Downloading via $iface (attempt ${attempt}/${retries}): $SUBNET_URL"

    if "$loader" "$SUBNET_URL" "$iface_arg" > "$tmp_file" 2>/dev/null; then
      local count
      count=$(wc -l < "$tmp_file")

      if [ "$count" -lt 100 ]; then
        log_error "Downloaded list too small ($count lines) via $iface, possible error"
        rm -f "$tmp_file"
      else
        mv "$tmp_file" "$SUBNET_LIST_FILE"
        log "Updated subnet list: $count subnets (via $iface)"
        return 0
      fi
    else
      log_error "Download failed via $iface (attempt ${attempt}/${retries})"
      rm -f "$tmp_file"
    fi

    if [ "$attempt" -lt "$retries" ]; then
      sleep "$delay"
    fi
    attempt=$((attempt + 1))
  done

  return 1
}

# Download subnets with multi-interface failover
download_subnets() {
  local loader
  loader=$(resolve_loader) || return 1

  local interfaces
  interfaces=$(resolve_download_interfaces)

  if [ -z "$interfaces" ]; then
    log_error "No download interfaces available (DOWNLOAD_INTERFACES=$DOWNLOAD_INTERFACES)"
    return 1
  fi

  log "Download interfaces: $interfaces"

  local iface
  for iface in $interfaces; do
    if try_download "$loader" "$iface"; then
      return 0
    fi
    log "Interface $iface exhausted, trying next..."
  done

  log_error "All interfaces exhausted, download failed"
  return 1
}

# --- main ---
main() {
  local force="${1:-}"

  if [ "$force" = "--force" ] || ! is_cache_fresh "$SUBNET_LIST_FILE" "$MAX_CACHE_AGE"; then
    local t_start t_end
    t_start=$(date +%s)
    download_subnets
    t_end=$(date +%s)
    log "Subnet update completed ($((t_end - t_start))s)"
  fi
}

main "$@"

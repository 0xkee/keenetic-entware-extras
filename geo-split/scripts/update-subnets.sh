#!/opt/bin/sh
# Fetch GEO IP subnet list and fill routing table.
# Supports multi-interface failover: tries each configured interface.
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
# shellcheck disable=SC1091  # sourced files resolved at runtime on router
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
. "$SCRIPT_DIR/../../lib/lists.sh"
. "$SCRIPT_DIR/../../lib/ip.sh"
_CONFIG_DIR="$(cd "$SCRIPT_DIR/../config" && pwd)"
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
        # Aggregate overlapping/adjacent CIDRs if enabled
        if [ "${SUBNET_AGGREGATE:-0}" = "1" ]; then
          local before_count="$count"
          list_aggregate_cidrs < "$tmp_file" > "${tmp_file}.agg"
          mv "${tmp_file}.agg" "$tmp_file"
          count=$(wc -l < "$tmp_file")
          log "Aggregated CIDRs: $before_count -> $count"
        fi

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

# Download subnets with multi-interface failover.
# Caches last successful interface in LAST_IFACE_CACHE to prioritize it next run.
download_subnets() {
  local loader
  loader=$(resolve_loader) || return 1

  local interfaces
  interfaces=$(resolve_download_interfaces)

  if [ -z "$interfaces" ]; then
    log_error "No download interfaces available (DOWNLOAD_INTERFACES=$DOWNLOAD_INTERFACES)"
    return 1
  fi

  # Reorder: put last successful interface first (if still in resolved list)
  local last_iface=""
  if [ -f "$LAST_IFACE_CACHE" ]; then
    last_iface=$(cat "$LAST_IFACE_CACHE")
  fi
  if [ -n "$last_iface" ]; then
    case " $interfaces " in
      *" $last_iface "*)
        local reordered="$last_iface"
        local i
        for i in $interfaces; do
          [ "$i" = "$last_iface" ] || reordered="$reordered $i"
        done
        interfaces="$reordered"
        ;;
    esac
  fi

  log "Download interfaces: $interfaces"

  local iface
  for iface in $interfaces; do
    if try_download "$loader" "$iface"; then
      echo "$iface" > "$LAST_IFACE_CACHE"
      return 0
    fi
    log "Interface $iface exhausted, trying next..."
  done

  log_error "All interfaces exhausted, download failed"
  return 1
}

# Fill subnet routing table from cached list
_fill_subnet_table() {
  local dev
  dev=$(resolve_target_interface) || {
    log "No target interface, subnet table fill deferred"
    return 0
  }
  log "Route out: $dev"
  fill_routes_batch "$SUBNET_ROUTE_TABLE" "$SUBNET_LIST_FILE" "$dev"
}

# --- main ---
main() {
  local arg="${1:-}"

  # --refill: fill table from existing cache (no download, for NDM hook UP)
  if [ "$arg" = "--refill" ]; then
    _fill_subnet_table
    return 0
  fi

  if [ "$arg" = "--force" ] || ! is_cache_fresh "$SUBNET_LIST_FILE" "$MAX_CACHE_AGE"; then
    local t_start t_end
    t_start=$(date +%s)
    download_subnets
    t_end=$(date +%s)
    log "Subnet update completed ($((t_end - t_start))s)"
    _fill_subnet_table
    return 0  # data updated + table filled
  fi
  # Cache fresh — only refill if table is empty (e.g. after restart)
  if is_table_filled "$SUBNET_ROUTE_TABLE"; then
    log "Subnet cache fresh, table $SUBNET_ROUTE_TABLE already filled — skipping"
    return 0
  fi
  _fill_subnet_table
  return 0
}

main "$@"

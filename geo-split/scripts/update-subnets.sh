#!/opt/bin/sh
# Fetch GEO IP subnet lists and fill routing table.
# Supports multi-zone (GEO_ZONE → union of countries) with local geoip files.
# Falls back to online download for missing zones.
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
# shellcheck disable=SC1091  # sourced files resolved at runtime on router
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
. "$SCRIPT_DIR/../../lib/lists.sh"
. "$SCRIPT_DIR/../../lib/ip.sh"
. "$SCRIPT_DIR/../../lib/geo.sh"
_CONFIG_DIR="$(cd "$SCRIPT_DIR/../config" && pwd)"
. "$_CONFIG_DIR/defaults.conf"
[ -f "$_CONFIG_DIR/config.conf" ] && . "$_CONFIG_DIR/config.conf"

# Cleanup temp files on exit
_cleanup() { rm -f "${SUBNET_LIST_FILE}.tmp" "${SUBNET_LIST_FILE}.tmp.agg" "/opt/tmp/geo-zone-dl.tmp"; }
trap _cleanup EXIT

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
resolve_download_interfaces() {
  local active_ifaces token iface result=""
  active_ifaces=$(ip -o link show up 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//')

  for token in $DOWNLOAD_INTERFACES; do
    case "$token" in
      default)
        result="$result default"
        ;;
      *\**)
        for iface in $active_ifaces; do
          case "$iface" in lo|br*|ifb*) continue ;; esac
          # shellcheck disable=SC2254
          case "$iface" in
            $token) result="$result $iface" ;;
          esac
        done
        ;;
      *)
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

# Try downloading a URL via a specific interface.
# Args: $1 - loader path, $2 - interface, $3 - URL, $4 - output file
# Returns: 0 on success, 1 on failure
try_download_url() {
  local loader="$1" iface="$2" url="$3" out_file="$4"
  local iface_arg=""
  [ "$iface" != "default" ] && iface_arg="$iface"

  local attempt=1
  local retries="${DOWNLOAD_RETRIES:-2}"
  local delay="${DOWNLOAD_RETRY_DELAY:-3}"

  while [ "$attempt" -le "$retries" ]; do
    log "Downloading via $iface (attempt ${attempt}/${retries}): $url"

    if "$loader" "$url" "$iface_arg" > "$out_file" 2>/dev/null; then
      local count
      count=$(wc -l < "$out_file")
      if [ "$count" -lt 10 ]; then
        log_error "Downloaded list too small ($count lines) via $iface"
        rm -f "$out_file"
      else
        return 0
      fi
    else
      log_error "Download failed via $iface (attempt ${attempt}/${retries})"
      rm -f "$out_file"
    fi

    if [ "$attempt" -lt "$retries" ]; then
      sleep "$delay"
    fi
    attempt=$((attempt + 1))
  done

  return 1
}

# Download a single zone file with multi-interface failover.
# Downloads plain text from ipdeny.com, then gzip-compresses to output path.
# Args: $1 - country code, $2 - output file path (.zone.gz)
# Returns: 0 on success, 1 on failure
download_zone() {
  local cc="$1" out_file="$2"
  local url dl_tmp="/opt/tmp/geo-zone-dl.tmp"

  url=$(echo "$SUBNET_URL_PATTERN" | sed "s/{cc}/$cc/g")

  local loader
  loader=$(resolve_loader) || return 1

  local interfaces
  interfaces=$(resolve_download_interfaces)
  if [ -z "$interfaces" ]; then
    log_error "No download interfaces available"
    return 1
  fi

  # Reorder: put last successful interface first
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

  local iface
  for iface in $interfaces; do
    if try_download_url "$loader" "$iface" "$url" "$dl_tmp"; then
      echo "$iface" > "$LAST_IFACE_CACHE"
      # Compress downloaded plain-text zone to .gz (default -6: low CPU on router)
      gzip -c "$dl_tmp" > "$out_file"
      rm -f "$dl_tmp"
      return 0
    fi
  done

  log_error "All interfaces exhausted for zone $cc"
  return 1
}

# Legacy mode: download single SUBNET_URL (backward compat for custom URLs).
download_legacy() {
  local loader
  loader=$(resolve_loader) || return 1

  local interfaces
  interfaces=$(resolve_download_interfaces)
  if [ -z "$interfaces" ]; then
    log_error "No download interfaces available (DOWNLOAD_INTERFACES=$DOWNLOAD_INTERFACES)"
    return 1
  fi

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

  log "Legacy mode: downloading $SUBNET_URL"
  local tmp_file="${SUBNET_LIST_FILE}.tmp"
  local iface
  for iface in $interfaces; do
    if try_download_url "$loader" "$iface" "$SUBNET_URL" "$tmp_file"; then
      echo "$iface" > "$LAST_IFACE_CACHE"
      local count
      count=$(wc -l < "$tmp_file")
      # Aggregate if enabled
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
    log "Interface $iface exhausted, trying next..."
  done

  log_error "All interfaces exhausted, download failed"
  return 1
}

# Read a zone file (plain or gzipped) to stdout.
# Args: $1 - file path (.zone or .zone.gz)
_read_zone() {
  case "$1" in
    *.gz) gzip -dc "$1" ;;
    *)    cat "$1" ;;
  esac
}

# Find zone file for a country code.
# Prefers .zone.gz (smaller), falls back to plain .zone (pre-0.6.0 compat).
# Args: $1 - country code
# stdout: file path or empty
_find_zone_file() {
  local cc="$1"
  if [ -f "${GEOIP_DIR}/${cc}.zone.gz" ] && [ -s "${GEOIP_DIR}/${cc}.zone.gz" ]; then
    echo "${GEOIP_DIR}/${cc}.zone.gz"
  elif [ -f "${GEOIP_DIR}/${cc}.zone" ] && [ -s "${GEOIP_DIR}/${cc}.zone" ]; then
    echo "${GEOIP_DIR}/${cc}.zone"
  fi
}

# Merge zone files for all active countries into SUBNET_LIST_FILE.
# Uses pre-packaged geoip files (.zone.gz preferred, .zone fallback);
# downloads missing ones.
merge_zones() {
  local zones
  zones="$(resolve_geo_zone "$GEO_ZONE")"
  log "GEO_ZONE=$GEO_ZONE → zones: $zones"

  local tmp_merged="${SUBNET_LIST_FILE}.tmp"
  local cc zone_file missing="" found=0

  : > "$tmp_merged"

  for cc in $zones; do
    zone_file="$(_find_zone_file "$cc")"
    if [ -n "$zone_file" ]; then
      _read_zone "$zone_file" >> "$tmp_merged"
      found=$((found + 1))
    else
      missing="$missing $cc"
    fi
  done

  # Download missing zones
  if [ -n "$missing" ]; then
    log "Missing local zones:$missing — downloading"
    for cc in $missing; do
      if download_zone "$cc" "${GEOIP_DIR}/${cc}.zone.gz"; then
        _read_zone "${GEOIP_DIR}/${cc}.zone.gz" >> "$tmp_merged"
        found=$((found + 1))
      else
        log_error "Failed to get zone $cc, skipping"
      fi
    done
  fi

  if [ "$found" -eq 0 ]; then
    log_error "No zones loaded, merge failed"
    rm -f "$tmp_merged"
    return 1
  fi

  # Aggregate all merged CIDRs
  local raw_count agg_count
  raw_count=$(wc -l < "$tmp_merged")

  if [ "${SUBNET_AGGREGATE:-0}" = "1" ]; then
    list_aggregate_cidrs < "$tmp_merged" > "${tmp_merged}.agg"
    mv "${tmp_merged}.agg" "$tmp_merged"
    agg_count=$(wc -l < "$tmp_merged")
    log "Merged $found zone(s): $raw_count CIDRs → $agg_count aggregated"
  else
    agg_count="$raw_count"
    log "Merged $found zone(s): $agg_count CIDRs (no aggregation)"
  fi

  mv "$tmp_merged" "$SUBNET_LIST_FILE"
  return 0
}

# Fill subnet routing table from cached list
_fill_subnet_table() {
  local dev gw
  dev=$(resolve_target_interface) || {
    log "No target interface, subnet table fill deferred"
    return 0
  }
  gw=$(resolve_target_gateway "$dev")
  log "Route out: $dev${gw:+ via $gw}"
  fill_routes_batch "$SUBNET_ROUTE_TABLE" "$SUBNET_LIST_FILE" "$dev" cidr "$gw"
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

    # Legacy mode: SUBNET_URL override set → single URL download
    if [ -n "${SUBNET_URL:-}" ]; then
      download_legacy
    else
      merge_zones
    fi

    t_end=$(date +%s)
    log "Subnet update completed ($((t_end - t_start))s)"
    _fill_subnet_table
    return 0
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

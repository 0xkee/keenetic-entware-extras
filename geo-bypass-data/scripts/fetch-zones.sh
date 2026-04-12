#!/bin/bash
# Fetch GEO IP zone files from ipdeny.com, aggregate CIDRs, save to lists/geoip/.
# Usage: ./geo-bypass-data/scripts/fetch-zones.sh [--force]
# Runs on dev/build machine (not router).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GEOIP_DIR="$SCRIPT_DIR/../lists/geoip"

# Source CIDR aggregation library
# shellcheck source=../../lib/ip.sh disable=SC1091
. "$PROJECT_ROOT/lib/ip.sh"

# Countries to fetch (ISO 3166-1 alpha-2, lowercase)
COUNTRIES=(ru)

# ipdeny.com base URL
IPDENY_BASE="https://www.ipdeny.com/ipblocks/data/countries"

# Max age before re-fetch (30 days in seconds)
MAX_AGE=$((30 * 86400))

mkdir -p "$GEOIP_DIR"

for cc in "${COUNTRIES[@]}"; do
    zone_file="$GEOIP_DIR/${cc}.zone"
    force="${1:-}"

    # Skip if fresh (unless --force)
    if [ "$force" != "--force" ] && [ -f "$zone_file" ]; then
        age=$(( $(date +%s) - $(stat -c %Y "$zone_file") ))
        if [ "$age" -lt "$MAX_AGE" ]; then
            echo "Skip ${cc}.zone: fresh (age ${age}s < ${MAX_AGE}s)"
            continue
        fi
    fi

    url="${IPDENY_BASE}/${cc}.zone"
    echo "Fetching ${cc}.zone from ${url} ..."
    tmp_file="$(mktemp)"

    if ! curl -sSf --max-time 30 -o "$tmp_file" "$url"; then
        echo "ERROR: Failed to download ${cc}.zone" >&2
        rm -f "$tmp_file"
        continue
    fi

    raw_count=$(grep -cE '^[0-9]' "$tmp_file" || true)
    if [ "$raw_count" -lt 100 ]; then
        echo "ERROR: ${cc}.zone too small (${raw_count} lines), skipping" >&2
        rm -f "$tmp_file"
        continue
    fi

    # Aggregate overlapping/adjacent CIDRs
    agg_file="$(mktemp)"
    list_aggregate_cidrs < "$tmp_file" > "$agg_file"
    agg_count=$(wc -l < "$agg_file")

    mv "$agg_file" "$zone_file"
    rm -f "$tmp_file"
    echo "Saved ${cc}.zone: ${raw_count} -> ${agg_count} CIDRs (aggregated)"
done

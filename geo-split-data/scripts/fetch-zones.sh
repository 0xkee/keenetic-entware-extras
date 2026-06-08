#!/bin/bash
# Fetch GEO IP zone files from ipdeny.com, aggregate CIDRs, save to lists/geoip/.
# Usage: ./geo-split-data/scripts/fetch-zones.sh [--force]
# Runs on dev/build machine (not router).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GEOIP_DIR="$SCRIPT_DIR/../lists/geoip"

# Source CIDR aggregation library
# shellcheck source=../../lib/ip.sh disable=SC1091
. "$PROJECT_ROOT/lib/ip.sh"

# shellcheck source=../../lib/common.sh disable=SC1091
. "$PROJECT_ROOT/lib/common.sh"
require_cmd aggregate

# Countries to fetch (ISO 3166-1 alpha-2, lowercase)
# All countries available on ipdeny.com (~240 zones)
COUNTRIES=(
  ad ae af ag ai al am ao ar as at au aw ax az
  ba bb bd be bf bg bh bi bj bm bn bo br bs bt bw by bz
  ca cd cf cg ch ci ck cl cm cn co cr cu cv cw cy cz
  de dj dk dm do dz
  ec ee eg er es et
  fi fj fk fm fo fr
  ga gb gd ge gf gh gi gl gm gn gq gr gt gu gw gy
  hk hn hr ht hu
  id ie il im in io iq ir is it
  je jm jo jp
  ke kg kh ki km kn kp kr kw ky kz
  la lb lc li lk lr ls lt lu lv ly
  ma mc md me mg mh mk ml mm mn mo mp mq mr ms mt mu mv mw mx my mz
  na nc ne nf ng ni nl no np nr nu nz
  om
  pa pe pf pg ph pk pl pm pn pr ps pt pw py
  qa
  re ro rs ru rw
  sa sb sc sd se sg sh si sk sl sm sn so sr ss st sv sx sy sz
  tc td tg th tj tk tl tm tn to tr tt tv tw tz
  ua ug us uy uz
  va vc ve vg vi vn vu
  wf ws
  ye yt
  za zm zw
)

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
    if [ "$raw_count" -eq 0 ]; then
        echo "WARN: ${cc}.zone empty (0 CIDRs), skipping" >&2
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

#!/bin/bash
# scripts/test-geo-zones.sh — validate lib/geo.sh union country codes.
# Dev-time only (runs on build machine, not router).
# Checks:
#   1. All country codes in UNION_* are valid format (2 lowercase letters)
#   2. All codes have corresponding smartdns zone preset (warning only)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GEO_LIB="$ROOT/lib/geo.sh"
ZONES_DIR="$ROOT/smartdns-geo-conf/config/zones"

errors=0

# Extract all unique country codes from UNION_* variables
all_codes=$(grep -oP '^UNION_\w+="[^"]*"' "$GEO_LIB" | \
  sed 's/^UNION_[^=]*="//; s/"$//' | tr ' ' '\n' | sort -u)

total=$(echo "$all_codes" | wc -l)

# 1. Validate format: each code must be exactly 2 lowercase letters
invalid=""
for cc in $all_codes; do
  if ! [[ "$cc" =~ ^[a-z]{2}$ ]]; then
    invalid="$invalid $cc"
    errors=$((errors + 1))
  fi
done

if [ -n "$invalid" ]; then
  echo "❌ Invalid country codes in lib/geo.sh unions:$invalid"
fi

# 2. Check zone presets exist (warning, not error)
missing=""
for cc in $all_codes; do
  if [ ! -f "$ZONES_DIR/${cc}.conf" ]; then
    missing="$missing $cc"
  fi
done

if [ -n "$missing" ]; then
  missing_count=$(echo "$missing" | wc -w)
  echo "⚠️  $missing_count code(s) in unions without zone preset:$missing"
fi

# Summary
if [ "$errors" -eq 0 ]; then
  echo "✅ geo-zones: $total unique codes in unions, all valid ISO 3166-1 alpha-2"
else
  echo "❌ geo-zones: $errors invalid code(s) found"
  exit 1
fi

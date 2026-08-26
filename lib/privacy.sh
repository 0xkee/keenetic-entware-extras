#!/opt/bin/sh
# lib/privacy.sh — Shared privacy filter for public-facing output.
# Masks public IPv4, IPv6, and ASN patterns. Preserves well-known DNS IPs
# and RFC 1918 / loopback ranges. Width-preserving for table alignment.
#
# Usage: source this file, then pipe output through priv_basic_filter.
#   . "$BASE/lib/privacy.sh"
#   some_command | priv_basic_filter "$wellknown_ips"
#
# Dependencies: none (self-contained awk + sed)
# shellcheck disable=SC3043

# ─── Well-known IP defaults ──────────────────────────────────────────────────
# Top public DNS resolvers — always shown as-is (not personal data).
# Callers may override by passing a custom list to priv_basic_filter().
_PRIV_DEFAULT_WELLKNOWN="8.8.8.8 8.8.4.4 1.1.1.1 1.0.0.1 9.9.9.9 149.112.112.112 208.67.222.222 208.67.220.220 77.88.8.1 77.88.8.8"

# Replace public IPv4 addresses with #.#.#.# and ASN with AS*****.
# Preserves well-known DNS IPs and RFC 1918 / loopback ranges.
# Args: $1 - space-separated well-known IPs to preserve (optional)
#       $2 - "pad" for width-preserving (tables), omit for compact (status/text)
# Reads from stdin, writes to stdout.
priv_mask_ip_asn() {
  local _wellknown="${1:-$_PRIV_DEFAULT_WELLKNOWN}"
  local _pad="${2:-}"
  awk -v wellknown="$_wellknown" -v dopad="$_pad" '
  BEGIN {
    n = split(wellknown, arr, " ")
    for (i = 1; i <= n; i++) wk[arr[i]] = 1
  }
  # Helper: pad string s to width w with spaces
  function pad(s, w) { while (length(s) < w) s = s " "; return s }
  {
    # Pass 1: Mask IPv4 addresses
    line = $0; result = ""
    while (match(line, /[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/)) {
      prefix = substr(line, 1, RSTART - 1)
      ip = substr(line, RSTART, RLENGTH)
      rest = substr(line, RSTART + RLENGTH)
      result = result prefix
      if (ip in wk) {
        result = result ip
      } else {
        split(ip, o, ".")
        # Preserve: RFC 1918, loopback, 0.0.0.0, 255.255.255.255
        if (o[1]+0 == 0 || o[1]+0 == 10 || o[1]+0 == 127 || \
            (o[1]+0 == 172 && o[2]+0 >= 16 && o[2]+0 <= 31) || \
            (o[1]+0 == 192 && o[2]+0 == 168) || \
            (o[1]+0 == 255 && o[2]+0 == 255 && o[3]+0 == 255 && o[4]+0 == 255)) {
          result = result ip
        } else {
          if (dopad == "pad") result = result pad("#.#.#.#", RLENGTH)
          else result = result "#.#.#.#"
        }
      }
      line = rest
    }
    result = result line

    # Pass 2: Mask ASN (AS12345 → AS**** padded to same width)
    line = result; result = ""
    while (match(line, /AS[0-9][0-9]*/)) {
      prefix = substr(line, 1, RSTART - 1)
      rest = substr(line, RSTART + RLENGTH)
      result = result prefix
      if (dopad == "pad") result = result pad("AS****", RLENGTH)
      else result = result "AS****"
      line = rest
    }
    result = result line

    print result
  }'
}

# Mask IPv6 addresses (require ≥3 colon-separated hex groups).
# Args: $1 - "pad" for width-preserving (tables), omit for compact (status/text)
# Reads from stdin, writes to stdout.
priv_mask_ipv6() {
  local _pad="${1:-}"
  awk -v dopad="$_pad" '{
    line = $0; result = ""
    while (match(line, /[0-9a-fA-F]+:[0-9a-fA-F]+:[0-9a-fA-F]+:[0-9a-fA-F:]+/)) {
      prefix = substr(line, 1, RSTART - 1)
      rest = substr(line, RSTART + RLENGTH)
      repl = "#::#"
      if (dopad == "pad") { while (length(repl) < RLENGTH) repl = repl " " }
      result = result prefix repl
      line = rest
    }
    print result line
  }'
}

# Combined basic privacy filter: mask public IPv4, IPv6, and ASN.
# Compact mode (no padding) — suitable for non-table text (bug-report, status).
# Args: $1 - space-separated well-known IPs to preserve (optional)
# Reads from stdin, writes to stdout.
priv_basic_filter() {
  priv_mask_ip_asn "${1:-}" | priv_mask_ipv6
}

# Combined table-aware privacy filter: width-preserving padding.
# For tabular output (net-check tables) where column alignment matters.
# Args: $1 - space-separated well-known IPs to preserve (optional)
# Reads from stdin, writes to stdout.
priv_table_filter() {
  priv_mask_ip_asn "${1:-}" "pad" | priv_mask_ipv6 "pad"
}

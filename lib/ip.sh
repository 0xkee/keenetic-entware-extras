#!/opt/bin/sh
# lib/ip.sh - IP/CIDR manipulation library (aggregation, conversion)
# Source: . ./lib/ip.sh
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
set -eu

# Parse CIDR lines to numeric ranges.
# stdin: CIDR lines; stdout: "start end" decimal per line.
# Invalid lines silently skipped.
_cidr_to_ranges() {
  awk '
    /^[[:space:]]*($|#)/ { next }
    {
      sub(/#.*/, "")
      gsub(/[[:space:]]/, "")
      if ($0 == "") next

      n = split($0, parts, "/")
      if (n != 2) next
      prefix = int(parts[2])
      if (prefix < 0 || prefix > 32) next

      m = split(parts[1], o, ".")
      if (m != 4) next
      for (i = 1; i <= 4; i++)
        if (o[i] < 0 || o[i] > 255) next

      ip = o[1]*16777216 + o[2]*65536 + o[3]*256 + o[4]

      ms = 1
      for (i = 0; i < 32 - prefix; i++) ms *= 2

      start = ip - (ip % ms)
      print start, start + ms - 1
    }
  '
}

# Merge sorted ranges, emit minimal CIDRs.
# stdin: sorted "start end" lines; stdout: CIDR lines.
# Uses precomputed pow2[] table - saves ~33% time vs loop computation.
_merge_and_emit_cidrs() {
  awk '
    BEGIN { p2[0] = 1; for (i = 1; i <= 32; i++) p2[i] = p2[i-1] * 2 }

    function emit(s, e,    ab, sb, k, a, b, c, d, tmp) {
      while (s <= e) {
        if (s == 0) { ab = 32 }
        else { ab = 0; tmp = s; while (tmp % 2 == 0) { ab++; tmp /= 2 } }

        sb = 0
        while (sb < 32 && p2[sb + 1] <= e - s + 1) sb++

        k = (ab < sb) ? ab : sb

        a = int(s / 16777216) % 256
        b = int(s / 65536) % 256
        c = int(s / 256) % 256
        d = int(s) % 256
        printf "%d.%d.%d.%d/%d\n", a, b, c, d, 32 - k

        s = s + p2[k]
      }
    }

    NR == 1 { ms = $1; me = $2; next }
    {
      if ($1 <= me + 1) { if ($2 > me) me = $2 }
      else { emit(ms, me); ms = $1; me = $2 }
    }
    END { if (NR > 0) emit(ms, me) }
  '
}

# Pipe filter: aggregate (merge overlapping/adjacent) CIDR subnets.
# Strict: only exact merges, no supernetting.
# stdin: CIDR lines (one per line, comments/blanks skipped)
# stdout: minimal set of CIDRs covering the same IP space
list_aggregate_cidrs() {
  _cidr_to_ranges | sort -n | _merge_and_emit_cidrs
}

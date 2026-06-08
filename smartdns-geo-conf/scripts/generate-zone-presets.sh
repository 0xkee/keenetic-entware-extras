#!/bin/bash
# Generate smartdns zone preset files for ALL countries.
# Creates config/zones/<cc>.conf for each ISO 3166-1 alpha-2 code.
# Skips already existing hand-curated presets (unless --force).
# Run once on dev machine, then commit generated files.
#
# Usage: ./smartdns-geo-conf/scripts/generate-zone-presets.sh [--force]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ZONES_DIR="$SCRIPT_DIR/../config/zones"
FORCE="${1:-}"

mkdir -p "$ZONES_DIR"

# ===================================================================
# All ISO 3166-1 alpha-2 codes available on ipdeny.com (~240 countries)
# ===================================================================
ALL_COUNTRIES="
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
"

# ===================================================================
# DNS type classification
# ===================================================================
# CIS countries: Yandex + AdGuard (best regional coverage for CIS)
CIS="am az by kg kz md ru tj tm uz"

# China: AliDNS + Tencent DNSPod
CN="cn"

# Template: CIS (Yandex DoT + AdGuard DoT)
tpl_cis() {
  local cc="$1"
  cat <<EOF
# --- Upstream DNS servers for ${cc} group ---

# Yandex DoT (CIS coverage, CDN presence)
server-tls 77.88.8.8:853 -group ${cc} -exclude-default-group \\
    -host-name common.dot.dns.yandex.net \\
    -tls-host-verify common.dot.dns.yandex.net

server-tls 77.88.8.1:853 -group ${cc} -exclude-default-group \\
    -host-name common.dot.dns.yandex.net \\
    -tls-host-verify common.dot.dns.yandex.net

# AdGuard Non-filtering DoT (CIS coverage)
server-tls 94.140.14.140:853 -group ${cc} -exclude-default-group \\
    -host-name unfiltered.adguard-dns.com \\
    -tls-host-verify unfiltered.adguard-dns.com

# UDP fallback (Yandex)
server 77.88.8.8 -group ${cc} -exclude-default-group
server 77.88.8.1 -group ${cc} -exclude-default-group
EOF
}

# Template: China (AliDNS + Tencent)
tpl_cn() {
  cat <<EOF
# --- Upstream DNS servers for cn group ---

# AliDNS DoT (Alibaba Cloud, mainland)
server-tls 223.5.5.5:853 -group cn -exclude-default-group \\
    -host-name dns.alidns.com \\
    -tls-host-verify dns.alidns.com

server-tls 223.6.6.6:853 -group cn -exclude-default-group \\
    -host-name dns.alidns.com \\
    -tls-host-verify dns.alidns.com

# Tencent DNSPod DoT (mainland)
server-tls 1.12.12.12:853 -group cn -exclude-default-group \\
    -host-name dot.pub \\
    -tls-host-verify dot.pub

# UDP fallback
server 223.5.5.5 -group cn -exclude-default-group
server 119.29.29.29 -group cn -exclude-default-group
EOF
}

# Template: Default (Cloudflare + Google — global anycast)
tpl_default() {
  local cc="$1"
  cat <<EOF
# --- Upstream DNS servers for ${cc} group ---

# Cloudflare DoT (global anycast, geo-optimized responses)
server-tls 1.1.1.1:853 -group ${cc} -exclude-default-group \\
    -host-name cloudflare-dns.com \\
    -tls-host-verify cloudflare-dns.com

server-tls 1.0.0.1:853 -group ${cc} -exclude-default-group \\
    -host-name cloudflare-dns.com \\
    -tls-host-verify cloudflare-dns.com

# Google DoT (global anycast)
server-tls 8.8.8.8:853 -group ${cc} -exclude-default-group \\
    -host-name dns.google \\
    -tls-host-verify dns.google

server-tls 8.8.4.4:853 -group ${cc} -exclude-default-group \\
    -host-name dns.google \\
    -tls-host-verify dns.google

# UDP fallback
server 1.1.1.1 -group ${cc} -exclude-default-group
server 8.8.8.8 -group ${cc} -exclude-default-group
EOF
}

# ===================================================================
# IDN TLDs (additional TLDs beyond .<cc>)
# ===================================================================
idn_tlds() {
  local cc="$1"
  case "$cc" in
    ru) echo ".xn--p1ai .su" ;;  # .rf .su
    ua) echo ".xn--j1amh" ;;
    cn) echo ".xn--fiqs8s .xn--fiqz9s" ;;
    eg) echo ".xn--wgbh1c" ;;
    qa) echo ".xn--wgbl6a" ;;
    il) echo ".xn--4dbrk0ce" ;;
    in) echo ".xn--h2brj9c" ;;
    kr) echo ".xn--3e0b707e" ;;
    th) echo ".xn--o3cw4h" ;;
    ge) echo ".xn--node" ;;
    sa) echo ".xn--mgbaam7a8h" ;;
    ae) echo ".xn--mgbaam7a8h" ;;
    ir) echo ".xn--mgba3a4f16a" ;;
    *) echo "" ;;
  esac
}

# ===================================================================
# Generate one zone file
# ===================================================================
generate_zone() {
  local cc="$1"
  local zone_file="$ZONES_DIR/${cc}.conf"
  local cc_upper
  cc_upper="$(echo "$cc" | tr '[:lower:]' '[:upper:]')"

  # Skip existing unless --force
  if [ -f "$zone_file" ] && [ "$FORCE" != "--force" ]; then
    return 1
  fi

  {
    echo "# Zone: ${cc_upper} — DNS servers + nameserver routing rules."
    echo "# Part of smartdns-geo-conf. Included via dns-zones-active.conf."
    echo ""

    # Select DNS template
    if [ "$cc" = "cn" ]; then
      tpl_cn
    elif echo " $CIS " | grep -q " $cc "; then
      tpl_cis "$cc"
    else
      tpl_default "$cc"
    fi

    echo ""
    echo "# --- Nameserver routing rules (${cc_upper}) ---"
    echo "nameserver /.${cc}/${cc}"

    # Add IDN TLDs
    local extra
    extra="$(idn_tlds "$cc")"
    if [ -n "$extra" ]; then
      for tld in $extra; do
        echo "nameserver /${tld}/${cc}"
      done
    fi
  } > "$zone_file"

  return 0
}

# ===================================================================
# Main
# ===================================================================
echo "=== Generating zone configs ==="
created=0
skipped=0

for cc in $ALL_COUNTRIES; do
  if generate_zone "$cc"; then
    created=$((created + 1))
  else
    skipped=$((skipped + 1))
  fi
done

total=$(ls "$ZONES_DIR"/*.conf 2>/dev/null | grep -cv test-domains || true)
echo "Created: $created, Skipped (existing): $skipped, Total zone files: $total"

# Patch zone headers with flag emojis + country names (for WebUI zone_selector)
PATCH_SCRIPT="$SCRIPT_DIR/patch-zone-labels.py"
if [ -f "$PATCH_SCRIPT" ] && command -v python3 >/dev/null 2>&1; then
  python3 "$PATCH_SCRIPT"
fi

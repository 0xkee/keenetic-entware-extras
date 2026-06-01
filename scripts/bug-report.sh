#!/opt/bin/sh
# bug-report.sh — collect diagnostics for forum bug reports
# Output is safe to post publicly (no passwords, keys, or WAN IPs).
set -eu

BASE="/opt/keenetic-entware-extras"
# shellcheck disable=SC1091
. "$BASE/lib/ip.sh"
SEP="──────────────────────────────────────────────"

section() {
    printf "\n%s\n  %s\n%s\n" "$SEP" "$1" "$SEP"
}


# ─── 1. System info ──────────────────────────────────────────────────────────

section "System"

printf "Date: %s\n" "$(date '+%Y-%m-%d %H:%M:%S %Z')"

if command -v ndmc >/dev/null 2>&1; then
    printf "\nFirmware:\n"
    ndmc -c "show version" 2>/dev/null \
        | grep -E "^\s+(title|release|arch|cores|model|hw_id|hw_version|sandbox)" \
        | head -10 || echo "  (ndmc unavailable)"
else
    echo "ndmc: not found"
fi

printf "\nKernel: %s\n" "$(uname -r 2>/dev/null || echo 'unknown')"
printf "Arch:   %s\n" "$(uname -m 2>/dev/null || echo 'unknown')"

# ─── 2. Memory & disk ────────────────────────────────────────────────────────

section "Memory & disk"

printf "Memory:\n"
if [ -f /proc/meminfo ]; then
    mem_total="$(grep MemTotal /proc/meminfo | awk '{print $2}')"
    mem_avail="$(grep MemAvailable /proc/meminfo | awk '{print $2}')"
    if [ -n "$mem_total" ] && [ -n "$mem_avail" ]; then
        mem_used=$((mem_total - mem_avail))
        printf "  Total: %d kB, Used: %d kB, Available: %d kB (%d%% used)\n" \
            "$mem_total" "$mem_used" "$mem_avail" \
            "$((mem_used * 100 / mem_total))"
    else
        cat /proc/meminfo | head -5
    fi
else
    free 2>/dev/null || echo "  (unavailable)"
fi

printf "\nDisk (/opt):\n"
df -h /opt 2>/dev/null | tail -1 | awk '{printf "  Size: %s, Used: %s, Avail: %s (%s used)\n", $2, $3, $4, $5}' \
    || echo "  (unavailable)"

# ─── 3. Installed packages ───────────────────────────────────────────────────

section "Installed packages (related)"

if command -v opkg >/dev/null 2>&1; then
    opkg list-installed 2>/dev/null \
        | grep -E "geo-split|smartdns|webui|keenetic-entware|nginx|^cron |^aggregate |^bind-dig |^ca-certificates |^curl |^ip-full |^iptables |^logrotate " \
        || echo "  (none found)"
else
    echo "opkg: not found"
fi

# ─── 4. Service status ───────────────────────────────────────────────────────

section "Service status"

if [ -x "$BASE/scripts/kee-status.sh" ]; then
    "$BASE/scripts/kee-status.sh" -d -n 2>&1 | head -200 || true
elif [ -x /opt/bin/kee-status ]; then
    /opt/bin/kee-status -d -n 2>&1 | head -200 || true
else
    echo "kee-status.sh not found, running individual status scripts..."
    for script in "$BASE"/*/scripts/status.sh; do
        [ -x "$script" ] || continue
        pkg="$(echo "$script" | sed "s|$BASE/||;s|/scripts/status.sh||")"
        printf "\n--- %s ---\n" "$pkg"
        "$script" 2>&1 | head -50 || true
    done
fi

# ─── 5. DNS check ────────────────────────────────────────────────────────────

section "DNS check"

# SmartDNS direct (port 6053)
printf "SmartDNS direct (:6053):\n"
if command -v dig >/dev/null 2>&1; then
    printf "  ya.ru:      "
    dig ya.ru @127.0.0.1 -p 6053 +short +time=3 2>&1 | head -1 || echo "FAILED"
    printf "  google.com: "
    dig google.com @127.0.0.1 -p 6053 +short +time=3 2>&1 | head -1 || echo "FAILED"
elif command -v nslookup >/dev/null 2>&1; then
    printf "  ya.ru:      "
    nslookup ya.ru 127.0.0.1#6053 2>/dev/null | grep "Address" | tail -1 | awk '{print $2}' || echo "FAILED"
    printf "  google.com: "
    nslookup google.com 127.0.0.1#6053 2>/dev/null | grep "Address" | tail -1 | awk '{print $2}' || echo "FAILED"
else
    echo "  dig/nslookup: not installed"
fi

# System resolver (end-to-end)
printf "\nSystem resolver (end-to-end):\n"
if command -v dig >/dev/null 2>&1; then
    printf "  ya.ru:      "
    dig ya.ru +short +time=3 2>&1 | head -1 || echo "FAILED"
    printf "  google.com: "
    dig google.com +short +time=3 2>&1 | head -1 || echo "FAILED"
elif command -v nslookup >/dev/null 2>&1; then
    printf "  ya.ru:      "
    nslookup ya.ru 2>/dev/null | grep "Address" | tail -1 | awk '{print $2}' || echo "FAILED"
    printf "  google.com: "
    nslookup google.com 2>/dev/null | grep "Address" | tail -1 | awk '{print $2}' || echo "FAILED"
else
    echo "  (no DNS tools available)"
fi

printf "\n/tmp/resolv.conf:\n"
if [ -f /tmp/resolv.conf ]; then
    sed 's/^/  /' /tmp/resolv.conf | head -10
elif [ -f /etc/resolv.conf ]; then
    sed 's/^/  /' /etc/resolv.conf | head -10
else
    echo "  (not found)"
fi

# ─── 6. Connectivity ─────────────────────────────────────────────────────────

section "Connectivity"

check_url() {
    url="$1"
    label="$2"
    if command -v curl >/dev/null 2>&1; then
        code="$(curl -so /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$url" 2>/dev/null)" || code="000"
        printf "  %s → %s\n" "$label" "$code"
    elif command -v wget >/dev/null 2>&1; then
        if wget -q --spider --timeout=5 "$url" 2>/dev/null; then
            printf "  %s → OK\n" "$label"
        else
            printf "  %s → FAIL\n" "$label"
        fi
    fi
}

if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
    check_url "http://ya.ru" "ya.ru (RU)"
    check_url "http://google.com" "google.com (INT)"
    check_url "http://rutracker.org" "rutracker.org (blocked)"
else
    echo "  curl/wget: not installed"
fi

# ─── 7. Routes & rules (geo-split) ──────────────────────────────────────────

section "Routes & rules"

if command -v ip >/dev/null 2>&1; then
    printf "ip rules (geo-split):\n"
    ip rule show 2>/dev/null | grep -E "1000|1001" | head -10 || echo "  (no geo-split rules)"

    printf "\nRoute counts:\n"
    printf "  table 1000 (domains):  %s routes\n" \
        "$(table_route_count 1000)"
    printf "  table 1001 (subnets):  %s routes\n" \
        "$(table_route_count 1001)"

    printf "\nDefault gateway (table 1000): "
    gw="$(ip route show table 1000 2>/dev/null | grep "^default" | head -1)"
    printf "%s\n" "${gw:-(no default — host routes only)}"
    printf "Default gateway (table 1001): "
    gw="$(ip route show table 1001 2>/dev/null | grep "^default" | head -1)"
    printf "%s\n" "${gw:-(no default — host routes only)}"

    printf "\nSample routes (table 1000, first 3):\n"
    ip route show table 1000 2>/dev/null | head -3 | sed 's/^/  /'
else
    echo "ip: not found"
fi

# ─── 8. Netfilter rules (smartdns-redirect) ─────────────────────────────────

section "Netfilter (DNS redirect)"

if command -v iptables >/dev/null 2>&1; then
    printf "iptables NAT (DNAT/REDIRECT :53):\n"
    iptables -t nat -L PREROUTING -n --line-numbers 2>/dev/null \
        | grep -E "53|smartdns|REDIRECT|DNAT" | head -20 || echo "  (no DNS redirect rules)"
else
    echo "iptables: not found"
fi

# ─── 9. Network interfaces ──────────────────────────────────────────────────

section "Network interfaces (UP only, no IPs)"

if command -v ip >/dev/null 2>&1; then
    # Show interface names & state only (no addresses = no leaks)
    ip -brief link show 2>/dev/null | grep -v "DOWN" | awk '{printf "%-16s %s\n", $1, $2}' | head -30

    # Show only private (safe) LAN assignments for key bridges
    printf "\nLAN assignments:\n"
    ip -brief addr show 2>/dev/null \
        | grep -E "^(br|lo)" \
        | awk '{printf "  %-16s", $1; for(i=3;i<=NF;i++){if($i~/^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|127\.|fe80:|fd)/)printf " %s",$i}; printf "\n"}' \
        | head -10
else
    echo "  (ip command not found)"
fi

# ─── 10. Logs (last 20 lines) ────────────────────────────────────────────────

section "Logs (tail)"

if [ -f /tmp/smartdns.log ]; then
    printf "\n--- /tmp/smartdns.log (last 15 errors) ---\n"
    grep -i "error\|fail\|warn" /tmp/smartdns.log 2>/dev/null | tail -15 || echo "  (no errors)"
fi

if [ -f /tmp/nginx-webui-error.log ]; then
    printf "\n--- /tmp/nginx-webui-error.log (last 10) ---\n"
    tail -10 /tmp/nginx-webui-error.log 2>/dev/null || true
fi

if [ -f /opt/var/log/geo-split.log ]; then
    printf "\n--- /opt/var/log/geo-split.log (last 10) ---\n"
    tail -10 /opt/var/log/geo-split.log 2>/dev/null || true
fi

if command -v logread >/dev/null 2>&1; then
    printf "\n--- logread (geo-split|smartdns|nginx-webui, last 15) ---\n"
    logread 2>/dev/null | grep -E "geo-split|smartdns|nginx-webui" | tail -15 || echo "  (nothing)"
fi

# ─── Footer ──────────────────────────────────────────────────────────────────

printf "\n%s\n" "$SEP"
echo "Bug report collected. Copy everything above and paste into the forum topic."
echo "No passwords, WAN IPs, or private keys are included in this output."
echo "If you see any info you consider private, replace it with *** before posting."
printf "%s\n" "$SEP"

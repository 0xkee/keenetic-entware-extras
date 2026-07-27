#!/opt/bin/sh
# smartdns-redirect watchdog — called periodically by cron (*/5 min).
# Checks: (1) expected iptables rules present, (2) upstream DNS responsive.
# Recovers by reloading dns-redirect.sh and/or restarting WATCHDOG_SERVICE.
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
# shellcheck disable=SC1091  # sourced files resolved at runtime on router
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
_CONFIG_DIR="$(cd "$SCRIPT_DIR/../config" && pwd)"
. "$_CONFIG_DIR/defaults.conf"
[ -f "$_CONFIG_DIR/config.conf" ] && . "$_CONFIG_DIR/config.conf"

# Guard: exit if user disabled the service
is_service_enabled "S39smartdns-redirect" || exit 0

# Exit silently if disabled (empty INTERFACES == package inactive).
[ -n "${INTERFACES:-}" ] || exit 0

: "${UPSTREAM_PORT:=6053}"

DNS_REDIRECT_SCRIPT="$SCRIPT_DIR/dns-redirect.sh"

# Detect router LAN IP for DNAT rule check (must match dns-redirect.sh).
ROUTER_IP="$(detect_router_ip)"
ROUTER_IP6=""
if command -v ip6tables >/dev/null 2>&1; then
    ROUTER_IP6="$(detect_router_ip6)"
fi

# --- IPv6 auto-detection (same logic as dns-redirect.sh) ---

# Check if we can DNAT IPv6 DNS to SmartDNS.
can_dnat_ipv6() {
    command -v ip6tables >/dev/null 2>&1 || return 1
    [ -n "$ROUTER_IP6" ] || return 1
    grep -q 'bind \[' /opt/etc/smartdns/bind-addrs.conf 2>/dev/null || return 1
    return 0
}

# --- helpers ---

# Check if a single rule exists.
# Args: $1 - rule type ("v4_dnat"|"v6_dnat"|"v6_reject"), $2 - iface, $3 - proto
rule_exists() {
    local rtype="$1" iface="$2" proto="$3"
    case "$rtype" in
        v4_dnat)
            iptables -t nat -C PREROUTING -i "$iface" -p "$proto" --dport 53 \
                -j DNAT --to-destination "${ROUTER_IP}:${UPSTREAM_PORT}" 2>/dev/null
            ;;
        v6_dnat)
            ip6tables -t nat -C PREROUTING -i "$iface" -p "$proto" --dport 53 \
                -j DNAT --to-destination "[${ROUTER_IP6}]:${UPSTREAM_PORT}" 2>/dev/null
            ;;
        v6_reject)
            ip6tables -C INPUT -i "$iface" -p "$proto" --dport 53 \
                -j REJECT --reject-with icmp6-port-unreachable 2>/dev/null
            ;;
        *)  return 1 ;;
    esac
}

# Returns 0 if any expected rule is missing (i.e. reload needed).
any_rule_missing() {
    local iface proto v6_type
    for iface in $INTERFACES; do
        for proto in udp tcp; do
            rule_exists "v4_dnat" "$iface" "$proto" || return 0
        done
    done
    # IPv6: check based on auto-detected mode
    if command -v ip6tables >/dev/null 2>&1; then
        if can_dnat_ipv6; then
            v6_type="v6_dnat"
        else
            v6_type="v6_reject"
        fi
        for iface in $INTERFACES; do
            for proto in udp tcp; do
                rule_exists "$v6_type" "$iface" "$proto" || return 0
            done
        done
    fi
    return 1
}

# Check upstream DNS responsiveness on 127.0.0.1:UPSTREAM_PORT.
# Returns 0 if responsive, 1 if not. Returns 0 when no probe tool is
# available to avoid false positives (no remediation on unknown state).
upstream_responsive() {
    if command -v dig >/dev/null 2>&1; then
        dig @127.0.0.1 -p "$UPSTREAM_PORT" +time=2 +tries=1 +short example.com \
            >/dev/null 2>&1 && return 0
        return 1
    fi
    # Fallback: port listening (weaker — process may be alive but stuck).
    if command -v netstat >/dev/null 2>&1; then
        netstat -lnu 2>/dev/null | awk '{print $4}' \
            | grep -qE "(^|:)${UPSTREAM_PORT}\$" && return 0
        return 1
    fi
    # No tools — assume OK.
    return 0
}

restart_upstream_service() {
    [ -n "${WATCHDOG_SERVICE:-}" ] || return 0
    local svc="/opt/etc/init.d/$WATCHDOG_SERVICE"
    if [ -x "$svc" ]; then
        log "upstream :$UPSTREAM_PORT not responding, restarting $WATCHDOG_SERVICE"
        "$svc" restart || log_error "failed to restart $WATCHDOG_SERVICE"
    else
        log_error "WATCHDOG_SERVICE='$WATCHDOG_SERVICE' but $svc not executable"
    fi
}

# --- main ---

# Check 1: expected iptables/ip6tables rules present?
if any_rule_missing; then
    log "iptables rule missing, reloading via dns-redirect.sh"
    "$DNS_REDIRECT_SCRIPT" reload || log_error "reload failed"
fi

# Check 2: upstream responsive?
if ! upstream_responsive; then
    restart_upstream_service
fi

#!/opt/bin/sh
# smartdns-redirect — DNAT LAN DNS (:53) to local resolver (e.g. SmartDNS :6053).
# Idempotent: repeated start does not duplicate rules (iptables -C guard).
# IPv6: fully automatic — DNAT when SmartDNS has IPv6 bind, REJECT otherwise
#       (instant Happy Eyeballs fallback to IPv4 DNAT).
# Subcommands: start | stop | reload | restart
# Config:      $SCRIPT_DIR/../config/defaults.conf (sourced)
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
# shellcheck disable=SC1091  # sourced files resolved at runtime on router
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
_CONFIG_DIR="${SCRIPT_DIR%/*}/config"
. "$_CONFIG_DIR/defaults.conf"
[ -f "$_CONFIG_DIR/config.conf" ] && . "$_CONFIG_DIR/config.conf"

# --- backwards compatibility: ignore legacy ENABLE_IPV6 ---
if [ "${ENABLE_IPV6:-}" = "yes" ]; then
    log "ENABLE_IPV6 is deprecated and ignored. IPv6 is now automatic."
fi

# --- config validation ---
case "${UPSTREAM_PORT:-}" in
    ''|*[!0-9]*)
        log_error "invalid UPSTREAM_PORT='${UPSTREAM_PORT:-}' (must be integer)"
        exit 1
        ;;
esac
if [ "$UPSTREAM_PORT" -lt 1 ] || [ "$UPSTREAM_PORT" -gt 65535 ]; then
    log_error "UPSTREAM_PORT=$UPSTREAM_PORT out of range (1..65535)"
    exit 1
fi
: "${INTERFACES:=}"

require_cmd iptables

# Detect router LAN IP for DNAT target.
# DNAT to br0 IP ensures SmartDNS receives the packet regardless of which
# interface it arrived on (br0, br1, nwg1, etc.) — unlike REDIRECT which
# sends to the primary IP of the *incoming* interface (may not have SmartDNS).
ROUTER_IP="$(detect_router_ip)"
if [ -z "$ROUTER_IP" ]; then
    log_error "cannot detect router LAN IP (br0) — DNAT target unknown"
    exit 1
fi

# IPv6 auto-detection (set ROUTER_IP6 for use by helpers)
ROUTER_IP6=""
if command -v ip6tables >/dev/null 2>&1; then
    ROUTER_IP6="$(detect_router_ip6)"
fi

# --- IPv6 auto-detection logic ---

# Check if we can DNAT IPv6 DNS to SmartDNS.
# Conditions: ip6tables available + global IPv6 on br0 + SmartDNS IPv6 bind.
can_dnat_ipv6() {
    command -v ip6tables >/dev/null 2>&1 || return 1
    [ -n "$ROUTER_IP6" ] || return 1
    # SmartDNS IPv6 bind (managed by smartdns-geo-conf postinst)
    grep -q 'bind \[' /opt/etc/smartdns/bind-addrs.conf 2>/dev/null || return 1
    return 0
}

# --- rule manipulation helpers (IPv4) ---

# Idempotent insert at index 1. No-op if the rule already exists.
# In "local" mode, only intercept DNS targeted at router IP (-d $ROUTER_IP).
# Args: $1 - interface, $2 - protocol (udp|tcp)
add_rule_if_missing() {
    local iface="$1" proto="$2"
    if [ "${REDIRECT_MODE:-force}" = "local" ]; then
        # local mode: only intercept DNS targeted at router IP
        if iptables -t nat -C PREROUTING -i "$iface" -p "$proto" -d "$ROUTER_IP" --dport 53 \
                -j DNAT --to-destination "${ROUTER_IP}:${UPSTREAM_PORT}" 2>/dev/null; then
            return 0
        fi
        iptables -t nat -I PREROUTING 1 -i "$iface" -p "$proto" -d "$ROUTER_IP" --dport 53 \
            -j DNAT --to-destination "${ROUTER_IP}:${UPSTREAM_PORT}"
        log "added (local): -i $iface -p $proto -d $ROUTER_IP --dport 53 -> DNAT ${ROUTER_IP}:${UPSTREAM_PORT}"
    else
        # force mode: intercept ALL DNS
        if iptables -t nat -C PREROUTING -i "$iface" -p "$proto" --dport 53 \
                -j DNAT --to-destination "${ROUTER_IP}:${UPSTREAM_PORT}" 2>/dev/null; then
            return 0
        fi
        iptables -t nat -I PREROUTING 1 -i "$iface" -p "$proto" --dport 53 \
            -j DNAT --to-destination "${ROUTER_IP}:${UPSTREAM_PORT}"
        log "added: -i $iface -p $proto --dport 53 -> DNAT ${ROUTER_IP}:${UPSTREAM_PORT}"
    fi
}

# --- rule manipulation helpers (IPv6 DNAT mode) ---

# Idempotent IPv6 DNAT rule. Used when SmartDNS listens on IPv6.
# In "local" mode, only intercept DNS targeted at router IPv6 (-d $ROUTER_IP6).
# Args: $1 - interface, $2 - protocol (udp|tcp)
add_v6_dnat_rule() {
    local iface="$1" proto="$2"
    if [ "${REDIRECT_MODE:-force}" = "local" ]; then
        if ip6tables -t nat -C PREROUTING -i "$iface" -p "$proto" -d "$ROUTER_IP6" --dport 53 \
                -j DNAT --to-destination "[${ROUTER_IP6}]:${UPSTREAM_PORT}" 2>/dev/null; then
            return 0
        fi
        ip6tables -t nat -I PREROUTING 1 -i "$iface" -p "$proto" -d "$ROUTER_IP6" --dport 53 \
            -j DNAT --to-destination "[${ROUTER_IP6}]:${UPSTREAM_PORT}"
        log "added (v6 dnat local): -i $iface -p $proto -d $ROUTER_IP6 --dport 53 -> DNAT [${ROUTER_IP6}]:${UPSTREAM_PORT}"
    else
        if ip6tables -t nat -C PREROUTING -i "$iface" -p "$proto" --dport 53 \
                -j DNAT --to-destination "[${ROUTER_IP6}]:${UPSTREAM_PORT}" 2>/dev/null; then
            return 0
        fi
        ip6tables -t nat -I PREROUTING 1 -i "$iface" -p "$proto" --dport 53 \
            -j DNAT --to-destination "[${ROUTER_IP6}]:${UPSTREAM_PORT}"
        log "added (v6 dnat): -i $iface -p $proto --dport 53 -> DNAT [${ROUTER_IP6}]:${UPSTREAM_PORT}"
    fi
}

# --- rule manipulation helpers (DoT blocking — FORWARD REJECT :853) ---

# Idempotent FORWARD REJECT for DoT (port 853) — always-on alongside DNAT :53.
# Prevents LAN clients from bypassing SmartDNS via direct DNS-over-TLS.
# Args: $1 - interface, $2 - protocol (udp|tcp)
add_dot_block_rule() {
    local iface="$1" proto="$2"
    if iptables -C FORWARD -i "$iface" -p "$proto" --dport 853 \
            -j REJECT --reject-with icmp-port-unreachable 2>/dev/null; then
        return 0
    fi
    iptables -I FORWARD 1 -i "$iface" -p "$proto" --dport 853 \
        -j REJECT --reject-with icmp-port-unreachable
    log "dot-block: added -i $iface -p $proto --dport 853 -> REJECT"
}

# IPv6 variant: FORWARD REJECT for DoT (port 853).
# Args: $1 - interface, $2 - protocol (udp|tcp)
add_dot_block_v6_rule() {
    local iface="$1" proto="$2"
    if ip6tables -C FORWARD -i "$iface" -p "$proto" --dport 853 \
            -j REJECT --reject-with icmp6-port-unreachable 2>/dev/null; then
        return 0
    fi
    ip6tables -I FORWARD 1 -i "$iface" -p "$proto" --dport 853 \
        -j REJECT --reject-with icmp6-port-unreachable
    log "dot-block: added (v6) -i $iface -p $proto --dport 853 -> REJECT"
}

# --- rule manipulation helpers (IPv6 REJECT mode) ---

# Idempotent IPv6 INPUT REJECT rule. Blocks IPv6 DNS to router → client falls
# back to IPv4 via Happy Eyeballs (instant, <50ms).
# Args: $1 - interface, $2 - protocol (udp|tcp)
add_v6_reject_input() {
    local iface="$1" proto="$2"
    if ip6tables -C INPUT -i "$iface" -p "$proto" --dport 53 \
            -j REJECT --reject-with icmp6-port-unreachable 2>/dev/null; then
        return 0
    fi
    ip6tables -I INPUT 1 -i "$iface" -p "$proto" --dport 53 \
        -j REJECT --reject-with icmp6-port-unreachable
    log "added (v6 reject): -i $iface -p $proto --dport 53 -> REJECT"
}

# --- add/remove orchestration ---

add_rules() {
    local iface proto

    # IPv4 DNAT (unchanged)
    for iface in $INTERFACES; do
        for proto in udp tcp; do
            add_rule_if_missing "$iface" "$proto"
        done
    done

    # IPv6 — fully automatic
    if command -v ip6tables >/dev/null 2>&1; then
        if can_dnat_ipv6; then
            for iface in $INTERFACES; do
                for proto in udp tcp; do
                    add_v6_dnat_rule "$iface" "$proto"
                done
            done
            log "IPv6 DNS: DNAT to [${ROUTER_IP6}]:${UPSTREAM_PORT}"
        else
            for iface in $INTERFACES; do
                for proto in udp tcp; do
                    add_v6_reject_input "$iface" "$proto"
                done
            done
            log "IPv6 DNS: REJECT on INPUT (no IPv6 DNAT target)"
        fi
    fi

    # DoT blocking: only in "force" mode (prevents bypassing SmartDNS via DoT).
    # In "local" mode, DoT :853 passes through (permissive).
    if [ "${REDIRECT_MODE:-force}" = "force" ]; then
        for iface in $INTERFACES; do
            for proto in tcp udp; do
                add_dot_block_rule "$iface" "$proto"
            done
        done
        if command -v ip6tables >/dev/null 2>&1; then
            for iface in $INTERFACES; do
                for proto in tcp udp; do
                    add_dot_block_v6_rule "$iface" "$proto"
                done
            done
        fi
        log "dot-block: DoT (:853) blocked on FORWARD for: $INTERFACES"
    fi
}

# Remove ALL our DNS DNAT/REDIRECT rules for dport 53 (any port, any iface).
# Also removes DoT blocking FORWARD REJECT rules for dport 853.
# Used by stop/reload so they fully clean up after any previous config
# (different UPSTREAM_PORT, different INTERFACES, stale v6 rules).
# Matches both DNAT (current) and legacy REDIRECT rules for clean upgrade.
del_all_rules() {
    local line rest
    iptables -t nat -S PREROUTING 2>/dev/null \
        | grep -E '^-A PREROUTING .*--dport 53 .*-j (DNAT|REDIRECT) ' \
        | while IFS= read -r line; do
            rest=${line#-A PREROUTING }
            # shellcheck disable=SC2086
            if iptables -t nat -D PREROUTING $rest 2>/dev/null; then
                log "removed: $rest"
            fi
        done
    # DoT blocking: FORWARD REJECT :853 (always clean up)
    iptables -S FORWARD 2>/dev/null \
        | grep -E '^-A FORWARD .*--dport 853 .*-j REJECT' \
        | while IFS= read -r line; do
            rest=${line#-A FORWARD }
            # shellcheck disable=SC2086
            if iptables -D FORWARD $rest 2>/dev/null; then
                log "dot-block: removed $rest"
            fi
        done
    # IPv6 (always try if ip6tables available — defensive cleanup)
    if command -v ip6tables >/dev/null 2>&1; then
        # IPv6 nat PREROUTING (DNAT mode)
        ip6tables -t nat -S PREROUTING 2>/dev/null \
            | grep -E '^-A PREROUTING .*--dport 53 .*-j (DNAT|REDIRECT) ' \
            | while IFS= read -r line; do
                rest=${line#-A PREROUTING }
                # shellcheck disable=SC2086
                if ip6tables -t nat -D PREROUTING $rest 2>/dev/null; then
                    log "removed (v6 nat): $rest"
                fi
            done
        # IPv6 filter INPUT (REJECT mode)
        ip6tables -S INPUT 2>/dev/null \
            | grep -E '^-A INPUT .*--dport 53 .*-j REJECT' \
            | while IFS= read -r line; do
                rest=${line#-A INPUT }
                # shellcheck disable=SC2086
                if ip6tables -D INPUT $rest 2>/dev/null; then
                    log "removed (v6 input): $rest"
                fi
            done
        # IPv6 DoT blocking: FORWARD REJECT :853
        ip6tables -S FORWARD 2>/dev/null \
            | grep -E '^-A FORWARD .*--dport 853 .*-j REJECT' \
            | while IFS= read -r line; do
                rest=${line#-A FORWARD }
                # shellcheck disable=SC2086
                if ip6tables -D FORWARD $rest 2>/dev/null; then
                    log "dot-block: removed (v6) $rest"
                fi
            done
    fi
}

# Exit cleanly if INTERFACES is empty (explicit disable via config).
check_interfaces_empty() {
    if [ -z "$INTERFACES" ]; then
        log "disabled (INTERFACES='')"
        exit 0
    fi
}

# --- dispatcher ---
case "${1:-}" in
    start)
        check_interfaces_empty
        add_rules
        ;;
    stop)
        del_all_rules
        ;;
    reload|restart)
        del_all_rules
        check_interfaces_empty
        add_rules
        ;;
    *)
        echo "usage: $0 {start|stop|restart|reload}" >&2
        exit 1
        ;;
esac

#!/opt/bin/sh
# smartdns-redirect — DNAT LAN DNS (:53) to local resolver (e.g. SmartDNS :6053).
# Idempotent: repeated start does not duplicate rules (iptables -C guard).
# Subcommands: start | stop | reload | restart
# Config:      $SCRIPT_DIR/../config/defaults.conf (sourced)
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
# shellcheck disable=SC1091  # sourced files resolved at runtime on router
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/../../lib/common.sh"
_CONFIG_DIR="$(cd "$SCRIPT_DIR/../config" && pwd)"
. "$_CONFIG_DIR/defaults.conf"
[ -f "$_CONFIG_DIR/config.conf" ] && . "$_CONFIG_DIR/config.conf"

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
: "${ENABLE_IPV6:=no}"

require_cmd iptables

# --- rule manipulation helpers (IPv4) ---

# Idempotent insert at index 1. No-op if the rule already exists.
# Args: $1 - interface, $2 - protocol (udp|tcp)
add_rule_if_missing() {
    local iface="$1" proto="$2"
    if iptables -t nat -C PREROUTING -i "$iface" -p "$proto" --dport 53 \
            -j REDIRECT --to-ports "$UPSTREAM_PORT" 2>/dev/null; then
        return 0
    fi
    iptables -t nat -I PREROUTING 1 -i "$iface" -p "$proto" --dport 53 \
        -j REDIRECT --to-ports "$UPSTREAM_PORT"
    log "added: -i $iface -p $proto --dport 53 -> REDIRECT :$UPSTREAM_PORT"
}

# --- rule manipulation helpers (IPv6, when ENABLE_IPV6=yes) ---

add_rule_if_missing_v6() {
    local iface="$1" proto="$2"
    if ip6tables -t nat -C PREROUTING -i "$iface" -p "$proto" --dport 53 \
            -j REDIRECT --to-ports "$UPSTREAM_PORT" 2>/dev/null; then
        return 0
    fi
    ip6tables -t nat -I PREROUTING 1 -i "$iface" -p "$proto" --dport 53 \
        -j REDIRECT --to-ports "$UPSTREAM_PORT"
    log "added (v6): -i $iface -p $proto --dport 53 -> REDIRECT :$UPSTREAM_PORT"
}

# True when IPv6 redirect is requested AND ip6tables is available.
ipv6_enabled() {
    [ "$ENABLE_IPV6" = "yes" ] || return 1
    if ! command -v ip6tables >/dev/null 2>&1; then
        log "ENABLE_IPV6=yes but ip6tables not available, skipping IPv6"
        return 1
    fi
    return 0
}

add_rules() {
    local iface proto
    for iface in $INTERFACES; do
        for proto in udp tcp; do
            add_rule_if_missing "$iface" "$proto"
            if ipv6_enabled; then
                add_rule_if_missing_v6 "$iface" "$proto"
            fi
        done
    done
}

# Remove ALL our REDIRECT-to-port rules for dport 53 (any port, any iface).
# Used by stop/reload so they fully clean up after any previous config
# (different UPSTREAM_PORT, different INTERFACES, stale v6 rules).
# Signature: iptables -t nat -S PREROUTING lines ending with:
#   --dport 53 -j REDIRECT --to-ports <N>
del_all_rules() {
    local line rest
    iptables -t nat -S PREROUTING 2>/dev/null \
        | grep -E '^-A PREROUTING .*--dport 53 .*-j REDIRECT --to-ports [0-9]+' \
        | while IFS= read -r line; do
            rest=${line#-A PREROUTING }
            # shellcheck disable=SC2086
            if iptables -t nat -D PREROUTING $rest 2>/dev/null; then
                log "removed: $rest"
            fi
        done
    # IPv6 (always try if ip6tables available — defensive cleanup)
    if command -v ip6tables >/dev/null 2>&1; then
        ip6tables -t nat -S PREROUTING 2>/dev/null \
            | grep -E '^-A PREROUTING .*--dport 53 .*-j REDIRECT --to-ports [0-9]+' \
            | while IFS= read -r line; do
                rest=${line#-A PREROUTING }
                # shellcheck disable=SC2086
                if ip6tables -t nat -D PREROUTING $rest 2>/dev/null; then
                    log "removed (v6): $rest"
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

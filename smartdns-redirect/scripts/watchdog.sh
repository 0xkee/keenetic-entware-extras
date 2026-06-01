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

: "${ENABLE_IPV6:=no}"
: "${UPSTREAM_PORT:=6053}"

DNS_REDIRECT_SCRIPT="$SCRIPT_DIR/dns-redirect.sh"

# --- helpers ---

# Check if a single REDIRECT rule exists for (family, iface, proto).
# Args: $1 - "v4"|"v6", $2 - iface, $3 - proto (udp|tcp)
rule_exists() {
    local family="$1" iface="$2" proto="$3" bin
    case "$family" in
        v4) bin="iptables" ;;
        v6) bin="ip6tables" ;;
        *)  return 1 ;;
    esac
    "$bin" -t nat -C PREROUTING -i "$iface" -p "$proto" --dport 53 \
        -j REDIRECT --to-ports "$UPSTREAM_PORT" 2>/dev/null
}

# Returns 0 if any expected rule is missing (i.e. reload needed).
any_rule_missing() {
    local iface proto
    for iface in $INTERFACES; do
        for proto in udp tcp; do
            rule_exists "v4" "$iface" "$proto" || return 0
            if [ "$ENABLE_IPV6" = "yes" ] && command -v ip6tables >/dev/null 2>&1; then
                rule_exists "v6" "$iface" "$proto" || return 0
            fi
        done
    done
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

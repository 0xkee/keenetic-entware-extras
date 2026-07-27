#!/opt/bin/sh
# NDM netfilter hook for smartdns-redirect.
# Installed as symlink: /opt/etc/ndm/netfilter.d/10-smartdns-redirect
# Called by Keenetic NDM after iptables flush / policy change.
# Restores smartdns-redirect DNAT rules idempotently.
# NOTE: calls `start` (idempotent), NOT `reload` — we must not drop rules
# even for milliseconds during NDM-triggered reapplies.
# shellcheck disable=SC1091  # sourced files resolved at runtime on router
set -eu

# Resolve symlink to find real script location (robust if invoked via link)
REAL_PATH="$(readlink -f "$0" 2>/dev/null || readlink "$0" 2>/dev/null || echo "$0")"
HOOK_DIR="$(dirname "$REAL_PATH")"
SCRIPT="$HOOK_DIR/dns-redirect.sh"

# Guard: exit if user disabled the service
. /opt/keenetic-entware-extras/lib/common.sh
is_service_enabled "S39smartdns-redirect" || exit 0

# Guard: exit if SmartDNS disabled (S38 renamed by S37smartdns-conf disable)
[ -x /opt/etc/init.d/S38smartdns ] || exit 0

# Skip silently if target script missing / not executable
[ -x "$SCRIPT" ] || exit 0

"$SCRIPT" start >/dev/null 2>&1 \
    || logger -t smartdns-redirect "netfilter.d hook: start failed"

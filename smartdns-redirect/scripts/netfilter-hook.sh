#!/opt/bin/sh
# NDM netfilter hook for smartdns-redirect.
# Installed as symlink: /opt/etc/ndm/netfilter.d/10-smartdns-redirect
# Called by Keenetic NDM after iptables flush / policy change.
# Restores smartdns-redirect DNAT rules idempotently.
# NOTE: calls `start` (idempotent), NOT `reload` — we must not drop rules
# even for milliseconds during NDM-triggered reapplies.
set -eu

# Resolve symlink to find real script location (robust if invoked via link)
REAL_PATH="$(readlink -f "$0" 2>/dev/null || readlink "$0" 2>/dev/null || echo "$0")"
HOOK_DIR="$(dirname "$REAL_PATH")"
SCRIPT="$HOOK_DIR/dns-redirect.sh"

# Skip silently if target script missing / not executable
[ -x "$SCRIPT" ] || exit 0

"$SCRIPT" start >/dev/null 2>&1 \
    || logger -t smartdns-redirect "netfilter.d hook: start failed"

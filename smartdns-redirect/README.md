# smartdns-redirect

> 📖 **[User Manual (RU)](docs/user-manual.ru.md)** — step-by-step installation, configuration, troubleshooting.

Universal DNS DNAT for Keenetic/Entware — intercept LAN `:53` and redirect to a local DNS resolver.

## What is this

iptables DNAT on `PREROUTING` for configured interfaces (`br0` LAN, `br1` Guest, `nwg1` WG Server, etc.): all client DNS queries go directly to local DNS (SmartDNS `:6053` by default) instead of Keenetic ndnproxy. The router itself (ndnproxy :53) is **not affected** — works as before.

**Why:**
- **Latency** — measured: ~130ms → <80ms on LAN clients (minus hop through ndnproxy).
- **Split-DNS policy** works for clients directly (SmartDNS decides which upstream to use).
- **Keenetic integrity** — ndnproxy is not broken, webui/diagnostics are not affected.

**Compatible with:**
- [`smartdns-geo-conf`](../smartdns-geo-conf) (default upstream `:6053`)
- AdGuard Home (`UPSTREAM_PORT=5353`)
- Unbound (`UPSTREAM_PORT=5335`)
- dnsmasq (any port)
- [`geo-split`](../geo-split) — works in tandem.

## Requirements

- Keenetic with Entware
- `opkg install iptables` (installed automatically as dependency)
- Local DNS resolver on the router listening on UDP/TCP port (default `:6053`)

## Installation

### Via .ipk (recommended)

```sh
scp -O smartdns-redirect_<ver>_all.ipk root@<router-ip>:/tmp/
opkg install /tmp/smartdns-redirect_<ver>_all.ipk
```

`postinst` automatically:
- creates symlink `/opt/etc/ndm/netfilter.d/smartdns-redirect-hook` (rule restoration on `iptables flush` by NDM),
- adds cron watchdog (`*/5 * * * *`) to `/opt/etc/crontab`,
- starts `S39smartdns-redirect`.

## Configuration

File: `/opt/keenetic-entware-extras/smartdns-redirect/config/config.conf`

> 📝 In `config.conf` specify only parameters that differ from defaults (`defaults.conf`). The file is not created automatically — create it manually if needed. On package update `defaults.conf` is updated, while `config.conf` is not touched.

```sh
UPSTREAM_PORT=6053         # SmartDNS=6053, AGH=5353, Unbound=5335
INTERFACES="br0"           # LAN interfaces (space-separated)
ENABLE_IPV6=no             # IPv6 DNAT (experimental)
WATCHDOG_SERVICE="S38smartdns"   # init script to restart on failure
PRESERVE_FILTER_PROFILES=no      # Phase 5 (not implemented)
```

After changing config:

```sh
/opt/etc/init.d/S39smartdns-redirect restart
```

## Verification

```sh
# Rules in NAT PREROUTING
iptables -t nat -S PREROUTING | grep DNAT
# Expected (10.0.0.1 = router LAN IP):
#   -A PREROUTING -i br0 -p udp -m udp --dport 53 -j DNAT --to-destination 10.0.0.1:6053
#   -A PREROUTING -i br0 -p tcp -m tcp --dport 53 -j DNAT --to-destination 10.0.0.1:6053

# Status
/opt/etc/init.d/S39smartdns-redirect status

# Logs
logread | grep smartdns-redirect
```

## How it works

### LAN client request flow

```
Client (10.0.0.42) → UDP :53 → br0 →
  [iptables PREROUTING DNAT → 10.0.0.1:6053] →
    SmartDNS (10.0.0.1:6053) → upstream (DoT/DoH/UDP)
```

The router itself (loopback `127.0.0.1:53`) goes to ndnproxy — LAN interface rules don't apply to it.

### NDM resilience

Keenetic periodically flushes iptables via its netfilter hooks. The symlink in `/opt/etc/ndm/netfilter.d/` calls [`netfilter-hook.sh`](scripts/netfilter-hook.sh) every time NDM touches the tables — rules are immediately restored.

### Watchdog

Cron runs [`watchdog.sh`](scripts/watchdog.sh) every 5 minutes:

1. Checks for rules in `PREROUTING` — restores if missing.
2. Sends a test DNS query to `UPSTREAM_PORT`. If upstream is unresponsive — restarts `WATCHDOG_SERVICE` (default `S38smartdns`).

## Removal

```sh
opkg remove smartdns-redirect
```

`prerm` / `postrm` will revert everything: init script, symlink, iptables, cron, PID file, installation directory.

## Architecture

```
smartdns-redirect/
├── config/
│   ├── defaults.conf               # default values
│   └── config.conf                  # 🔧 user overrides (create manually if needed)
├── init.d/
│   └── S39smartdns-redirect        # init (start/stop/restart/status)
├── scripts/
│   ├── dns-redirect.sh             # apply/remove iptables rules
│   ├── netfilter-hook.sh           # NDM hook: restore on flush
│   ├── watchdog.sh                 # cron: rule presence + upstream health
│   └── status.sh                   # diagnostics
└── docs/
    └── user-manual.ru.md
```

## License

MIT — see [LICENSE](../LICENSE).

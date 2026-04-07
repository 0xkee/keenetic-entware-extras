# Code Quality Targets — geo-bypass

Inherits all rules from root [`.project/target-code.md`](../../.project/target-code.md).

## Additional Constraints

### Shebang
- `#!/opt/bin/sh` — all geo-bypass scripts use POSIX sh only

### Available Tools on Host (required)
- `curl` — HTTPS downloads for CIDR lists
- `ip` — policy routing: `ip route`, `ip rule`
- `ipset` — ipset management: `ipset create`, `ipset restore`, `ipset swap`
- `grep -E` — regex matching (NO `-P` / PCRE)

### Available Tools on Host (optional)
- `dig` (bind-dig) — DNS resolution for domain lists: `dig +short <domain> @localhost`

### DNS Specifics
- See [`smartdns/`](../../smartdns/) for DNS server configuration
- `dig @localhost` resolves through SmartDNS on port 6053

### Routing Specifics
- `ipset` hash:net — stores GEO CIDRs, loaded via `ipset restore` + atomic `swap`
- `iptables -t mangle PREROUTING` — marks packets by dst match in ipset (`--set-mark`)
- `ip rule add fwmark <mark> table 1000 priority 100` — routes marked packets
- `ip route replace default via <gw> dev <IFACE> table 1000` — single default route in custom table

### Dependencies (Entware)
- `ipset` — `opkg install ipset`
- `iptables` — pre-installed on Keenetic (kernel module)
- `curl` — `opkg install curl`
- `bind-dig` (optional) — `opkg install bind-dig` (for domain DNS resolution)

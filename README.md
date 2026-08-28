# Keenetic Entware Extras

> 📖 **[Руководство пользователя (RU)](user-manual.ru.md)** — установка, настройка, диагностика.

A set of `.ipk` packages for Keenetic routers with Entware. Makes routing smarter, DNS faster, and network problems visible — all manageable from a web dashboard.

## What it does

- 🌍 **Split traffic by country** — send regional traffic through ISP, everything else through a tunnel (or vice versa)
- 🔗 **Smart DNS by region** — local domains resolve via nearby DNS, international — via encrypted channels
- ⚡ **Faster DNS for all devices** — clients get DNS responses directly, skipping the default proxy
- 🔍 **Network diagnostics** — one command checks if traffic goes where it should, detects anomalies, tests DNS integrity
- 📊 **Web dashboard** — monitor everything from your browser, edit configs, integrates into stock Keenetic UI

## Packages

### 🌍 geo-split

**Route traffic by country.**

Sends traffic to specific countries through one network path (e.g. ISP), and everything else through another (e.g. encrypted tunnel). Works with GeoIP subnets and domain lists — resolves domains to IPs and routes them too.

- 240 countries + 40 regional alliances (EAEU, BRICS, EU, ASEAN…)
- Automatic failover on interface changes (NDM hook)
- CIDR aggregation: ~13K subnets → ~8.5K routes
- Uses policy routing (`ip rule` / `ip route`), not iptables — fully compatible with Keenetic per-device routing

→ [Details](geo-split/README.md) · [User Manual (RU)](geo-split/docs/user-manual.ru.md)

### 🔗 smartdns-geo-conf

**Smart DNS by region.**

Sends DNS queries for regional domains (`.ru`, `.рф`, `.by`…) to nearby DNS servers (Yandex, AdGuard), and everything else to international ones (Google, Cloudflare) over encrypted channels. Result: faster responses for local sites, reliable resolution for everything else.

- 15 DNS providers with multi-select
- Configurable geo-zones (single country or alliance)
- Optional tunnel interface binding for DNS integrity protection

→ [Details](smartdns-geo-conf/README.md) · [User Manual (RU)](smartdns-geo-conf/docs/user-manual.ru.md)

### ⚡ smartdns-redirect

**Faster DNS for all devices on your network.**

Intercepts DNS queries from LAN clients and sends them directly to a local resolver (SmartDNS, AdGuard Home, Unbound) instead of going through Keenetic ndnproxy. The router's own DNS is not affected.

- Measured improvement: ~130 ms → <80 ms
- Survives Keenetic iptables flushes (netfilter.d hook)
- Blocks DNS-over-TLS leaks from clients
- IPv6 support (automatic DNAT or REJECT with Happy Eyeballs fallback)

→ [Details](smartdns-redirect/README.md) · [User Manual (RU)](smartdns-redirect/docs/user-manual.ru.md)

### 🔍 net-check

**Network diagnostics toolkit.**

One command checks everything: is your traffic going where you think? Are DNS responses genuine? Is anyone intercepting your certificates? Supports per-interface comparison and privacy mode for safe sharing.

- 9 diagnostic modules: GeoIP egress, connectivity, IPv6 leak, DNS resolution, DNS leak, HTTP reachability, CDN geo-steering, TLS MITM detection, speed
- Deep single-resource check: `net-check.sh check youtube.com`
- JSON output for automation

→ [Details](net-check/README.md) · [User Manual (RU)](net-check/docs/user-manual.ru.md)

### 📊 webui

**Dashboard in your browser.**

Web panel on port `:8080` with live status of all services. Config editor with validation, zone/provider selectors, toggle switches. Integrates into the stock Keenetic dashboard — adds an Entware Extras card and optional sidebar link.

- Schema-driven config editor for all packages
- Status API with shared-memory cache (low CPU even with multiple tabs)
- Auto-patches stock Keenetic UI bundles (KeeneticOS 5.0–5.2)
- System info: CPU, RAM, disk, uptime

→ [Details](webui/README.md) · [User Manual (RU)](webui/docs/user-manual.ru.md)

## Installation

### Quick install (recommended)

One command — configures the opkg feed, installs HTTPS support, and offers a package selection menu:

```sh
curl -fsSL https://raw.githubusercontent.com/0xkee/keenetic-entware-extras/master/scripts/install.sh | sh
```

Install specific packages directly:

```sh
curl -fsSL https://raw.githubusercontent.com/0xkee/keenetic-entware-extras/master/scripts/install.sh | sh -s -- geo-split webui
```

Install everything:

```sh
curl -fsSL https://raw.githubusercontent.com/0xkee/keenetic-entware-extras/master/scripts/install.sh | sh -s -- --all
```

### Manual install

```sh
# Add opkg feed
cat >> /opt/etc/opkg.conf << 'EOF'
src/gz kee https://0xkee.github.io/keenetic-entware-extras/stable
EOF
opkg update

# Install (dependencies are resolved automatically)
opkg install geo-split smartdns-geo-conf smartdns-redirect net-check webui
```

See [repository docs](releases/README.md) for channels (stable/dev), switching, and updating.

### Uninstall

One command — removes all packages and the opkg feed:

```sh
curl -fsSL https://raw.githubusercontent.com/0xkee/keenetic-entware-extras/master/scripts/install.sh | sh -s -- --uninstall
```

Or manually:

```sh
opkg remove webui net-check smartdns-redirect smartdns-geo-conf geo-split geo-split-data
opkg remove keenetic-entware-extras
sed -i '/kee/d' /opt/etc/opkg.conf
```

## Diagnostics

After installation, the `kee-status` command shows a summary of all services:

```sh
kee-status          # colored output
kee-status -d       # detailed — full status of each package
```

For bug reports — collects full system info (safe, no passwords or keys):

```sh
/opt/keenetic-entware-extras/scripts/bug-report.sh
```

## Requirements

- Keenetic router with **Entware** installed
- **KeeneticOS 5.0+**
- All package dependencies are installed automatically via opkg

## License

[MIT](LICENSE)

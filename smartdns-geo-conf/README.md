# smartdns-geo-conf

> 📖 **[User Manual (RU)](docs/user-manual.ru.md)** — step-by-step installation, configuration, troubleshooting.

SmartDNS split-DNS configuration with configurable geo-zones on Keenetic/Entware.

## What is this

Split DNS: routing DNS queries by geo-zones.

- **Zones** (configurable: RU, EAEU, CIS, BRICS, EU…) → regional DNS (Yandex DoT, AdGuard DoT)
- **Everything else** → international DNS (Google DoH, Cloudflare DoH)
- **VPN-bypass** — optional binding of DNS queries to VPN interfaces to bypass MITM

**Why:**
- Speed for in-zone domains — nearest CDN nodes via regional DNS
- Bypass DNS manipulation for foreign domains — DoH via HTTPS/443
- Flexibility — any combination of countries or geo-alliances

## Requirements

- Keenetic with Entware
- `opkg install smartdns` (installed automatically as dependency)
- `opkg install ca-certificates` (installed automatically as dependency)

## Installation

### Via .ipk (recommended)

```sh
# Copy to router
scp -O smartdns-geo-conf_<ver>_all.ipk root@<router-ip>:/tmp/

# Install
opkg install /tmp/smartdns-geo-conf_<ver>_all.ipk
```

### From repository (for developers)

```sh
./scripts/build-ipk.sh smartdns-geo-conf
# Result: dist/smartdns-geo-conf_<ver>_all.ipk
```

## Direct DNS traffic to SmartDNS

After installation, DNS queries from clients need to be directed to SmartDNS. Two options:

### Option A: smartdns-redirect (recommended)

Install the [`smartdns-redirect`](../smartdns-redirect/) package — it automatically intercepts DNS queries from LAN via iptables DNAT. Changes to Keenetic settings (DNS, DoT/DoH) are **not required**.

```sh
opkg install /tmp/smartdns-redirect_<ver>_all.ipk
```

### Option B: manual Keenetic DNS setup

If you don't want DNAT interception:

> ⚠️ **Important:** If Keenetic has DoT/DoH servers configured (dns-proxy tls/https) — ndnproxy will use them and **ignore** plain DNS, including SmartDNS. Remove all DoT/DoH first.

```sh
# 1. Remove all DoT/DoH servers (required for option B!)
ndmc -c 'no dns-proxy tls upstream 1.1.1.1'
ndmc -c 'no dns-proxy https upstream https://1.1.1.1/dns-query'
# ... (remove all your DoT/DoH entries)

# 2. Add SmartDNS as DNS server
ndmc -c 'ip name-server <router-IP>:6053'

# 3. Save
ndmc -c 'system configuration save'
```

**Or via web interface:** *Internet Filters → DNS* → remove all DoT/DoH servers, add `<router-IP>:6053`.

## Zone configuration

File: `config/config.conf`

```sh
# Zone — single country or geo-alliance
DNS_ZONE="eas"

# International DNS providers (space-separated)
OTHER_DNS_PROVIDER="google cloudflare"

# Zone DNS providers (space-separated)
# Default: "yandex alidns system" (see defaults.conf)
ZONE_DNS_PROVIDER="yandex adguard"

# VPN interfaces for international DNS (MITM bypass)
OTHER_DNS_INTERFACES=""

# VPN interface for zone DNS (usually not needed)
ZONE_DNS_INTERFACE=""
```

### Available zones

| Value | Description | Countries |
|-------|-------------|-----------|
| `ru` | Russia | .ru, .рф, .su |
| `by` | Belarus | .by |
| `kz` | Kazakhstan | .kz |
| `am` | Armenia | .am |
| `kg` | Kyrgyzstan | .kg |
| `eas` | EAEU | ru+by+kz+am+kg |
| `cis` | CIS | ru+by+kz+am+kg+uz+tj+md+az |
| `brics` | BRICS+ | ru+br+in+cn+za+eg+et+ae+sa+ir |
| `sco` | SCO | ru+cn+in+kz+kg+pk+tj+uz+ir+by |
| ... | [Full list →](../lib/geo.sh) | 40+ alliances |

### DNS providers

Providers are configured via `OTHER_DNS_PROVIDER` (international) and `ZONE_DNS_PROVIDER` (zone/regional).

**International** (`OTHER_DNS_PROVIDER`):

| Value | Provider | Protocol |
|-------|----------|----------|
| `system` | System (Keenetic) | UDP |
| `google` | Google Public DNS | DoH |
| `cloudflare` | Cloudflare | DoH |
| `quad9` | Quad9 (malware filter) | DoT |
| `quad9uf` | Quad9 Unfiltered | DoT |
| `mullvad` | Mullvad (no-log) | DoH |
| `mullvad_adblock` | Mullvad + adblock | DoH |
| `controld` | ControlD Free | DoH |
| `adguard` | AdGuard (ads filter) | DoH |

**Zone/Regional** (`ZONE_DNS_PROVIDER`):

| Value | Provider | Protocol | Region |
|-------|----------|----------|--------|
| `system` | System (Keenetic) | UDP | — |
| `yandex` | Yandex DNS | DoT+UDP | RU/CIS |
| `yandex_safe` | Yandex Safe | DoT+UDP | RU/CIS |
| `yandex_family` | Yandex Family | DoT+UDP | RU/CIS |
| `adguard` | AdGuard Unfiltered | DoT | RU/CIS |
| `adguard_ads` | AdGuard Default | DoT | RU/CIS |
| `alidns` | AliDNS | DoT+UDP | China |
| `tencent` | Tencent DNSPod | DoT+UDP | China |

### Custom DNS servers

The file `config/dns-providers-custom.conf` allows adding custom DNS servers.
Not overwritten during package update. Format is the same as `dns-providers.conf`:

```sh
# Plain UDP
OTHER_mydns_LABEL="My DNS"
OTHER_mydns_PROTO="udp"
OTHER_mydns_IP1="1.2.3.4"
OTHER_mydns_IP2=""

# Then in config.conf:
OTHER_DNS_PROVIDER="google mydns"
```

Supported protocols: `udp`, `dot` (DoT), `doh` (DoH).
For DoH, `IP1`/`IP2` are **optional** — if omitted, SmartDNS resolves the hostname itself.
Required for Private DoH (AdGuard, NextDNS) where IP pinning breaks profile identification.
More details — in [user-manual.ru.md](docs/user-manual.ru.md).

> Provider list is cached by WebUI for 1 hour. For immediate refresh:
> `/opt/etc/init.d/S80nginx-webui restart`

### Applying changes

```sh
/opt/etc/init.d/S37smartdns-conf restart
```

### Configuration examples

**EAEU (default):**
```sh
DNS_ZONE="eas"
OTHER_DNS_PROVIDER="google cloudflare"
ZONE_DNS_PROVIDER="yandex adguard"
```

**Russia only + Quad9:**
```sh
DNS_ZONE="ru"
OTHER_DNS_PROVIDER="quad9"
ZONE_DNS_PROVIDER="yandex"
```

**China (AliDNS + Tencent):**
```sh
DNS_ZONE="cn"
ZONE_DNS_PROVIDER="alidns tencent"
```

**International DNS via VPN (MITM bypass):**
```sh
OTHER_DNS_INTERFACES="nwg3 nwg4"
```

## Management

```sh
# Enable split-DNS
/opt/etc/init.d/S37smartdns-conf enable

# Disable (all queries → Google/Cloudflare)
/opt/etc/init.d/S37smartdns-conf disable

# Status
/opt/etc/init.d/S37smartdns-conf status

# Regenerate configs + restart SmartDNS
/opt/etc/init.d/S37smartdns-conf restart

# Diagnostics
/opt/keenetic-entware-extras/smartdns-geo-conf/scripts/status.sh
```

## Ports

| Port | Purpose |
|------|---------|
| 6053 | Primary DNS (all queries) |
| 6153 | geo-split (all IPs, no speed-check) |

## Structure

```
smartdns-geo-conf/
├── config/
│   ├── config.conf            # 🔧 user configuration
│   ├── defaults.conf          # default values
│   ├── dns-providers.conf     # DNS provider catalog (15 providers)
│   ├── zone-routing-rules.conf # IDN TLDs + extra CDN domains (80+ countries)
│   ├── test-domains.conf      # test domains for status.sh
│   ├── smartdns.conf          # split-DNS mode template
│   └── smartdns-default.conf  # default mode template
├── init.d/
│   └── S37smartdns-conf       # init script (enable/disable/restart)
├── scripts/
│   ├── generate-conf.sh       # dynamic config generator
│   ├── status.sh              # diagnostics
│   └── toggle.sh              # enable/disable helper (legacy, used by API)
└── docs/
    └── user-manual.ru.md
```

## Adding a domain to a zone

To add extra domains to a zone's DNS routing (e.g. for CDN optimization):

1. Edit `config/zone-routing-rules.conf` — add domain to the appropriate country section
2. `/opt/etc/init.d/S37smartdns-conf restart`

Example (add `example.com` to RU zone):
```conf
# In zone-routing-rules.conf, under [extra:ru] section:
example.com
```

# geo-split-data

> 📖 **[User Manual (RU)](docs/user-manual.ru.md)**

GeoIP subnet data and domain lists for [geo-split](../geo-split/).

## Contents

| Path | Description |
|------|-------------|
| `lists/domains.txt` | Curated domain list (conffile — opkg won't overwrite) |
| `lists/ru-whitelist.txt` | RU allowlist: 100+ domains (government services, banks, streaming, etc.) |
| `lists/geoip/*.zone.gz` | Pre-built gzip-compressed country IP subnets (232 zones from [ipdeny.com](https://www.ipdeny.com)) |
| `scripts/fetch-zones.sh` | Download & aggregate zone files (build-time script) |

## Installation

```sh
opkg install /tmp/geo-split-data_<ver>_all.ipk
```

> **conffiles:** `lists/domains.txt` and `lists/ru-whitelist.txt` are declared as conffiles —
> user changes are **not overwritten** during `opkg upgrade`.
> opkg will keep your version and create the `.ipk` version alongside with `.opkg-new` suffix.

## Deploy path

```
/opt/keenetic-entware-extras/geo-split-data/
  lists/
    domains.txt
    ru-whitelist.txt
    geoip/
      ru.zone.gz       ← Russia (~13K CIDRs)
      by.zone.gz       ← Belarus
      kz.zone.gz       ← Kazakhstan
      cn.zone.gz       ← China
      us.zone.gz       ← United States
      de.zone.gz       ← Germany
      ...              ← 232 zones total
```

## Zone files

Zone files are fetched from ipdeny.com during package build (`scripts/fetch-zones.sh`).
CIDRs are aggregated (merged overlapping/adjacent) to reduce route count.
Files are stored as `.zone.gz` (gzip compressed), saving ~60–70% flash space on routers.
geo-split transparently decompresses them at runtime.

**232 zone files included** — all countries with registered IP address blocks.

By default, geo-split uses `GEO_ZONE="eas"` (EAEU: ru+by+kz+am+kg).
To use a different zone, change `GEO_ZONE` in `geo-split/config/config.conf`.

### Manual fetch

```sh
./geo-split-data/scripts/fetch-zones.sh          # skip if fresh (<30 days)
./geo-split-data/scripts/fetch-zones.sh --force   # force re-download
```

The script downloads, aggregates CIDRs, and compresses each zone with `gzip`.

### Build

Zone fetching is integrated into `scripts/build-ipk.sh`:

```sh
./scripts/build-ipk.sh geo-split-data   # fetches zones if stale, then builds .ipk
./scripts/build-ipk.sh all               # builds all 3 packages
```

## Package info

- **Package:** `geo-split-data`
- **Depends:** `keenetic-entware-extras`
- **Architecture:** all

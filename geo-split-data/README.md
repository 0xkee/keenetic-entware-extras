# geo-split-data

GeoIP subnet data and domain lists for [geo-split](../geo-split/).

## Contents

| Path | Description |
|------|-------------|
| `lists/domains.txt` | Curated domain list (conffile — opkg won't overwrite) |
| `lists/ru-whitelist.txt` | RU whitelist: 100+ domains (госуслуги, банки, стриминг и др.) |
| `lists/geoip/*.zone` | Pre-built country IP subnets from [ipdeny.com](https://www.ipdeny.com) |
| `scripts/fetch-zones.sh` | Download & aggregate zone files (build-time script) |

## Deploy path

```
/opt/keenetic-entware-extras/geo-split-data/
  lists/
    domains.txt
    ru-whitelist.txt
    geoip/
      ru.zone          ← aggregated CIDRs
```

## Zone files

Zone files are fetched from ipdeny.com during package build (`scripts/fetch-zones.sh`).
CIDRs are aggregated (merged overlapping/adjacent) to reduce ipset/route count.

### Manual fetch

```sh
./geo-split-data/scripts/fetch-zones.sh          # skip if fresh (<30 days)
./geo-split-data/scripts/fetch-zones.sh --force   # force re-download
```

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

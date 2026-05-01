# geo-split-data

GeoIP subnet data and domain lists for [geo-split](../geo-split/).

## Contents

| Path | Description |
|------|-------------|
| `lists/domains.txt` | Curated domain list (conffile — opkg won't overwrite) |
| `lists/ru-whitelist.txt` | RU whitelist: 100+ domains (госуслуги, банки, стриминг и др.) |
| `lists/geoip/*.zone` | Pre-built country IP subnets from [ipdeny.com](https://www.ipdeny.com) |
| `scripts/fetch-zones.sh` | Download & aggregate zone files (build-time script) |

## Установка

```sh
opkg install /tmp/geo-split-data_0.3.0_all.ipk
```

> **conffiles:** Файлы `lists/domains.txt` и `lists/ru-whitelist.txt` объявлены как conffiles —
> при `opkg upgrade` пользовательские изменения **не перезатираются**.
> opkg сохранит вашу версию и создаст `.ipk`-версию рядом с суффиксом `.opkg-new`.

## Deploy path

```
/opt/keenetic-entware-extras/geo-split-data/
  lists/
    domains.txt
    ru-whitelist.txt
    geoip/
      ru.zone          ← Russia
      by.zone          ← Belarus
      kz.zone          ← Kazakhstan
      am.zone          ← Armenia
      kg.zone          ← Kyrgyzstan
```

## Zone files

Zone files are fetched from ipdeny.com during package build (`scripts/fetch-zones.sh`).
CIDRs are aggregated (merged overlapping/adjacent) to reduce route count.

Included zones (EAEU countries): `ru`, `by`, `kz`, `am`, `kg`.

By default, geo-split uses `ru.zone`. To use a different zone, change `SUBNET_URL`
or `SUBNET_LIST_FILE` in `geo-split/config/config.conf`.

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
- **Version:** 0.3.0
- **Depends:** `keenetic-entware-extras`
- **Architecture:** all

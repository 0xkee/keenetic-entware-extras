# net-check: План рефакторинга для международного использования

## Статус: ✅ Утверждён — единый файл + custom + runtime zone filter

**Дата утверждения:** 2026-08-08
**Подход:** Один файл на тип данных (global+intl+zone catalog) + optional custom (conffile)

---

## Архитектура

### Принцип

Следуем паттерну **smartdns-geo-conf** (`zone-routing-rules.conf`):
один файл содержит данные для **всех** стран. Секции zone-XX фильтруются
при загрузке по `_ZONE_CC_LIST` из активной geo-зоны.

### Как работает

```
smartdns-geo-conf/config/config.conf    ← DNS_ZONE="eas"
  → lib/geo.sh: resolve_geo_zone("eas") → "ru by kz am kg"
    → net-check/wan.sh: _ZONE_CC_LIST="ru by kz am kg"
      → _cat_config(): фильтрует zone-XX из main файла по CC list
        → пользователь видит ТОЛЬКО targets своей зоны + global + intl
```

### Файловая структура (после)

```
config/
  defaults.conf                    # + CHECK_ZONE="auto"

  check-targets.conf               # MERGED: global + intl + zone catalog (все страны)
                                   # НЕ conffile → обновляется с пакетом
  check-targets-custom.conf        # optional, conffile → пользовательские targets

  cdn-domains.conf                 # MERGED: global + intl + zone CDN (все страны)
                                   # НЕ conffile → обновляется с пакетом
  cdn-domains-custom.conf          # optional, conffile → пользовательские CDN

  anomaly-markers.conf             # MERGED: worldwide + zone markers (все страны)
                                   # НЕ conffile → обновляется с пакетом
                                   # (custom не нужен — пользователи не добавляют маркеры)

  dns-providers.conf               # без изменений (conffile)
  wellknown-ips.conf               # без изменений (conffile)
  mitm-issuers.conf                # без изменений (conffile)
  privacy-providers.conf           # без изменений (conffile)
```

### Удалённые файлы

- `check-targets-base.conf` → слит в `check-targets.conf`
- `check-targets-zone.conf` → слит в `check-targets.conf`
- `cdn-domains-base.conf` → слит в `cdn-domains.conf`
- `cdn-domains-zone.conf` → слит в `cdn-domains.conf`

### Ключевое изменение: `_cat_config()` в output.sh

```sh
# Load main config + filter zone entries by active CC list + append custom.
# Args: $1 - config name (e.g. "check-targets", "cdn-domains", "anomaly-markers")
_cat_config() {
  local _file="$_CONFIG_DIR/${1}.conf"
  [ -f "$_file" ] || return 0

  if [ -n "$_ZONE_CC_LIST" ]; then
    # Include all non-zone lines + only matching zone-CC lines
    awk -F'|' -v cclist=" $_ZONE_CC_LIST " '
      /^#/ || /^$/ { print; next }
      $0 ~ /\|zone-/ {
        # Extract CC from zone-XX category
        for (i=1; i<=NF; i++) {
          if ($i ~ /^zone-/) {
            cc = substr($i, 6)
            if (index(cclist, " " cc " ") > 0) print
            next
          }
        }
        next
      }
      { print }
    ' "$_file"
  else
    # No zone configured — skip all zone-XX entries
    grep -v '|zone-' "$_file" | grep -v '^$'
  fi

  # Append user custom file (if exists)
  [ -f "$_CONFIG_DIR/${1}-custom.conf" ] && cat "$_CONFIG_DIR/${1}-custom.conf"
}
```

### CHECK_ZONE — автономность net-check

```sh
# defaults.conf
# Zone for catalog filtering.
# "auto" = read DNS_ZONE from smartdns-geo-conf (default).
# Explicit: "ru", "tr", "eas", "eu", "brics", etc.
# Empty "" = no zone targets (only global + intl).
CHECK_ZONE="auto"
```

---

## Что уже полностью интернационально (не требует изменений)

Все 13 библиотечных скриптов в `scripts/lib/` работают через абстракции.
Ноль hardcoded country codes в скриптах.

---

## Soft-зависимости от экосистемы

| Зависимость | Graceful degradation |
|-------------|---------------------|
| smartdns-geo-conf → DNS_ZONE | ✅ fallback: CHECK_ZONE в net-check config |
| lib/geo.sh → resolve_geo_zone() | ✅ fallback: CHECK_ZONE="ru" = single CC |
| geo-split → wan-paths.sh | ✅ fallback: ip route |
| Keenetic DNS → ndnproxymain.conf | ✅ fallback: /etc/resolv.conf |

---

## Чеклист реализации

- [x] Анализ и утверждение подхода
- [x] Утверждение файловой структуры (catalog+custom)
- [x] Создать `check-targets.conf` — 51 страна с zone targets (seed из zone-routing-rules)
- [x] Создать `cdn-domains.conf` — 12+ стран с zone CDN
- [x] `anomaly-markers.conf` — оставлен flat (zone-теги не нужны, маркеры не мешают друг другу)
- [x] Добавить `CHECK_ZONE="auto"` в `defaults.conf`
- [x] Переписать `_cat_config()` в `output.sh` — zone filter + custom append
- [x] Добавить CHECK_ZONE support в `load_zone_context()` в `wan.sh`
- [x] Удалить старые файлы: *-base.conf, *-zone.conf
- [x] Обновить `packaging/net-check/conffiles` — *-custom.conf (conffiles) + placeholder-ы
- [x] Обновить `CHANGELOG.md` — v0.1.0
- [x] Version bump 0.0.5 → 0.1.0, пакет собран

## 🔮 Будущее: экосистемная интеграция

Рассмотреть единый API/библиотеку для получения зоны и настроек
из geo-split/smartdns-geo-conf другими пакетами (не только net-check).
Потенциально: `lib/ecosystem.sh` с функциями `get_active_zone()`,
`get_zone_cc_list()`, `get_zone_route_dev()`.

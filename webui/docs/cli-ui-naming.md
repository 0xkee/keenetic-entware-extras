# CLI vs UI: семантическое разделение именования

## Принцип

| Слой | Что показывать | Пример |
|------|---------------|--------|
| **CLI** (shell-скрипты, JSON-вывод) | Технические Linux device names | `br0`, `nwg0`, `lte_br1`, `ppp0` |
| **UI** (WebUI карточки, диаграммы, формы) | Человеко-читаемое имя + (dev) | `Home network (br0)`, `Auto (ISP detect)` |
| **Config** (defaults.conf, config.conf) | Технические имена (CLI-уровень) | `ROUTE_IN="br0"`, `ROUTE_OUT="auto"` |

---

## Текущая архитектура

### Слой 1: CLI (shell-скрипты)

Скрипты работают с Linux device names — это правильно и **не меняется**.

| Скрипт | Что выводит | Формат |
|--------|------------|--------|
| `geo-split/scripts/status.sh` | `route_in`, `route_out`, `rules` | Raw: `"br0"`, `"lte_br1 (auto)"` |
| `geo-split/scripts/route-check.sh` | `source_iface`, `routes[].dev`, `default_route.dev`, `verdict_devs` | Raw: `"br0"`, `"lte_br1"`, `"nwg0"` |
| `smartdns-geo-conf/scripts/dns-check.sh` | `upstream.interface`, `groups[].interface` | Raw: `"nwg3"`, `"default"` |
| `smartdns-geo-conf/scripts/status.sh` | `other_ifaces` | Raw: `"nwg3 nwg4"` |
| `smartdns-redirect/scripts/status.sh` | `interfaces` | Raw: `"br0"` |

### Слой 2: API/Middleware (Lua)

`api-router.lua` — единственное место маппинга NDM → Linux:

```
NDM_TYPE_TO_PREFIX = {
    Bridge    → "br"       (Bridge0 → br0)
    Wireguard → "nwg"      (Wireguard0 → nwg0)
    AmneziaWG → "awg"      (AmneziaWG0 → awg0)
    UsbLte    → "lte_br"   (UsbLte0 → lte_br0)
    OpenVPN   → "ovpn_br"
    PPPoE/PPTP/L2TP → "ppp"
}
```

**`GET /api/system/interfaces`** — отдаёт `{id, name, label, description, up}` для каждого интерфейса.
Frontend кеширует это в `window._ewIfaceMap` (dev → human label).

### Слой 3: UI (JavaScript)

Центральная функция — [`_ifaceLabel(dev)`](../static/route-diagram.js:15):
```js
function _ifaceLabel(dev) {
    var map = window._ewIfaceMap;
    return (map && map[dev]) ? map[dev] : dev;
}
```
Возвращает **только** человеко-читаемый label, **без** технического имени.

---

## Текущее состояние

### ✅ Status card details — полностью humanized

[`parseDetails()`](../static/shared.js:326) автоматически humanizes device names через [`IFACE_DETAIL_KEYS`](../static/shared.js:33) whitelist:

| Ключ | Тип | Detail (с dev) | Summary (без dev) |
|------|-----|----------------|-------------------|
| `route_in` | `space-list` | `Home network (br0)` | `Home network` |
| `route_out` | `single-suffix` | `Beeline 4G (lte_br1, auto)` | `Beeline 4G` |
| `other_interfaces` | `space-list` | `Fornex Sweden (nwg0)` + lines | `Fornex Sweden, ...` |
| `interfaces` | `space-list` | `Home network (br0)` | `Home network` |
| `gateway` | `gateway` | `Direct` / `—` | `Direct` / `—` |

Механизм Summary/Detail toggle:
- [`app.js:191-194`](../static/app.js:191) — high-priority поля рендерят два span'а: `.ew-val-short` (без dev) + `.ew-val-full` (с dev)
- [`layout.css:313-315`](../static/layout.css:313) — CSS переключает видимость по классу `.ew-summary-mode`
- `shortValue` вычисляется в [`parseDetails()`](../static/shared.js:407) — `_humanizeIfaceDetail(key, rawVal, false)` без showDev

### ✅ Route Check / DNS Check details

| Место | Файл | Строка | Формат |
|-------|------|--------|--------|
| Route Check dropdown (source iface) | `route-check.js` | :819 | `ifcLabel + ' (' + ifcId + ')'` |
| Route Check details — Default Route | `route-check.js` | :347 | `_ifaceLabel(dev) + ' (' + dev + ')'` |
| DNS Check details — Interface | `route-check.js` | :393 | `label + ' (' + iif + ')'` (когда отличается) |

### ❌ Только human label (нет dev в скобках)

| Место | Файл | Строка | Текущий формат |
|-------|------|--------|---------------|
| Route diagram — WAN path sublabel | `route-diagram.js` | :498 | `_ifaceLabel(p.dev)` |
| Route diagram — source sublabel | `route-diagram.js` | :455 | `_ifaceLabel(data.source_iface)` |
| Route Check summary line | `route-check.js` | :257 | `_ifaceLabel(route.dev)` |
| Route Check batch table — iface col | `route-check.js` | :580,589,595,601 | `_ifaceLabel(rt.dev)` |

### ❌ Ещё не humanized

| Место | Файл | Строка | Текущий формат |
|-------|------|--------|---------------|
| Status card — `rules` | не в `IFACE_DETAIL_KEYS` | — | Raw: `"br0: #1000 domains"` |
| Config editor dropdown — current value | `app.js` | :1312 | `selectedIfs.join(', ')` (raw names) |

### ❌ Hardcoded fallback

| Место | Файл | Строка | Проблема |
|-------|------|--------|----------|
| Route Check — default dropdown | `route-check.js` | :801 | `'Home network (br0)'` — hardcoded |

---

## Спецзначения config-ключей

Некоторые config-значения — не device names, а семантические ключевые слова:

| Значение | Контекст | CLI (unchanged) | UI (target format) |
|----------|----------|-----|-----|
| `auto` | ROUTE_OUT, ROUTE_GW | `"auto"` | `Auto (ISP detect)` |
| `default` | DOWNLOAD_INTERFACES | `"default"` | `Default route` |
| `*` | DOWNLOAD_INTERFACES | `"*"` | `All VPNs (*)` |
| `none` | ROUTE_GW | `"none"` | `None (dev-only)` |
| `scope link` | Gateway | `"scope link"` | `Direct` |
| `direct` | dns-check interface | `"direct"` | `Direct (ISP)` |

В config editor (`app.js`) `preItems` уже определяют правильный UI-label для этих значений.

---

## Оставшийся план рефакторинга

### TODO: Route Diagram & Route Check — добавить (dev)

| Файл | Строка | Текущее | Замена |
|------|--------|--------|--------|
| `route-diagram.js` | :498 | `_ifaceLabel(p.dev)` | `EW.ifaceLabelFull(p.dev)` |
| `route-diagram.js` | :455 | `_ifaceLabel(data.source_iface)` | `EW.ifaceLabelFull(data.source_iface)` |
| `route-check.js` | :257 | `_ifaceLabel(route.dev)` | `EW.ifaceLabelFull(route.dev)` |
| `route-check.js` | :580,589,595,601 | `_ifaceLabel(rt.dev)` | `EW.ifaceLabelFull(rt.dev)` |
| `route-check.js` | :801 | hardcoded `'Home network (br0)'` | строить из `_ensureIfaceMap` |

Helper [`EW.ifaceLabelFull(dev)`](../static/shared.js:448) уже реализован в `shared.js`.

### TODO: `rules` ключ — добавить в IFACE_DETAIL_KEYS

Добавить `rules: 'prefixed-lines'` в [`IFACE_DETAIL_KEYS`](../static/shared.js:33) + handler в `_humanizeIfaceDetail`.

### TODO: Config Editor Display Text

В [`app.js`](../static/app.js:1312) — `iface_select` показывает raw names. Заменить на `EW.ifaceLabelFull()`.

---

## Что НЕ меняется

- Shell-скрипты (`status.sh`, `route-check.sh`, `dns-check.sh`) — raw device names
- Config файлы (`defaults.conf`, `config.conf`) — только Linux device names
- JSON API ответы — только технические имена (UI резолвит labels)
- `api-router.lua` маппинг — работает правильно
- CLI text output — raw names ок (целевая аудитория — sysadmin)

# Диагностика маршрутов и DNS — Дизайн-план

> **Запрос:** проверка выбора маршрута для хоста/домена из WebUI с наглядной визуализацией
> **Источник:** AndreyEver (форум, 2026-06-23)
> **Связанные задачи:** [`webui/TODO.md:41`](../TODO.md:41)

---

## 🎯 Концепция: две проверки

### Tool 1: Route Check (geo-split)
> «Куда пойдёт трафик к этому хосту?»

Пользователь вводит **домен или IP** → система показывает **SVG-схему сетевой топологии**
с реальным путём трафика: DNS resolve → routing table match → выходной интерфейс → интернет.

**Расположение:** карточка Geo-Split (кастомная страница `/custom/#geo-split`)

### Tool 2: DNS Zone Check (smartdns)
> «Кто резолвит этот домен и через какой канал?»

Пользователь вводит **домен** → система показывает:
- В какую DNS-группу попадает домен (`ru-group`, `by-group`, `default-group`)
- Какой upstream DNS отвечает (Yandex DoT? Cloudflare DoH? Google UDP?)
- Через какой интерфейс идёт DNS-трафик (direct? VPN tunnel?)
- Resolved IP + TTL

**Расположение:** карточка SmartDNS Geo-Config (кастомная страница `/custom/#smartdns`)

### Почему раздельно

| | Route Check | DNS Zone Check |
|--|-------------|----------------|
| **Вопрос** | Куда пойдёт трафик? | Кто резолвит домен? |
| **Подсистема** | geo-split (ip route) | smartdns-geo-conf (DNS groups) |
| **Input** | домен ИЛИ IP | только домен |
| **Визуал** | Топология: клиент→роутер→интерфейс→облако | DNS-flow: домен→группа→upstream→ответ |
| **Зависимость** | Использует DNS для resolve, потом route | Только DNS |

---

## 🎨 Визуальный стиль: Сетевая топология (иконографическая)

### Элементы схемы (SVG-иконки)

Не абстрактные блоки, а **узнаваемые иконки**:

```
  ☁️                    📡                     📋                    🖥️
┌───────────┐      ┌──────────┐         ┌──────────┐         ┌──────────┐
│  Облачко  │      │  Роутер  │         │  Таблица │         │  Клиент  │
│ Интернет  │      │ с антен- │         │ маршрут- │         │   LAN    │
│           │      │  ками    │         │ изации   │         │          │
└───────────┘      └──────────┘         └──────────┘         └──────────┘
```

**Конкретные SVG-иконки:**

| Элемент | Визуал | Описание |
|---------|--------|----------|
| **Интернет** | Облачко (cloud shape) с текстом | Конечная точка — куда уходит трафик |
| **Роутер** | Корпус + 4 антенны + WAN-кабель | Keenetic (центральный элемент) |
| **Интерфейс ISP** | Провод/порт от роутера → облако (прямая линия) | lte_br1, ppp0, eth3 |
| **Интерфейс VPN** | Туннель (пунктирная линия) → облако | nwg0, ovpn_br0 |
| **Клиент** | Монитор/ноутбук/телефон | Источник запроса |
| **DNS** | Мини-облачко с "DNS" | SmartDNS resolver |
| **Routing table** | Мини-таблица/список | Table 1000/1001/main |

### Пример итоговой визуализации

```
                            ╭──── ISP (lte_br1) ─── via 192.168.1.1 ───╮
                            │     ████ активный путь ████               │
 ┌─────┐    ┌───────┐    ┌─┴────────────┐                       ┌─────┴─────┐
 │ 🖥️  │───▶│  DNS  │───▶│    ╔══════╗  │                       │    ☁️     │
 │     │    │6153   │    │    ║Keen- ║  │                       │ Интернет  │
 │ LAN │    │ya.ru→ │    │    ║etic  ║  │                       │           │
 │br0  │    │5.x.x  │    │    ╚══════╝  │                       └─────┬─────┘
 └─────┘    └───────┘    │  /|\ /|\ /|\ │                             │
                          └──┼───┼───┼───┘                             │
                             │   │   │                                 │
                             ╰── VPN (nwg0) ─── default route ─────────╯
                                 ░░░░ неактивный путь ░░░░
```

### Все пути видны — активный и неактивные

Ключевой принцип: схема показывает **ВСЕ доступные пути**, а не только выбранный.
Пользователь сразу видит куда трафик ИДЁТ и куда НЕ ИДЁТ:

| Путь | Стиль | Описание |
|------|-------|----------|
| **Активный** (match) | Яркая зелёная линия, animated dash, толстая | Куда реально пойдёт трафик |
| **Неактивные** (no match) | Серая пунктирная, тонкая, приглушённая | Куда трафик НЕ пойдёт |

Примеры:
- `ozon.ru` → **ISP (зелёный)**, VPN (серый) — "geo-split domain match, трафик через ISP"
- `github.com` → ISP (серый), **VPN (зелёный)** — "no match, трафик через default route (VPN)"
- `kaspi.kz` → **ISP (зелёный, subnet)**, VPN (серый) — "geo-split subnet CIDR match"

### Трёхслойное отображение результата

Чтобы не перегружать визуал, информация структурирована по слоям:

#### Слой 1: SVG-схема (визуальная, простая)

Только иконки + colored paths + **минимум** лейблов:
- Имя домена и resolved IP на DNS-ноде
- Имя интерфейса на линии
- Один badge-вердикт ("✓ geo-split" / "→ default")

Без технических деталей (table numbers, rule priorities, gateway IP) — для глаз.

#### Слой 2: Текстовый summary (одна строка, всегда видно)

```
✓ geo-split │ ozon.ru → 5.255.255.242 │ table 1000 (domain /32) │ lte_br1 via 192.168.1.1 │ 12ms
```

#### Слой 3: Technical details (collapsed, expandable ▸)

Полная информация в таблице:
- DNS: resolver, port, group, all IPs, time
- Route: table, match prefix, match type
- Interface: dev, gateway, source iface (iif)
- Default route (для сравнения)

```
┌─────────────────────────────────────────────────────┐
│  [SVG DIAGRAM — простая, красивая, 5 иконок, paths] │  ← слой 1
│                                                     │
│  ✓ geo-split │ lte_br1 via 192.168.1.1 │ 12ms      │  ← слой 2
│                                                     │
│  ▸ Technical details                                │  ← слой 3 (collapsed)
└─────────────────────────────────────────────────────┘
```

**Цветовые verdict-рамки** (без чтения текста):
- 🟢 Зелёная рамка = geo-split match (домен/подсеть)
- 🔵 Синяя/серая = default route (обычный путь)
- 🔴 Красная = ошибка (DNS fail, route not found)

---

## 🖼️ Технология рендеринга

### Решение: Inline SVG template (без библиотек)

**Почему:**
- `target-arch.md`: Simplicity 90%+, Over-engineering 5%
- WebUI уже на vanilla JS без build tools
- Для фиксированной топологии (5-7 нод) не нужен graph engine
- SVG viewBox → адаптивность из коробки
- CSS variables → тёмная тема бесплатно

**Файл:** `webui/static/route-diagram.js` (~300 LOC)

Содержит:
- SVG paths для иконок (роутер, облако, клиент, DNS)
- Layout функцию (фиксированные координаты, left-to-right flow)
- Highlight функцию (подсветка активного пути, анимация flow)
- Responsive scaling (viewBox + CSS width:100%)

**Почему НЕ библиотека:**

| Библиотека | Размер | Проблема |
|-----------|--------|----------|
| Mermaid | 300 KB | Overkill, свой стиль не кастомизируем |
| D3.js | 80 KB | Общий инструмент, нет готовых сетевых иконок |
| vis-network | 200 KB | Тяжёлый для 5 нод |
| SVG.js | 16 KB | Не нужен — наши SVG статические с highlight |
| GoJS | commercial | ❌ |

Для **5 фиксированных нод + 3-4 connections** inline SVG template —
оптимальное решение.

---

## 🧩 Архитектура

### Backend: `geo-split/scripts/route-check.sh`

```sh
#!/opt/bin/sh
# Route check for a domain/IP: DNS resolve + routing table lookup
# Usage: route-check.sh --json <domain-or-ip>
# Output: JSON with DNS + route info for each resolved IP
set -eu

# 1. DNS resolve (if domain)
# 2. For each IP: ip route get <IP> iif br0
# 3. Determine source: table 1000 (domain) / 1001 (subnet) / main
# 4. Output JSON
```

**JSON response:**
```json
{
  "ok": true,
  "query": "ozon.ru",
  "source_iface": "br0",
  "dns": {
    "resolver": "localhost:6153",
    "group": "ru",
    "ips": ["5.255.255.242", "5.255.255.241"],
    "time_ms": 12
  },
  "routes": [
    {
      "ip": "5.255.255.242",
      "dev": "lte_br1",
      "via": "192.168.1.1",
      "table": "1000",
      "table_name": "domains",
      "match_type": "host",
      "match_prefix": "5.255.255.242/32"
    }
  ],
  "default_route": {
    "dev": "nwg0",
    "via": ""
  },
  "verdict": "geo-split",
  "iface_label": "Beeline LTE"
}
```

> **Параметр `iif`** (source interface): определяет из какой сети проверять маршрут.
> Backend выполняет `ip route get <IP> iif <iif>`. Default = первый интерфейс из `ROUTE_IN` конфига.

### Source Interface selector

Данные для dropdown берутся из **уже существующего** API `/api/system/interfaces`
(возвращает список интерфейсов с NDM-лейблами). Фильтрация: только интерфейсы из `ROUTE_IN` (активные LAN/tunnel).

```
Dropdown: [Home LAN (br0) ▾]
           ├── Home LAN (br0)       ← default
           ├── Guest LAN (br1)
           └── VPN Client (nwg0)
```

Человеческие имена берутся из NDM interface labels (уже реализовано в config editor).

### API: Lua endpoints

В `webui/lua/api-router.lua` — новые **GET** endpoints (read-only диагностика, как status):

```lua
-- Tool 1: Route check
-- GET /api/geo-split/route-check?host=ozon.ru&iif=br0
-- iif — опционально (default из ROUTE_IN конфига)
["/api/geo-split/route-check"] = ...

-- Tool 2: DNS zone check
-- GET /api/smartdns/dns-check?host=ozon.ru
["/api/smartdns/dns-check"] = ...
```

Параметры передаются как query string (парсится в Lua, передаётся shell-аргументом).
**Санитизация:** `host` — только `[a-zA-Z0-9._-]`, `iif` — только `[a-z0-9_]`.
**Rate limit:** 1 req/sec (аналогично action_routes) — dig + ip route не мгновенные.

### Frontend: интеграция

```
webui/static/route-diagram.js    # SVG renderer + topology icons
webui/static/route-diagram.css   # стили схемы (анимации, адаптив)
webui/static/app.js              # + 2 кнопки + 2 модала + fetch + localStorage
```

---

## 🔗 DNS в Route Check (решение)

> «не понятно, как быть с dns — от него ведь тоже тест зависит»

**DNS отрисовывается как первая нода в схеме Route Check.** Полный путь на topology:

```
 🖥️ Client ──▶ ☁️ DNS SmartDNS ──▶ 📡 Router (Keenetic) ──▶ ☁️ Internet
    br0           :6153 ru-group       table 1000 match         via lte_br1
                  → 5.255.255.242      domain /32               via 192.168.1.1
```

Таким образом Route Check визуализирует **полный путь** включая DNS-шаг:
- Какой resolver и DNS-группа обслуживает домен
- Какой IP получен
- В какую route table попал → какой интерфейс

**Edge cases:**
- DNS fail → красная DNS-нода, путь обрывается
- IP введён напрямую → DNS-нода серая (skipped), сразу route
- Множественные IP → для каждого отдельная route-линия

---

## 🔵 Tool 2: DNS Zone Check (smartdns) — отдельный простой инструмент

Не визуализация топологии — а **быстрый ответ**: в какую DNS-зону попадает домен.

### Что показывает

Ввод: `ozon.ru` → Ответ:

| Поле | Значение |
|------|----------|
| **Zone group** | `ru` |
| **Match rule** | `/.ru/` (ccTLD) |
| **Upstream** | Yandex DoT + AdGuard DoT |
| **Resolved IP** | `5.255.255.242` |
| **Response time** | 14ms |
| **Interface** | direct (без VPN) |

### Визуализация

Можно использовать **ту же SVG-либу** но с лёгким layout (горизонтальный flow):

```
 ┌─────────┐      ┌───────────────┐      ┌──────────────┐      ┌─────────┐
 │  📝     │─────▶│  🔀 Zone      │─────▶│  📡 Upstream │─────▶│  📋     │
 │  Domain │      │  Matching     │      │  DNS Server  │      │ Result  │
 │ ozon.ru │      │  /.ru/ → ru   │      │  Yandex DoT  │      │5.x.x.x │
 └─────────┘      └───────────────┘      └──────────────┘      └─────────┘
                   nameserver rule          77.88.8.8:853         TTL: 300
                   group: ru               interface: direct      12ms
```

### Backend: `smartdns-geo-conf/scripts/dns-check.sh`

```sh
#!/opt/bin/sh
# DNS zone check: determine which group/upstream handles a domain
# Usage: dns-check.sh --json <domain>
set -eu

# 1. Match domain against zone-routing-rules.conf (ccTLD, explicit rules)
# 2. Determine DNS group (ru, by, kz, ... or default)
# 3. Identify upstream servers for that group
# 4. Resolve via dig @localhost -p 6053 +stats
# 5. Output JSON
```

**JSON response:**
```json
{
  "ok": true,
  "query": "ozon.ru",
  "zone": {
    "group": "ru",
    "match_rule": "/.ru/",
    "match_type": "ccTLD"
  },
  "upstream": {
    "providers": ["yandex", "adguard"],
    "interface": "direct"
  },
  "result": {
    "ips": ["5.255.255.242"],
    "ttl": 300,
    "time_ms": 14
  }
}
```

---

## 🎨 Цветовая схема (Keenetic dark theme)

Из CSS переменных проекта (`layout.css`):

| Элемент | Цвет | Переменная |
|---------|------|------------|
| Фон | `#1b2434` | `--background` |
| Текст | `#c2c2c2` | `--primary-text` |
| Активный path | `#7dce70` (зелёный) | `--indicator-online` |
| DNS/Primary | `#0086cb` (синий) | `--primary-color` |
| Warning | `#f2e572` (жёлтый) | `--indicator-yellow` |
| Error/fail | `#de3d3d` (красный) | `--error` |
| Inactive path | `#4d545f` (серый) | `--stroke` |
| Иконки | `#949b9f` (серый текст) | `--text-gray` |

**Активный путь** — зелёная линия с animated dash (марширующие муравьи):
```css
.route-path--active {
  stroke: var(--indicator-online, #7dce70);
  stroke-dasharray: 8 4;
  animation: flow 1s linear infinite;
}
```

---

## 📐 UX Flow

### Tool 1: Route Check (geo-split card)

1. Кнопка **"🔍 Route Check"** в карточке geo-split (header, рядом с Edit)
2. Открывается **модал** с:
   - Input: `Enter domain or IP (e.g. ozon.ru, 8.8.8.8)`
   - **Source interface selector** (dropdown): из какой сети проверять
     - Значения из `/api/system/interfaces` (уже есть) с человеческими именами:
       `Home LAN (br0)`, `Guest LAN (br1)`, `VPN Client (nwg0)`, etc.
     - Default: первый из конфига `ROUTE_IN` (обычно `br0`)
     - Передаётся как `?iif=br0` в API
   - Кнопка "Check" / Enter
   - **История** (pills/chips): последние проверенные домены из localStorage (×-кнопка удаления)
   - **[▶ Check All]** — запустить все домены из истории
3. Loading: skeleton/spinner в области диаграммы
4. Результат — **зависит от количества**:
   - **1-4 результата:** полные SVG-схемы вертикальным стеком (слой 1 + слой 2 + collapsed слой 3)
   - **5+ результатов (batch):** компактная таблица-сводка с кнопкой "Show ▸" для раскрытия SVG
5. Каждый результат имеет заголовок с доменом и кнопку "×" для удаления
6. Домен автоматически сохраняется в localStorage

### Tool 2: DNS Zone Check (smartdns card)

1. Кнопка **"🔍 DNS Check"** в карточке SmartDNS Geo-Config (header, рядом с Edit)
2. Открывается **модал** с:
   - Input: `Enter domain (e.g. ozon.ru, google.com)`
   - **История** (pills): последние проверенные домены из localStorage
3. Результат: **SVG flow** (domain → zone → upstream → result)
4. **Множественная проверка:** результаты стеком одна под другой + заголовок с доменом
5. Домен сохраняется в localStorage

### Layout: 1-4 результата (полные диаграммы)

```
┌──────────────────────────────────────────────────────────────┐
│ 🔍 Route Check                                          [×]  │
│                                                              │
│  [ ozon.ru_________ ] [Source: Home LAN (br0) ▾] [Check]    │
│                                                              │
│  History: [ozon.ru ×] [github.com ×] [ya.ru ×] [▶ Check All]│
│                                                              │
│  ─── ozon.ru ──────────────────────────────────── [×] ───    │
│  ┌─ SVG topology diagram ─────────────────────────────┐      │
│  │  🖥️ → DNS → 📡 Router →→ ISP (green) →→ ☁️       │      │
│  │                        ░░ VPN (gray)  ░░          │      │
│  └────────────────────────────────────────────────────┘      │
│  ✓ geo-split │ table 1000 (domain) │ lte_br1 │ 12ms         │
│  ▸ Technical details                                         │
│                                                              │
│  ─── github.com ──────────────────────────────── [×] ───     │
│  ┌─ SVG topology diagram ─────────────────────────────┐      │
│  │  🖥️ → DNS → 📡 Router ░░ ISP (gray)  ░░ ☁️       │      │
│  │                        →→ VPN (green) →→          │      │
│  └────────────────────────────────────────────────────┘      │
│  → default │ main table │ nwg0 │ 8ms                         │
│  ▸ Technical details                                         │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### Layout: 5+ результатов (batch table mode)

При "Check All" или ≥5 результатов — переключается в компактную таблицу:

```
┌──────────────────────────────────────────────────────────────┐
│ 🔍 Route Check — Batch Results (6/6 done)               [×]  │
│                                                              │
│  [ ______________ ] [Source: Home LAN (br0) ▾] [Check]       │
│  History: [ozon.ru ×] [github.com ×] [ya.ru ×] [▶ Check All]│
│                                                              │
│  Domain          Route              Interface   Verdict      │
│  ────────────────────────────────────────────────────────    │
│  ✓ ozon.ru       table 1000 /32     lte_br1    geo-split    │  [▸]
│  → github.com    main               nwg0       default      │  [▸]
│  ✓ ya.ru         table 1000 /32     lte_br1    geo-split    │  [▸]
│  ✓ kaspi.kz      table 1001 CIDR    lte_br1    geo-split    │  [▸]
│  → cloudflare.com main              nwg0       default      │  [▸]
│  ✗ bad.test      DNS FAILED         —          error        │  [▸]
│                                                              │
│  [▸] = клик раскрывает полную SVG-диаграмму для строки       │
└──────────────────────────────────────────────────────────────┘
```

Цветные индикаторы строк: ✓ зелёный, → серый/синий, ✗ красный.

### localStorage: история доменов

```javascript
// Key: 'ew-route-check-history' (Tool 1)
// Key: 'ew-dns-check-history'   (Tool 2)
// Value: JSON array of strings, max 20 items, newest first

// Save:
function saveToHistory(key, domain) {
  var history = JSON.parse(localStorage.getItem(key) || '[]');
  history = history.filter(function(d) { return d !== domain; }); // dedupe
  history.unshift(domain);                                        // newest first
  if (history.length > 20) history = history.slice(0, 20);        // cap at 20
  localStorage.setItem(key, JSON.stringify(history));
}

// Delete single:
function removeFromHistory(key, domain) { ... }

// Render: pills/chips with × buttons above results area
```

### Кнопка "Check All" (batch из истории)

Поведение:
- **Sequential** fetch (не параллельный!) — роутер не потянет 20 одновременных dig
- Progress: `Checking 3/8...` с индикатором (animated bar)
- Rate: ~1 req/сек (API rate-limit + естественная задержка dig)
- Результаты появляются в batch-таблице **по мере готовности**
- Автоматически переключается в batch table mode
- Порядок: по истории (newest first)
- Кнопка "Stop" для прерывания batch

Используется для быстрой проверки "а мои домены все правильно маршрутизируются?"
после изменения конфигурации (ROUTE_OUT, GEO_ZONE, domain list).

### Быстрые примеры (для новичков)

Под input — кликабельные примеры:
```
  Try: ozon.ru • github.com • 8.8.8.8
```
Клик → сразу запускает проверку (без ручного ввода). Помогает при первом знакомстве.

---

## 🔗 Общая SVG-библиотека: `route-diagram.js`

Оба инструмента используют **один файл**:

```javascript
// route-diagram.js — shared SVG topology/flow renderer
//
// Public API:
//   renderRouteDiagram(container, routeCheckData)   — Tool 1 (geo-split topology)
//   renderDnsDiagram(container, dnsCheckData)       — Tool 2 (smartdns flow)
//
// Shared internals:
//   ICONS = { cloud, router, client, dns, table, server }
//   drawNode(svg, type, x, y, label, status)
//   drawConnection(svg, from, to, active, label)
//   highlightPath(svg, nodeIds, color)
```

---

## 📐 Файловая структура

```
# Backends
geo-split/scripts/route-check.sh           # Tool 1: dig + ip route get → JSON
smartdns-geo-conf/scripts/dns-check.sh      # Tool 2: zone match + dig → JSON

# API (in webui/lua/api-router.lua)
POST /api/geo-split/route-check?host=...    # Tool 1
POST /api/smartdns/dns-check?host=...       # Tool 2

# Frontend (shared SVG lib)
webui/static/route-diagram.js              # SVG renderer (icons, 2 layouts, highlight)
webui/static/route-diagram.css             # стили (анимации, адаптив, dark theme)

# Frontend (integration)
webui/static/app.js                        # + 2 кнопки + 2 модала
```

---

## 📊 Оценка effort

| Компонент | Effort | Сложность |
|-----------|--------|-----------|
| `route-check.sh` (backend Tool 1) | 1.5ч | Low |
| `dns-check.sh` (backend Tool 2) | 2ч | Medium (zone matching) |
| 2× API endpoints в Lua (+ sanitize + rate-limit) | 1.5ч | Low |
| SVG иконки (роутер, облако, клиент, DNS, server) | 2-3ч | Medium |
| `route-diagram.js` (shared renderer, 2 layouts) | 4-5ч | Medium |
| `route-diagram.css` (анимации, адаптив) | 1ч | Low |
| UI: модалы + interface selector + history pills | 3ч | Medium |
| UI: batch table mode + sequential runner + progress | 2ч | Medium |
| UI: localStorage + "Check All" + examples | 1ч | Low |
| **Итого** | **~18-20ч** | |

---

## 🗂️ Порядок реализации

```
Phase 1 — Backend (тестируется из CLI/curl):
  1. route-check.sh (geo-split) — dig + ip route get + JSON
  2. dns-check.sh (smartdns-geo-conf) — zone match + dig + JSON
  3. API endpoints в Lua (GET, query params, sanitize, rate-limit)

Phase 2 — SVG Library:
  4. Иконки SVG (статический прототип в HTML файле)
  5. route-diagram.js: renderRouteDiagram() — topology layout
  6. route-diagram.js: renderDnsDiagram() — flow layout
  7. route-diagram.css (dark theme, animated paths)

Phase 3 — UI Integration:
  8. Route Check модал (input + interface selector + check button)
  9. DNS Check модал (input + check button)
  10. localStorage history (pills, save, delete)
  11. Batch mode: sequential runner, progress, table view
  12. Polish: "Try" examples, keyboard, responsive, edge cases
```

---

## 💡 Будущее расширение

- **Тест из domain list:** dropdown с доменами из `geo-split-data/lists/domains.txt` (кнопка "Check domain list")
- **Export:** кнопка "Copy SVG" / "Copy as text" для вставки в форумы/документацию
- **DNS Redirect проверка:** третий визуал — через какой интерфейс перехватывается DNS клиента
- **Сравнение:** Route Check показывает "а если бы geo-split был выключен" (only main table)
- **Watchdog/monitoring:** периодическая проверка из списка + алерт при аномалиях

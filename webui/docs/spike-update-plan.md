# WebUI Spike Update Plan

**Дата:** 2026-04-18  
**Статус:** 📋 Ready for implementation  
**Основа:** [router-1-admin-study.md](../../docs/knowledge/keenetic-webui-research/router-1-admin-study.md) + [keenetic-dom-catalog.md](../../docs/knowledge/keenetic-webui-research/keenetic-dom-catalog.md)

---

## Knowledge Base Context

| Документ | Содержание |
|----------|-----------|
| [router-1-admin-study.md](../../docs/knowledge/keenetic-webui-research/router-1-admin-study.md) | Полное исследование UI: 346 CSS vars, навигация, API паттерны, сравнение, план улучшений |
| [keenetic-dom-catalog.md](../../docs/knowledge/keenetic-webui-research/keenetic-dom-catalog.md) | Каталог DOM-классов: 23 компонента, 93 ndw-* классов, copy-paste HTML для каждого элемента |
| [screenshots/](../../docs/knowledge/keenetic-webui-research/screenshots/) | 6 скриншотов стокового UI (login, dashboard, menu, settings, OPKG, diagnostics) |
| [01-09 research docs](../../docs/knowledge/keenetic-webui-research/) | Pre-existing: архитектура, авторизация, API, интеграция, security |

---

## Цель

Обновить spike webui так, чтобы он **выглядел как нативная часть Keenetic**, используя стоковый CSS и DOM-классы. Показывать только то, чего **нет** в стоковом UI: geo-split, smartdns, dns-redirect.

## Принципы

1. **Zero custom CSS** для визуальных свойств — только стоковые Keenetic классы и CSS переменные
2. **Copy DOM structure** из стока — карточки, кнопки, статусы, переключатели
3. **Не дублировать** стоковый функционал (system info, traffic, WiFi)
4. **`status.sh --json`** для structured API данных, текст для CLI

---

## Batch 1: Native Look (файлы: `style.css`, `index.html`)

### 1.1 Удалить `style.css`

Полностью удалить файл `webui/static/style.css` (223 строки). Заменить на минимальный `layout.css` (~25 строк) с ТОЛЬКО layout-правилами.

### 1.2 Создать `layout.css`

```css
/* layout.css — ТОЛЬКО layout, НИКАКИХ визуальных свойств */
/* Все цвета, шрифты, тени — от стокового CSS Keenetic */

body {
    font-family: 'Roboto', sans-serif;
    margin: 0;
    padding: 0;
    background: var(--background);
    color: var(--primary-text);
    min-height: 100vh;
}

.ew-page { padding: 24px; }
.ew-services { display: flex; flex-direction: column; gap: 0; }
.ew-service-row { display: flex; align-items: center; gap: 12px; padding: 10px 0; }
.ew-service-row + .ew-service-row { border-top: 1px solid var(--stroke); }
.ew-service-info { flex: 1; }
.ew-service-meta { color: var(--text-gray); font-size: 12px; margin-top: 2px; }
.ew-toggle-wrap { flex-shrink: 0; }

/* hidden utility */
.ew-hidden { display: none !important; }
```

### 1.3 Переписать `index.html`

> **Ref:** DOM-классы из [keenetic-dom-catalog.md](../../docs/knowledge/keenetic-webui-research/keenetic-dom-catalog.md):
> §1 Dashboard Card, §3 Status Badges, §4 Buttons, §11 Tabs, §17 Page Wrapper, §19 Block Header

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Entware Extras</title>
    <link rel="shortcut icon" type="image/x-icon" href="/assets/images/favicon/favicon.ico">
    <!-- Стоковый CSS Keenetic (через proxy) -->
    <link rel="stylesheet" href="/styles-J4CVWJOW.css">
    <!-- Наш минимальный layout -->
    <link rel="stylesheet" href="layout.css">
</head>
<body>

  <!-- Page wrapper в стиле Keenetic -->
  <div class="ndw-page-wrapper">
    <div class="ndw-page-wrapper__header">
      <h1 class="ndw-page-wrapper__title">Entware Extras</h1>
    </div>
    
    <!-- Tabs: Geo-Split / SmartDNS / DNS Redirect -->
    <div class="ndw-tabs" id="service-tabs">
      <div role="tablist" class="ndw-tabs__list">
        <div tabindex="0" class="ndw-tabs__tab ndw-tabs__tab--active"
             id="tab-all" role="tab" aria-selected="true"
             onclick="switchTab('all')">
          <div class="ndw-tabs__tab__label">All Services</div>
        </div>
        <div tabindex="0" class="ndw-tabs__tab"
             id="tab-geo-split" role="tab" aria-selected="false"
             onclick="switchTab('geo-split')">
          <div class="ndw-tabs__tab__label">Geo-Split</div>
        </div>
        <div tabindex="0" class="ndw-tabs__tab"
             id="tab-smartdns" role="tab" aria-selected="false"
             onclick="switchTab('smartdns')">
          <div class="ndw-tabs__tab__label">SmartDNS</div>
        </div>
        <div tabindex="0" class="ndw-tabs__tab ndw-tabs__tab--last"
             id="tab-smartdns-redirect" role="tab" aria-selected="false"
             onclick="switchTab('smartdns-redirect')">
          <div class="ndw-tabs__tab__label">DNS Redirect</div>
        </div>
      </div>
    </div>
    
    <div class="ndw-page-wrapper__content">
      
      <!-- Geo-Split card -->
      <div class="dashboard-card" id="card-geo-split">
        <div class="dashboard-card__header">
          <span class="text-card-heading">GEO-SPLIT</span>
          <div class="dashboard-card__header-buttons">
            <button class="ndw-button ndw-button--toggle ndw-button--toggle-enabled ndw-button--small ndw-button--no-text"
                    onclick="fetchStatus('/api/geo-split/status', 'geo-split')" title="Refresh">
              ⟳
            </button>
          </div>
        </div>
        <div class="dashboard-card__content" id="content-geo-split">
          <div class="ew-service-row">
            <div class="ew-toggle-wrap">
              <!-- Toggle будет добавлен позже (Batch 3) -->
            </div>
            <div class="ew-service-info">
              <div class="ndw-status ndw-status--chip" id="status-geo-split">
                <div class="status">
                  <div class="status__text">Loading...</div>
                </div>
              </div>
            </div>
          </div>
          <div id="details-geo-split">
            <!-- Structured details from status.sh --json -->
          </div>
        </div>
      </div>
      
      <!-- SmartDNS card -->
      <div class="dashboard-card" id="card-smartdns">
        <div class="dashboard-card__header">
          <span class="text-card-heading">SMARTDNS</span>
          <div class="dashboard-card__header-buttons">
            <button class="ndw-button ndw-button--toggle ndw-button--toggle-enabled ndw-button--small ndw-button--no-text"
                    onclick="fetchStatus('/api/smartdns/status', 'smartdns')" title="Refresh">
              ⟳
            </button>
          </div>
        </div>
        <div class="dashboard-card__content" id="content-smartdns">
          <div class="ew-service-row">
            <div class="ew-service-info">
              <div class="ndw-status ndw-status--chip" id="status-smartdns">
                <div class="status">
                  <div class="status__text">Loading...</div>
                </div>
              </div>
            </div>
          </div>
          <div id="details-smartdns"></div>
        </div>
      </div>
      
      <!-- SmartDNS Redirect card -->
      <div class="dashboard-card" id="card-smartdns-redirect">
        <div class="dashboard-card__header">
          <span class="text-card-heading">DNS REDIRECT</span>
          <div class="dashboard-card__header-buttons">
            <button class="ndw-button ndw-button--toggle ndw-button--toggle-enabled ndw-button--small ndw-button--no-text"
                    onclick="fetchStatus('/api/smartdns-redirect/status', 'smartdns-redirect')" title="Refresh">
              ⟳
            </button>
          </div>
        </div>
        <div class="dashboard-card__content" id="content-smartdns-redirect">
          <div class="ew-service-row">
            <div class="ew-service-info">
              <div class="ndw-status ndw-status--chip" id="status-smartdns-redirect">
                <div class="status">
                  <div class="status__text">Loading...</div>
                </div>
              </div>
            </div>
          </div>
          <div id="details-smartdns-redirect"></div>
        </div>
      </div>
      
    </div>
  </div>

  <script src="app.js"></script>
</body>
</html>
```

### 1.4 Убрать `@font-face` из нового CSS

Roboto доступен через стоковый CSS Keenetic — не нужен свой `@font-face`.

### 1.5 Убрать System Info card

System info (hostname, uptime, memory, disk) уже показывается на стоковом Dashboard. Не дублируем.

---

## Batch 2: Structured API (файлы: `status.sh` ×3, `api-router.lua`, `app.js`)

### 2.1 `status.sh --json` для всех сервисов

Каждый `scripts/status.sh` получает флаг `--json`:

```sh
#!/opt/bin/sh
set -eu

# ... existing checks ...

if [ "${1:-}" = "--json" ]; then
    # JSON output for webui
    printf '{"running":%s,"pid":"%s","memory_kb":"%s","details":{...}}' \
        "$is_running" "$pid" "$mem_kb"
else
    # Text output for CLI (existing behavior)
    echo "    Process: running (pid $pid) ✓"
fi
```

Затронутые файлы:
- `geo-split/scripts/status.sh`
- `smartdns-conf-ru-split/scripts/status.sh`
- `smartdns-redirect/scripts/status.sh`
- `webui/scripts/status.sh`

### 2.2 `api-router.lua` — вызов с `--json`

```lua
-- Изменить status_routes: добавить --json
local status_routes = {
    ["/api/geo-split/status"]        = base .. "/geo-split/scripts/status.sh --json 2>&1",
    ["/api/smartdns/status"]          = base .. "/smartdns-conf-ru-split/scripts/status.sh --json 2>&1",
    ["/api/smartdns-redirect/status"] = base .. "/smartdns-redirect/scripts/status.sh --json 2>&1",
}

-- Для JSON ответов: возвращать output напрямую (уже JSON), не оборачивать в строку
-- Нужно определять: если output начинается с '{' → пробросить как JSON
```

### 2.3 `app.js` — structured card rendering

```js
// Вместо setOutput(id, text) → renderServiceCard(id, data)
function renderServiceCard(id, data) {
    const statusEl = document.getElementById('status-' + id);
    const detailsEl = document.getElementById('details-' + id);
    
    // Status badge
    if (data.running) {
        statusEl.innerHTML = '<div class="status status--success">' +
            '<div class="status__icon"></div>' +
            '<div class="status__text">Running (pid ' + data.pid + ')</div></div>';
    } else {
        statusEl.innerHTML = '<div class="status">' +
            '<div class="status__text">Stopped</div></div>';
    }
    
    // Details
    if (data.details) {
        detailsEl.innerHTML = renderKeyValue(data.details);
    }
}

function renderKeyValue(obj) {
    return Object.entries(obj).map(([k, v]) =>
        '<div class="ew-service-row">' +
        '<span style="color:var(--text-gray)">' + k + '</span>' +
        '<span style="color:var(--primary-text); margin-left:auto;">' + v + '</span>' +
        '</div>'
    ).join('');
}
```

### 2.4 Убрать `fetchSystemInfo()`

Функция `fetchSystemInfo()` удаляется — system info не дублируем.

---

## Batch 3: inject.js — Dashboard Card + улучшения (файл: `inject.js`)

> **Ref:** [keenetic-dom-catalog.md](../../docs/knowledge/keenetic-webui-research/keenetic-dom-catalog.md) §5 Sidebar Menu Header, §6 Page Links, §7 SVG Icons, §10 Full Dashboard Card Example
> **Ref:** [router-1-admin-study.md](../../docs/knowledge/keenetic-webui-research/router-1-admin-study.md) §7 Summary-блок на Dashboard

### 3.1 Dashboard summary card injection

На странице `/dashboard` (проверяем `location.pathname`) инжектируем карточку `ENTWARE EXTRAS` с кликабельными названиями сервисов и live-статусом.

Структура — из [keenetic-dom-catalog.md § 10](../../docs/knowledge/keenetic-webui-research/keenetic-dom-catalog.md).

### 3.2 Использовать реальную иконку из sprite

Заменить хардкоженный `settings+` на реальную иконку:

```js
// Вместо кастомной иконки с "+" overlay:
header.innerHTML = '<ndw-svg-icon class="menu-subtitle__icon">' +
    '<svg class="ndw-svg-icon svg-settings-dims">' +
    '<use href="./assets/sprite/sprite.svg#extensions"></use>' +
    '</svg></ndw-svg-icon>' +
    '<span class="ew-group-text">ENTWARE EXTRA</span>';
```

### 3.3 Sidebar items — стоковые классы

Заменить кастомные `.ew-link` на стоковые `page-link__link text-menu-item`:

```js
var link = document.createElement('a');
link.className = 'page-link__link text-menu-item page-link__link--wrapped';
link.setAttribute('role', 'menuitem');
link.tabIndex = 0;
var span = document.createElement('span');
span.className = 'page-link__label';
span.textContent = item.label;
link.appendChild(span);
```

### 3.4 Active state — стоковый класс

```js
// Active: page-link__link--active (вместо ew-link--active)
link.classList.add('page-link__link--active');
```

---

## Batch 4: Polish (файлы: `app.js`, `layout.css`, `nginx.conf`)

### 4.1 Адаптивный polling

```js
// 5s когда страница видима, 60s когда скрыта (фоновая вкладка)
const POLL_ACTIVE = 5000;
const POLL_BACKGROUND = 60000;

document.addEventListener('visibilitychange', () => {
    clearInterval(autoRefreshTimer);
    autoRefreshTimer = setInterval(refreshAll,
        document.hidden ? POLL_BACKGROUND : POLL_ACTIVE);
});
```

### 4.2 CSS filename resilience

Стоковый CSS имеет hash в имени (`styles-J4CVWJOW.css`). При обновлении прошивки hash сменится. Решения:

**Вариант A (простой)**: В nginx.conf добавить rewrite:
```nginx
# Fallback для кэшированного CSS filename
location ~* /styles-\w+\.css$ {
    proxy_pass http://keenetic_ui;
}
```

**Вариант B (robust)**: В `inject.js` определить актуальный CSS URL из parent document:
```js
var stockCSS = document.querySelector('link[rel="stylesheet"][href*="styles-"]');
if (stockCSS) {
    // Сообщить iframe актуальный URL через postMessage
}
```

### 4.3 Toast Notifications

При ошибках API — показывать toast вместо текста в карточке:

```js
function showToast(message, type) {
    // type: 'success' | 'warning' | 'error'
    var container = document.querySelector('.ndw-notification-container')
        || document.body;
    var toast = document.createElement('div');
    toast.className = 'ndw-notification ndw-notification--' + type;
    toast.textContent = message;
    container.appendChild(toast);
    setTimeout(() => toast.remove(), 5000);
}
```

---

## Файлы для изменения (итого)

| Файл | Действие | Batch |
|------|----------|-------|
| `webui/static/style.css` | **Удалить** | 1 |
| `webui/static/layout.css` | **Создать** (~25 строк) | 1 |
| `webui/static/index.html` | **Переписать** (стоковые DOM-классы) | 1 |
| `webui/static/app.js` | **Переписать** (structured rendering, убрать system info, adaptive polling) | 2 + 4 |
| `webui/lua/api-router.lua` | **Изменить** (--json, passthrough JSON) | 2 |
| `geo-split/scripts/status.sh` | **Добавить** --json flag | 2 |
| `smartdns-conf-ru-split/scripts/status.sh` | **Добавить** --json flag | 2 |
| `smartdns-redirect/scripts/status.sh` | **Добавить** --json flag | 2 |
| `webui/static/inject.js` | **Переработать** (stock classes, dashboard card, svg icons) | 3 |
| `webui/config/nginx.conf` | **Добавить** CSS fallback rewrite | 4 |

## Зависимости между батчами

```
Batch 1 (Native Look)     — независимый, можно начинать сразу
Batch 2 (Structured API)  — независимый от Batch 1, можно параллельно
Batch 3 (inject.js)       — зависит от Batch 2 (нужен JSON API для dashboard card)
Batch 4 (Polish)          — зависит от Batch 1+2
```

## Definition of Done

- [ ] Наш UI внутри iframe неотличим от стокового Keenetic по стилю
- [ ] Dark + Light тема автоматически наследуется
- [ ] System info card убрана (не дублируем сток)
- [ ] API возвращает structured JSON
- [ ] Sidebar items используют стоковые `page-link__*` классы
- [ ] Dashboard card инжектируется с live-статусами сервисов
- [ ] Polling адаптивный (5s/60s)

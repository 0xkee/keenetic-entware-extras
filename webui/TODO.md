# WebUI — TODO

> Обновлено 2026-04-29. v0.3.0: Angular-native card — пустой CDK row (sub_filter #9 ngTemplateOutlet=null), inject.js создаёт card DOM с нуля. Удалены хаки: CSS stub hiding, header patch, dialog toggle/header patches. Target: `.project/target-arch.md`.

## 🎯 Спайки — свой template для Angular

- [x] **Spike A: Проверить нативность dialog** ✅ — удалены header/toggle патчи из `injectIntoCardsDialog()` и `_repatchDialogEntwareRow()`. **Результат: Angular рендерит ENTWARE_EXTRAS нативно** — header "ENTWARE EXTRAS" (из dXe), aria-label "ENTWARE_EXTRAS" (из Po), toggle state (FormControl). inject.js change handler оставлен только для dashboard sync. Скриншот: `docs/screenshots/spike-a-dialog-native.png`
- [x] **Spike D: Пустой CDK row** ✅ — sub_filter #3 → `{__ew:1}` (truthy), sub_filter #9 → `ngTemplateOutlet: templateMap.has(e)?getTemplate(e):null`. Dashboard: пустой CDK row, inject.js создаёт card DOM. Dialog: Bli template нативно. Скриншот: `docs/screenshots/spike-d-entware-card-visible.png`
- [x] **Spike E: Dashboard хаки удалены** ✅ — `ewPatchDashboardRow()` создаёт полный card DOM в пустом row. CSS stub hiding удалён. Header patch удалён. Loading skeleton удалён. `ewUnpatchRow()` упрощён.

## 🔴 Критичные (логи / disk I/O) — ✅ ВЫПОЛНЕНО

- [x] **nginx: access_log conditional** — `map $uri $loggable` + `if=$loggable` фильтрует /rci/, /auth, статику (~85% шума). Результат: access.log ~1.5MB/день вместо ~10MB
- [x] **nginx: увеличить proxy_buffers** — `proxy_buffer_size 16k; proxy_buffers 8 32k; proxy_busy_buffers_size 64k`. Устранено 98% error.log warn'ов + temp file disk I/O
- [x] **nginx: error_log level warn → error** — `config/nginx.conf:14`, только реальные ошибки
- [x] **logrotate: ротация nginx-webui логов** — `logrotate` в Depends `packaging/webui/control`, конфиг `webui/config/logrotate.conf` (daily, rotate 3, compress, USR1 reopen), cron.daily wrapper
- [x] **packaging/webui/ создан** — `control` (Depends: keenetic-entware-extras, nginx, nginx-mod-lua, logrotate), `conffiles`, `postinst`, `prerm`, `postrm`
- [x] **nginx: proxy_intercept_errors для 502** — `error_page 502 503 504 /custom/502.html`, stock-styled страница с auto-refresh 5с
- [x] **inject.js: DRY рефакторинг** — вынесена `applyServiceData()`, устранено дублирование (1410 → 1385 строк)
- [x] **status.sh: logrotate в статусе** — проверка binary/config/cron, поле `"logrotate": true/false` в JSON

## 🔴 Критичные (drag duplication) — ✅ ВЫПОЛНЕНО (v0.2.1)

- [x] **inject.js: replaceChildren → hide + append** — `ewPatchDashboardRow()` теперь скрывает Angular-managed контент (`display:none` + `.ew-hidden-original`) вместо удаления. Angular ViewRef остаётся нетронутым
- [x] **inject.js: ewUnpatchRow() reversible** — удаляет `#entware-dash-content`, восстанавливает скрытый Angular контент и оригинальный заголовок из `dataset.ewOrigTitle`/`ewOrigHref`
- [x] **nginx: drop-патч pre-move + dedupe** — sub_filter #5 разбит на 5a (IIFE pre-move: подмена source slot) + 5b (post-emit: dedupe-only). Флаг через `window.__ewDrag`

## 🔴 Cards Position + Dashboard drag — ✅ ВЫПОЛНЕНО (v0.2.3)

- [x] **Toggle "слипшийся"** — Root cause: `Control at ENTWARE_EXTRAS not found` — Angular FormGroup не имел контрола для ENTWARE. Fix: sub_filter #6 добавляет ENTWARE_EXTRAS в Po enum, #8 bypass isCardAvailable → Angular создаёт FormControl нативно. Toggle обрабатывается Angular, ошибка устранена.
- [x] **Cross-column drag flicker** — Root cause: singleton `_dialogRepatchObserver` покрывал только последний column-wrapper. Fix: `_dialogRepatchObservers` array — каждый wrapper получает свой observer. rAF убран → patch в microtask.
- [x] **Reconciler ошибочно патчит stock card** — Root cause: index-based lookup без валидации содержимого. Fix: fingerprint guard в `ewPatchDashboardRow()` — проверяет наличие `ndw-*-card` компонентов, не патчит реальные stock cards.

## 🟡 Важные

- [ ] **Sidebar menu: config-driven при реанимации** — если будем возвращать sidebar меню (`injectSidebar`), сделать его config-driven аналогично dashboard card (CUSTOM_ITEMS/SERVICE_APIS → shared config в `EW.*` или `__ewConfig`). Не хардкодить список пунктов в inject.js.

- [x] **Refresh button: emoji → SVG sprite** ✅ — устарело, старый iframe-based index.html заменён на tab-архитектуру (app.js)
- [x] **CUSTOM_ITEMS: добавить DNS Redirect** — добавлен smartdns-redirect в sidebar
- [x] **Dashboard card: стоковый вид** — переписан на stock DOM-классы, toggle switches, status chips, expandable details, localStorage persist
- [ ] **Sidebar icon: #settings → уникальная иконка** — `inject.js` использует `#settings` (та же что у MANAGEMENT), рассмотреть `#extensions` или другую из sprite
- [x] **Light theme: проверить CSS fallback** ✅ — проверено, корректно
- [x] **Status.sh: добавить geo domain и upstream DNS** ✅ — geo-split: `geo_zone` в JSON; dns-redirect: `upstream` + `name` в JSON
- [x] **Fast polling для всех сервисов** ✅ — `startTogglePoller(serviceId, targetRunning)`: 1s fast-poll после toggle до совпадения `data.running === target` или timeout 10s. `stopAllTogglePollers()` при route change / card hide.

## 🟡 Средние

- [x] **postinst: автоопределение listen IP** ✅ — `postinst` определяет IP через `ip route get 1 | awk src`, `sed -i` заменяет non-loopback listen в `nginx.conf`. Safe on upgrade (conffile preserved).
- [x] **Init script: AGENTS.md compliance** ✅ — `S80nginx-webui` использует `#!/opt/bin/sh` + `set -eu`
- [x] ~~**nginx: user root → privilege separation**~~ — won't fix: LAN-only, всё на роутере от root, lua вызывает только фиксированные команды без user input. Пересмотреть при WAN-доступе.
- [x] **inject.js: window.showInContent утечка** — заменено на addEventListener
- [x] **inject.js: setInterval pathname polling** ✅ — неактуально: MutationObserver покрывает DOM-изменения, 2с poll — одно сравнение строк (нулевая нагрузка), popstate не ловит pushState Angular Router
- [x] **Toggle switches: подключить к backend** ✅ — inject.js wires toggle → `POST /api/{service}/start|stop`, обработка ответов, re-fetch
- [ ] **Webui pluggable modules** — сделать архитектуру расширяемой (geo, smartdns как модули)

## 🟢 Мелкие / Cleanup

- [x] **Dashboard card header: кликабельный заголовок** — `<span>` с hover underline, ведёт на /custom/
- [x] **Dashboard card: drag-and-drop icon** — SVG sprite 6 dots
- [x] **Dashboard card: expand details** — 4-square icon, expandable grid, localStorage persist
- [x] **iframe page card headers: `<span>` → ссылки** ✅ — устарело, iframe-архитектура удалена

# WebUI — TODO

> Обновлено 2026-04-29. v0.3.0: Angular-native card — пустой CDK row (sub_filter #9 ngTemplateOutlet=null), inject.js создаёт card DOM с нуля. Удалены хаки: CSS stub hiding, header patch, dialog toggle/header patches. Target: `.project/target-arch.md`.

## 🎯 Спайки — свой template для Angular

- [x] **Spike A: Проверить нативность dialog** ✅ — удалены header/toggle патчи из `injectIntoCardsDialog()` и `_repatchDialogEntwareRow()`. **Результат: Angular рендерит ENTWARE_EXTRAS нативно** — header "ENTWARE EXTRAS" (из dXe), aria-label "ENTWARE_EXTRAS" (из Po), toggle state (FormControl). inject.js change handler оставлен только для dashboard sync. Скриншот: `docs/screenshots/spike-a-dialog-native.png`
- [x] **Spike D: Пустой CDK row** ✅ — sub_filter #3 → `{__ew:1}` (truthy), sub_filter #9 → `ngTemplateOutlet: templateMap.has(e)?getTemplate(e):null`. Dashboard: пустой CDK row, inject.js создаёт card DOM. Dialog: Bli template нативно. Скриншот: `docs/screenshots/spike-d-entware-card-visible.png`
- [x] **Spike E: Dashboard хаки удалены** ✅ — `ewPatchDashboardRow()` создаёт полный card DOM в пустом row. CSS stub hiding удалён. Header patch удалён. Loading skeleton удалён. `ewUnpatchRow()` упрощён.

## 🔴 OOM на 128MB MIPS роутерах (router-4 KN-2310)

> Диагностика 2026-07-21. **214 OOM-kills** nginx workers в error.log (`exited on signal 9`).
> При работе webui 0.33.2 на 128MB MIPS (router-4, firmware 5.1.1): available RAM падает с 32 MB до 5 MB,
> io.popen() в Lua порождает sh-процессы → OOM Killer убивает nginx workers → master
> respawn → повторный OOM = death loop (load 30+, CPU 100%).
>
> **Не связано с v4 patch** — патч-код v3/v4 идентичен (`families/signal.sh`).
> Причина: рост memory footprint прошивки 5.1.1 + webui 0.33.2 (новые API, Lua-эндпоинты)
> превысил 128MB бюджет. На 512MB (router-2 KN-1011) проблем нет.
>
> Бюджет: ndm 23MB + smartdns 11MB + stock_nginx 20MB = 54MB baseline.
> webui: 5 nginx proc (14MB RSS) + tmpfs (12MB) + io.popen спайки → >128MB → OOM.
--- это уже сделано

- [ ] добавить бейджи в кастом (насчет дашборда - оценить нужноли), в виде как на мобилах красный кружок у приложений (правый верхний угол), в которм показывать число ошибок по пакету, и ещё желтый треугольник с предупрежденниям (треугольник левее если есть), всё это в табах кастома, в названиях пакетов табов
- [-] **F1: `worker_processes 1`** — (может быть потом, если возникнет необходимость) `nginx.conf:21`, сейчас `auto`.
- [x] **F2: Минимальный кеш** — `patch-stock-ui.sh` копирует только `index.html` + `main-*.js` + `polyfills-*.js` + `styles-*.css` + `.gz`
  в `webui/htdocs-cache/` (на /opt). Остальное отдаётся nginx `@stock` напрямую с flash. Экономия: ~4 MB I/O.
- [x] **F3: Fallback-location на flash** — `nginx.conf`: `try_files $uri @stock;` + `location @stock { root /usr/share/htdocs_; }`.
  Непатченные файлы (`assets/`, `wizards/`, `ndm*.js`, `worker-*.js`) идут напрямую с flash.
- [-] **F4: `gzip -1` вместо `-6`** — (может быть потом, если возникнет необходимость) `patch-stock-ui.sh:149`. Level 6 vs Level 1.
- [-] **F5: Объединить 9 sed в 1** — (может быть потом, если возникнет необходимость) `families/signal.sh` и `families/setter.sh`.

**F1 = ~6 MB RAM** при переключении на 1 worker.

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

## 🔴 Navigation fixes — ✅ ВЫПОЛНЕНО (v0.20.1)

- [x] **Sidebar broken after custom page visit** — Root cause: `removeIframe()` не восстанавливала `display` скрытых Angular-элементов. Fix: восстановление `dataset.entwareHidden` при удалении iframe.
- [x] **Browser back/forward не работает** — Root cause: `showInContent()` не делала `pushState`, `switchTab()` использовала `replaceState`. Fix: pushState в обоих + popstate listeners.

## 🔴 WebUI DRY Refactoring R1-R9 — ✅ ВЫПОЛНЕНО (v0.31.1)

- [x] **R-1**: Details rendering dedup — `EW.renderDetailValue()`, `EW.renderUpdateBtn()`, `EW.detailValueStyle()` в shared.js
- [x] **R-2**: Toggle polling dedup — `EW.createTogglePoller()` factory в shared.js
- [x] **R-3**: Удалён `_ensureIfaceMap()` из route-check.js → `EW.loadIfaceMap()`
- [x] **R-4**: Экспорт `EW.ifaceLabelShort()`; удалены `_ifaceLabel()` из route-diagram.js и route-check.js
- [x] **R-5**: `EW.escapeHtml()` в shared.js; удалены дубли из app.js и route-check.js
- [x] **R-6**: `EW.getService(id)` helper; заменены lookup loops в app.js и inject.js
- [x] **R-7**: Config Editor (~790 строк) вынесен из app.js в config-editor.js (app.js: 1898→1034)
- [x] **R-8**: Унификация Route Check / DNS Check модалей через `_openCheckModal()` factory
- [x] **R-9**: `EW.hasFailField()` в shared.js; удалён из inject.js и inline из app.js

## � Важные

- [x] **Route check из WebUI** ✅ — проверка выбора маршрута для конкретного хоста/домена прямо из интерфейса (диагностика: через какой интерфейс/таблицу пойдёт трафик).
- [x] **Route check: цветные history pills** ✅ — бейджи в истории окрашены по verdict последнего теста (зелёный=geo-split, синий=tunnel, оранжевый=mixed). localStorage: `[{d:"domain", v:"tunnel"}]`, backward-compat с plain strings.
- [x] **Route check: стилизация Technical Details** ✅ — good enough: секции с цветными заголовками, двухколоночная таблица, multi-line IPs с border-разделителями, verdict badges, humanized interface names. Проверено 2026-07-07.
- [x] **Route check: показывать policy name для tunnel клиентов** ✅ — реализовано в v0.31.0 (Interface humanization system): `ifaceLabelShort()` маппит `nwg0` → "FirstVDS Holland" и т.д. через `/api/system/interfaces`. Работает в Routes per IP, Via колонке batch-таблицы и на SVG-диаграмме.
- [x] **Route check: семантические названия секций в Tech Details** ✅ — закрыто вместе со стилизацией (good enough). Текущие названия (DNS, Routes per IP, Default Route) достаточно ясны.
- [x] **Route check: IPs overflow в batch tech details** ✅ — `_multiLine()` рендерит каждый IP как `<div>` (block-level), overflow не воспроизводится. Проверено 2026-07-07.
- [x] добавить Upstream в status + webui (Ok когда доступен) ✅ — `check_upstream()` в status.sh: парсит listen.conf для IP, curl probe. JSON: `details.upstream` (addr) + `checks.upstream` ("ok"|"warn"). Карточка рендерит автоматически через `parseDetails`.
- [x] **Модалы диагностики: увеличить размер** ✅ — max-height 95vh, шрифты 14px (batch table, summary) / 13px (details, examples, legend), Check All absolute-pinned top-right, flex-shrink:0 на history (fix наплывания при росте таблицы). Оба модала (Route Check + DNS Check) унифицированы.
- [ ] **Version badge → GitHub releases ссылка** — сейчас ew-version-badge ведёт на forum.keenetic.ru. Когда появится GitHub репо, поменять URL в `app.js` (`setDetails()` isVersion block) на GitHub releases page.
- [ ] **Service icons: SVG иконки в card headers + tabs** — визуальная дифференциация (route/globe для Geo-Split, DNS для SmartDNS, shield для DNS Redirect, monitor для WebUI). Inline SVG в `SERVICE_APIS`. (target-gui: #1, #3)
- [ ] **System info: donut rings вместо thin bars** — SVG кольца 24×24 с заливкой по %, заменят текущие 48×4px полоски. Уникальная фича (stock dashboard не имеет system info). (target-gui: #2 Tech)
- [ ] - таймер на лейбл , когда сервис stopped (disabled)?
- [x] **Status flicker fix** ✅ — stale-while-revalidate: при ошибке fetch НЕ перезаписывать badge если есть предыдущие данные. Error показывается только при 3+ подряд неудачах или если данных ещё не было. app.js: `_hasGoodData`/`_consecutiveErrors`/`ERRORS_BEFORE_SHOW`. inject.js: `.catch()` в `fetchDashboardStatuses()` молчит если chip уже имеет данные.
- [x] **False-positive badges fix** ✅ — 5-state badge (ok/caution/stopped/stale/error), stale-while-revalidate (30s), pending response, stopped vs failed, disabled state (gray), card accent 5 colors, toggle flash suppression.
- [x] **upstream: использовать LAN IP вместо 127.0.0.1** ✅ — удалён блок `upstream keenetic_ui`, `proxy_pass $stock_httpd` (nginx-переменная из `listen.conf`). Self-healing в init-скрипте генерирует listen.conf с `set $stock_httpd http://<LAN_IP>:80;` при старте. Команда `update-listen` для ручного обновления IP.

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

## 🔴 Custom Dashboard UX (v0.12.0 + v0.13.0)

- [x] **Scroll fix** — stock CSS `overflow:hidden` блокирует скролл на `/custom/`. Fix: `html,body { overflow-y:auto!important }` в `layout.css`
- [x] **Auth для POST API** — `access_by_lua` subrequest к /auth для action-роутов (start/stop/update). GET status остаётся без auth (read-only)
- [x] **Hash-routing для табов** — чтение `location.hash` при загрузке → activeTab. Поддержка `#geo-split`, `#smartdns`, `#smartdns-redirect`, `#webui`
- [x] **Toggle buttons на кастомной странице** — start/stop кнопки в каждой карточке сервиса (аналог inject.js dashboard card)
- [x] **System info panel** ✅ — `fetchSystemInfo()` в header: hostname, uptime, RAM%, /opt disk% с progress bar. Color-coded (blue/yellow/red)
- [x] **Mobile tabs scroll** ✅ — `overflow-x:auto` + hidden scrollbar для `.ndw-tabs__list`, `flex-shrink:0` на табах
- [x] **Loading skeleton** ✅ — shimmer animation (`ew-skeleton`) вместо "Loading..." при fetch
- [ ] **Last Updated timestamp** — индикатор последнего успешного fetch
- [ ] **Retry кнопка при ошибке** — визуальный error boundary с action

## 🟡 Безопасность

- [x] **CORS whitelist** ✅ — `Access-Control-Allow-Origin: $scheme://$host` для `/api/*`
- [x] **Rate limiting** ✅ — `limit_req zone=api_post burst=3 nodelay` для POST (map-based: GET не ограничен)
- [ ] **Concurrent action guard** — проверка running background process перед запуском нового

## � Мелкие / Cleanup

- [x] **Dashboard card header: кликабельный заголовок** — `<span>` с hover underline, ведёт на /custom/
- [x] **Dashboard card: drag-and-drop icon** — SVG sprite 6 dots
- [x] **Dashboard card: expand details** — 4-square icon, expandable grid, localStorage persist
- [x] **iframe page card headers: `<span>` → ссылки** ✅ — устарело, iframe-архитектура удалена

## 🧊 Порт на KeeneticOS 4.x (KN-1711 Extra)

> Исследование прошивки KN-1711 stable 4.3.7 (`docs/knowledge/stock-firmware/KN-1711_stable_4.3.7_4.03.C.7.0-3.bin`) показало: NDW4 (Angular) **присутствует**.

**Отличия от 5.x:**

- Бандл: `main.790e5e1f5b169fd2.js` (ТОЧКА в имени, на 5.x — тире: `main-HASH.js`)
- Отдельный `vendor.238eaa341d3874ba.js` + `runtime.2fb25874618f03d2.js` (на 5.x bundled)
- CSS: `styles.1d2e1ec4187acf13.css`

**Анализ паттернов v1 против бандла 4.3.7:**

| #   | Паттерн                                          | 4.3                                                   | Статус           |
| --- | ------------------------------------------------ | ----------------------------------------------------- | ---------------- |
| #6  | `TELEPHONY:"TELEPHONY"}`                         | Идентичен                                             | ✅               |
| #6a | `.values(Po))`                                   | `.values(we))` — enum `Po`→`we`                       | ✅ тривиально    |
| #7  | `[Po.TELEPHONY]:...title"};`                     | `[we.TELEPHONY]:...title"},` — `Po`→`we` + `;`→`,`    | ⚠️ тривиально    |
| #8  | `filter(a=>this.viewService...)`                 | `filter(r=>this.viewService...)` — var `a`→`r`        | ⚠️ тривиально    |
| #QS | `Po.INTERNET,...Po.TELEPHONY]`                   | `we.INTERNET,...we.TELEPHONY]` — `Po`→`we`            | ✅ тривиально    |
| #2  | `set order(e){this.elementsOrder=e}`             | Идентичен                                             | ✅               |
| #3  | `getTemplate(e){return this.templateMap.get(e)}` | Идентичен                                             | ✅               |
| #9  | `d("ngTemplateOutlet",i.getTemplate(e))`         | `Y8G("ngTemplateOutlet",...)` — другая Ivy-инструкция | ❌ новый паттерн |
| #4  | `enterPredicate=(n,r)=>...`                      | Не найден — CDK в `vendor.js`?                        | ❌ исследовать   |

**Вывод:** 5/9 ✅, 2/9 ⚠️ тривиальная адаптация, 2/9 ❌ требуют исследования (Ivy instructions + CDK DragDrop в vendor.js).

**Задачи:**

- [ ] `patch-stock-ui.sh`: поддержка паттерна `main.*.js` (сейчас ищет `main-*.js`)
- [ ] Создать `v0.sh` patch-set: адаптировать 7 тривиальных паттернов (`Po`→`we`, `;`→`,`, `a`→`r`)
- [ ] #9: найти `Y8G("ngTemplateOutlet"...)` + `getTemplate` в контексте и написать новый sed
- [ ] #4: проверить `vendor.238eaa341d3874ba.js` на CDK enterPredicate/sortPredicate
- [ ] Создать `v0.sh` с `PATCH_ENUM` для KeeneticOS 4.x (если поддержка нужна)
- [ ] Тест: inject.js (sidebar ✅ `ndw-menu`, dashboard card ✅ `dashboard-card` — подтверждены в бандле)
- [ ] Определить CSS-хеш для `index.html` stock CSS link (`styles.1d2e1ec4187acf13.css`)

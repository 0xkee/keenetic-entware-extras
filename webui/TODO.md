# WebUI — TODO

> Обновлено 2026-04-21. Dashboard card переведён на стоковый вид.

## 🟠 Важные

- [ ] **Refresh button: emoji → SVG sprite** — `index.html:55,79,105` используют emoji `⟳`, нужно `<use href="./assets/sprite/sprite.svg#refresh">` по keenetic-dom-catalog.md §12
- [x] **CUSTOM_ITEMS: добавить DNS Redirect** — добавлен smartdns-redirect в sidebar
- [x] **Dashboard card: стоковый вид** — переписан на stock DOM-классы, toggle switches, status chips, expandable details, localStorage persist
- [ ] **Sidebar icon: #settings → уникальная иконка** — `inject.js` использует `#settings` (та же что у MANAGEMENT), рассмотреть `#extensions` или другую из sprite
- [ ] **Light theme: проверить CSS fallback** — fallback значения захардкожены под dark theme; проверить light
- [ ] **Status.sh: добавить geo domain и upstream DNS** — geo-split: актуальный гео-домен (не хардкод "RU") в JSON; dns-redirect: upstream DNS в JSON (чтобы показывать в деталях)

## 🟡 Средние

- [ ] **Init script: AGENTS.md compliance** — `S80nginx-webui` использует `#!/bin/sh` (нужно `#!/opt/bin/sh`) и нет `set -eu`
- [ ] **webui/scripts/status.sh: добавить --json** — единственный status.sh без JSON-вывода
- [ ] **nginx: user root → privilege separation** — `config/nginx.conf:11` — io.popen() от root = RCE risk
- [x] **inject.js: window.showInContent утечка** — заменено на addEventListener
- [ ] **inject.js: setInterval pathname polling → popstate** — опрашивает pathname каждые 2с
- [ ] **Toggle switches: подключить к backend** — сейчас cosmetic; нужен API start/stop

## 🟢 Мелкие / Cleanup

- [x] **Dashboard card header: кликабельный заголовок** — `<span>` с hover underline, ведёт на /custom/
- [x] **Dashboard card: drag-and-drop icon** — SVG sprite 6 dots
- [x] **Dashboard card: expand details** — 4-square icon, expandable grid, localStorage persist
- [ ] **iframe page card headers: `<span>` → ссылки** — `index.html:52,76,100`
- [ ] **README.md: обновить** — описать inject.js, proxy architecture, expand details
- [ ] **spike-update-plan.md: отметить батчи** — Batch 1–4 выполнены

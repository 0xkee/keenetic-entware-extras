# WebUI — Анализ Over-engineering + Refactoring

**Version:** v1.0 | **Created:** 2026-07-04 | **Status:** ✅ Final

**Scope:** все файлы `webui/` (JS client, Lua server, shell, nginx config)
**Targets:** Simplicity 90%+, Over-engineering tolerance 5%

## Размер кодовой базы

| Файл | Строки | Роль |
|------|--------|------|
| `shared.js` | 457 | Общие утилиты (EW namespace) |
| `app.js` | 1898 | Custom dashboard (iframe) |
| `inject.js` | 1153 | Stock UI injection + dashboard card |
| `route-check.js` | 1325 | Route/DNS Check модальные окна |
| `route-diagram.js` | 696 | SVG диаграммы |
| `api-router.lua` | 1047 | API router (nginx Lua) |
| `serve-index.lua` | 35 | Index.html serving |
| `stock-css-init.lua` | 25 | CSS detection at startup |
| `status.sh` | 305 | WebUI status script |
| `nginx.conf` | 191 | Nginx config |
| **Итого** | **~7130** | |

---

## 🟢 Over-engineering: НИЗКИЙ (~3-5%)

Код проекта **в целом прагматичный** и хорошо соответствует таргету 5%. Обнаружены только **минорные** случаи over-engineering:

### OE-1. Skeleton counts в localStorage (Marginal)
**Файл:** `app.js:20-35`

`getSkeletonCount()` / `saveSkeletonCount()` кэшируют точное количество placeholder-скелетов per service в localStorage для точного рендеринга при следующей загрузке. Достаточно было бы фиксированного числа (9) — разница в UX минимальна.

**Effort:** ~1ч | **Impact:** minimal | **Verdict:** 🟡 оставить как есть — не мешает

### OE-2. Двойной механизм CSS discovery (Marginal)
**Файлы:** `app.js:621-655`, `inject.js:462-480`

`discoverStockCSS()` парсит HTML через fetch + `postMessage` от inject.js — два способа получить один URL. Оба простые (~20 строк вместе), оба нужны (iframe может грузиться отдельно от stock page).

**Verdict:** 🟢 оправдано — разные контексты загрузки

### OE-3. Stale-while-revalidate на клиенте (Justified)
**Файл:** `app.js:41-42, 491-500`

`_lastGoodData` хранит последние данные 30с для подавления transient ошибок. Это хороший UX-паттерн для нестабильных LAN-соединений роутера.

**Verdict:** 🟢 оправдано — реальная UX-проблема

### Итого по over-engineering:
Все найденные случаи — **оправданная функциональность**, не бесполезные абстракции. Проект **соответствует таргету** 5%.

---

## 🔴 Refactoring: ЗНАЧИТЕЛЬНЫЕ возможности

### R-1. 🔴 CRITICAL: Дублирование деталей рендеринга inject.js ↔ app.js (~150 строк)

**Проблема:** `renderDetailsGrid()` в inject.js и `setDetails()` в app.js — это два независимых рендерера одних и тех же данных (из `EW.parseDetails()`). Оба содержат:
- DNS provider enrichment с ✓/✗ иконками и clickable ссылками (~20 строк × 2)
- DNS test results вставка перед cache (~25 строк × 2)
- Multiline value splitting по пробелам (~5 строк × 2)
- Error/warning coloring через inline styles (~5 строк × 2)

**inject.js** рендерит compact grid (stock dashboard), **app.js** рендерит list с приоритетами (custom dashboard). Структура HTML отличается, но **логика преобразования данных → HTML идентична**.

**Рекомендация:** Вынести в `shared.js` общую функцию `renderDetailEntry(entry, opts)` → возвращает `{labelHtml, valueHtml}`, а оба рендерера только оборачивают в свои контейнеры.

**Effort:** 3-4ч | **Impact:** -100 строк дублирования, единая точка правки

---

### R-2. 🔴 CRITICAL: Дублирование toggle polling inject.js ↔ app.js (~80 строк)

**Проблема:** Идентичный паттерн `startTogglePoller()` / `stopTogglePoller()` реализован дважды:
- `app.js:775-810` — для custom dashboard
- `inject.js:776-827` — для stock dashboard card

Оба: создают `setInterval` с таймаутом, останавливают по условию/таймауту, хранят в `togglePollers` map.

**Рекомендация:** Добавить в `EW` (shared.js): `createTogglePoller(serviceId, fetchFn, opts)` → возвращает `{start, stop}`. Обе страницы используют один и тот же factory.

**Effort:** 2ч | **Impact:** -60 строк, единая логика

---

### R-3. 🟡 HIGH: Дублирование `_ensureIfaceMap()` ↔ `EW.loadIfaceMap()`

**Проблема:** `_ensureIfaceMap()` в route-check.js — это полная копия `EW.loadIfaceMap()` из shared.js. Обе загружают `/api/system/interfaces` и строят `window._ewIfaceMap`.

**Рекомендация:** Удалить `_ensureIfaceMap()`, использовать `EW.loadIfaceMap()` (уже доступен — shared.js грузится раньше).

**Effort:** 15мин | **Impact:** -17 строк

---

### R-4. 🟡 HIGH: Дублирование `_ifaceLabel()` ↔ `EW._ifaceLabelShort()`

**Проблема:** `_ifaceLabel()` в route-diagram.js — это упрощённая copy-paste версия `_ifaceLabelShort()` из shared.js (без обработки IFACE_SPECIAL).

**Рекомендация:** Экспортировать `_ifaceLabelShort` из `EW` как `EW.ifaceLabelShort()`. Использовать в route-diagram.js и route-check.js.

**Effort:** 20мин | **Impact:** -5 строк + единая логика

---

### R-5. 🟡 HIGH: Дублирование `_esc()` ↔ `escapeHtml()`

**Проблема:** `_esc()` в route-check.js — идентичная копия `escapeHtml()` из app.js.

**Рекомендация:** Экспортировать `escapeHtml` из `EW` (shared.js). Использовать везде.

**Effort:** 15мин | **Impact:** -5 строк + единая точка правки

---

### R-6. 🟡 MEDIUM: Повторяющийся lookup сервиса по ID

**Проблема:** Паттерн "найти сервис по id в массиве" повторяется **6+ раз**:
```js
for (var i = 0; i < EW.SERVICE_APIS.length; i++) {
    if (EW.SERVICE_APIS[i].id === serviceId) { svc = ...; break; }
}
```
В `app.js:786`, `inject.js:759`, `inject.js:779` и др.

**Рекомендация:** Добавить `EW.getService(id)` в shared.js (3 строки).

**Effort:** 20мин | **Impact:** -30 строк, чище код

---

### R-7. 🟡 MEDIUM: app.js слишком длинный (1898 строк)

**Проблема:** `app.js` совмещает 5 логических модулей:
1. Dashboard (fetch, render, tabs, system info) ~500 строк
2. Config Editor (schema, modal, form render, save, reset) ~700 строк
3. Toggle handling ~70 строк
4. Auto-refresh + polling ~50 строк
5. Init + event delegation ~100 строк

**Рекомендация:** Вынести Config Editor (schema + modal + form) в отдельный `config-editor.js`. Это самый самостоятельный блок (~700 строк) с чётким API: `toggleConfigEditor(svcId)`, `closeConfigModal()`.

**Effort:** 2-3ч | **Impact:** app.js ~1200 строк, config-editor.js ~700 строк, лучше читаемость

---

### R-8. 🟡 MEDIUM: openRouteCheckModal() ↔ openDnsCheckModal() структурно идентичны

**Проблема:** `openRouteCheckModal()` и `openDnsCheckModal()` — ~120 строк каждая — имеют **идентичную структуру**: input row → examples → history → progress → results → doCheck → Check All. Отличия: URL endpoint, наличие interface dropdown, history key.

**Рекомендация:** Извлечь общий factory `_createCheckModal(opts)` с параметрами для различий. ~80 строк экономии.

**Effort:** 2ч | **Impact:** -80 строк, единый UX-контракт

---

### R-9. 🟢 LOW: `hasFailField()` дублирован inline

**Проблема:** `hasFailField()` в inject.js и inline-версия в `app.js:399-404`.

**Рекомендация:** Вынести в `EW.hasFailField()`.

**Effort:** 10мин | **Impact:** -5 строк

---

## Сводная таблица

| # | Тип | Приоритет | Описание | Файлы | Effort | Экономия |
|---|-----|-----------|----------|-------|--------|----------|
| R-1 | Refactor | 🔴 Critical | Details rendering дублирование | inject.js, app.js → shared.js | 3-4ч | ~100 строк |
| R-2 | Refactor | 🔴 Critical | Toggle polling дублирование | inject.js, app.js → shared.js | 2ч | ~60 строк |
| R-3 | Refactor | 🟡 High | `_ensureIfaceMap` → `EW.loadIfaceMap` | route-check.js | 15мин | ~17 строк |
| R-4 | Refactor | 🟡 High | `_ifaceLabel` → `EW.ifaceLabelShort` | route-diagram.js | 20мин | ~5 строк |
| R-5 | Refactor | 🟡 High | `_esc` → `EW.escapeHtml` | route-check.js | 15мин | ~5 строк |
| R-6 | Refactor | 🟡 Medium | Service lookup helper | app.js, inject.js → shared.js | 20мин | ~30 строк |
| R-7 | Refactor | 🟡 Medium | Вынести Config Editor | app.js → config-editor.js | 2-3ч | структура |
| R-8 | Refactor | 🟡 Medium | Unify Route/DNS Check modals | route-check.js | 2ч | ~80 строк |
| R-9 | Refactor | 🟢 Low | `hasFailField()` → shared | inject.js, app.js → shared.js | 10мин | ~5 строк |

**Общая потенциальная экономия:** ~300 строк дублирования + значительно лучшая maintainability.

---

## Вердикт

| Аспект | Оценка | Комментарий |
|--------|--------|-------------|
| **Over-engineering** | 🟢 **3-5%** (в таргете ≤5%) | Код прагматичный, нет бесполезных абстракций |
| **DRY compliance** | 🔴 **~80%** (таргет 95%+) | Значительное дублирование между inject.js и app.js |
| **File size** | 🟡 **app.js 1898 строк** | Превышает разумный предел ~1000 для одного файла |

**Главная проблема — не over-engineering, а DRY-нарушения.** Два контекста рендеринга (stock dashboard card в inject.js и custom dashboard в app.js) привели к параллельной эволюции одинакового кода. `shared.js` уже содержит `parseDetails()` — осталось довести идею до конца и вынести rendering utilities.

**Quick wins (R-3, R-4, R-5, R-6, R-9):** ~1ч суммарно, сразу убирают мелкие дублирования.
**Strategic (R-1, R-2):** ~5-6ч, убирают основную массу дублирования.
**Structure (R-7, R-8):** ~4-5ч, улучшают читаемость длинных файлов.

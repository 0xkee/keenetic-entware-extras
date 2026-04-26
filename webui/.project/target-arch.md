# WebUI — Target Architecture

## Целевая архитектура

Хакаем Angular bundle через nginx sub_filter, чтобы отдать ему **нативную карточку**
ENTWARE_EXTRAS — в том же формате, что INTERNET, SYSTEM и другие стоковые.
Angular делает всё сам (CDK drag-drop, dialog, toggle, persistence, header).
inject.js только наполняет content данными от нашего API.

## Принципы

- **Angular — хозяин карточки**: CDK row, drag, dialog, visibility, header, wrapper
- **inject.js — только контент**: service rows, статусы, toggle'ы сервисов
- **nginx sub_filter — мост**: патчит bundle на лету, регистрирует ENTWARE_EXTRAS
  как first-class citizen (Po enum, dXe title, templateMap, CARD_ID_LIST)
- **Свой template**: Angular рендерит `<ndw-dashboard-card>` с правильным заголовком
  и пустым content-контейнером — без чужого stub, без CSS-скрытия, без header patch

## inject.js surface (target)

1. Sidebar menu injection
2. Dashboard card content population (append в пустой контейнер Angular)
3. Iframe content loading

## Stability

- Патчи стабильны при обновлениях FW (Angular Ivy не минифицирует class field names)
- Graceful degradation: патч не сработал → sidebar без dashboard карточки

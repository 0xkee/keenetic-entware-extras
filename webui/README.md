# webui

Веб-панель мониторинга для Keenetic/Entware — дашборд статуса сервисов + прокси штатного WebUI с инъекцией кастомного меню.

Типичные сценарии:
- 📊 **Мониторинг:** единый дашборд статуса geo-split, smartdns-conf-ru-split, smartdns-redirect, систематики (uptime, RAM, диск)
- 🎨 **Интеграция:** карточка Entware Extras на стоковом дашборде Keenetic + Cards Position dialog через inject.js
- 🔌 **API:** JSON-эндпоинты для автоматизации и мониторинга через Lua

## Установка

Основной способ — через opkg:

```sh
opkg install webui_0.3.0_all.ipk
```

Зависимости (`keenetic-entware-extras`, `nginx`, `nginx-mod-lua`, `logrotate`) устанавливаются автоматически.

> `config/nginx.conf` и `config/logrotate.conf` — conffiles: при `opkg upgrade` пользовательский конфиг сохраняется.

После установки:

```sh
# Дашборд доступен сразу (postinst запускает сервис)
# Кастомный дашборд:
curl http://<ip-роутера>:8080/custom/

# Проксированный штатный WebUI:
curl http://<ip-роутера>:8080/
```

> **Примечание:** `lua-resty-core` может не работать на ARM — в конфиге установлен `lua_load_resty_core off`.

## Удаление

```sh
opkg remove webui
```

Автоматически выполняется: останов nginx-webui, удаление init-скрипта и logrotate-конфига. Логи сохраняются для инспекции.

## Архитектура

Отдельный экземпляр nginx на порту `:8080`, независимый от штатного Keenetic httpd (:80).

```
Browser → nginx :8080
  ├── /custom/*     → static HTML/JS/CSS (кастомный дашборд)
  ├── /api/*        → content_by_lua (api-router.lua) → io.popen(shell) → JSON
  └── /             → proxy_pass 127.0.0.1:80 (штатный Keenetic UI)
                      └── sub_filter: инъекция inject.js + CDK DragDrop патчи
```

### Stock CSS auto-detection

При старте nginx Lua-скрипт `stock-css-init.lua` сканирует файловую систему `/usr/share/htdocs_/*.css` (без рекурсии — `wizards/` содержит свой отдельный CSS). Найденные CSS-файлы подставляются в `index.html` через `serve-index.lua`. При `nginx -s reload` список обновляется — дашборд автоматически подхватывает стили после обновления прошивки.

### Inject.js + CDK DragDrop патчи

`sub_filter` в nginx подменяет фрагменты JS-бандла Keenetic на лету:
- Инъекция `<script src="/custom/inject.js">` перед `</body>`
- Патчи `NdwDragPanel.set order` / `getTemplate` / `ngTemplateOutlet` для интеграции карточки ENTWARE_EXTRAS на дашборд
- Патчи `CdkDropList` enter/sort predicate для Cards Position dialog
- Патчи drop-обработчика для сохранения позиции Entware-карточки при drag & drop

## Команды управления

```sh
/opt/etc/init.d/S80nginx-webui <команда>
```

| Команда | Что делает |
|---------|-----------|
| `start` | Запустить nginx-webui |
| `stop` | Остановить nginx-webui |
| `restart` | Остановить + запустить |
| `reload` | Перечитать конфиг без даунтайма |
| `status` | Проверить статус (running/not running) |

Детальная диагностика:

```sh
/opt/keenetic-entware-extras/webui/scripts/status.sh
/opt/keenetic-entware-extras/webui/scripts/status.sh --json
```

## Настройка

Конфигурация: `config/nginx.conf`

| Параметр | Значение | Описание |
|----------|----------|----------|
| Listen | `10.0.0.1:8080`, `127.0.0.1:8080` | Порт дашборда |
| Upstream | `127.0.0.1:80` | Штатный Keenetic httpd |
| Lua path | `/opt/keenetic-entware-extras/webui/lua/` | api-router, serve-index, stock-css-init |
| Static | `/opt/keenetic-entware-extras/webui/static/` | HTML/JS/CSS кастомного дашборда |
| Logrotate | `/opt/keenetic-entware-extras/webui/config/logrotate.conf` | Ротация логов nginx-webui |

После изменения конфига:

```sh
/opt/etc/init.d/S80nginx-webui reload    # перечитать конфиг без даунтайма
```

## API

| Метод | Эндпоинт | Описание |
|-------|----------|----------|
| GET | `/api/system/info` | Системная информация (hostname, uptime, RAM, диск) |
| GET | `/api/geo-split/status` | Статус geo-split (`status.sh --json`) |
| GET | `/api/smartdns/status` | Статус smartdns-conf-ru-split |
| GET | `/api/smartdns-redirect/status` | Статус smartdns-redirect |
| GET | `/api/webui/status` | Самодиагностика webui |

### Формат ответа

**system/info:**
```json
{
  "ok": true,
  "hostname": "Keenetic",
  "uptime": "5d 3h 12m",
  "memory": {"total_kb": 262144, "available_kb": 180000},
  "disk_opt": {"total_kb": 7654321, "used_kb": 1234567, "free_kb": 6419754}
}
```

**status-эндпоинты:**
```json
{
  "ok": true,
  "output": "geo-split:\n    Process: running ✓\n    ..."
}
```

## Диагностика (status.sh)

```sh
/opt/keenetic-entware-extras/webui/scripts/status.sh
```

Пример вывода:

```
nginx-webui:
    Process:     running (pid 1234 via pidfile, RSS 2048kB) ✓
    Config:      /opt/keenetic-entware-extras/webui/config/nginx.conf ✓
    Lua module:  /opt/lib/nginx/modules/ngx_http_lua_module.so ✓
    Port:        :8080 listening ✓
    HTTP:        /custom/ → 200 ✓
    API:         /api/system/info → 200 ✓
```

**Exit code:** `0` — всё в порядке, `1` — есть проблемы (✗ в выводе).

## Файлы

| Файл | Назначение |
|------|-----------|
| `config/nginx.conf` | Конфигурация nginx (listen, proxy, sub_filter, lua paths) |
| `config/logrotate.conf` | Logrotate: ротация error-лога nginx-webui |
| `lua/api-router.lua` | Lua-роутер: /api/* → shell commands → JSON |
| `lua/serve-index.lua` | Lua: подстановка stock CSS ссылок в index.html |
| `lua/stock-css-init.lua` | Lua: сканирование `/usr/share/htdocs_/*.css` при старте nginx |
| `static/index.html` | Кастомный дашборд — HTML |
| `static/app.js` | Кастомный дашборд — JS (карточки статуса, API-запросы) |
| `static/inject.js` | Инъекция в штатный WebUI (меню, карточка Entware Extras) |
| `static/inject.css` | Стили для inject.js компонентов |
| `static/common.css` | Общие стили дашборда |
| `static/layout.css` | Layout-стили дашборда |
| `static/502.html` | Страница ошибки при недоступности штатного httpd |
| `scripts/status.sh` | Диагностика: процесс, порт, конфиг, HTTP-проверки |
| `rootfs/opt/etc/init.d/S80nginx-webui` | Init-скрипт (start/stop/restart/reload/status) |

## Логи

| Файл | Описание |
|------|----------|
| `/opt/var/log/nginx-webui-error.log` | Ошибки nginx + Lua |
| Access log | Отключен (экономия ~1.5MB/день; диагностика через `status.sh`) |
| `/opt/etc/logrotate.d/nginx-webui` | Logrotate конфиг (деплоится postinst) |

## Зависимости

| Пакет | Тип | Назначение |
|-------|-----|-----------|
| `keenetic-entware-extras` | Depends | Базовый пакет (общие библиотеки) |
| `nginx` | Depends | Веб-сервер / reverse proxy |
| `nginx-mod-lua` | Depends | Lua-модуль для nginx (API, шаблоны) |
| `logrotate` | Depends | Ротация логов |

## Для разработчиков

Сборка .ipk:

```sh
./scripts/build-ipk.sh webui
# Результат: dist/webui_0.3.0_all.ipk
```

Деплой на роутер (без .ipk):

```sh
scp -O -r webui/ root@<router>:/opt/keenetic-entware-extras/webui/
scp -O -r lib/ root@<router>:/opt/keenetic-entware-extras/lib/
ssh root@<router> '/opt/etc/init.d/S80nginx-webui restart'
```

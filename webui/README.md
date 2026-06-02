# webui

> 📖 **[Руководство пользователя](docs/user-manual.ru.md)** — пошаговая установка, настройка, troubleshooting.

Веб-панель мониторинга для Keenetic/Entware — дашборд статуса сервисов + патчинг штатного WebUI с инъекцией кастомного меню и карточек.

Типичные сценарии:
- 📊 **Мониторинг:** единый дашборд статуса geo-split, smartdns-conf-ru-split, smartdns-redirect, системы (uptime, RAM, диск)
- 🎨 **Интеграция:** карточка Entware Extras на стоковом дашборде Keenetic + Cards Position dialog через inject.js
- 🔌 **API:** JSON-эндпоинты для автоматизации и мониторинга через Lua

## Установка

Основной способ — через opkg:

```sh
opkg install webui_<ver>_all.ipk
```

Зависимости (`keenetic-entware-extras`, `nginx`, `nginx-mod-lua`, `logrotate`) устанавливаются автоматически.

> `config/nginx.conf`, `config/logrotate.conf`, `config/config.conf` — conffiles: при `opkg upgrade` пользовательский конфиг сохраняется.

После установки:

```sh
# Дашборд доступен сразу (postinst запускает сервис)
# Кастомный дашборд:
curl http://<ip-роутера>:8080/custom/

# Патченный штатный WebUI:
curl http://<ip-роутера>:8080/
```

## Удаление

```sh
opkg remove webui
```

Автоматически выполняется: останов nginx-webui, удаление tmpfs-патчей (`/tmp/ew-webui`), удаление init-скрипта и logrotate-конфига. Логи сохраняются для инспекции.

## Архитектура

Отдельный экземпляр nginx на порту `:8080`, независимый от штатного Keenetic httpd (:80). Stock UI патчится в tmpfs при старте/reload — никакой модификации оригинальных файлов.

```
Browser → nginx :8080
  ├── /custom/*     → static (кастомный дашборд, JS/CSS)
  ├── /api/*        → content_by_lua (api-router.lua) → shell → JSON
  ├── /auth, /rci/  → proxy_pass 127.0.0.1:80 (stock httpd, WebSocket)
  └── /*            → static /tmp/ew-webui/ (patched stock UI from tmpfs)
                      └── patch-stock-ui.sh: inject.js + inject.css + v1.sh bundle patches
```

### Патчинг stock UI (tmpfs)

При `start` или `reload` скрипт `patch-stock-ui.sh`:

1. Копирует `/usr/share/htdocs_/` → `/tmp/ew-webui/` (tmpfs, без записи на flash)
2. Патчит `index.html` — инъекция `<script>` и `<link>` тегов (`inject.js`, `inject.css`)
3. Загружает `patches/hash-map.conf`, определяет версию patch-set по хешу JS-бандла
4. Вызывает `source patches/v1.sh` → `apply_patches` на JS-бандл (9 sed-замен для CDK DragDrop интеграции)

**hash-map.conf** — маппинг хеша JS-бандла прошивки → версия patch-set:

| Хеш | Прошивка |
|------|----------|
| `ZYVOXYLQ` | 5.0.4 mipsel |
| `XXXXXXXX` | 5.0.8 aarch64 |
| `4QPHZXFY` | 5.0.8 mipsel |
| `TXLLNFBH` | 5.0.10 mipsel |

**Fallback:** если хеш бандла не найден в `hash-map.conf`, используется последний patch-set.

**Добавление новой прошивки:** проверить совпадение паттернов sed-замен → добавить хеш в `hash-map.conf` или создать `v2.sh` при изменении паттернов.

## Команды управления

```sh
/opt/etc/init.d/S80nginx-webui <команда>
```

| Команда | Что делает |
|---------|-----------|
| `start` | Патчит stock UI (`patch-stock-ui.sh`) + запускает nginx-webui |
| `stop` | Останавливает nginx-webui + удаляет `/tmp/ew-webui` |
| `restart` | `stop` + `start` |
| `reload` | Повторный патчинг + `nginx -s reload` (для обновления после firmware upgrade) |
| `check` / `status` | Проверить статус (running/not running) |

Детальная диагностика:

```sh
/opt/keenetic-entware-extras/webui/scripts/status.sh
/opt/keenetic-entware-extras/webui/scripts/status.sh --json
```

## Настройка

Конфигурация: `config/config.conf`

| Параметр | По умолчанию | Описание |
|----------|-------------|----------|
| `ENABLED` | `"yes"` | Включить/выключить сервис (`"yes"` / `"no"`) |
| `LISTEN_PORT` | `8080` | Порт nginx-webui |
| `INJECT_SIDEBAR` | `0` | Инъекция sidebar-меню в stock UI (0/1) |
| `DASH_POLL_INTERVAL` | `30000` | Интервал опроса API на дашборде (мс) |
| `PIDFILE` | `/tmp/nginx-webui.pid` | PID-файл (tmpfs — сбрасывается при ребуте) |
| `LOG_TAG` | `"kee-webui"` | Тег для logger |

> **Listen-адрес:** генерируется в `config/listen.conf` при `postinst` (через `detect_router_ip`) + `listen 127.0.0.1:8080`. Нет хардкода IP.

После изменения конфига:

```sh
/opt/etc/init.d/S80nginx-webui restart
```

## API

Все эндпоинты обслуживаются через `content_by_lua_file api-router.lua`.

### GET (статусы)

| Метод | Эндпоинт | Описание |
|-------|----------|----------|
| GET | `/api/system/info` | Системная информация (hostname, uptime, RAM, диск) |
| GET | `/api/geo-split/status` | Статус geo-split |
| GET | `/api/smartdns/status` | Статус smartdns-conf-ru-split |
| GET | `/api/smartdns-redirect/status` | Статус smartdns-redirect |
| GET | `/api/webui/status` | Самодиагностика webui |

### POST (действия)

Возвращают `405 Method Not Allowed` если вызваны не через POST.

| Метод | Эндпоинт | Описание |
|-------|----------|----------|
| POST | `/api/geo-split/start` | Запустить geo-split |
| POST | `/api/geo-split/stop` | Остановить geo-split |
| POST | `/api/smartdns/start` | Включить smartdns config |
| POST | `/api/smartdns/stop` | Отключить smartdns config |
| POST | `/api/smartdns-redirect/start` | Запустить dns-redirect |
| POST | `/api/smartdns-redirect/stop` | Остановить dns-redirect |
| POST | `/api/geo-split/update-subnets` | Обновить подсети (фон) |
| POST | `/api/geo-split/update-domains` | Обновить домены (фон) |

### Формат ответа

**system/info:**
```json
{"ok":true,"hostname":"Keenetic","uptime":"5d 3h 12m","memory":{"total_kb":262144,"available_kb":180000},"disk_opt":{"total_kb":7654321,"used_kb":1234567,"free_kb":6419754}}
```

**status-эндпоинты:** прямой JSON от `status.sh --json`:
```json
{"running":true,"ok":true,"details":{...}}
```

**action-эндпоинты:**
```json
{"ok":true,"output":"..."}
```

## Диагностика (status.sh)

```sh
/opt/keenetic-entware-extras/webui/scripts/status.sh
```

Пример вывода:

```
nginx-webui status:
  Service:
    Process:     running (pid 1234 via pidfile, RSS 2048kB) ✓
    Config:      /opt/keenetic-entware-extras/webui/config/nginx.conf ✓
    Lua module:  /opt/lib/nginx/modules/ngx_http_lua_module.so ✓
    Port:        :8080 listening ✓

  HTTP:
    Static:      GET / → 200 ✓
    API:         GET /api/system/info → 200 ✓

  Logrotate:
    Binary:      /opt/sbin/logrotate ✓
    Config:      /opt/etc/logrotate.d/nginx-webui ✓
    Cron daily:  /opt/etc/cron.daily/logrotate ✓

  System:
    Uptime:      5d 3h 12m ✓
    Version:     x.y.z
```

**Exit code:** `0` — всё в порядке, `1` — есть проблемы (✗ в выводе).

## Файлы

| Файл | Назначение |
|------|-----------|
| `config/config.conf` | Конфигурация (ENABLED, порт, sidebar, poll interval) |
| `config/nginx.conf` | Конфигурация nginx (listen, proxy, lua paths, gzip) |
| `config/logrotate.conf` | Logrotate: ротация error-лога nginx-webui |
| `config/listen.conf` | Listen-адрес (генерируется postinst, не conffile) |
| `lua/api-router.lua` | Lua-роутер: /api/* → shell commands → JSON |
| `lua/serve-index.lua` | (не используется в текущей архитектуре) |
| `lua/stock-css-init.lua` | Lua: сканирование stock CSS при старте nginx |
| `patches/hash-map.conf` | Маппинг JS-хешей прошивок → версия patch-set |
| `patches/v1.sh` | Patch set v1: 9 sed-замен для CDK DragDrop интеграции |
| `scripts/patch-stock-ui.sh` | Копирует stock UI в tmpfs и применяет патчи |
| `scripts/status.sh` | Диагностика: процесс, порт, конфиг, HTTP, logrotate |
| `static/index.html` | Кастомный дашборд — HTML |
| `static/app.js` | Кастомный дашборд — JS (карточки статуса, tabs, API) |
| `static/shared.js` | Общие утилиты EW.* (SERVICE_APIS, formatters, ticker, poller) |
| `static/inject.js` | Инъекция в stock UI (sidebar, dashboard card, toggle, expand) |
| `static/inject.css` | Стили для inject.js компонентов |
| `static/common.css` | Общие стили (update-кнопки, tooltips) |
| `static/layout.css` | Layout-стили кастомного дашборда |
| `static/502.html` | Страница ошибки при недоступности stock httpd |
| `rootfs/opt/etc/init.d/S80nginx-webui` | Init-скрипт (start/stop/restart/check/status/reload) |

## Логи

| Файл | Описание |
|------|----------|
| `/tmp/nginx-webui-error.log` | Ошибки nginx + Lua (level: error, tmpfs — теряются при ребуте) |
| Access log | Отключен (экономия I/O; диагностика через `status.sh`) |
| `/opt/etc/logrotate.d/nginx-webui` | Logrotate конфиг (daily, rotate 3, compress, USR1 reopen) |

## Зависимости

| Пакет | Тип | Назначение |
|-------|-----|-----------|
| `keenetic-entware-extras` | Depends | Базовый пакет (общие библиотеки) |
| `nginx` | Depends | Веб-сервер |
| `nginx-mod-lua` | Depends | Lua-модуль для nginx (API, init) |
| `logrotate` | Depends | Ротация логов |

## Для разработчиков

Сборка .ipk:

```sh
./scripts/build-ipk.sh webui
# Результат: dist/webui_<ver>_all.ipk
```

Деплой без .ipk:

```sh
scp -O -r webui/ root@<router>:/opt/keenetic-entware-extras/webui/
scp -O -r lib/ root@<router>:/opt/keenetic-entware-extras/lib/
ssh root@<router> '/opt/etc/init.d/S80nginx-webui restart'
```

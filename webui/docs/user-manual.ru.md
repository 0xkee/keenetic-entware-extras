# webui — Руководство пользователя

## Что это такое

**webui** — веб-панель мониторинга и управления для Keenetic/Entware. Предоставляет дашборд статуса всех сервисов проекта и интегрируется в штатный WebUI Keenetic.

### Возможности

- 📊 **Дашборд** — единая панель мониторинга geo-split, smartdns-conf-ru-split, smartdns-redirect, системы
- 🎨 **Интеграция в stock WebUI** — карточка Entware Extras на стоковом дашборде Keenetic
- 🔌 **REST API** — JSON-эндпоинты для автоматизации и внешнего мониторинга
- ⚡ **Управление** — старт/стоп сервисов, обновление данных через браузер

---

## Требования

- Роутер Keenetic с Entware
- **KeeneticOS 5.0+**

### Программные зависимости

**Из Entware-репозитория** (устанавливаются автоматически):

| Пакет | Назначение |
|-------|-----------|
| `nginx` | Веб-сервер |
| `nginx-mod-lua` | Lua-модуль для API-эндпоинтов |
| `logrotate` | Ротация логов nginx |

**Из проекта keenetic-entware-extras** (устанавливаются вручную):

| Пакет | Назначение |
|-------|-----------|
| `keenetic-entware-extras` | Общие библиотеки проекта (обязательно) |

---

## Установка

### Шаг 1. Установить зависимости проекта

```sh
opkg install keenetic-entware-extras_<версия>_all.ipk
```

### Шаг 2. Установить пакет

```sh
opkg install webui_<версия>_all.ipk
```

После установки:
- nginx-webui запускается автоматически на порту `:8080`
- Stock WebUI Keenetic патчится (в tmpfs, без изменения оригинальных файлов)

### Шаг 3. Открыть в браузере

| URL | Описание |
|-----|----------|
| `http://<ip-роутера>:8080/custom/` | Кастомный дашборд |
| `http://<ip-роутера>:8080/` | Патченный штатный WebUI с интеграцией |

---

## Настройка

Файл конфигурации: `/opt/keenetic-entware-extras/webui/config/config.conf`

> 📝 conffile — сохраняется при обновлении.

### Параметры

| Параметр | По умолч. | Описание |
|----------|-----------|----------|
| `ENABLED` | `"yes"` | Включить/выключить сервис |
| `LISTEN_PORT` | `8080` | Порт nginx-webui |
| `INJECT_SIDEBAR` | `0` | Инъекция sidebar-меню в stock UI (0/1) |
| `DASH_POLL_INTERVAL` | `30000` | Интервал опроса API на дашборде (мс) |

### Применить изменения

```sh
/opt/etc/init.d/S80nginx-webui restart
```

---

## Использование

### Команды управления

```sh
/opt/etc/init.d/S80nginx-webui <команда>
```

| Команда | Описание |
|---------|----------|
| `start` | Патч stock UI + запуск nginx-webui |
| `stop` | Остановка + удаление tmpfs-патчей |
| `restart` | stop + start |
| `reload` | Повторный патчинг + nginx reload |
| `check` / `status` | Проверить статус (running/not running) |
| `enable` | Включить сервис (создать symlink + запустить) |
| `disable` | Отключить сервис (остановить + удалить symlink) |
| `update-listen` | Пересоздать listen.conf (если сменился IP роутера) |

> ⚠️ После `disable` symlink `/opt/etc/init.d/S80nginx-webui` удаляется. Для повторного включения:
> ```sh
> /opt/keenetic-entware-extras/webui/init.d/S80nginx-webui enable
> ```

### Кастомный дашборд

Доступен по адресу: `http://<ip-роутера>:8080/custom/`

Показывает:
- Статус всех сервисов (geo-split, smartdns, smartdns-redirect)
- Системную информацию (hostname, uptime, RAM, диск)
- Кнопки управления (start/stop, update подсетей/доменов)

### Интеграция в stock WebUI

При патчинге stock UI добавляется:
- Карточка «Entware Extras» на главный дашборд
- Кнопки управления сервисами

> 📝 Патчинг выполняется в tmpfs (`/tmp/ew-webui/`) — оригинальные файлы прошивки **не модифицируются**. При ребуте патч применяется заново.

### REST API

Все API-эндпоинты доступны через Lua-роутер.

**GET — статусы:**

| Эндпоинт | Описание |
|----------|----------|
| `/api/system/info` | Системная информация (hostname, uptime, RAM, диск) |
| `/api/geo-split/status` | Статус geo-split (JSON) |
| `/api/smartdns/status` | Статус smartdns-conf-ru-split (JSON) |
| `/api/smartdns-redirect/status` | Статус smartdns-redirect (JSON) |
| `/api/webui/status` | Самодиагностика webui |

**POST — действия:**

| Эндпоинт | Описание |
|----------|----------|
| `/api/geo-split/start` | Запустить geo-split |
| `/api/geo-split/stop` | Остановить geo-split |
| `/api/smartdns/start` | Включить split-DNS |
| `/api/smartdns/stop` | Отключить split-DNS |
| `/api/smartdns-redirect/start` | Запустить dns-redirect |
| `/api/smartdns-redirect/stop` | Остановить dns-redirect |
| `/api/geo-split/update-subnets` | Обновить подсети (фоново) |
| `/api/geo-split/update-domains` | Обновить домены (фоново) |

**Пример использования API:**
```sh
# Получить статус geo-split
curl http://192.168.1.1:8080/api/geo-split/status

# Обновить подсети
curl -X POST http://192.168.1.1:8080/api/geo-split/update-subnets
```

**Формат ответа:**
```json
{"ok":true,"running":true,"enabled":true,"details":{...},"checks":{...}}
```

---

## Диагностика

### Проверка статуса

```sh
/opt/keenetic-entware-extras/webui/scripts/status.sh
```

Пример вывода:

```
nginx-webui status: ✓ Alive
  Service:
    Process:     running (pid 1234 via pidfile, RSS 2048kB) ✓
    Config:      /opt/keenetic-entware-extras/webui/config/nginx.conf ✓
    Listen conf: /opt/keenetic-entware-extras/webui/config/listen.conf ✓
    Lua module:  /opt/lib/nginx/modules/ngx_http_lua_module.so ✓
    Port:        :8080 listening ✓

  HTTP:
    Static:      GET / → 200 ✓
    API:         GET /api/system/info → 200 ✓

  Upstream:
    Stock httpd: http://192.168.1.1:80 → 200 ✓

  Logrotate:
    Binary:      /opt/sbin/logrotate ✓
    Config:      /opt/etc/logrotate.d/nginx-webui ✓
    Cron daily:  /opt/etc/cron.daily/logrotate ✓

  System:
    Uptime:      5d 3h 12m ✓
    Version:     0.11.1
```

**JSON-вывод:**
```sh
/opt/keenetic-entware-extras/webui/scripts/status.sh --json
```

### Частые проблемы

| Симптом | Причина | Решение |
|---------|---------|---------|
| Порт 8080 не отвечает | nginx не запущен | `S80nginx-webui start` |
| 502 Bad Gateway на `/` | Stock httpd (:80) не доступен | Проверить, что Keenetic httpd работает |
| API возвращает ошибку | Lua-модуль не загружен | `opkg install nginx-mod-lua` + restart |
| Stock UI не патчится | Хеш бандла не найден в hash-map | `S80nginx-webui reload` (попробует fallback) |

### Логи

```sh
# Ошибки nginx (tmpfs, теряются при ребуте)
cat /tmp/nginx-webui-error.log

# Системный лог
dmesg | grep kee-webui
```

---

## Обновление

```sh
opkg upgrade webui
```

Конфигурация (`config.conf`, `nginx.conf`, `logrotate.conf`) сохраняется при обновлении.

---

## Удаление

```sh
opkg remove webui
```

Автоматически: остановка nginx-webui, удаление tmpfs-патчей, init-скрипта, logrotate-конфига.

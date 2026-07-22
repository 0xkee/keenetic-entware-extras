# webui — Руководство пользователя

## Что это такое

**webui** — веб-панель мониторинга и управления для Keenetic/Entware. Предоставляет дашборд с реальным статусом всех сервисов проекта, инструменты диагностики и редактор конфигураций. Интегрируется в штатный WebUI Keenetic.

### Возможности

- 📊 **Дашборд** — карточки статуса geo-split, smartdns-geo-conf, smartdns-redirect + системная информация
- 🔍 **Route Check** — проверка маршрутов до любого домена/IP с SVG-визуализацией топологии
- 🧬 **DNS Check** — диагностика DNS: какая зона, какой upstream, какие IP получит клиент
- ⚙️ **Config Editor** — редактор конфигураций всех сервисов прямо из браузера
- 🎨 **Интеграция в stock WebUI** — карточка Entware Extras на стоковом дашборде Keenetic
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
| `http://<ip-роутера>:8080/custom/` | Кастомный дашборд (рекомендуется) |
| `http://<ip-роутера>:8080/` | Патченный штатный WebUI с карточкой Entware |

---

## Настройка

Файл конфигурации: `/opt/keenetic-entware-extras/webui/config/config.conf`

> 📝 conffile — сохраняется при обновлении пакета.

### Параметры

| Параметр | По умолч. | Описание |
|----------|-----------|----------|
| `ENABLED` | `"yes"` | Включить/выключить сервис |
| `LISTEN_PORT` | `8080` | Порт nginx-webui |
| `INJECT_SIDEBAR` | `0` | Инъекция sidebar-меню в stock UI (0/1) |
| `DASH_POLL_INTERVAL` | `30000` | Интервал автообновления дашборда (мс) |

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

---

### Кастомный дашборд

Доступен по адресу: `http://<ip-роутера>:8080/custom/`

#### Карточки сервисов

Дашборд отображает карточку для каждого установленного сервиса:

| Карточка | Информация |
|----------|-----------|
| **Geo-Split** | Статус, маршрутизируемых подсетей/доменов, таблицы, интерфейс, гео-зона |
| **SmartDNS** | Статус, DNS-тесты по зонам, порт, кэш, провайдеры |
| **SmartDNS Redirect** | Статус, DNAT-правила, watchdog, порт назначения |
| **WebUI** | Самодиагностика nginx, порты, upstream |

Каждая карточка показывает:
- Цветной индикатор статуса (🟢 running / 🟡 warnings / ⚪ disabled / 🟠 stale / 🔴 failed)
- Кнопки Start/Stop (toggle-переключатель)
- Детальную информацию при раскрытии

> 📝 **5 состояний индикатора:**
> - 🟢 **running** — сервис работает нормально
> - 🟡 **warnings** — сервис работает, но есть предупреждения
> - ⚪ **disabled / stopped** — сервис отключён пользователем
> - 🟠 **stale** — нет свежих данных (потеря связи с API, обновится автоматически в течение 30с)
> - 🔴 **failed** — сервис включён, но процесс не найден (аварийная остановка)

**Дополнительные поля карточек:**
- **Cache** — количество записей в кэше (для SmartDNS и WebUI). Кнопка ⟳ Flush очищает кэш
- **Интерфейсы** — отображаются с человекочитаемыми именами (ppp0 → имя ISP-подключения, nwg1 → имя туннеля)

#### Системная информация

В шапке дашборда показана системная информация:
- **Hostname** — имя роутера
- **Uptime** — время работы с последней перезагрузки
- **RAM** — использование оперативной памяти (полоска + процент)
- **Disk /opt** — использование Entware-раздела (полоска + процент)
- **CPU** — загрузка процессора (progress bar на основе `/proc/stat`)

#### Навигация — табы

Дашборд организован вкладками:
- **Summary** — обзор всех сервисов + системная информация
- **Geo-Split** — детальная информация о маршрутизации
- **SmartDNS** — DNS-зоны, провайдеры, тесты
- **DNS Redirect** — правила перехвата
- **WebUI** — самодиагностика

---

### Route Check (диагностика маршрутов)

Проверяет, через какой интерфейс пойдёт трафик до указанного домена, IP-адреса или CIDR-подсети.

**Как открыть:** Кнопка «Диагностика» → «Route Check» на дашборде.

#### Работа с Route Check

1. Введите домен, IP-адрес или CIDR-подсеть (например, `ozon.ru`, `8.8.8.8` или `5.0.0.0/8`)
2. Выберите клиента/интерфейс:
   - **Router (local)** — маршрут от самого роутера
   - **Home network (br0)** — маршрут для клиента без туннельной политики
   - **Имя устройства** — маршрут для конкретного клиента (с учётом его политики маршрутизации)
3. Нажмите «Check» или Enter

#### SVG-диаграмма

Результат отображается как интерактивная SVG-топология сети:

```
[Клиент] → [DNS] → [Роутер] → [WAN интерфейс] → [Сервер]
```

Диаграмма использует двухиконочную модель WAN-путей: 🌐 globe (ISP) + 🛡️ shield (шифрованный канал).

- **Зелёный путь** — трафик идёт через geo-split (ISP)
- **Синий путь** — трафик идёт через шифрованный канал (туннель)
- **Оранжевый путь** — CDN-домен, IPs идут разными путями (mixed)
- **Серый путь** — маршрут по умолчанию

#### Вердикты

| Иконка | Значение | Описание |
|--------|----------|----------|
| `⇄` | geo-split | Хост/IP матчит domain table или subnet table geo-split |
| `⊙` | tunnel | Трафик идёт через туннельную политику клиента |
| `⚠` | mixed | CDN — часть IPs через geo-split, часть через туннель |
| `⊞` | policy | Маршрут определён через fwmark/policy routing (NDM default route) |
| `⇒` | default | Маршрут по умолчанию (ни geo-split, ни tunnel, ни policy) |

#### История и Batch-проверка

- Проверенные домены сохраняются в историю (цветные бейджи по вердикту)
- Кнопка **Check All** — последовательно проверяет все домены из истории
- Результаты batch-проверки отображаются в таблице

#### Technical Details

Под диаграммой доступна подробная техническая информация:
- DNS-разрешение (все IP-адреса, время)
- Маршруты по каждому IP (таблица, префикс, интерфейс)
- **Route Devices** — уникальные устройства сгруппированные по вердикту с именами таблиц маршрутизации

---

### DNS Check (диагностика DNS)

Проверяет, как SmartDNS обрабатывает запрос: какая зона, какой upstream, какие IP вернёт.

**Как открыть:** Кнопка «Диагностика» → «DNS Check» на дашборде.

1. Введите домен (например, `google.com`)
2. Результат показывает:
   - **Зона** — в какую DNS-группу попал домен (RU/international/etc.)
   - **Upstream** — какой DNS-сервер ответил (провайдер, IP, протокол)
   - **IP-адреса** — результат резолва

#### SVG-диаграмма DNS

Результат отображается как интерактивная SVG-топология с двумя ветками (matched/unmatched):

- **Зелёная ветка** — домен попал в зону (zone-specific override)
- **Серая ветка** — остальные DNS-группы (не сматчились)
- **Синяя иконка группы** — zone-specific override
- **Серая иконка группы** — default DNS-группа

#### Иконки DNS Check

| Иконка | Значение | Описание |
|--------|----------|----------|
| `⇄` | zone match | Домен попал в zone-specific DNS-группу (зелёный) |
| `→` | default | Домен обрабатывается default DNS-группой (синий) |

Цветовое кодирование унифицировано с Route Check. История проверок сохраняется с цветными бейджами по зоне.

---

### Config Editor (редактор конфигураций)

Позволяет менять конфигурацию всех сервисов прямо из браузера.

**Как открыть:** Иконка ✏️ (карандаш) в карточке сервиса.

#### Поддерживаемые сервисы и параметры

| Сервис | Настраиваемые параметры |
|--------|------------------------|
| **Geo-Split** | GEO_ZONE, ROUTE_OUT, ROUTE_IN, ROUTE_GW, таблицы маршрутизации, DNS-порт, интервалы обновления |
| **SmartDNS** | ZONE_DNS_PROVIDER, OTHER_DNS_PROVIDER и другие |
| **SmartDNS Redirect** | UPSTREAM_PORT, INTERFACES |
| **WebUI** | LISTEN_PORT, INJECT_SIDEBAR, DASH_POLL_INTERVAL |

#### Как работает

1. Откроется модальное окно с формой (select-поля для провайдеров, числовые поля для портов, toggle для on/off)
2. Измените нужные параметры
3. **Save & Restart** — сохраняет конфиг и перезапускает сервис
4. **Reset All** — сбрасывает к значениям по умолчанию

> 📝 Конфиг хранится в `config/config.conf` каждого сервиса. Там записываются только отличия от `defaults.conf`.

---

### Интеграция в stock WebUI

При запуске webui патчит штатный WebUI Keenetic:
- Добавляется карточка «Entware Extras» на главный дашборд (между другими карточками)
- Карточка показывает краткий статус всех сервисов
- Заголовок карточки «ENTWARE EXTRAS» — кликабельная ссылка на кастомный дашборд

> 📝 Патчинг выполняется в `webui/htdocs-cache/` — **оригинальные файлы прошивки не затрагиваются**. При ребуте патч применяется заново. Непатченные файлы отдаёт nginx напрямую с flash (`/usr/share/htdocs_`).
>
> Патч определяется автоматически по enum из Angular-бандла KeeneticOS. Поддерживаются patch set v1–v4, два семейства: **setter** (v1/v2) и **signal** (v3/v4).

---

## REST API

Все API-эндпоинты доступны через Lua-роутер (`api-router.lua`).

### GET — статусы (кэшируются)

| Эндпоинт | TTL | Описание |
|----------|-----|----------|
| `/api/system/info` | 5с | Системная информация |
| `/api/geo-split/status` | 10с | Статус geo-split |
| `/api/smartdns/status` | 15с | Статус smartdns-geo-conf |
| `/api/smartdns-redirect/status` | 5с | Статус smartdns-redirect |
| `/api/webui/status` | 5с | Самодиагностика webui |

### POST — действия (инвалидируют кэш)

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
| `/api/webui/flush-cache` | Сброс UI-кэша статусов (принудительное обновление) |
| `/api/smartdns/flush-cache` | Сброс кэша SmartDNS (стоп + удаление + рестарт) |

### GET — диагностика (rate-limited: 1 запрос/сек)

| Эндпоинт | Описание |
|----------|----------|
| `/api/geo-split/route-check?host=...&from=...` | Проверка маршрута. `from` — MAC клиента или `local` |
| `/api/smartdns/dns-check?host=...` | Диагностика DNS |
| `/api/geo-split/wan-paths` | WAN-пути (для SVG-диаграммы) |
| `/api/system/clients` | Клиенты с политиками маршрутизации |
| `/api/system/interfaces` | Сетевые интерфейсы с человекочитаемыми метками |

### Пример использования

```sh
# Статус geo-split
curl http://192.168.1.1:8080/api/geo-split/status

# Route Check — проверить маршрут до ozon.ru
curl "http://192.168.1.1:8080/api/geo-split/route-check?host=ozon.ru"

# Route Check — от лица конкретного клиента
curl "http://192.168.1.1:8080/api/geo-split/route-check?host=github.com&from=AA:BB:CC:DD:EE:FF"

# DNS Check
curl "http://192.168.1.1:8080/api/smartdns/dns-check?host=google.com"

# Обновить подсети
curl -X POST http://192.168.1.1:8080/api/geo-split/update-subnets
```

### Формат ответа

```json
{"ok":true,"running":true,"enabled":true,"details":{...},"checks":{...}}
```

---

## Диагностика

### Проверка статуса (CLI)

```sh
/opt/keenetic-entware-extras/webui/scripts/status.sh
```

Пример вывода:

```
nginx-webui status: ✓ Alive
  Service:
    Process:     running (pid 2133 via pidfile, RSS 1252kB) ✓
    Config:      /opt/keenetic-entware-extras/webui/config/nginx.conf ✓
    Listen conf: /opt/keenetic-entware-extras/webui/config/listen.conf ✓
    Lua module:  /opt/lib/nginx/modules/ngx_http_lua_module.so ✓
    Ports:       192.168.1.1:8080 ✓
                 127.0.0.1:8080 ✓

  HTTP:
    Static:      GET / → 200 ✓
    API:         GET /api/system/info → 200 ✓

  Upstream:
    Stock httpd: 192.168.1.1:80 → listening ✓

  Logrotate:
    Binary:      /opt/sbin/logrotate ✓
    Config:      /opt/etc/logrotate.d/nginx-webui ✓
    Cron daily:  /opt/etc/cron.daily/logrotate ✓

  Patch:
    Firmware:    5.1.1 → patch v4 ✓

  System:
    Uptime:      2d 5h ✓
    Version:     0.33.2
```

**JSON-вывод (для автоматизации):**
```sh
/opt/keenetic-entware-extras/webui/scripts/status.sh --json
```

### Частые проблемы

| Симптом | Причина | Решение |
|---------|---------|---------|
| Порт 8080 не отвечает | nginx не запущен | `S80nginx-webui start` |
| 502 Bad Gateway на `/` | Stock httpd (:80) недоступен | Проверить, что Keenetic httpd работает |
| API возвращает ошибку | Lua-модуль не загружен | `opkg install nginx-mod-lua` + restart |
| Stock UI не патчится | Enum бандла не распознан | `S80nginx-webui reload` после обновления прошивки; если не помогло — нужен новый patch set vN.sh |
| Route Check: «timeout» | DNS-резолвер не отвечает | Проверить SmartDNS: `dig ya.ru @127.0.0.1 -p 6053` |
| Карточка показывает «Stale» | Временная потеря связи с API | Подождать 30с (stale-while-revalidate), обновится автоматически |

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

Для применения обновлений stock-патча:
```sh
/opt/etc/init.d/S80nginx-webui reload
```

---

## Удаление

```sh
opkg remove webui
```

При удалении:
- nginx-webui останавливается
- tmpfs-патчи удаляются
- Штатный WebUI Keenetic возвращается к исходному состоянию
- Конфиг сохраняется (для переустановки)

# geo-split — Руководство пользователя

## Что это такое

**geo-split** — модуль split-маршрутизации для роутеров Keenetic с Entware. Позволяет автоматически разделять интернет-трафик по GeoIP-подсетям и спискам доменов, направляя его через разные сетевые интерфейсы.

### Типичные сценарии использования

| Сценарий | Описание |
|----------|----------|
| 🇷🇺 ЕАЭС → ISP | Подсети ЕАЭС (RU+BY+KZ+AM+KG) идут через провайдера, остальное — через VPN |
| 🔒 Selected → VPN | Определённые подсети/домены отправляются в VPN-туннель |
| 🌍 Multi-zone | Любая комбинация стран или союзов (СНГ, BRICS, EU, 232 зоны, 40+ объединений) |

---

## Требования

### Аппаратные

- Роутер Keenetic с поддержкой Entware (USB-порт + накопитель с Ext4/ExFAT)
- **KeeneticOS 5.0+**
- Рекомендуется ≥128 МБ RAM (для загрузки ~13 000 маршрутов)

### Компоненты прошивки Keenetic

В веб-интерфейсе роутера (*Общие настройки → Изменить набор компонентов*) должны быть включены:

- ✅ **OPKG** (Поддержка пакетов OPKG) — обязательно
- ✅ **Драйвер ФС** для USB-накопителя (Ext4 или ExFAT) — обязательно
- ❌ *Netfilter*, *ipset*, *nftables* — **НЕ требуются**

### Программные зависимости

**Из Entware-репозитория** (устанавливаются автоматически):

| Пакет | Назначение |
|-------|-----------|
| `ip-full` | Policy routing (`ip rule`, `ip route`, `ip -batch`) |
| `curl` | Скачивание GeoIP-подсетей |
| `bind-dig` | DNS-резолвинг доменов для маршрутизации |
| `aggregate` | Агрегация (оптимизация) CIDR-подсетей |
| `coreutils-touch` | Управление метками времени кэшей |

**Из проекта keenetic-entware-extras** (пока не настроен репозиторий — устанавливаются вручную):

| Пакет | Назначение |
|-------|-----------|
| `keenetic-entware-extras` | Общие библиотеки проекта (обязательно) |
| `geo-split-data` | Предзаполненные списки доменов и GeoIP-зоны (опционально, для начального запуска) |

**Опционально:**

| Пакет | Назначение |
|-------|-----------|
| `jq` | Для загрузчика `ripe-json` (альтернативный источник подсетей) |

---

## Установка

### Шаг 1. Установить зависимости проекта

```sh
# Сначала — общие библиотеки (обязательно)
opkg install keenetic-entware-extras_<версия>_all.ipk

# Предзаполненные данные (опционально, для быстрого старта)
opkg install geo-split-data_<версия>_all.ipk
```

### Шаг 2. Установить geo-split

```sh
opkg install geo-split_<версия>_all.ipk
```

Зависимости из Entware-репозитория (`ip-full`, `curl`, `bind-dig`, `aggregate`, `coreutils-touch`) установятся автоматически.

После установки сервис **запускается автоматически** с конфигурацией по умолчанию.

### Шаг 3. Проверить статус

```sh
/opt/etc/init.d/S99geo-split status
```

> 💡 Конфигурация по умолчанию работает «из коробки»: `ROUTE_OUT="auto"` определяет ISP-интерфейс автоматически. Если вам не нужно менять поведение — настройка не требуется.

### Шаг 4. (Опционально) Настроить конфигурацию

Если нужно изменить поведение:

```sh
vi /opt/keenetic-entware-extras/geo-split/config/config.conf
```

Применить изменения:

```sh
/opt/etc/init.d/S99geo-split restart
```

---

## Настройка

Файл конфигурации: `/opt/keenetic-entware-extras/geo-split/config/config.conf`

> 📝 Этот файл объявлен как `conffile` — при обновлении пакета через `opkg upgrade` ваши изменения **сохраняются**.

> 📝 Значения по умолчанию задокументированы в `config/defaults.conf`. В `config.conf` указывайте **только параметры, которые отличаются** от дефолтных. Если конфиг пустой или отсутствует — используются значения по умолчанию.

### Основные параметры

#### ROUTE_OUT — куда направлять GEO-трафик

| Значение | Поведение |
|----------|-----------|
| `"auto"` (по умолч.) | Автоопределение ISP-интерфейса из `ip route show default` |
| `"lte_br0"` | Через LTE-модем |
| `"nwg0"` | Через WireGuard/AmneziaWG VPN |
| `"ppp0"` | Через PPP-соединение |

> 💡 `"auto"` — рекомендация для типичного сценария «RU → ISP».

#### ROUTE_GW — шлюз для маршрутов

| Значение | Поведение |
|----------|-----------|
| `"auto"` (по умолч.) | Определить из default route целевого интерфейса |
| `"none"` | Без шлюза (dev-only routes, scope link) |
| `"1.2.3.4"` | Указать IP-шлюз явно |

> 📝 На point-to-point интерфейсах (LTE/PPP) auto-detect возвращает пустое значение — маршруты добавляются без gateway (это нормально для таких интерфейсов).

#### ROUTE_IN — откуда берётся трафик

Пробелом разделённые имена LAN-интерфейсов:

| Значение | Описание |
|----------|----------|
| `"br0"` (по умолч.) | Только домашняя сеть |
| `"br0 br1"` | Домашняя + гостевая сеть |

### GEO-зона (multi-zone)

Главный параметр, определяющий **какие страны** маршрутизировать:

| Параметр | По умолч. | Описание |
|----------|-----------|----------|
| `GEO_ZONE` | `"eas"` | Зона: код страны ISO 3166-1 (ru, cn, us…) или союз (eas, cis, brics…) |

`GEO_ZONE` определяет набор стран, чьи IP-подсети загружаются и маршрутизируются. Все 240+ зон предзагружены в `geo-split-data/lists/geoip/<cc>.zone`.

**Отдельные страны** — любой ISO 3166-1 alpha-2 код:

| Значение | Страна |
|----------|--------|
| `"ru"` | 🇷🇺 Россия |
| `"cn"` | 🇨🇳 Китай |
| `"us"` | 🇺🇸 США |
| `"de"` | 🇩🇪 Германия |

**Объединения** (подсети всех стран объединяются в один маршрутный набор):

| Значение | Описание | Страны |
|----------|----------|--------|
| `"eas"` | ЕАЭС | ru, by, kz, am, kg |
| `"cis"` | СНГ | ru, by, kz, am, kg, uz, tj, md, az |
| `"postsov"` | Постсоветские (все 15) | ru, by, kz, am, kg, uz, tj, tm, md, az, ua, ge, ee, lv, lt |
| `"brics"` | BRICS+ | ru, br, in, cn, za, eg, et, ae, sa, ir |
| `"sco"` | ШОС | ru, cn, in, kz, kg, pk, tj, uz, ir, by |
| `"eu"` | Евросоюз (EU-27) | de, fr, it, es, pl, nl… |
| `"europe"` | Вся Европа | 45 стран |
| `"asia"` | Азия | 48 стран |

> 📝 Полный список 40+ объединений: `lib/geo.sh`.

### Настройка подсетей

| Параметр | По умолч. | Описание |
|----------|-----------|----------|
| `SUBNET_URL_PATTERN` | `ipdeny.com/…/{cc}.zone` | URL-шаблон для скачивания подсетей (`{cc}` → код страны) |
| `SUBNET_URL` | `""` (не задан) | Переопределение: если задан — игнорирует GEO_ZONE, скачивает один URL |
| `SUBNET_LOADER` | `"cidr-plain"` | Загрузчик: `cidr-plain` или `ripe-json` |
| `SUBNET_AGGREGATE` | `1` | Агрегация CIDR (1=вкл, 0=выкл) |
| `MAX_CACHE_AGE` | `604800` (7 дней) | Макс. возраст кэша подсетей (сек) |

> 📝 При использовании `GEO_ZONE` подсети берутся из локальных файлов `geo-split-data/lists/geoip/<cc>.zone` (предзагружены). Если локальный файл отсутствует или устарел — скачивается по `SUBNET_URL_PATTERN`.

### Настройка доменов

| Параметр | По умолч. | Описание |
|----------|-----------|----------|
| `DOMAINS_LIST_FILE` | `geo-split-data/lists/domains.txt` | Файл со списком доменов |
| `DOMAINS_UPDATE_INTERVAL` | `3600` (1 час) | Интервал обновления резолва (0 = отключить) |
| `DNS_FULL_RESOLVER_PORT` | `""` (auto) | Порт DNS-резолвера (auto: SmartDNS 6153 → 6053 → system) |

### Настройка скачивания

| Параметр | По умолч. | Описание |
|----------|-----------|----------|
| `DOWNLOAD_RETRIES` | `2` | Попытки скачивания на каждый интерфейс |
| `DOWNLOAD_RETRY_DELAY` | `3` | Задержка между попытками (сек) |
| `DOWNLOAD_INTERFACES` | `"default *"` | Интерфейсы для скачивания с failover |

### Таблицы маршрутизации

| Параметр | По умолч. | Описание |
|----------|-----------|----------|
| `DOMAIN_ROUTE_TABLE` | `1000` | Таблица для доменов (/32 host routes) |
| `DOMAIN_RULE_PRIORITY` | `50` | Приоритет ip rule для доменов |
| `SUBNET_ROUTE_TABLE` | `1001` | Таблица для GeoIP-подсетей (CIDR) |
| `SUBNET_RULE_PRIORITY` | `51` | Приоритет ip rule для подсетей |

### Примеры конфигурации

**Сценарий 1: ЕАЭС → ISP (по умолчанию, конфиг не нужен)**

Подсети стран ЕАЭС (RU+BY+KZ+AM+KG) идут через ISP, остальной — через VPN:
```sh
# config.conf — пустой или:
GEO_ZONE="eas"
ROUTE_OUT="auto"
```

**Сценарий 2: Только Россия → ISP**

Маршрутизировать только российские подсети:
```sh
GEO_ZONE="ru"
```

**Сценарий 3: СНГ-зона через VPN-туннель**

Направить подсети СНГ через VPN (доступ к RU-сервисам из-за рубежа):
```sh
GEO_ZONE="cis"
ROUTE_OUT="nwg0"
```

**Сценарий 4: BRICS+ → ISP (широкая зона)**

Маршрутизировать трафик в страны BRICS+ через провайдера:
```sh
GEO_ZONE="brics"
```

**Сценарий 5: GEO-трафик через конкретный LTE-интерфейс**
```sh
ROUTE_OUT="lte_br0"
```

**Сценарий 6: Домашняя + гостевая сеть**
```sh
ROUTE_IN="br0 br1"
```

**Сценарий 7: Отключить резолвинг доменов (только подсети)**
```sh
DOMAINS_UPDATE_INTERVAL=0
```

**Сценарий 8: Использовать RIPE API вместо ipdeny (legacy)**
```sh
SUBNET_LOADER="ripe-json"
SUBNET_URL="https://stat.ripe.net/data/country-resource-list/data.json?resource=RU"
```

> 📝 Если задан `SUBNET_URL` — он переопределяет GEO_ZONE (legacy-совместимость).

---

## Использование

### Команды управления

Сервис управляется через init-скрипт:

```sh
/opt/etc/init.d/S99geo-split <команда>
```

> ⚠️ **Важно:** Если сервис был **выключен** командой `disable`, symlink `/opt/etc/init.d/S99geo-split` не существует. Для повторного включения используйте полный путь:
> ```sh
> /opt/keenetic-entware-extras/geo-split/init.d/S99geo-split enable
> ```

| Команда | Описание |
|---------|----------|
| `start` | Запуск: загрузка подсетей и доменов (параллельно) → подключение правил |
| `stop` | Остановка: удаление ip rules, очистка таблиц |
| `restart` | Перезапуск (stop → start) |
| `status` | Подробная диагностика состояния |
| `refresh` | Проверить свежесть кэша, обновить если устарел (используется cron) |
| `update` | Принудительно обновить подсети и домены |
| `update-subnets` | Принудительно обновить только подсети |
| `update-domains` | Принудительно обновить только домены |
| `enable` | Включить сервис (создать symlink + запустить) |
| `disable` | Отключить сервис (остановить + удалить symlink) |

### enable / disable

| Команда | Что происходит |
|---------|---------------|
| `enable` | Создаётся symlink в `/opt/etc/init.d/` → сервис запускается и будет стартовать при каждой загрузке |
| `disable` | Сервис останавливается, symlink удаляется → **не стартует при загрузке**, команды `start`/`restart` недоступны через /opt/etc/init.d/ |

> ⚠️ После `disable` нельзя запустить сервис через `/opt/etc/init.d/S99geo-split start` — этого файла больше нет. Чтобы вернуть сервис, используйте `enable` через полный путь.

### Диагностика маршрутов (route-check)

Утилита `route-check.sh` определяет, через какой интерфейс пойдёт трафик к указанному хосту или IP.

```sh
/opt/keenetic-entware-extras/geo-split/scripts/route-check.sh <домен-или-IP>
```

**Примеры:**
```sh
# Проверить маршрут до домена
route-check.sh ozon.ru
# ⇒  ozon.ru → geo-split (subnet 5.188.140.0/22 table 1001) → eth3

# Проверить как конкретный клиент
route-check.sh github.com --from AA:BB:CC:DD:EE:FF
# ⊙  github.com → tunnel (policy table 4097) → nwg0

# JSON-формат (для WebUI/автоматизации)
route-check.sh --json ozon.ru
```

**Опции:**

| Опция | Описание |
|-------|----------|
| `--json` | Вывод в формате JSON |
| `--from <MAC>` | Проверить маршрут от лица конкретного клиента (MAC-адрес) |

**Вердикты:**

| Символ | Значение |
|--------|----------|
| `⇒` (geo-split) | Трафик идёт через geo-split (domain table или subnet table) |
| `⊙` (tunnel) | Трафик идёт через VPN-туннель (политика клиента) |
| `⚠` (mixed) | CDN — разные IP идут разными путями |
| `→` (default) | Трафик идёт по маршруту по умолчанию |

> 💡 **В WebUI**: Route Check доступен через кнопку «Диагностика» → «Route Check» на дашборде.

### Управление списком доменов

Список доменов находится в `/opt/keenetic-entware-extras/geo-split-data/lists/domains.txt`.

**Добавить домен:**
```sh
echo "example.com" >> /opt/keenetic-entware-extras/geo-split-data/lists/domains.txt
```

**Применить изменения:**
```sh
/opt/etc/init.d/S99geo-split update-domains
```

**Формат файла:**
- Один домен на строку
- Строки с `#` — комментарии
- `@filename` — подключить другой файл (относительно текущей директории)

Пример:
```
# Подключить белый список российских сервисов
@ru-whitelist.txt

# Мои домены
mybank.ru
my-ru-service.com
```

### Автоматическая работа

После запуска geo-split работает автономно:

1. **Cron** (каждые 15 мин со случайным сдвигом) — проверяет свежесть кэша, обновляет при необходимости
2. **NDM hook** — реагирует на переключение интерфейсов (VPN up/down) и восстанавливает маршруты
3. **Boot** — автоматический запуск при загрузке роутера (если сервис enabled)

---

## Диагностика

### Проверка статуса

```sh
/opt/etc/init.d/S99geo-split status
```

Пример вывода (всё работает):

```
geo-split status: ✓ Alive
  Mode:
    Geo zone:    eas → [ru by kz am kg]
    Route in:    br0
    Route out:   auto (detect ISP)
    Active out:  apcli0 (tables 1000,1001)
    Gateway:     192.168.1.1

  IP rules:
    iif br0 → table 1000 (domains) ✓
    iif br0 → table 1001 (subnets) ✓

  Routes:
    Domains:     183 routes in table 1000, filled 32m 56s ago ✓
    Subnets:     9274 routes in table 1001, filled 33m 31s ago ✓

  Caches:
    Subnets:     cache 2d 6h 51m old (max 7d 0h 0m) ✓
    Domains:     183 in cache, 33m 11s old (max 1h 0m 0s) ✓

  Domain sources: 103 domain(s) configured

  System:
    Uptime:      2d 5h ✓
    Cron:        1 job(s) (shift 7m) ✓
    NDM hook:    /opt/etc/ndm/ifstatechanged.d/geo-split-hook ✓
    DL iface:    default (cached)
    DNS:         localhost:6153 (SmartDNS no-speed-check)
    Background:  idle
    Loader:      cidr-plain
    Version:     0.13.0
```

Пример вывода (сервис отключён):

```
geo-split status: ⚠ Disabled
```

Пример вывода (есть проблемы):

```
geo-split status: ✗ Fail
  ...
    Subnets:     0 routes in table 1001 ✗
  ...
```

**Индикаторы:** ✓ = ok, ✗ = проблема, ⚠ = предупреждение.

**Exit code:** `0` = всё в порядке, `1` = есть проблемы.

**JSON-вывод** (для автоматизации):
```sh
/opt/keenetic-entware-extras/geo-split/scripts/status.sh --json
```

### Проверка маршрутов вручную

```sh
# Посмотреть ip rules
/opt/sbin/ip rule show

# Посмотреть domain routes (table 1000)
/opt/sbin/ip route show table 1000 | head -20

# Посмотреть subnet routes (table 1001)
/opt/sbin/ip route show table 1001 | wc -l

# Проверить маршрут конкретного IP
/opt/sbin/ip route get 5.255.255.242
```

### Частые проблемы

| Симптом | Причина | Решение |
|---------|---------|---------|
| Status: `✗ Fail`, 0 routes | Не скачались подсети / нет интернета | `S99geo-split update` |
| `Active out: — detached` | VPN не поднят или rules не подключены | Поднять VPN; geo-split подхватит через NDM hook |
| Домены не резолвятся | Нет DNS-резолвера | Установить `smartdns-geo-conf` или указать `DNS_FULL_RESOLVER_PORT` |
| Status: ✗ для Cron | Нет cron-задачи | `S99geo-split restart` |
| `ip: command not found` | Нет ip-full | `opkg install ip-full` |
| Сервис не стартует при загрузке | `disable` был вызван ранее | Запустить `enable` из полного пути |
| После firmware upgrade — нет маршрутов | Keenetic пересоздал интерфейсы | `S99geo-split restart` |

### Логи

```sh
# Системный лог
dmesg | grep geo-split
```

---

## Как это работает

### Архитектура: route-based (без iptables)

geo-split **не использует** iptables MARK/mangle (чтобы не конфликтовать с Keenetic NDM per-device routing). Вместо этого — policy routing:

1. `ip rule add iif br0 table 1000 priority 50` — domain routes (/32 host)
2. `ip rule add iif br0 table 1001 priority 51` — subnet routes (GeoIP CIDRs)
3. Трафик, не попавший ни в один маршрут, идёт обычным путём

Domain table (prio 50) проверяется **первой** → можно точечно маршрутизировать домены поверх целых подсетей.

### Потоки данных

```
Boot:           update-subnets & update-domains (параллельно) → attach-rules
Cron (15 мин):  update-subnets & update-domains (параллельно, если кэш устарел)
Interface Up:   update-subnets --refill & update-domains --refill → attach-rules
Interface Down: detach-rules
```

---

## Обновление

```sh
opkg upgrade geo-split
```

Конфигурация (`config/config.conf`) сохраняется при обновлении.

---

## Удаление

```sh
opkg remove geo-split
```

Автоматически: остановка сервиса, удаление cron-задачи, NDM hook, batch-файлов.

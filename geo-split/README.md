# geo-split

Split routing для Keenetic/Entware — маршрутизация трафика по GeoIP-подсетям и спискам доменов через разные сетевые интерфейсы.

Типичные сценарии:
- 🇷🇺 **RU → ISP:** российские подсети идут напрямую через провайдера, остальной трафик — через VPN
- 🔒 **Selected → VPN:** определённые подсети/домены маршрутизируются в VPN-туннель
- 🌍 **GeoIP split:** автоматическое разделение трафика по гео-принадлежности IP

## Установка

Основной способ — через opkg:

```sh
opkg install geo-split_0.7.0_all.ipk
```

Зависимости (`keenetic-entware-extras`, `geo-split-data`, `ip-full`, `curl`, `bind-dig`, `aggregate`) устанавливаются автоматически.

> `config/config.sh` — conffile: при `opkg upgrade` пользовательский конфиг сохраняется.

После установки:

```sh
# 1. Отредактировать конфигурацию
vi /opt/keenetic-entware-extras/geo-split/config/config.sh

# 2. Запустить
/opt/etc/init.d/S99geo-split start
```

## Удаление

```sh
opkg remove geo-split
```

Автоматически выполняется: останов сервиса, удаление cron-задания, NDM hook, batch-файлов.

## Маршрутизация (ROUTE_OUT / ROUTE_IN)

Два ключевых параметра управляют маршрутизацией:

| Параметр | Описание | По умолчанию |
|----------|----------|--------------|
| `ROUTE_OUT` | Куда направлять GEO-трафик (выходной интерфейс) | `"auto"` |
| `ROUTE_IN` | Откуда берётся трафик (LAN-интерфейсы для `ip rule iif`) | `"br0"` |

**Семантика `ROUTE_OUT`:**
- `"auto"` или пустая строка → автоопределение ISP через `ip route show default`
- Явное имя интерфейса (`"lte_br1"`, `"nwg0"`, `"ppp0"`) → использовать напрямую

## Архитектура

### Принцип: async-данные + мгновенные правила

Загрузка данных (CIDR-подсети, DNS-резолвинг доменов) выполняется **асинхронно** через cron. Подключение маршрутных правил — **мгновенно** из кэша (~1 сек для 13K+ маршрутов через `ip-full -batch`). Это разделение обеспечивает быстрый старт и надёжную работу при перезагрузках и переключении интерфейсов.

### Подход: route-based (без iptables)

Вместо `iptables mangle MARK` (который конфликтует с Keenetic NDM per-device routing) используется **route-based** подход:

1. `ip rule add iif br0 table 1000 priority 50` — domain routes (/32 host routes)
2. `ip rule add iif br0 table 1001 priority 51` — subnet routes (GeoIP CIDRs)
3. Загрузчики заполняют таблицы: domains → table 1000, subnets → table 1001
4. Трафик, не попавший ни в один маршрут, проходит по обычному маршруту

Domain table (prio 50) проверяется первой — позволяет точечно маршрутизировать отдельные домены поверх подсетей.

Подробнее о несовместимости fwmark: [keenetic-fwmark-analysis.md](../docs/knowledge/keenetic-fwmark-analysis.md)

## Flows

### Boot flow (`S99geo-split start`)

Последовательное выполнение (cold start: sequential во избежание конфликтов temp-файлов на роутерах с малым объёмом RAM):

```
1. update-subnets.sh  — проверяет кэш, скачивает если stale, заполняет subnet table
2. update-domains.sh  — проверяет кэш, резолвит если stale, заполняет domain table
3. attach-rules.sh    — подключает ip rules для всех iface из ROUTE_IN
```

### Cron flow (`S99geo-split refresh`, каждые 15 мин)

```
update-subnets.sh & update-domains.sh  (параллельно)
```

Оба скрипта проверяют свежесть кэша (`MAX_CACHE_AGE`, `DOMAINS_UPDATE_INTERVAL`) — реальная загрузка происходит только если кэш устарел. Routing tables перезаполняются при необходимости. Команда `refresh` не затрагивает ip rules.

### NDM hook flow (интерфейс up/down)

```
Interface UP:
  sleep 2 (debounce)
  → update-subnets.sh --refill & update-domains.sh --refill  (параллельно)
  → attach-rules.sh                                          (фоново)

Interface DOWN:
  → detach-rules.sh
```

Hook слушает интерфейс в зависимости от `ROUTE_OUT`:
- `"auto"` → интерфейс с default route
- Явное имя → только указанный интерфейс

## Команды управления

```sh
/opt/etc/init.d/S99geo-split <команда>
```

| Команда | Что делает | Режим |
|---------|-----------|-------|
| `start` | `update-subnets.sh` → `update-domains.sh` → `attach-rules.sh` | Последовательно |
| `stop` | `detach-rules.sh` — удаляет ip rules + flush route tables | Синхронно |
| `restart` | `stop` → `sleep 1` → `start` | Синхронно |
| `status` | `status.sh` — диагностика | Синхронно |
| `refresh` | `update-subnets.sh` & `update-domains.sh` (проверяют свежесть) | Параллельно |
| `update` | `update-subnets.sh --force` & `update-domains.sh --force` | Параллельно |
| `update-subnets` | `update-subnets.sh --force` | Синхронно |
| `update-domains` | `update-domains.sh --force` | Синхронно |

## Настройка

Конфигурация: `config/config.sh`

### Полная таблица параметров

| Параметр | По умолчанию | Описание |
|----------|-------------|----------|
| `ROUTE_OUT` | `"auto"` | Целевой исходящий интерфейс. `auto` = ISP из default route |
| `ROUTE_IN` | `"br0"` | Входные LAN-интерфейсы (через пробел) |
| `DOMAIN_ROUTE_TABLE` | `"1000"` | Routing table для доменов (/32 host routes) |
| `DOMAIN_RULE_PRIORITY` | `"50"` | Priority ip rule для domain table |
| `SUBNET_ROUTE_TABLE` | `"1001"` | Routing table для GeoIP подсетей (CIDR) |
| `SUBNET_RULE_PRIORITY` | `"51"` | Priority ip rule для subnet table |
| `SUBNET_URL` | `ipdeny.com/...ru.zone` | URL для скачивания подсетей |
| `SUBNET_LOADER` | `"cidr-plain"` | Загрузчик из каталога `loaders/` |
| `SUBNET_AGGREGATE` | `1` | Агрегация CIDR (1 = включена, требует `aggregate`) |
| `MAX_CACHE_AGE` | `604800` | Макс. возраст кэша подсетей, секунды (7 дней) |
| `DOWNLOAD_RETRIES` | `2` | Попытки скачивания на каждый интерфейс |
| `DOWNLOAD_RETRY_DELAY` | `3` | Задержка между попытками (секунды) |
| `DOWNLOAD_INTERFACES` | `"default nwg* ovpn* l2tp* pptp* sstp* ipsec*"` | Интерфейсы для скачивания (glob-паттерны), failover по списку |
| `DNS_FULL_RESOLVER_PORT` | `""` | Порт DNS-резолвера (пусто = автоопределение: SmartDNS 6153 → 6053 → system) |
| `DOMAINS_LIST_FILE` | `geo-split-data/lists/domains.txt` | Файл списка доменов (поддержка `@include`) |
| `DOMAINS_UPDATE_INTERVAL` | `3600` | Интервал обновления доменов, секунды (1 час; `0` = отключить) |

### Примеры конфигурации

**RU → ISP — GEO-трафик через конкретный ISP-интерфейс:**
```sh
ROUTE_OUT="lte_br0"
```

**VPN — GEO-трафик через WireGuard:**
```sh
ROUTE_OUT="nwg0"
```

**Auto — автоопределение ISP (рекомендуется):**
```sh
ROUTE_OUT="auto"
```

**Несколько LAN-интерфейсов (домашняя + гостевая сеть):**
```sh
ROUTE_IN="br0 br1"
```

**Отключить резолвинг доменов:**
```sh
DOMAINS_UPDATE_INTERVAL=0
```

## Файлы

| Файл | Назначение |
|------|-----------|
| `scripts/attach-rules.sh` | Подключить ip rules для всех iface из `ROUTE_IN` (domain prio 50, subnet prio 51) |
| `scripts/detach-rules.sh` | Отключить ip rules + flush route tables |
| `scripts/update-subnets.sh` | Скачать GeoIP подсети через loader + заполнить subnet table |
| `scripts/update-domains.sh` | DNS-резолвинг доменов (dig → /32 host routes в domain table) |
| `scripts/ndm-hook.sh` | NDM hook: реакция на interface up/down |
| `scripts/status.sh` | Диагностика: режим, правила, таблицы, кэши |
| `loaders/cidr-plain.sh` | Загрузчик: plain CIDR (по умолчанию) |
| `loaders/ripe-json.sh` | Загрузчик: RIPE JSON API (требует `jq`) |
| `config/config.sh` | Конфигурация (режим, интерфейсы, URL, интервалы) |
| `rootfs/opt/etc/init.d/S99geo-split` | Init-скрипт (start/stop/restart/status/refresh/update) |

Данные (домен-листы, geoip-зоны) вынесены в отдельный пакет [`geo-split-data`](../geo-split-data/).

## Загрузчики

Загрузчики — скрипты в каталоге `loaders/`, которые скачивают CIDR-подсети из внешнего источника и выдают их в stdout (одна подсеть на строку).

| Загрузчик | Описание | Зависимости |
|-----------|----------|-------------|
| `cidr-plain` | Plain-текст CIDR, фильтрация IPv6. По умолчанию | `curl` |
| `ripe-json` | RIPE Stat JSON API | `curl`, `jq` |

Выбор загрузчика в `config/config.sh`:

```sh
SUBNET_LOADER="cidr-plain"
SUBNET_URL="https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4/ru.cidr"
```

## Диагностика (status.sh)

```sh
/opt/etc/init.d/S99geo-split status
```

Пример вывода:

```
geo-split status:
  Mode:
    Route in:    br0
    Route out:   auto (detect ISP)
    Active out:  ppp0 (tables 1000,1001)

  IP rules:
    iif br0 → table 1000 (domains) ✓
    iif br0 → table 1001 (subnets) ✓

  Routes:
    Domains:     175 routes in table 1000 ✓
    Subnets:     8768 routes in table 1001 ✓

  Caches:
    Subnets:     cache 8m old (max 7d 0h) ✓
    Domains:     180 in cache, 8m old (max 1h 0m) ✓

  Domain sources: 1 domain(s) configured

  System:
    Uptime:      2d 5h ✓
    Cron:        1 job(s) ✓
    NDM hook:    /opt/etc/ndm/ifstatechanged.d/geo-split-hook ✓
    DL iface:    default (cached)
    DNS:         localhost:6153 (SmartDNS no-speed-check)
    Background:  idle
    Loader:      cidr-plain
    Version:     0.8.0
```

**Exit code:** `0` — всё в порядке, `1` — есть проблемы (✗ в выводе).

## Зависимости

| Пакет | Тип | Назначение |
|-------|-----|-----------|
| `keenetic-entware-extras` | Depends | Базовый пакет (общие библиотеки) |
| `geo-split-data` | Depends | Списки доменов и GeoIP-зоны |
| `ip-full` | Depends | `ip rule`, `ip route`, `ip -batch` |
| `curl` | Depends | Скачивание подсетей |
| `bind-dig` | Depends | DNS-резолвинг доменов |
| `aggregate` | Depends | Агрегация CIDR-подсетей |
| `jq` | Recommends | Для загрузчика `ripe-json` |

## Для разработчиков

Деплой на роутер (без .ipk):

```sh
scp -O -r geo-split/ root@<router>:/opt/keenetic-entware-extras/geo-split/
scp -O -r lib/ root@<router>:/opt/keenetic-entware-extras/lib/
ssh root@<router> '/opt/etc/init.d/S99geo-split restart'
```

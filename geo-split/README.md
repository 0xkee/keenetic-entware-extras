# geo-split

Split routing для Keenetic/Entware — маршрутизация трафика по GeoIP-подсетям и спискам доменов через разные сетевые интерфейсы.

Типичные сценарии:
- 🇷🇺 **RU → ISP:** российские подсети идут напрямую через провайдера, остальной трафик — через VPN
- 🔒 **Selected → VPN:** определённые подсети/домены маршрутизируются в VPN-туннель
- 🌍 **GeoIP split:** автоматическое разделение трафика по гео-принадлежности IP

## Режимы работы

| Режим | Описание | Целевой интерфейс |
|-------|----------|-------------------|
| `bypass` | GEO-трафик идёт напрямую через ISP, минуя VPN | `ISP_INTERFACE` (или auto-detect) |
| `vpn` | GEO-трафик направляется в VPN-туннель | `VPN_INTERFACE` |
| `auto` | Автоопределение ISP-интерфейса, GEO-трафик через ISP | `ip route show default` |

## Архитектура

### Принцип: async-данные + мгновенные правила

Загрузка данных (CIDR-подсети, DNS-резолвинг доменов) выполняется **асинхронно** через cron. Подключение маршрутных правил — **мгновенно** из кэша (~1 сек для 13K+ маршрутов через `ip-full -batch`). Это разделение обеспечивает быстрый старт и надёжную работу при перезагрузках и переключении интерфейсов.

### Подход: route-based (без iptables)

Вместо `iptables mangle MARK` (который конфликтует с Keenetic NDM per-device routing) используется **route-based** подход:

1. `ip rule add iif br0 table 1000` — весь LAN-трафик попадает в таблицу 1000
2. Per-subnet маршруты в таблице 1000 — трафик к GEO-подсетям идёт через целевой интерфейс
3. Трафик, не попавший ни в один маршрут таблицы 1000, проходит по обычному маршруту

Подробнее о несовместимости fwmark: [docs/keenetic-fwmark-analysis.md](../docs/keenetic-fwmark-analysis.md)

### Boot flow (S99geo-split start)

```
1. load-ipset.sh     — загрузить кэш-файлы (subnets + domains) в ipset  ~мгновенно
2. attach-rules.sh   — ip rule iif br0 + загрузить маршруты (ip-full -batch)  ~1 сек
3. update-subnets.sh — фоново: проверить свежесть, скачать если stale   (background)
4. update-domains.sh — фоново: проверить свежесть, обновить если stale  (background)
```

### Cron flow (каждые 15 мин)

```
update-subnets.sh → проверить возраст кэша → если stale → loader → файл → load-ipset.sh
update-domains.sh → проверить возраст кэша → если stale → dig → файл → ipset add
```

Скрипты сами проверяют свежесть кэша (`MAX_CACHE_AGE`, `DOMAINS_UPDATE_INTERVAL`) — cron вызывает их часто, но реальная загрузка происходит только при необходимости.

### NDM hook flow (интерфейс up/down)

```
interface up   → attach-rules.sh (ip rule iif br0 + routes)  ~1 сек
interface down → detach-rules.sh (ip rule del + route flush)  <1 сек
                 + failover: если есть другой default route → re-attach
```

## Файлы

| Файл | Назначение |
|------|-----------|
| `scripts/apply-routes.sh` | Оркестратор: load-ipset + attach-rules |
| `scripts/attach-rules.sh` | Подключить ip rule iif br0 + per-subnet маршруты (~1 сек) |
| `scripts/detach-rules.sh` | Отключить маршрутные правила |
| `scripts/load-ipset.sh` | Загрузить кэш-файлы (subnets + domains) в ipset |
| `scripts/update-subnets.sh` | Скачать CIDR-подсети через loader |
| `scripts/update-domains.sh` | DNS-резолвинг доменов (dig → ipset + кэш) |
| `scripts/ndm-hook.sh` | NDM hook: реакция на interface up/down |
| `scripts/install.sh` | Установка: init-скрипт + cron + NDM hook |
| `scripts/uninstall.sh` | Удаление: cleanup правил + файлов |
| `scripts/status.sh` | Диагностика: режим, ipset, правила, кэши |
| `loaders/cidr-plain.sh` | Загрузчик: plain CIDR (одна подсеть на строку) |
| `loaders/ripe-json.sh` | Загрузчик: RIPE JSON API (требует jq) |
| `config/config.sh` | Конфигурация (режим, интерфейсы, URL, интервалы) |

Данные (домен-листы, geoip-зоны) вынесены в отдельный подпроект [`geo-split-data/`](../geo-split-data/).

## Настройка

Отредактируйте `config/config.sh`:

```sh
# Режим маршрутизации: bypass | vpn | auto
ROUTE_MODE="auto"

# ISP-интерфейс (для режимов bypass/auto)
# Пустое значение = автоопределение через ip route show default
ISP_INTERFACE=""

# VPN-интерфейс (для режима vpn)
VPN_INTERFACE="nwg0"

# Имя ipset
IPSET_NAME="geo-split"

# Таблица маршрутизации
ROUTE_TABLE="1000"

# LAN-интерфейсы (через пробел)
# br0 = домашняя сеть, br1 = гостевая
LAN_INTERFACES="br0"
```

### Примеры конфигурации

**bypass — GEO-трафик через конкретный ISP-интерфейс:**
```sh
ROUTE_MODE="bypass"
ISP_INTERFACE="lte_br0"
```

**vpn — GEO-трафик через WireGuard:**
```sh
ROUTE_MODE="vpn"
VPN_INTERFACE="nwg0"
```

**auto — автоопределение ISP (рекомендуется):**
```sh
ROUTE_MODE="auto"
ISP_INTERFACE=""
```

### Параметры кэширования

```sh
# Максимальный возраст кэша подсетей (7 дней, в секундах)
MAX_CACHE_AGE=604800

# Интервал обновления DNS-резолва доменов (1 час, в секундах)
# 0 = отключить автоматическое обновление доменов
DOMAINS_UPDATE_INTERVAL=3600
```

## Загрузчики (Loaders)

Загрузчики — скрипты в каталоге `loaders/`, которые скачивают CIDR-подсети из внешнего источника и выдают их в stdout (одна подсеть на строку).

### Доступные загрузчики

| Загрузчик | Описание | Зависимости |
|-----------|----------|-------------|
| `cidr-plain` | Plain-текст: одна CIDR-подсеть на строку | `curl` |
| `ripe-json` | RIPE Stat JSON API | `curl`, `jq` |

### Выбор загрузчика

В `config/config.sh`:

```sh
SUBNET_LOADER="cidr-plain"
SUBNET_URL="https://raw.githubusercontent.com/herrbischoff/country-ip-blocks/master/ipv4/ru.cidr"
```

### Как создать свой загрузчик

1. Создайте файл `loaders/my-loader.sh`
2. Скрипт получает URL через `$1` (первый аргумент)
3. Скрипт должен выводить в stdout CIDR-подсети (одна на строку)
4. Укажите имя в конфиге: `SUBNET_LOADER="my-loader"`

Пример минимального загрузчика:

```sh
#!/opt/bin/sh
# My custom loader: URL → stdout CIDRs
set -eu
curl -sSf "$1" | grep -E '^[0-9]+\.'
```

## DNS-резолвинг доменов

Отдельный скрипт `update-domains.sh` резолвит домены из `geo-split-data/lists/domains.txt` и добавляет IP в ipset.

### Настройка

1. Добавьте домены в [`geo-split-data/lists/domains.txt`](../geo-split-data/lists/domains.txt) (по одному на строку):

```
gosuslugi.ru
nalog.ru
mos.ru
```

2. Убедитесь что в `config/config.sh` указан путь к файлу:

```sh
DOMAINS_LIST_FILE="$_LISTS_DIR/domains.txt"
```

3. Настройте интервал обновления (по умолчанию 1 час):

```sh
DOMAINS_UPDATE_INTERVAL=3600
```

### Как работает

- `update-domains.sh` вызывается по cron каждые 15 минут
- Скрипт проверяет возраст кэша (`DOMAINS_CACHE_FILE`) — обновляет только если stale
- Каждый домен резолвится через `dig +short <domain> @localhost`
- Приватные IP (10.x, 192.168.x, 172.16-31.x, 127.x) отфильтровываются
- Resolved IP добавляются в ipset (`ipset add -exist`)
- Результат кэшируется в `geo-split-data/lists/domains-resolved.txt`
- Флаг `--force` принудительно обновляет кэш

### Требования

- `dig` (пакет `bind-dig`) — если не установлен, скрипт завершится с ошибкой
- [SmartDNS](../smartdns-ru/) на localhost — для DNS-резолвинга

### Отключение

Чтобы отключить резолвинг доменов, в `config/config.sh`:

```sh
DOMAINS_UPDATE_INTERVAL=0
```

## NDM Hook (interface up/down)

geo-split автоматически реагирует на изменение состояния сетевых интерфейсов через NDM hook (`/opt/etc/ndm/ifstatechanged.d/geo-split-hook`).

### Поведение

| Событие | Действие |
|---------|----------|
| `yes-up-up` (интерфейс поднялся) | `attach-rules.sh` — подключает ip rule + маршруты |
| `no-down-*` (интерфейс упал) | `detach-rules.sh` — отключает правила; если есть failover → re-attach |

Hook вызывает только `attach-rules.sh` / `detach-rules.sh` — мгновенное подключение/отключение правил без загрузки данных.

### Какой интерфейс слушает

| Режим | Целевой интерфейс |
|-------|--------------------|
| `bypass` / `auto` + `ISP_INTERFACE` задан | Только указанный ISP-интерфейс |
| `bypass` / `auto` + `ISP_INTERFACE` пуст | Интерфейс с default route (up) / интерфейс из route table (down) |
| `vpn` | `VPN_INTERFACE` |

### Failover (multi-WAN)

При переключении аплинков hook автоматически пере-применяет маршруты:

1. **Uplink1 down → Uplink2 up** — cleanup + re-attach через новый интерфейс
2. **Uplink2 up → Uplink1 down** — после cleanup, если есть failover default route — re-attach

Hook устанавливается автоматически при запуске `install.sh` как symlink на `scripts/ndm-hook.sh`.

## Команда status

Диагностика текущего состояния geo-split:

```sh
/opt/keenetic-entware-extras/geo-split/scripts/status.sh
```

Или через init-скрипт:

```sh
/opt/etc/init.d/S99geo-split status
```

Пример вывода:

```
geo-split status:
  Mode:        auto
  Interface:   ppp0 (active in table 1000)
  Ipset:       geo-split (8588 entries / 205KB) ✓ (obsoleted)
  IP rule:     iif br0 → table 1000 ✓
  Routes:      8768 in table 1000 ✓

  Subnets:     cache 8m old (max 7d 0h) ✓
  Domains:     180 in cache, 8m old (max 1h 0m) ✓
  Dom sources: 1 domain(s) configured

  Cron:        2 job(s) ✓
  NDM hook:    /opt/etc/ndm/ifstatechanged.d/geo-split-hook ✓
  DL iface:    default (cached)
  DNS:         localhost:6153 (SmartDNS no-speed-check)
  Background:  idle

  Loader:      cidr-plain
  Version:     0.2.0
```

**Exit code:** `0` — всё в порядке, `1` — есть проблемы (✗ в выводе).

## Установка / Удаление

### Установка

```sh
# 1. Скопировать на роутер
scp -r geo-split/ root@192.168.1.1:/opt/keenetic-entware-extras/geo-split/
scp -r geo-split-data/ root@192.168.1.1:/opt/keenetic-entware-extras/geo-split-data/

# 2. Запустить установку
ssh root@192.168.1.1 '/opt/keenetic-entware-extras/geo-split/scripts/install.sh'
```

`install.sh` автоматически:
- Установит зависимости (`ipset`, `curl`, `ip-full`)
- Создаст init-скрипт `/opt/etc/init.d/S99geo-split`
- Установит NDM hook
- Настроит cron-задания (обновление подсетей + доменов каждые 15 мин)

### Удаление

```sh
ssh root@192.168.1.1 '/opt/keenetic-entware-extras/geo-split/scripts/uninstall.sh'
```

`uninstall.sh` удалит:
- Init-скрипт
- NDM hook symlink
- Cron-задания
- Маршрутные правила (ip rule, route table, ipset)
- Кэш-файлы подсетей

## Зависимости (Entware)

```sh
# Обязательные
opkg install ipset curl ip-full

# Опционально — для DNS-резолвинга доменов:
opkg install bind-dig

# Опционально — для загрузчика ripe-json:
opkg install jq
```

- [SmartDNS](../smartdns-ru/) — DNS-сервер для резолвинга доменов (если используется [`geo-split-data/lists/domains.txt`](../geo-split-data/lists/domains.txt))

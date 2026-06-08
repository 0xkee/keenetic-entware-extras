# geo-split — Руководство пользователя

## Что это такое

**geo-split** — модуль split-маршрутизации для роутеров Keenetic с Entware. Позволяет автоматически разделять интернет-трафик по GeoIP-подсетям и спискам доменов, направляя его через разные сетевые интерфейсы.

### Типичные сценарии использования

| Сценарий | Описание |
|----------|----------|
| 🇷🇺 RU → ISP | Российские подсети идут напрямую через провайдера, остальное — через VPN |
| 🔒 Selected → VPN | Определённые подсети/домены отправляются в VPN-туннель |
| 🌍 GeoIP split | Автоматическое разделение трафика по гео-принадлежности IP-адресов |

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

### Настройка подсетей

| Параметр | По умолч. | Описание |
|----------|-----------|----------|
| `SUBNET_URL` | ipdeny.com/ru.zone | URL для скачивания GeoIP-подсетей |
| `SUBNET_LOADER` | `"cidr-plain"` | Загрузчик: `cidr-plain` или `ripe-json` |
| `SUBNET_AGGREGATE` | `1` | Агрегация CIDR (1=вкл, 0=выкл) |
| `MAX_CACHE_AGE` | `604800` (7 дней) | Макс. возраст кэша подсетей (сек) |

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

**Сценарий 1: RU → ISP (по умолчанию, конфиг не нужен)**

Российские подсети идут через ISP, остальной трафик — через VPN. Автоопределение ISP:
```sh
# config.conf — пустой или:
ROUTE_OUT="auto"
```

**Сценарий 2: RU-зона через VPN-туннель**

Направить российские подсети через VPN (например, для доступа к RU-сервисам из-за рубежа):
```sh
ROUTE_OUT="nwg0"
```

**Сценарий 3: GEO-трафик через конкретный LTE-интерфейс**
```sh
ROUTE_OUT="lte_br0"
```

**Сценарий 4: Домашняя + гостевая сеть**
```sh
ROUTE_IN="br0 br1"
```

**Сценарий 5: Отключить резолвинг доменов (только подсети)**
```sh
DOMAINS_UPDATE_INTERVAL=0
```

**Сценарий 6: Использовать RIPE API вместо ipdeny**
```sh
SUBNET_LOADER="ripe-json"
SUBNET_URL="https://stat.ripe.net/data/country-resource-list/data.json?resource=RU"
```

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
    Geo zone:    RU
    Route in:    br0
    Route out:   auto (detect ISP)
    Active out:  ppp0 (tables 1000,1001)
    Gateway:     10.64.0.1

  IP rules:
    iif br0 → table 1000 (domains) ✓
    iif br0 → table 1001 (subnets) ✓

  Routes:
    Domains:     175 routes in table 1000, filled 8m ago ✓
    Subnets:     8768 routes in table 1001, filled 8m ago ✓

  Caches:
    Subnets:     cache 2d 3h old (max 7d 0h) ✓
    Domains:     180 in cache, 8m old (max 1h 0m) ✓

  Domain sources: 142 domain(s) configured

  System:
    Uptime:      2d 5h ✓
    Cron:        1 job(s) (shift 7m) ✓
    NDM hook:    /opt/etc/ndm/ifstatechanged.d/geo-split-hook ✓
    DL iface:    default (cached)
    DNS:         localhost:6153 (SmartDNS no-speed-check)
    Background:  idle
    Loader:      cidr-plain
    Version:     0.12.3
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

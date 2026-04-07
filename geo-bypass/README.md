# geo-bypass

Селективная маршрутизация GEO IP-подсетей — через ISP напрямую (в обход VPN) или через VPN-туннель.

## Режимы работы

| Режим | Описание | Целевой интерфейс |
|-------|----------|-------------------|
| `bypass` | GEO-трафик идёт напрямую через ISP, минуя VPN | `ISP_INTERFACE` (или auto-detect) |
| `vpn` | GEO-трафик направляется в VPN-туннель | `VPN_INTERFACE` |
| `auto` | Автоопределение ISP-интерфейса, GEO-трафик через ISP | `ip route show default` |

## Принцип работы

1. `update-domains.sh` — загружает актуальные GEO IP-подсети
2. `apply-routes.sh` — определяет целевой интерфейс по `ROUTE_MODE`, загружает подсети в `ipset`, настраивает `ip rule` + `iptables mangle`

## Файлы

| Файл | Назначение |
|------|-----------|
| `scripts/update-domains.sh` | Обновление списка GEO IP-подсетей |
| `scripts/apply-routes.sh` | Определение интерфейса + применение маршрутов |
| `scripts/ndm-hook.sh` | NDM hook — реакция на interface up/down |
| `scripts/install.sh` | Установка в cron, автозапуск и NDM hook |
| `config/config.sh` | Настройки (режим, интерфейсы, ipset и т.д.) |
| `lists/` | Загруженные списки IP (генерируются автоматически) |
| `lists/domains.txt` | Опциональный список доменов для DNS-резолвинга |
| `lists/domains-resolved.txt` | Кэш resolved IP доменов (авто, не редактировать) |

## Настройка

Отредактируйте `config/config.sh`:

```bash
# Режим маршрутизации: bypass | vpn | auto
ROUTE_MODE="auto"

# ISP-интерфейс (для режимов bypass/auto)
# Пустое значение = автоопределение через ip route show default
ISP_INTERFACE=""

# VPN-интерфейс (для режима vpn)
VPN_INTERFACE="nwg0"

# Имя ipset
IPSET_NAME="geo-bypass"

# Таблица маршрутизации
ROUTE_TABLE="1000"
```

### Примеры конфигурации

**bypass — GEO-трафик через конкретный ISP-интерфейс:**
```bash
ROUTE_MODE="bypass"
ISP_INTERFACE="lte_br0"
```

**vpn — GEO-трафик через WireGuard:**
```bash
ROUTE_MODE="vpn"
VPN_INTERFACE="nwg0"
```

**auto — автоопределение ISP (рекомендуется):**
```bash
ROUTE_MODE="auto"
ISP_INTERFACE=""
```

## DNS-резолвинг доменов (опционально!)

Помимо CIDR-подсетей, можно добавить отдельные домены — их IP будут отрезолвлены через `dig @localhost` и добавлены в ipset.

### Настройка

1. Добавьте домены в `lists/domains.txt` (по одному на строку):

```
gosuslugi.ru
nalog.ru
mos.ru
```

2. Убедитесь что в `config/config.sh` указан путь к файлу:

```bash
DOMAINS_LIST_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lists/domains.txt"
```

3. Настройте время жизни кэша (по умолчанию 1 час):

```bash
DOMAINS_CACHE_AGE=3600
```

### Как работает

- `apply-routes.sh` после загрузки CIDR вызывает `resolve_domains()`
- Каждый домен резолвится через `dig +short <domain> @localhost`
- Приватные IP (10.x, 192.168.x, 172.16-31.x, 127.x) отфильтровываются
- Resolved IP добавляются в существующий ipset поштучно (`ipset add -exist`)
- Результат кэшируется в `lists/domains-resolved.txt` на `DOMAINS_CACHE_AGE` секунд

### Требования

- `dig` (пакет `bind-dig`) — если не установлен, функция тихо пропускается
- [SmartDNS](../smartdns/) на localhost — для DNS-резолвинга

### Отключение

Чтобы отключить резолвинг доменов, в `config/config.sh`:

```bash
DOMAINS_LIST_FILE=""
```

## NDM Hook (interface up/down)

geo-bypass автоматически реагирует на изменение состояния сетевых интерфейсов через NDM hook (`/opt/etc/ndm/ifstatechanged.d/geo-bypass-hook`).

### Поведение

| Событие | Действие |
|---------|----------|
| `yes-up-up` (интерфейс поднялся) | Запускает `apply-routes.sh` в background |
| `no-down-*` (интерфейс упал) | Удаляет `ip rule` и `iptables mangle` правило; если доступен failover-интерфейс — пере-применяет маршруты |

### Какой интерфейс слушает

| Режим | Целевой интерфейс |
|-------|--------------------|
| `bypass` / `auto` + `ISP_INTERFACE` задан | Только указанный ISP-интерфейс |
| `bypass` / `auto` + `ISP_INTERFACE` пуст | Интерфейс с default route (up) / интерфейс из route table (down) |
| `vpn` | `VPN_INTERFACE` |

### Failover (multi-WAN)

При переключении аплинков hook автоматически пере-применяет маршруты:

1. **Uplink1 down → Uplink2 up** — cleanup + re-apply через новый интерфейс
2. **Uplink2 up → Uplink1 down** — после cleanup, если есть failover default route — re-apply

Hook устанавливается автоматически при запуске `install.sh` как symlink на `scripts/ndm-hook.sh`.

## Установка на роутере

```bash
# 1. Скопировать на роутер
scp -r geo-bypass/ root@192.168.1.1:/opt/keenetic-entware/geo-bypass/

# 2. Запустить установку
ssh root@192.168.1.1 '/opt/keenetic-entware/geo-bypass/scripts/install.sh'
```

## Зависимости (Entware)

```bash
opkg install ipset curl
# Опционально, для DNS-резолвинга доменов:
opkg install bind-dig
```

- [SmartDNS](../smartdns/) — DNS-сервер для резолвинга доменов

# smartdns-redirect — Руководство пользователя

## Что это такое

**smartdns-redirect** — модуль перехвата DNS-трафика для роутеров Keenetic с Entware. Выполняет DNAT-перенаправление всех DNS-запросов с LAN на локальный DNS-резолвер (SmartDNS, AdGuard Home, Unbound и др.).

### Зачем это нужно

- **Снижение задержки** — DNS-запросы идут напрямую к локальному резолверу, минуя ndnproxy (~130ms → <80ms)
- **Прозрачная интеграция** — DNS-политики работают для всех LAN-клиентов без настройки на каждом устройстве
- **Целостность Keenetic** — ndnproxy продолжает работать для самого роутера, WebUI и диагностики не страдают

### Совместимость

Работает с любым локальным DNS-резолвером:

| Резолвер | Порт | Watchdog service |
|----------|------|-----------------|
| SmartDNS (smartdns-geo-conf) | 6053 | `S38smartdns` |
| AdGuard Home | 5353 | `S99adguardhome` |
| Unbound | 5335 | `S61unbound` |
| dnsmasq | любой | — |

---

## Требования

- Роутер Keenetic с Entware
- **KeeneticOS 5.0+**
- Локальный DNS-резолвер, слушающий на UDP/TCP порту

### Программные зависимости

**Из Entware-репозитория** (устанавливаются автоматически):

| Пакет | Назначение |
|-------|-----------|
| `iptables` | NAT PREROUTING DNAT правила |

**Из проекта keenetic-entware-extras** (устанавливаются вручную):

| Пакет | Назначение |
|-------|-----------|
| `keenetic-entware-extras` | Общие библиотеки проекта (обязательно) |

**Рекомендуется:**

| Пакет | Назначение |
|-------|-----------|
| `smartdns` | DNS-резолвер (или другой — AdGuard Home, Unbound) |

---

## Установка

### Шаг 1. Установить зависимости проекта

```sh
opkg install keenetic-entware-extras_<версия>_all.ipk
```

### Шаг 2. Убедиться, что DNS-резолвер работает

```sh
# Для SmartDNS:
dig ya.ru @127.0.0.1 -p 6053 +short
```

### Шаг 3. Установить пакет

```sh
opkg install smartdns-redirect_<версия>_all.ipk
```

После установки `postinst` автоматически:
- создаёт NDM-hook для восстановления правил при flush iptables
- добавляет cron-watchdog (каждые 5 минут)
- запускает сервис

Настройка по умолчанию работает «из коробки» с SmartDNS на порту `:6053`.

### Шаг 4. Проверить

```sh
/opt/etc/init.d/S39smartdns-redirect status
```

---

## Настройка

Файл конфигурации: `/opt/keenetic-entware-extras/smartdns-redirect/config/config.conf`

> 📝 `conffile` — ваши изменения сохраняются при `opkg upgrade`.

> 📝 Значения по умолчанию в `config/defaults.conf`. В `config.conf` указывайте только отличия.

### Параметры

| Параметр | По умолч. | Описание |
|----------|-----------|----------|
| `UPSTREAM_PORT` | `6053` | Порт локального DNS (SmartDNS=6053, AGH=5353, Unbound=5335) |
| `INTERFACES` | `"br0"` | LAN-интерфейсы для перехвата (через пробел) |
| `WATCHDOG_SERVICE` | `"S38smartdns"` | Init-скрипт для рестарта при падении upstream |

### Примеры конфигурации

**Для AdGuard Home:**
```sh
UPSTREAM_PORT=5353
WATCHDOG_SERVICE="S99adguardhome"
```

**Для Unbound:**
```sh
UPSTREAM_PORT=5335
WATCHDOG_SERVICE="S61unbound"
```

**Домашняя + гостевая сеть:**
```sh
INTERFACES="br0 br1"
```

**Отключить watchdog:**
```sh
WATCHDOG_SERVICE=""
```

### Применить изменения

```sh
/opt/etc/init.d/S39smartdns-redirect restart
```

---

## Использование

### Команды управления

```sh
/opt/etc/init.d/S39smartdns-redirect <команда>
```

| Команда | Описание |
|---------|----------|
| `start` | Добавить iptables DNAT правила |
| `stop` | Удалить iptables правила |
| `restart` | Переприменить правила |
| `status` | Подробная диагностика |
| `enable` | Включить автозапуск (создать symlink в `/opt/etc/init.d/`) |
| `disable` | Отключить автозапуск (удалить symlink); сервис не стартует при загрузке |

При `disable` symlink удаляется — сервис не стартует при загрузке, NDM-hook и watchdog также пропускают работу.

### Как это работает

Для всех настроенных интерфейсов используется `DNAT` на IP br0 — это гарантирует, что SmartDNS получит пакет независимо от входного интерфейса:

```
Client (10.0.0.42) → UDP :53 → br0/br1/nwg1
  → [iptables PREROUTING DNAT → 10.0.0.1:6053]
    → SmartDNS (10.0.0.1:6053) → upstream (DoT/DoH/UDP)
```

Роутер сам (loopback 127.0.0.1:53) ходит в ndnproxy — правила LAN-интерфейсов его не касаются.

### NDM-устойчивость

Keenetic периодически flush'ит iptables через свои netfilter hooks. Симлинк `/opt/etc/ndm/netfilter.d/smartdns-redirect-hook` вызывается при каждом flush — **правила восстанавливаются немедленно**.

### Watchdog

Cron каждые 5 минут запускает `watchdog.sh`:

1. Проверяет наличие DNAT-правил → если отсутствуют, восстанавливает
2. Шлёт тестовый DNS-запрос на `UPSTREAM_PORT` → если upstream не отвечает, рестартует `WATCHDOG_SERVICE`

### Совместимость с «Интернет-фильтрами» Keenetic

⚠️ **Ограничение:** «Интернет-фильтры» Keenetic (родительский контроль, DNS-профили устройств) работают через ndnproxy (:53). Поскольку smartdns-redirect перенаправляет DNS-запросы LAN-клиентов мимо ndnproxy — DNS-профили фильтрации **не применяются** к клиентам.

Если вы используете Internet filter с профилями для отдельных устройств — учитывайте это при установке.

> 📝 Параметр `PRESERVE_FILTER_PROFILES` зарезервирован для будущей реализации.

---

## Диагностика

### Проверка статуса

```sh
/opt/etc/init.d/S39smartdns-redirect status
```

Пример вывода:

```
smartdns-redirect status: ✓ Alive
  Mode:
    Config:      /opt/keenetic-entware-extras/smartdns-redirect/config/defaults.conf
    Upstream:    127.0.0.1:6053 (smartdns)
    Interfaces:  br0
    IPv6:        no

  Rules:
    v4   udp    br0 → 10.0.0.1:6053 ✓
    v4   tcp    br0 → 10.0.0.1:6053 ✓

  Upstream probe:
    UDP :6053: listening (192.168.1.1:6053 127.0.0.1:6053) ✓

  System:
    Uptime:      2d 5h ✓
    Init:        /opt/etc/init.d/S39smartdns-redirect ✓
    NDM hook:    /opt/etc/ndm/netfilter.d/smartdns-redirect-hook ✓
    Version:     0.3.7
```

### Проверка правил вручную

```sh
# Посмотреть NAT PREROUTING
iptables -t nat -S PREROUTING | grep DNAT

# Ожидаемый вывод (10.0.0.1 = IP вашего роутера):
# -A PREROUTING -i br0 -p udp -m udp --dport 53 -j DNAT --to-destination 10.0.0.1:6053
# -A PREROUTING -i br0 -p tcp -m tcp --dport 53 -j DNAT --to-destination 10.0.0.1:6053
```

### Тест DNS через redirect

С LAN-клиента (или с роутера через br0):
```sh
# Должен ответить SmartDNS (а не ndnproxy)
dig ya.ru @<IP-роутера> +short
```

### Частые проблемы

| Симптом | Причина | Решение |
|---------|---------|---------|
| Правила отсутствуют | NDM flush или ребут | Watchdog восстановит через ≤5 мин; или `restart` |
| Upstream not listening | DNS-резолвер не запущен | Запустить SmartDNS: `/opt/etc/init.d/S38smartdns start` |
| IPv6 DNS не перехватывается | SmartDNS не имеет IPv6 bind или нет IPv6 на br0 | Автоматический REJECT → Happy Eyeballs fallback на IPv4 |
| Клиенты не получают DNS | Неверный INTERFACES | Проверить имя LAN-интерфейса: `ip link show` |

### Логи

```sh
dmesg | grep smartdns-redirect
```

---

## Обновление

```sh
opkg upgrade smartdns-redirect
```

Конфигурация сохраняется при обновлении.

---

## Удаление

```sh
opkg remove smartdns-redirect
```

Автоматически: остановка, удаление iptables-правил, symlink, NDM-hook, cron-задачи, PID-файл.

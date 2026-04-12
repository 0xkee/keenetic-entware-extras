# SmartDNS Update Plan

**Created:** 2026-04-10
**Context:** Диагностика показала, что Keenetic ndnproxy (порт 53) тормозит DNS для LAN-клиентов (2-4s на новый домен). SmartDNS (порт 6053) работает быстро, но ndnproxy его игнорирует (DoT/DoH wrapping не совместим с plain UDP). Решение: iptables DNAT redirect LAN DNS → SmartDNS.

---

## Фаза 1: Критический фикс — DNS DNAT redirect ⭐

**Цель:** Перенаправить DNS-запросы LAN-клиентов напрямую в SmartDNS, минуя ndnproxy.
**Эффект:** DNS latency для новых доменов: 2-4s → 0.01-0.6s. Решает «Weak Internet» на Android 16.

### 1.1 Создать `scripts/dns-redirect.sh`

Скрипт для управления iptables DNAT правилами:

```
scripts/dns-redirect.sh start   — добавить DNAT правила (br0:53 → 10.0.0.1:6053)
scripts/dns-redirect.sh stop    — удалить DNAT правила
scripts/dns-redirect.sh status  — показать состояние правил
```

Правила:
```sh
iptables -t nat -I PREROUTING -i br0 -p udp --dport 53 -j DNAT --to ${ROUTER_IP}:${SMARTDNS_PORT}
iptables -t nat -I PREROUTING -i br0 -p tcp --dport 53 -j DNAT --to ${ROUTER_IP}:${SMARTDNS_PORT}
```

Конфигурируемые параметры (в скрипте или config-файле):
- `LAN_INTERFACES` — интерфейсы для DNAT (br0, br1)
- `SMARTDNS_PORT` — порт SmartDNS (6053)
- `ROUTER_IP` — IP роутера (10.0.0.1)

### 1.2 Создать init-скрипт `S39smartdns-redirect`

В `install.sh` генерировать `/opt/etc/init.d/S39smartdns-redirect`:
- S39 — после S38smartdns (SmartDNS уже запущен), до S60smartdns и S99geo-split
- `start` — вызывает `dns-redirect.sh start`
- `stop` — вызывает `dns-redirect.sh stop`

### 1.3 Обновить `install.sh`

- Добавить создание S39smartdns-redirect
- Проверять наличие iptables
- Запускать dns-redirect после старта SmartDNS

### 1.4 Обновить `uninstall.sh`

- Удалять DNAT правила (dns-redirect.sh stop)
- Удалять S39smartdns-redirect

### 1.5 Исследовать и учесть

- [ ] Проверить: как `ndm-hook.sh` (geo-split) взаимодействует с DNAT? При interface down/up DNAT правила могут сброситься?
- [ ] Проверить: Keenetic `netfilter.d` NDM hook — вызывается ли при изменении netfilter? Если да — добавить хук для восстановления DNAT
- [ ] Проверить: при ребуте Keenetic сбрасывает iptables nat? Init-скрипт S39 должен пересоздать правила
- [ ] Проверить: DNAT для br1 (гостевая сеть) — нужно ли?
- [ ] Проверить: iptables или nftables на Keenetic? (на router-1 iptables работает — подтверждено)

---

## Фаза 2: Оптимизация конфигурации SmartDNS для РФ+РКН

**Цель:** Оптимальный DNS для российских реалий — быстрый, безопасный, работающий с ТСПУ.

### 2.1 Аудит upstream DNS серверов

**Текущие:**
- Группа `ru`: Yandex DoT (77.88.8.8:853), AdGuard DoT (94.140.14.14:853), UDP fallback
- Группа `default`: Cloudflare DoT (1.1.1.1:853), Cloudflare DoH, Google UDP (8.8.8.8)

**Исследовать:**
- [ ] Блокирует ли ТСПУ на Beeline DoT к 1.1.1.1:853, 8.8.8.8:853? (измерить latency)
- [ ] Альтернативные зарубежные DNS: Mullvad (194.242.2.2), NextDNS, Quad9 (9.9.9.9:853 DoT)
- [ ] Альтернативные российские DNS: SberCloud (76.76.2.0), МТС DNS, Comss DNS (92.223.109.31)
- [ ] Yandex без фильтрации vs с фильтрацией (77.88.8.88 = safe, 77.88.8.7 = family)
- [ ] Проверить: `-k` флаг (skip TLS verify) — нужен ли? Или можно проверять сертификаты?

### 2.2 Оптимизация конфига SmartDNS

**Добавить:**

```conf
# Speed check — проверять latency resolved IPs, возвращать быстрейший
speed-check-mode ping,tcp:80,tcp:443

# Prefetch при половине TTL (а не при истечении)
prefetch-domain yes

# Ограничить число upstream для параллельных запросов (уменьшить нагрузку)
# SmartDNS по умолчанию отправляет ко всем — это может быть избыточно

# TCP keepalive для DoT (повторное использование TLS-соединений)
# SmartDNS делает это автоматически, но проверить в логах

# Audit log для отладки (включать временно)
# audit-enable yes
# audit-file /opt/var/log/smartdns-audit.log
# audit-size 128K
# audit-num 1

# EDNS Client Subnet (помогает CDN отдавать ближайший сервер)
# Исследовать: не выдаёт ли это реальный IP провайдеру?
# edns-client-subnet <ISP_SUBNET/24>
```

**Проверить/оптимизировать:**

- [ ] `cache-size 20000` — достаточно? Для домашней сети 10-20K норма
- [ ] `serve-expired-ttl 86400` (1 день) — ОК для стабильности
- [ ] `serve-expired-prefetch-time 86400` — слишком большое? Лучше 21600 (6ч)
- [ ] Добавить `max-query-limit 65536` — лимит одновременных запросов
- [ ] Добавить `log-size 128K` и `log-num 2` — ротация логов

### 2.3 Расширить доменные правила для группы `ru`

**Текущие:**
- `.ru`, `.рф` (.xn--p1ai), `.su`
- Явные: gov.ru, nalog.ru, mosenergosbyt.ru, gosuslugi.ru

**Добавить (РКН-значимые):**
```conf
# Банки и финансы (нужны российские IP для работы)
nameserver /sberbank.ru/ru
nameserver /vtb.ru/ru
nameserver /tinkoff.ru/ru
nameserver /cbr.ru/ru

# Маркетплейсы
nameserver /wildberries.ru/ru
nameserver /ozon.ru/ru
nameserver /yandex.ru/ru

# Мессенджеры (российские, для получения правильных IP)
nameserver /vk.com/ru
nameserver /ok.ru/ru
nameserver /mail.ru/ru

# Стриминг
nameserver /kinopoisk.ru/ru
nameserver /ivi.ru/ru

# Государственные (не .ru домены)
nameserver /mos.ru/ru
```

**Исследовать:**
- [ ] Загрузка доменных списков из файла: `domain-set -name ru_domains -file /opt/etc/smartdns/ru-domains.txt` + `nameserver /domain-set:ru_domains/ru` — вместо длинного списка в конфиге
- [ ] Есть ли готовые списки ru-доменов для SmartDNS?

### 2.4 Интеграция SmartDNS ↔ geo-split ipset

**Текущее:** geo-split `update-domains.sh` резолвит домены через `dig @localhost` → добавляет IP в ipset.

**Возможность SmartDNS:** SmartDNS умеет добавлять resolved IP напрямую в ipset!

```conf
# Добавлять resolved IP из группы ru в ipset geo-split
ipset /ru/geo-split
# Или для конкретных доменов:
# ipset /gosuslugi.ru/geo-split
```

- [ ] Исследовать: заменит ли это `update-domains.sh` полностью?
- [ ] Исследовать: `ipset` vs `nftset` directive в SmartDNS
- [ ] Исследовать: как это взаимодействует с geo-split ipset (атомарный swap)?

---

## Фаза 3: Структурные обновления проекта

### 3.1 Новые файлы

```
smartdns/
├── config/
│   ├── smartdns.conf          # обновлённый конфиг (Фаза 2)
│   └── ru-domains.txt         # (опционально) доменный список для группы ru
├── scripts/
│   ├── install.sh             # обновлённый (+ DNAT redirect)
│   ├── uninstall.sh           # обновлённый (+ cleanup DNAT)
│   ├── dns-redirect.sh        # НОВЫЙ: управление iptables DNAT
│   └── status.sh              # НОВЫЙ: диагностика DNS (как geo-split/status.sh)
├── .project/
│   ├── target-arch.md         # обновить (DNAT redirect, интеграция с geo-split)
│   └── target-code.md         # без изменений
└── README.md                  # обновить
```

### 3.2 `scripts/status.sh` — диагностика DNS

Показывать:
- SmartDNS процесс (PID, uptime)
- Порт 6053 — listening?
- iptables DNAT правила — активны?
- DNS-тест: resolve через :53 и :6053, сравнить скорость
- AAAA-тест: быстрый SOA через SmartDNS?
- Cache stats: размер, hit rate
- Upstream connectivity: DoT/DoH availability

### 3.3 Обновить lib/common.sh (если нужно)

target-code.md запрещает использовать lib/common.sh в smartdns (POSIX sh only).
Но dns-redirect.sh может использовать свои инлайн-хелперы (как install.sh).

### 3.4 Обновить README.md

- Добавить секцию "DNS DNAT Redirect"
- Объяснить, почему ndnproxy не работает с SmartDNS
- Обновить диаграмму архитектуры

### 3.5 Обновить target-arch.md

- Добавить DNAT redirect в архитектуру
- Обновить integration flow

---

## Фаза 4: Тестирование и деплой

### 4.1 Тесты на router-1

- [ ] Деплой обновлённых файлов (tar-ssh)
- [ ] Запустить install.sh
- [ ] Проверить: iptables DNAT правила активны
- [ ] Проверить: DNS через :53 теперь быстрый (SmartDNS)
- [ ] Проверить: AAAA → instant SOA
- [ ] Проверить: Android connectivity check < 1s
- [ ] Проверить: .ru домены резолвятся через Yandex/AdGuard
- [ ] Проверить: зарубежные домены резолвятся через Cloudflare
- [ ] Проверить: после ребута всё восстанавливается

### 4.2 Тесты на router-2

- [ ] Повторить те же тесты на втором роутере

---

## Приоритеты

| Фаза | Приоритет | Объём | Описание |
|------|-----------|-------|----------|
| **1** | 🔴 Critical | ~2ч | DNS DNAT redirect (решает «Weak Internet») |
| **2** | 🟡 High | ~3ч | Оптимизация конфига + исследование |
| **3** | 🟢 Normal | ~2ч | Структурные обновления (status.sh, docs) |
| **4** | 🟡 High | ~1ч | Тестирование на роутерах |

**Итого: ~8 часов работы**

---

## Связанные проекты

- **geo-split** — зависит от SmartDNS для `dig @localhost` в `update-domains.sh`
- **Keenetic NDM** — DNAT обходит ndnproxy; NDM hooks могут сбрасывать iptables

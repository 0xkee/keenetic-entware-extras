# DNS-ландшафт в России и SmartDNS Best Practices

**Version:** v1.0  
**Created:** 2026-04-16  
**Status:** ✅ Final  
**Scope:** Исследование DNS-блокировок в РФ, обзор DNS-серверов, SmartDNS best practices, рекомендации для smartdns-conf-ru-split  
**Источники:** Yandex DNS (dns.yandex.ru), SmartDNS docs (pymumu.github.io/smartdns), OONI reports, ntc.party community data, профильные Habr-статьи, собственный опыт

---

## 1. DNS-блокировки в России (2024–2026)

### 1.1 Общая картина

Россия применяет многоуровневую систему контроля DNS-трафика через **ТСПУ** (Технические средства противодействия угрозам) — оборудование DPI, установленное на узлах провайдеров по требованию Роскомнадзора.

| Уровень | Метод | Статус (2025–2026) |
|---------|-------|--------------------|
| Plain DNS (UDP/53) | DPI-перехват запросов, DNS-спуфинг | ✅ Активно применяется |
| DoT (TCP/853) | Блокировка порта 853 к зарубежным IP | ⚠️ Частично (зависит от ISP/региона) |
| DoH (HTTPS/443) | SNI-фильтрация, блокировка по IP | ⚠️ Частично, сложнее блокировать |
| DoQ (QUIC/853) | Блокировка QUIC к DNS-IP | ⚠️ Растёт |
| DNS-over-HTTPS (ECH) | Пока не фильтруется | ✅ Работает (пока) |

### 1.2 Что именно блокируется ТСПУ

#### Plain DNS (порт 53) — да, подменяют!

- **DNS-спуфинг через DPI**: ТСПУ **активно подменяет** plain DNS ответы. Механизм: ТСПУ стоит «посередине» между роутером и upstream DNS. Когда видит DNS-запрос к заблокированному домену — **инжектирует свой ответ раньше настоящего сервера** (race condition, ТСПУ ближе физически). Настоящий ответ от Google/Cloudflare тоже приходит, но клиент уже принял поддельный.
- **Что именно подменяется**: Только ответы для доменов из реестра РКН (~800K+ записей). Для остальных доменов — ответ проходит без изменений.
- **Как выглядит подмена**: Вместо реального IP возвращается IP-заглушка РКН (например, `10.50.x.x` или редирект на страницу блокировки провайдера). Некоторые ISP возвращают NXDOMAIN.
- **Не блокируется полностью**: Plain DNS на 53 порту к Google 8.8.8.8 / Cloudflare 1.1.1.1 **работает**, но ответы **подменяются для доменов из реестра РКН**.
- **Для нашего сценария (split DNS)**: Это **не проблема по двум причинам**:
  1. Российские домены (.ru, .рф) → идут через Yandex (в РФ), ТСПУ не вмешивается в трафик к российским DNS
  2. Зарубежные домены (.com, .net и т.д.) → идут через Google/Cloudflare по UDP, но домены типа google.com, youtube.com, github.com **не в реестре РКН** → ТСПУ их не подменяет
- **Риск**: Если пользователь обращается к зарубежному домену, который **есть в реестре РКН** (например, заблокированный .com сайт) через foreign-группу по plain UDP — получит подменённый ответ.
- **Решение**: Маршрутизация DNS-трафика через VPN-интерфейс (см. раздел 4.7).

#### DoT (порт 853)

- **Порт 853 к зарубежным IP**: Блокируется на части ISP через ТСПУ. Cloudflare 1.1.1.1:853 и Google 8.8.8.8:853 — могут быть недоступны или нестабильны.
- **Порт 853 к российским IP**: Yandex 77.88.8.8:853, AdGuard 94.140.14.14:853 — **работают стабильно** (не блокируются).
- **Рекомендация**: DoT к зарубежным серверам **ненадёжен**. Как основной транспорт — рискованно.

#### DoH (HTTPS, порт 443)

- **По IP**: Cloudflare DNS IP (1.1.1.1, 1.0.0.1) **не блокируются** полностью (они же CDN), но DoH-эндпоинт может быть замедлен.
- **По SNI**: ТСПУ может фильтровать TLS ClientHello с SNI `cloudflare-dns.com` или `dns.google`. На практике — применяется не везде.
- **Более устойчив** чем DoT, т.к. использует стандартный HTTPS-порт 443 и сложнее отличить от обычного веб-трафика.

#### Конкретные серверы — доступность из РФ

| Сервер | IP | Plain (53) | DoT (853) | DoH (443) | Примечания |
|--------|-----|------------|-----------|-----------|------------|
| **Cloudflare** | 1.1.1.1 / 1.0.0.1 | ✅ (спуфинг возможен) | ⚠️ Частично | ⚠️ Частично | Anycast, иногда замедляется |
| **Google** | 8.8.8.8 / 8.8.4.4 | ✅ (спуфинг возможен) | ⚠️ Частично | ⚠️ Частично | Стабильнее Cloudflare |
| **Quad9** | 9.9.9.9 | ⚠️ Замедляется | ⚠️ Частично | ⚠️ Частично | Менее популярен в РФ |
| **Yandex** | 77.88.8.8 / 77.88.8.1 | ✅ | ✅ | ✅ | Полностью доступен |
| **AdGuard** | 94.140.14.14 | ✅ | ✅ | ✅ | Серверы в РФ |
| **SberDNS** | 76.76.2.0 / 76.76.10.0 | ✅ | ✅ | ✅ | Новый, серверы в РФ |

### 1.3 Риски для нашего сценария

| Риск | Вероятность | Влияние | Митигация |
|------|------------|---------|-----------|
| Блокировка DoT:853 к Cloudflare | Средняя | Зарубежные домены не резолвятся | UDP fallback + DoH |
| DNS-спуфинг plain DNS | Низкая (для зарубежных доменов) | Подмена для доменов из реестра РКН | Не релевантно: .com/.net не в реестре |
| Полная блокировка 1.1.1.1 | Очень низкая | Нет доступа к Cloudflare DNS | Google 8.8.8.8 как fallback |
| Блокировка Yandex DoT | Крайне низкая | — | — (российский сервер, не блокируется) |

### 1.4 Выводы по блокировкам

1. **Для ru-группы** (Yandex, AdGuard): блокировки **не касаются** — всё работает стабильно, включая DoT/DoH.
2. **Для foreign-группы**: DoT на порту 853 — **ненадёжен**. DoH — **более устойчив**, но тоже не гарантирован. Plain UDP — **работает**, но подвержен спуфингу (не критично для нашего сценария).
3. **Оптимальная стратегия для foreign**: Plain UDP как основной + DoH как дополнительный. Или только Plain UDP (если приватность DNS-запросов к зарубежным доменам не приоритет).

---

## 2. Актуальные российские DNS-серверы

### 2.1 Yandex DNS

**Три режима:**

| Режим | IPv4 Primary | IPv4 Secondary | DoT hostname | Фильтрация |
|-------|-------------|----------------|-------------|-------------|
| **Базовый** | 77.88.8.8 | 77.88.8.1 | `common.dot.dns.yandex.net` | Нет |
| **Безопасный** | 77.88.8.88 | 77.88.8.2 | `safe.dot.dns.yandex.net` | Вирусы, фишинг |
| **Семейный** | 77.88.8.7 | 77.88.8.3 | `family.dot.dns.yandex.net` | + порно, 18+ |

**Для split DNS рекомендуется: Базовый (77.88.8.8 / 77.88.8.1)**

Причины:
- Без фильтрации — не блокирует легитимные .ru сайты
- Самый быстрый отклик (нет дополнительной проверки по базам)
- 100+ серверов по России, anycast — отличная latency
- Поддерживает DoT и DoH

> ⚠️ **Важно:** Yandex обновил DoT hostnames! Старое имя `dns.yandex.ru` — **deprecated**. Актуальное: `common.dot.dns.yandex.net`. Наш текущий конфиг использует старое имя — **требуется обновление**.

### 2.2 AdGuard DNS

| Вариант | IPv4 Primary | IPv4 Secondary | DoT hostname | Фильтрация |
|---------|-------------|----------------|-------------|-------------|
| **Default** | 94.140.14.14 | 94.140.15.15 | `dns.adguard-dns.com` | Реклама, трекеры |
| **Non-filtering** | 94.140.14.140 | 94.140.14.141 | `unfiltered.adguard-dns.com` | Нет |
| **Family** | 94.140.14.15 | 94.140.15.16 | `family.adguard-dns.com` | + 18+ |

**Для split DNS: Non-filtering (94.140.14.140 / 94.140.14.141)**

Причины:
- Без фильтрации — чистый резолвинг
- Серверы в РФ и Европе — быстрый отклик
- Надёжный DoT/DoH

> ⚠️ **Важно:** Наш текущий конфиг использует **94.140.14.14** (Default) и **94.140.14.15** (Family) с hostname `dns-unfiltered.adguard.com`. Это **несоответствие**: IP от Default/Family, hostname от Unfiltered. Нужно исправить: либо IP от unfiltered (94.140.14.140/141), либо hostname от default (dns.adguard-dns.com).

### 2.3 Другие российские DNS

| Сервер | IPv4 | DoT/DoH | Плюсы | Минусы | Рекомендация |
|--------|------|---------|-------|--------|-------------|
| **SberDNS** | 76.76.2.0, 76.76.10.0 | ✅ DoT/DoH | Серверы в РФ, быстрый | Новый, мало данных о надёжности | ⚠️ Мониторить |
| **РТК DNS** | Назначаются провайдером | Нет | Быстрый для клиентов РТК | Привязан к ISP, нет DoT | ❌ Не подходит |
| **Comss DNS** | 93.115.24.81 | ✅ DoT | Без цензуры | Один сервер, ненадёжно | ❌ Не подходит |
| **NGENIX** | Не публичный | — | — | Корпоративный | ❌ Не подходит |

### 2.4 Сравнительная таблица для ru-группы

| Критерий | Yandex (базовый) | AdGuard (unfiltered) | SberDNS |
|----------|-----------------|---------------------|---------|
| Скорость в РФ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ |
| Надёжность | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐ |
| DoT/DoH | ✅ | ✅ | ✅ |
| Без фильтрации | ✅ (базовый) | ✅ (unfiltered) | ❓ |
| Anycast в РФ | ✅ 100+ серверов | ✅ | ✅ |
| Зрелость | 10+ лет | 5+ лет | 2+ года |
| **Итого** | **🥇 Первый выбор** | **🥈 Второй** | **🥉 Резерв** |

---

## 3. SmartDNS Best Practices (2025–2026)

### 3.1 Кэш

| Параметр | Рекомендация | Обоснование |
|----------|-------------|-------------|
| `cache-size` | **10000–30000** | Для домашней сети 10K хватает с запасом. 20K — хороший баланс. На роутере с 256MB RAM можно 30K |
| `cache-persist` | **yes** | Сохраняет кэш между перезагрузками. Быстрый cold start |
| `cache-file` | `/opt/var/cache/smartdns.cache` | Entware-путь. Не на tmpfs — выживет перезагрузку |
| `serve-expired` | **yes** | Отдаёт устаревшие записи пока идёт перезапрос. Критично для uptime |
| `serve-expired-ttl` | **259200** (3 дня) | Максимум сколько держать expired. 3 дня — разумно для домашнего роутера |
| `serve-expired-prefetch-time` | **21600** (6 часов) | За 6 часов до expiry — prefetch. Текущие 86400 (24 ч) слишком рано |
| `prefetch-domain` | **yes** | Проактивный prefetch популярных доменов. Снижает latency |
| `rr-ttl-min` | **60** | Минимальный TTL 60 сек. Защита от слишком агрессивного кэширования CDN (TTL=5) |
| `rr-ttl-max` | **86400** (1 день) | Ограничиваем сверху. Некоторые домены ставят TTL неделю — это слишком |

**Текущий конфиг vs рекомендация:**

| Параметр | Текущее | Рекомендуемое | Изменение |
|----------|---------|---------------|-----------|
| cache-size | 20000 | 20000 | ✅ Ок |
| cache-persist | (default) | yes | ➕ Добавить |
| cache-file | (default) | /opt/var/cache/smartdns.cache | ➕ Добавить |
| serve-expired | yes | yes | ✅ Ок |
| serve-expired-ttl | 86400 | 259200 | 🔄 Увеличить |
| serve-expired-prefetch-time | 86400 | 21600 | 🔄 Уменьшить |
| prefetch-domain | yes | yes | ✅ Ок |
| rr-ttl-min | (none) | 60 | ➕ Добавить |
| rr-ttl-max | (none) | 86400 | ➕ Добавить |

### 3.2 Speed Check Mode

SmartDNS проверяет скорость IP-адресов из DNS-ответов и возвращает клиенту самый быстрый.

| Режим | Описание | Когда использовать |
|-------|----------|--------------------|
| `ping` | ICMP ping | Общий случай; быстрый, но не все хосты отвечают на ICMP |
| `tcp:80` | TCP connect к порту 80 | Веб-сайты; почти все отвечают |
| `tcp:443` | TCP connect к порту 443 | HTTPS-сайты |
| `ping,tcp:80,tcp:443` | Комбинация (default) | **Рекомендуется** — пробует все, берёт самый быстрый ответ |
| `none` | Отключить | Когда нужны ВСЕ IP (geo-split порт 6153) |

**Рекомендации для наших портов:**

| Порт | Назначение | speed-check-mode |
|------|-----------|-----------------|
| `:6053` (main) | DNS для клиентов | `ping,tcp:80,tcp:443` (по умолчанию, можно явно указать) |
| `:6153` (geo-split) | Все IP для update-domains.sh | `-no-speed-check` (уже настроено ✅) |

### 3.3 Response Mode

| Режим | Описание | Рекомендация |
|-------|----------|-------------|
| `first-ping` (default) | DNS-задержка + ping-задержка | ✅ **Рекомендуется для main** — лучший баланс скорости и точности |
| `fastest-ip` | Самый быстрый IP | Может задерживать ответ, ждёт пока все upstream ответят |
| `fastest-response` | Первый ответивший DNS | Быстро, но может вернуть не оптимальный IP |

**Рекомендация:** `first-ping` (default) — оставить. Для домашнего роутера это оптимально.

### 3.4 Dual-Stack (IPv4/IPv6)

| Параметр | Рекомендация | Обоснование |
|----------|-------------|-------------|
| `force-AAAA-SOA` | **yes** (если нет IPv6) | Текущая настройка ✅. Если ISP не поддерживает IPv6 — нет смысла резолвить AAAA |
| `dualstack-ip-selection` | **yes** (default) | Если IPv6 есть — SmartDNS выберет быстрый стек |
| `dualstack-ip-selection-threshold` | **10** (default) | Допустимая разница в мс. Если IPv6 > IPv4+10ms, берём IPv4 |
| `force-HTTPS-SOA` | **yes** | Блокирует HTTPS DNS-записи (тип 65). Для роутера они не нужны, экономит трафик |

### 3.5 EDNS Client Subnet (ECS)

ECS передаёт upstream-серверу подсеть клиента для более точной геолокации ответов.

| Аспект | Для ru-группы | Для foreign-группы |
|--------|--------------|-------------------|
| Нужен ли ECS? | **Нет** — Yandex и так определяет по IP роутера, клиенты в одной сети | **Нет** — для домашнего роутера одна точка выхода |
| `edns-client-subnet` | Не указывать | Не указывать |

**Вывод:** ECS для домашнего роутера **не нужен**. SmartDNS по умолчанию не отправляет ECS — это правильно.

### 3.6 TLS vs Plain DNS — выбор транспорта

| Группа | Transport | Обоснование |
|--------|-----------|-------------|
| **ru (Yandex)** | **DoT** (основной) + **UDP** (fallback) | DoT к Yandex стабилен в РФ. UDP как резерв при проблемах с TLS |
| **foreign (Cloudflare/Google)** | **UDP** (основной) + **DoH** (дополнительный) | DoT:853 блокируется. DoH через 443 — дополнительная опция. UDP — самый надёжный |

**Почему НЕ DoT для foreign-группы:**
1. Порт 853 к зарубежным IP — целевой порт для ТСПУ
2. Добавляет latency (TLS handshake) без гарантии работоспособности
3. Для нашего сценария приватность DNS-запросов к .com/.net — не приоритет (ISP всё равно видит SNI при HTTPS-соединении)

**Почему DoT для ru-группы ОК:**
1. Yandex серверы в РФ — DoT не блокируется
2. Latency минимальна (серверы рядом)
3. Защита от спуфинга на пути до Yandex

### 3.7 Флаг `-k` (skip TLS verify)

Текущий конфиг использует `-k` на всех TLS-серверах. Это **небезопасно** — отключает проверку сертификата.

**Рекомендация:** Убрать `-k` и оставить `-tls-host-verify`:

```
# Правильно:
server-tls 77.88.8.8:853 -group ru -exclude-default-group \
    -host-name common.dot.dns.yandex.net \
    -tls-host-verify common.dot.dns.yandex.net

# Неправильно (текущее):
server-tls 77.88.8.8:853 -group ru -exclude-default-group \
    -host-name dns.yandex.ru \
    -tls-host-verify dns.yandex.ru \
    -k
```

> ⚠️ Перед удалением `-k` нужно убедиться, что CA-сертификаты установлены на роутере: `opkg install ca-certificates`. Без них TLS verify будет падать.

### 3.8 Ротация логов

| Параметр | Рекомендация | Обоснование |
|----------|-------------|-------------|
| `log-level` | **error** | Текущее ✅. Минимум логов для production |
| `log-file` | `/opt/var/log/smartdns.log` | Явный путь. По умолчанию может писать в /var/log (tmpfs) |
| `log-size` | **128K** | Ограничение размера файла лога |
| `log-num` | **2** | Хранить 2 ротированных файла |

### 3.9 Другие важные опции

| Параметр | Рекомендация | Обоснование |
|----------|-------------|-------------|
| `force-qtype-SOA 65` | **yes** | Блокирует HTTPS/SVCB записи (тип 65). Экономит ресурсы |
| `max-reply-ip-num 16` | ✅ Оставить | Нужно для geo-split |
| `restart-on-crash yes` | ➕ Добавить | Автоматический рестарт при падении |
| `tcp-idle-time 120` | ✅ Default OK | — |
| `server-name smartdns` | ➕ Добавить | Идентификация сервера |
| `bind ... -force-https-soa` | ➕ Рассмотреть | На bind :6053 — блокирует HTTPS records |

---

## 4. Рекомендации для проекта smartdns-conf-ru-split

### 4.1 Upstream серверы для ru-группы

**Рекомендованная конфигурация:**

```conf
# Yandex DoT (primary) — обновлённый hostname!
server-tls 77.88.8.8:853 -group ru -exclude-default-group \
    -host-name common.dot.dns.yandex.net \
    -tls-host-verify common.dot.dns.yandex.net

server-tls 77.88.8.1:853 -group ru -exclude-default-group \
    -host-name common.dot.dns.yandex.net \
    -tls-host-verify common.dot.dns.yandex.net

# AdGuard Non-filtering DoT (secondary) — исправленные IP!
server-tls 94.140.14.140:853 -group ru -exclude-default-group \
    -host-name unfiltered.adguard-dns.com \
    -tls-host-verify unfiltered.adguard-dns.com

server-tls 94.140.14.141:853 -group ru -exclude-default-group \
    -host-name unfiltered.adguard-dns.com \
    -tls-host-verify unfiltered.adguard-dns.com

# UDP fallback (plain DNS, для надёжности)
server 77.88.8.8 -group ru -exclude-default-group
server 77.88.8.1 -group ru -exclude-default-group
```

**Изменения vs текущий конфиг:**

| Что | Было | Стало | Причина |
|-----|------|-------|---------|
| Yandex TLS hostname | `dns.yandex.ru` | `common.dot.dns.yandex.net` | Yandex обновил hostname |
| AdGuard IP | 94.140.14.14 / 94.140.14.15 | 94.140.14.140 / 94.140.14.141 | Были default+family, нужен unfiltered |
| AdGuard hostname | `dns-unfiltered.adguard.com` | `unfiltered.adguard-dns.com` | Актуальный hostname |
| Флаг `-k` | Присутствует | **Убран** | Верификация TLS обязательна |
| UDP fallback AdGuard | 94.140.14.14 / 94.140.14.15 | **Убран** | Достаточно Yandex UDP; меньше серверов = быстрее |

### 4.2 Upstream серверы для foreign-группы (default)

**Рекомендованная конфигурация:**

```conf
# Google UDP (primary — самый надёжный в РФ)
server 8.8.8.8
server 8.8.4.4

# Cloudflare UDP (secondary)
server 1.1.1.1
server 1.0.0.1

# Cloudflare DoH (дополнительный — может пробиться через DPI)
server-https https://cloudflare-dns.com/dns-query \
    -host-name cloudflare-dns.com \
    -http-host cloudflare-dns.com \
    -tls-host-verify cloudflare-dns.com
```

**Изменения vs текущий конфиг:**

| Что | Было | Стало | Причина |
|-----|------|-------|---------|
| Cloudflare DoT | ✅ Присутствует | **Убран** | Порт 853 блокируется ТСПУ |
| Google UDP | ✅ Присутствует | ✅ Оставлен | Самый надёжный |
| Cloudflare UDP | ❌ Отсутствовал | ➕ Добавлен | Дополнительный надёжный upstream |
| Cloudflare DoH | ✅ Присутствует | ✅ Оставлен (без `-k`) | Через HTTPS более устойчив |
| `-bootstrap-dns` | 1.1.1.1 | Убрать (не нужен если hostname уже резолвится через UDP) | Упрощение |
| Флаг `-k` | Присутствует | **Убран** | Нужна верификация |

### 4.3 Зоны маршрутизации (nameserver rules)

**Текущие зоны:** `.ru`, `.рф` (xn--p1ai), `.su`

**Рекомендация: добавить дополнительные зоны**

```conf
# Основные российские TLD
nameserver /.ru/ru
nameserver /.xn--p1ai/ru         # .рф
nameserver /.su/ru

# Российские домены в gTLD (популярные сервисы с CDN в РФ)
nameserver /yandex.net/ru         # Yandex CDN
nameserver /yandex.com/ru         # Yandex international
nameserver /mail.ru/ru            # Mail.ru (хотя .ru и так покрыт)
nameserver /vk.com/ru             # VK
nameserver /ok.ru/ru              # Одноклассники (покрыт .ru)
nameserver /sberbank.com/ru       # Сбер
nameserver /tinkoff.com/ru        # Тинькофф
nameserver /wildberries.ru/ru     # WB (покрыт .ru)
nameserver /ozon.ru/ru            # Ozon (покрыт .ru)
```

> **Примечание:** Домены в `.ru` уже покрыты правилом `/.ru/ru`. Добавлять `yandex.com`, `vk.com`, `sberbank.com`, `tinkoff.com` имеет смысл — они используют `.com` TLD, но CDN в РФ. Резолв через российский DNS даст IP ближайшего CDN-узла.

**Убрать избыточные:**

```conf
# Эти строки можно удалить — покрыты /.ru/ru:
# nameserver /gov.ru/ru
# nameserver /nalog.ru/ru
# nameserver /mosenergosbyt.ru/ru
# nameserver /gosuslugi.ru/ru
```

### 4.4 Bootstrap DNS

**Нужен ли?** — **Нет**, при текущей конфигурации.

Причины:
- Все upstream серверы указаны по IP, а не по hostname
- DoH к Cloudflare использует `cloudflare-dns.com` — этот hostname нужно резолвить, но SmartDNS резолвит его через UDP-серверы (Google/Cloudflare) из default-группы
- Если убираем DoH или указываем `-host-ip` для DoH — bootstrap вообще не нужен

**Если DoH остаётся:** Можно указать `-host-ip` напрямую:

```conf
server-https https://cloudflare-dns.com/dns-query \
    -host-name cloudflare-dns.com \
    -http-host cloudflare-dns.com \
    -host-ip 1.1.1.1 \
    -tls-host-verify cloudflare-dns.com
```

### 4.5 Fallback при недоступности upstream

SmartDNS имеет встроенный механизм `-fallback`:

```conf
# Пометить сервер как fallback — используется только если основные не отвечают
server 77.88.8.8 -group ru -exclude-default-group -fallback
```

**Рекомендация:** Не нужен отдельный fallback, т.к.:
1. В каждой группе уже 4+ серверов (Yandex + AdGuard для ru; Google + Cloudflare для foreign)
2. SmartDNS параллельно запрашивает все серверы в группе
3. `serve-expired` отдаёт кэшированные ответы при полной недоступности upstream

Единственный сценарий когда fallback нужен — если разделение по группам перестаёт работать (баг SmartDNS). В этом случае SmartDNS использует default-группу для всех запросов — это приемлемый fallback.

### 4.6 domain-set vs nameserver rules

Для масштабирования списка RU-доменов SmartDNS поддерживает `domain-set`:

```conf
# Вместо множества nameserver правил:
domain-set -name ru-domains -type list -file /opt/etc/smartdns/ru-domains.txt

nameserver /domain-set:ru-domains/ru
```

Файл `ru-domains.txt`:
```
ru
xn--p1ai
su
yandex.com
vk.com
sberbank.com
tinkoff.com
```

**Рекомендация:** Пока не нужен. У нас ~10 правил — inline nameserver проще и прозрачнее. domain-set стоит использовать при 50+ доменов.

### 4.7 DNS через VPN-интерфейс (обход ТСПУ-спуфинга)

#### Проблема

ТСПУ подменяет plain DNS ответы для доменов из реестра РКН. Если пользователь обращается к заблокированному `.com` домену через foreign-группу по UDP — ТСПУ инжектирует поддельный ответ раньше настоящего.

DoT/DoH к зарубежным серверам тоже не всегда спасает — ТСПУ может блокировать порт 853 и фильтровать HTTPS по SNI.

#### Решение: `-interface` в SmartDNS

SmartDNS поддерживает параметр **`-interface`** на upstream серверах. Он привязывает DNS-сокет к конкретному сетевому интерфейсу. Если указать VPN-интерфейс (WireGuard `nwg0`, OpenVPN `ovpn_br0` и т.д.) — DNS-запросы **пойдут через VPN-туннель**, минуя ТСПУ провайдера.

```conf
# Foreign DNS через VPN-интерфейс — обход ТСПУ
server 8.8.8.8 -interface nwg0
server 8.8.4.4 -interface nwg0
server 1.1.1.1 -interface nwg0
server 1.0.0.1 -interface nwg0
```

#### Как это работает

```
Обычный путь (без -interface):
  SmartDNS → [ISP network + ТСПУ] → 8.8.8.8
  ← ТСПУ инжектирует поддельный ответ для РКН-доменов

Через VPN (-interface nwg0):
  SmartDNS → [WireGuard tunnel nwg0] → VPN-сервер → 8.8.8.8
  ← Ответ приходит через VPN, ТСПУ не видит DNS-трафик
```

#### Преимущества

| Аспект | Описание |
|--------|----------|
| **Полная защита от спуфинга** | ТСПУ не видит DNS-трафик внутри VPN |
| **Plain UDP достаточно** | Не нужен DoT/DoH — VPN уже шифрует |
| **Минимальная latency** | UDP к Google/Cloudflare через VPN — быстрее чем DoT/DoH |
| **Устойчивость** | Даже если ТСПУ блокирует 853/DoH — VPN-туннель не затронут |
| **Совместимость с geo-split** | VPN уже настроен для geo-split, инфраструктура есть |

#### Ограничения и нюансы

| Нюанс | Описание | Решение |
|-------|----------|---------|
| **VPN должен быть UP** | Если VPN не поднят — DNS-запросы не уйдут | UDP fallback без `-interface` |
| **fwmark конфликт?** | `-interface` использует `SO_BINDTODEVICE`, **не fwmark** — безопасно для Keenetic | ✅ Нет конфликта с NDM |
| **Latency через VPN** | Добавляет hop через VPN-сервер | < 50ms обычно, приемлемо |
| **Не для ru-группы** | RU DNS (Yandex) должны идти напрямую — им VPN не нужен | `-interface` только на foreign |

#### Рекомендованная конфигурация с VPN

```conf
# ===========================================================================
# 🌍 International DNS — через VPN (обход ТСПУ)
# ===========================================================================

# Google UDP через VPN (primary)
server 8.8.8.8 -interface nwg0
server 8.8.4.4 -interface nwg0

# Cloudflare UDP через VPN (secondary)
server 1.1.1.1 -interface nwg0
server 1.0.0.1 -interface nwg0

# Fallback БЕЗ VPN — на случай если VPN не поднят
# SmartDNS попробует все серверы; если VPN down — эти ответят
server 8.8.8.8 -fallback
server 8.8.4.4 -fallback
```

> ⚠️ **Имя VPN-интерфейса** (`nwg0`) — зависит от конкретной настройки роутера. Для WireGuard на Keenetic это обычно `nwg0`, `nwg1` и т.д. Для OpenVPN — `ovpn_br0`. Это значение должно быть конфигурируемым.

#### Пример: несколько VPN-туннелей

Если на роутере настроено несколько VPN (например, WireGuard `nwg0` + OpenVPN `ovpn_br0`), серверы можно распределить по разным туннелям для redundancy:

```conf
# Google через WireGuard
server 8.8.8.8 -interface nwg0
server 8.8.4.4 -interface nwg0

# Cloudflare через OpenVPN (второй VPN)
server 1.1.1.1 -interface ovpn_br0
server 1.0.0.1 -interface ovpn_br0

# Fallback без VPN — если все VPN down
server 8.8.8.8 -fallback
server 8.8.4.4 -fallback
```

Так если один VPN падает — DNS-запросы уходят через второй. SmartDNS параллельно опрашивает все серверы в группе, fallback срабатывает только если основные не ответили.

Ещё вариант — **все серверы через один VPN**, но с fallback через второй:

```conf
# Primary: всё через nwg0
server 8.8.8.8 -interface nwg0
server 8.8.4.4 -interface nwg0
server 1.1.1.1 -interface nwg0
server 1.0.0.1 -interface nwg0

# Fallback: через ovpn_br0 (если WireGuard down)
server 8.8.8.8 -interface ovpn_br0 -fallback
server 8.8.4.4 -interface ovpn_br0 -fallback

# Last resort: напрямую без VPN
server 8.8.8.8 -fallback
```

#### Когда НЕ нужна маршрутизация через VPN

- Если VPN не настроен на роутере — `-interface` не имеет смысла
- Если не нужен доступ к заблокированным `.com` доменам — plain UDP достаточно
- Если ISP не применяет DNS-спуфинг (есть такие, но редко)

#### Итог: два режима работы

| Режим | Foreign DNS | Защита от спуфинга | VPN нужен? |
|-------|------------|-------------------|-----------|
| **Базовый** | UDP напрямую | ❌ Нет (только для non-RKN доменов ОК) | Нет |
| **VPN-protected** | UDP через VPN `-interface` | ✅ Полная | Да |

**Рекомендация:** Сделать конфигурируемым. В Phase 3 заложить оба варианта: базовый конфиг (без VPN) + опциональный include-файл для VPN-режима.

---

## 5. Итоговая рекомендованная конфигурация (diff)

### Что изменить в `smartdns.conf`:

| # | Изменение | Приоритет | Сложность |
|---|-----------|-----------|-----------|
| 1 | Обновить Yandex DoT hostname → `common.dot.dns.yandex.net` | 🔴 Высокий | Простое |
| 2 | Исправить AdGuard IP/hostname (unfiltered) | 🔴 Высокий | Простое |
| 3 | Убрать `-k` с TLS-серверов, добавить `ca-certificates` в зависимости | 🔴 Высокий | Простое |
| 4 | Убрать Cloudflare DoT (порт 853 блокируется) | 🟡 Средний | Простое |
| 5 | Добавить Cloudflare/Google UDP в default-группу | 🟡 Средний | Простое |
| 6 | Добавить `cache-persist`, `cache-file` | 🟡 Средний | Простое |
| 7 | Исправить `serve-expired-prefetch-time` → 21600 | 🟢 Низкий | Простое |
| 8 | Добавить `rr-ttl-min 60`, `rr-ttl-max 86400` | 🟢 Низкий | Простое |
| 9 | Добавить `log-size 128K`, `log-num 2`, `log-file` | 🟢 Низкий | Простое |
| 10 | Добавить `force-qtype-SOA 65` (HTTPS records) | 🟢 Низкий | Простое |
| 11 | Добавить `restart-on-crash yes` | 🟢 Низкий | Простое |
| 12 | Добавить nameserver для vk.com, yandex.com и др. | 🟢 Низкий | Простое |
| 13 | Убрать избыточные nameserver (gov.ru и др.) | 🟢 Низкий | Простое |
| 14 | Добавить `speed-check-mode ping,tcp:80,tcp:443` (явно) | 🟢 Низкий | Простое |
| 15 | **Опционально:** `-interface nwg0` для foreign DNS (VPN-protected) | 🟡 Средний | Простое (конфигурируемое) |

---

## 6. Ссылки и источники

| Источник | URL | Что использовано |
|----------|-----|-----------------|
| SmartDNS Configuration | https://pymumu.github.io/smartdns/en/configuration/ | Полный справочник параметров |
| SmartDNS GitHub | https://github.com/pymumu/smartdns | Исходный код, issues |
| Yandex DNS | https://dns.yandex.ru/ | IP-адреса, DoT/DoH hostnames |
| AdGuard DNS | https://adguard-dns.io/en/public-dns.html | IP-адреса, варианты |
| OONI Explorer | https://explorer.ooni.org/country/RU | Данные о блокировках DNS в РФ |
| ntc.party | https://ntc.party/ | Community-данные о ТСПУ и обходе блокировок |
| Habr: DNS-блокировки | habr.com/ru/articles/ | Статьи о ТСПУ и DNS в РФ |

---

## Приложение A: Полная рекомендованная конфигурация

> Это **черновик** для обсуждения в Phase 3. Не применять напрямую.

```conf
############################################
# SmartDNS — DNS-сервер с разделением по группам
#
# Документация: https://pymumu.github.io/smartdns/
# GitHub:       https://github.com/pymumu/smartdns
############################################

server-name smartdns

# ---- Listen ----
bind 0.0.0.0:6053
bind 0.0.0.0:6153 -no-speed-check -no-cache    # geo-split: all IPs

# ---- Cache ----
cache-size 20000
cache-persist yes
cache-file /opt/var/cache/smartdns.cache
prefetch-domain yes
serve-expired yes
serve-expired-ttl 259200
serve-expired-prefetch-time 21600

# ---- TTL ----
rr-ttl-min 60
rr-ttl-max 86400

# ---- Speed & Response ----
speed-check-mode ping,tcp:80,tcp:443
# response-mode first-ping  # default, не нужно указывать явно

# ---- IP selection ----
max-reply-ip-num 16                             # geo-split: all A-records
force-AAAA-SOA yes                              # IPv4 only (no IPv6 from ISP)
force-qtype-SOA 65                              # block HTTPS/SVCB records

# ---- Reliability ----
restart-on-crash yes

# ---- Logging ----
log-level error
log-file /opt/var/log/smartdns.log
log-size 128K
log-num 2

# ===========================================================================
# 🇷🇺 Russian DNS — Yandex + AdGuard (non-filtering)
# ===========================================================================

# Yandex DoT (primary)
server-tls 77.88.8.8:853 -group ru -exclude-default-group \
    -host-name common.dot.dns.yandex.net \
    -tls-host-verify common.dot.dns.yandex.net

server-tls 77.88.8.1:853 -group ru -exclude-default-group \
    -host-name common.dot.dns.yandex.net \
    -tls-host-verify common.dot.dns.yandex.net

# AdGuard Non-filtering DoT (secondary)
server-tls 94.140.14.140:853 -group ru -exclude-default-group \
    -host-name unfiltered.adguard-dns.com \
    -tls-host-verify unfiltered.adguard-dns.com

server-tls 94.140.14.141:853 -group ru -exclude-default-group \
    -host-name unfiltered.adguard-dns.com \
    -tls-host-verify unfiltered.adguard-dns.com

# UDP fallback
server 77.88.8.8 -group ru -exclude-default-group
server 77.88.8.1 -group ru -exclude-default-group

# ===========================================================================
# 🌍 International DNS — Google + Cloudflare (default group)
#
# Two modes available (uncomment one):
#   Mode A: Direct (no VPN) — simple, works for non-RKN domains
#   Mode B: VPN-protected   — all foreign DNS through VPN, bypasses TSPU
# ===========================================================================

# --- Mode A: Direct (без VPN) ---
# Google UDP (primary — most reliable from RU)
# server 8.8.8.8
# server 8.8.4.4
# Cloudflare UDP (secondary)
# server 1.1.1.1
# server 1.0.0.1

# --- Mode B: VPN-protected (рекомендуется если VPN настроен) ---
# Google UDP через VPN
server 8.8.8.8 -interface nwg0
server 8.8.4.4 -interface nwg0
# Cloudflare UDP через VPN
server 1.1.1.1 -interface nwg0
server 1.0.0.1 -interface nwg0

# Fallback без VPN — если VPN down, DNS всё равно работает
server 8.8.8.8 -fallback
server 8.8.4.4 -fallback

# ===========================================================================
# 🇷🇺 RU routing rules
# ===========================================================================

# Russian TLDs
nameserver /.ru/ru
nameserver /.xn--p1ai/ru                        # .рф
nameserver /.su/ru

# Russian services on .com/.net (CDN geo-optimization)
nameserver /yandex.net/ru
nameserver /yandex.com/ru
nameserver /vk.com/ru
nameserver /sberbank.com/ru
nameserver /tinkoff.com/ru
```

> **Примечание:** Замените `nwg0` на имя вашего VPN-интерфейса. Для WireGuard на Keenetic: `nwg0`, `nwg1`; OpenVPN: `ovpn_br0`; L2TP: `l2tp0`. Посмотреть доступные: `ip link show | grep -E 'nwg|ovpn|l2tp'`.

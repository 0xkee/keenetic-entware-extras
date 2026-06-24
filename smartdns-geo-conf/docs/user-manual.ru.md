# smartdns-geo-conf — Руководство пользователя

## Что это такое

**smartdns-geo-conf** — split-DNS конфигурация SmartDNS с настраиваемыми гео-зонами на роутерах Keenetic с Entware. Разделяет DNS-запросы по странам/регионам, обеспечивая оптимальную CDN-маршрутизацию и защиту от DNS-манипуляций.

### Как работает разделение

| Зона | DNS-серверы | Протокол |
|------|-------------|----------|
| Настраиваемые зоны (RU, ЕАЭС, СНГ, BRICS…) | Региональные (настраиваемые) | DoT + UDP fallback |
| Всё остальное (international) | International (настраиваемые) | DoH (HTTPS/443) |

### Зачем это нужно

- **Скорость для локальных доменов** — ответы от ближайших CDN-узлов через региональные DNS
- **Защита от DNS-манипуляций** для зарубежных доменов — шифрованные запросы через HTTPS/443
- **Гибкость** — любая комбинация стран или гео-союзов (40+ предустановлено)
- **Выбор провайдеров** — 15 DNS-провайдеров в каталоге (Google, Cloudflare, Quad9, Mullvad, Yandex, AliDNS…)

---

## Требования

- Роутер Keenetic с Entware
- **KeeneticOS 5.0+**

### Программные зависимости

**Из Entware-репозитория** (устанавливаются автоматически):

| Пакет | Назначение |
|-------|-----------|
| `smartdns` | DNS-сервер с группами и кэшированием |
| `ca-certificates` | TLS-сертификаты для DoT/DoH соединений |

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
opkg install smartdns-geo-conf_<версия>_all.ipk
```

Зависимости `smartdns` и `ca-certificates` установятся автоматически.

После установки SmartDNS **запускается автоматически** в режиме split-DNS.

### Шаг 3. Направить DNS-трафик на SmartDNS

Есть **два способа** направить DNS-запросы клиентов на SmartDNS:

#### Способ A: Установить пакет smartdns-redirect (рекомендуется)

Самый простой вариант — установить пакет [`smartdns-redirect`](../../smartdns-redirect/docs/user-manual.ru.md), который автоматически перехватывает DNS-запросы с LAN и направляет их на SmartDNS. Не требует изменения настроек роутера.

```sh
opkg install smartdns-redirect_<версия>_all.ipk
```

#### Способ B: Настроить Keenetic DNS вручную

Если вы не хотите использовать DNAT-перехват:

> ⚠️ **Важно:** Если в Keenetic настроены DoT/DoH серверы — ndnproxy будет использовать их и **игнорировать** SmartDNS. Сначала удалите все DoT/DoH.

**Через CLI Keenetic (SSH/Telnet к прошивке):**

```sh
# 1. Удалить все DoT/DoH серверы (обязательно!)
ndmc -c 'no dns-proxy tls upstream 1.1.1.1'
ndmc -c 'no dns-proxy tls upstream 1.0.0.1'
ndmc -c 'no dns-proxy https upstream https://1.1.1.1/dns-query'
ndmc -c 'no dns-proxy https upstream https://8.8.8.8/dns-query'
# ... (удалить все свои DoT/DoH записи)

# 2. Добавить SmartDNS как DNS-сервер
ndmc -c 'ip name-server <IP роутера>:6053'

# 3. Сохранить
ndmc -c 'system configuration save'
```

**Через веб-интерфейс:** *Интернет-фильтры → DNS* → убрать все DoT/DoH серверы, добавить `<IP роутера>:6053`.

> 📝 DNS-серверы, привязанные к VPN-интерфейсам (`ip name-server ... on ...`), можно оставить.

### Шаг 4. Проверить работу

```sh
# SmartDNS напрямую
dig ya.ru @127.0.0.1 -p 6053 +short

# Через ndnproxy → SmartDNS
dig ya.ru +short
```

---

## Настройка

### Конфигурация зон и провайдеров

Файл: `/opt/keenetic-entware-extras/smartdns-geo-conf/config/config.conf`

> 📝 Этот файл объявлен как `conffile` — при обновлении пакета ваши изменения **сохраняются**.

```sh
# Зона — одна страна или гео-союз
DNS_ZONE="eas"

# International DNS провайдеры (через пробел)
OTHER_DNS_PROVIDER="google cloudflare"

# Региональные DNS провайдеры (через пробел)
ZONE_DNS_PROVIDER="yandex adguard"

# VPN-интерфейсы для зарубежного DNS (обход MITM)
OTHER_DNS_INTERFACES=""

# VPN-интерфейс для DNS зоны (обычно не нужен)
ZONE_DNS_INTERFACE=""
```

### Доступные зоны

| Значение | Описание | Страны |
|----------|----------|--------|
| `ru` | Россия | .ru, .рф, .su |
| `by` | Беларусь | .by |
| `kz` | Казахстан | .kz |
| `am` | Армения | .am |
| `kg` | Кыргызстан | .kg |
| `eas` | ЕАЭС | ru+by+kz+am+kg |
| `cis` | СНГ | ru+by+kz+am+kg+uz+tj+md+az |
| `brics` | BRICS+ | ru+br+in+cn+za+eg+et+ae+sa+ir |
| `sco` | ШОС | ru+cn+in+kz+kg+pk+tj+uz+ir+by |
| ... | [Полный список](../../lib/geo.sh) | 40+ союзов |

> 📝 Зона определяет набор стран. Для каждой страны автоматически генерируются nameserver-правила на основе IDN TLD (из `zone-routing-rules.conf`).

### Выбор DNS-провайдера

DNS-провайдеры настраиваются через две переменные:

- **`OTHER_DNS_PROVIDER`** — провайдеры для international (зарубежных) запросов
- **`ZONE_DNS_PROVIDER`** — провайдеры для региональных запросов (зона)

Можно указать несколько провайдеров через пробел — SmartDNS опросит все параллельно.

#### International провайдеры (`OTHER_DNS_PROVIDER`)

| Значение | Провайдер | Протокол | Особенности |
|----------|-----------|----------|-------------|
| `system` | System (Keenetic) | UDP | DNS из настроек Keenetic, без шифрования |
| `google` | Google Public DNS | DoH | Быстрый, глобальный anycast |
| `cloudflare` | Cloudflare 1.1.1.1 | DoH | Быстрый, privacy-focused |
| `quad9` | Quad9 | DoT | Фильтрация malware |
| `quad9uf` | Quad9 Unfiltered | DoT | Без фильтрации |
| `mullvad` | Mullvad DNS | DoH | No-log, privacy |
| `mullvad_adblock` | Mullvad + Adblock | DoH | No-log + блокировка рекламы |
| `controld` | ControlD Free | DoH | Быстрый, без фильтрации |
| `adguard` | AdGuard DNS | DoH | Блокировка рекламы/трекеров |

#### Региональные провайдеры (`ZONE_DNS_PROVIDER`)

| Значение | Провайдер | Протокол | Регион |
|----------|-----------|----------|--------|
| `system` | System (Keenetic) | UDP | DNS из настроек Keenetic, без шифрования |
| `yandex` | Yandex DNS (базовый) | DoT + UDP | RU/СНГ |
| `yandex_safe` | Yandex Safe | DoT + UDP | RU/СНГ, фильтрация malware |
| `yandex_family` | Yandex Family | DoT + UDP | RU/СНГ, семейный фильтр |
| `adguard` | AdGuard Unfiltered | DoT | RU/СНГ |
| `adguard_ads` | AdGuard Default | DoT | RU/СНГ, блокировка рекламы |
| `alidns` | AliDNS | DoT + UDP | Китай |
| `tencent` | Tencent DNSPod | DoT + UDP | Китай |

#### Примеры выбора провайдера

**По умолчанию (RU/ЕАЭС):**
```sh
OTHER_DNS_PROVIDER="google cloudflare"
ZONE_DNS_PROVIDER="yandex adguard"
```

**Privacy-focused (Mullvad + Quad9):**
```sh
OTHER_DNS_PROVIDER="mullvad quad9"
ZONE_DNS_PROVIDER="yandex"
```

**Китайская зона:**
```sh
DNS_ZONE="cn"
ZONE_DNS_PROVIDER="alidns tencent"
```

**С блокировкой рекламы:**
```sh
OTHER_DNS_PROVIDER="mullvad_adblock"
ZONE_DNS_PROVIDER="adguard_ads"
```

### Свои DNS-серверы (custom providers)

Для добавления произвольных DNS-серверов (не из встроенного каталога) используйте файл:

```
config/dns-providers-custom.conf
```

Этот файл **не перезаписывается** при обновлении пакета. Формат — такой же как в `dns-providers.conf`:

**Пример: plain UDP DNS:**
```sh
OTHER_mydns_LABEL="My DNS"
OTHER_mydns_PROTO="udp"
OTHER_mydns_IP1="1.2.3.4"
OTHER_mydns_IP2="5.6.7.8"
```

**Пример: DoT:**
```sh
OTHER_privatedot_LABEL="Private DoT"
OTHER_privatedot_PROTO="dot"
OTHER_privatedot_IP1="10.0.0.1"
OTHER_privatedot_IP2=""
OTHER_privatedot_TLS_HOST="dns.example.com"
```

**Пример: DoH:**
```sh
OTHER_privatedoh_LABEL="Private DoH"
OTHER_privatedoh_PROTO="doh"
OTHER_privatedoh_DOH_URL="https://dns.example.com/dns-query"
OTHER_privatedoh_IP1="10.0.0.1"
OTHER_privatedoh_IP2=""
OTHER_privatedoh_TLS_HOST="dns.example.com"
```

**Пример: зоновый провайдер:**
```sh
ZONE_myzone_LABEL="My Zone DNS"
ZONE_myzone_PROTO="udp"
ZONE_myzone_IP1="192.168.1.1"
ZONE_myzone_IP2=""
ZONE_myzone_UDP_FALLBACK="no"
```

После добавления укажите имя провайдера в `config.conf`:
```sh
OTHER_DNS_PROVIDER="google mydns"
```

Пользовательские провайдеры отображаются в WebUI наравне со встроенными.

> 💡 **Совет:** WebUI автоматически обнаруживает изменения в `dns-providers-custom.conf` —
> новый провайдер появится в выпадающем списке при следующем открытии настроек (без  перезапуска nginx).

### Применение изменений

```sh
/opt/etc/init.d/S37smartdns-conf restart
```

### Порты

| Порт | Назначение |
|------|-----------|
| `:6053` | Основной DNS (используется клиентами и ndnproxy) |
| `:6153` | Вспомогательный: без speed-check (для geo-split — возврат всех IP) |

### Группы DNS-серверов

| Группа | Серверы | Протокол | Для чего |
|--------|---------|----------|----------|
| `zone` | Настраиваемые (`ZONE_DNS_PROVIDER`) | DoT + UDP | Домены из выбранной зоны |
| `default` | Настраиваемые (`OTHER_DNS_PROVIDER`) | DoH | Всё остальное (international) |

### Добавить домен в зону

Если нужно направить DNS-запросы домена через региональный DNS (для получения ближайшего CDN-IP):

```sh
vi /opt/keenetic-entware-extras/smartdns-geo-conf/config/zone-routing-rules.conf
```

Найти секцию `[extra:<cc>]` для нужной страны и добавить домен:
```conf
[extra:ru]
vk.com
yandex.com
mail.ru
example.com    # ← добавить сюда
```

Применить:
```sh
/opt/etc/init.d/S37smartdns-conf restart
```

> 📝 Домены из секции `[extra:<cc>]` маршрутизируются через региональный DNS той страны, к которой привязана секция.

### Параметры кэша

| Параметр | Значение | Описание |
|----------|----------|----------|
| `cache-size` | 20000 | Записей в кэше |
| `cache-persist` | yes | Сохранять кэш на диск |
| `serve-expired` | yes | Отдавать expired записи (обновляя фоново) |
| `prefetch-domain` | yes | Предзагрузка популярных записей |
| `rr-ttl-min` | 60 | Мин. TTL (защита от слишком низких CDN-TTL) |
| `rr-ttl-max` | 86400 | Макс. TTL |

---

## Управление

### Команды

```sh
# Генерация конфигов + перезапуск SmartDNS
/opt/etc/init.d/S37smartdns-conf restart

# Включить split-DNS
/opt/etc/init.d/S37smartdns-conf enable

# Отключить (простой форвардер, всё → international DNS)
/opt/etc/init.d/S37smartdns-conf disable

# Проверить текущий режим
/opt/etc/init.d/S37smartdns-conf status

# SmartDNS daemon напрямую
/opt/etc/init.d/S38smartdns start|stop|restart
```

### Режимы работы

| Режим | Описание |
|-------|----------|
| **split-DNS** (по умолч.) | Зоны → региональные DNS, остальное → международные DoH |
| **default** | Всё → international DNS (без разделения) |

> 📝 При переключении SmartDNS перезапускается фоново. Порты (:6053, :6153) остаются теми же — smartdns-redirect и geo-split продолжают работать.

---

## Диагностика

### Проверка статуса

```sh
/opt/keenetic-entware-extras/smartdns-geo-conf/scripts/status.sh
```

Пример вывода:

```
smartdns-geo-conf status: ✓ Alive
  Service:
    Mode:        split-DNS (enabled) ✓
    Zone:        eas → [ru by kz am kg]
    Zone DNS:    yandex adguard
    Other DNS:   google cloudflare
    Other VPN:   —
    Process:     running (pid 2035 via pidfile, RSS 10132kB) ✓
    Ports:       192.168.1.1:6053 ✓
                 127.0.0.1:6053 ✓
                 127.0.0.1:6153 ✓
    Config:      /opt/etc/smartdns/smartdns.conf (81 servers, 47 rules) ✓
    Cache:       48.0K (/opt/var/cache/smartdns.cache) ✓

  System:
    Uptime:      2d 5h ✓
    Version:     0.8.0

  DNS Tests:
    ya.ru:         5.255.255.242 (ru-group) ✓
    onliner.by:    178.124.129.12 (by-group) ✓
    kaspi.kz:      194.187.245.10 (kz-group) ✓
    news.am:       8.47.69.0 (am-group) ✓
    akipress.kg:   212.42.122.2 (kg-group) ✓
    google.com:    142.251.143.142 (default-group) ✓
```

**JSON-вывод** (для автоматизации):
```sh
/opt/keenetic-entware-extras/smartdns-geo-conf/scripts/status.sh --json
```

### DNS-тесты вручную

```sh
# RU домен (должен идти через zone-группу)
dig ya.ru @127.0.0.1 -p 6053 +short

# Российский .com (должен идти через zone-группу)
dig vk.com @127.0.0.1 -p 6053 +short

# Зарубежный домен (через default-группу, DoH)
dig google.com @127.0.0.1 -p 6053 +short

# Порт 6153 (без speed-check, все IP — для geo-split)
dig ya.ru @127.0.0.1 -p 6153 +short
```

### Частые проблемы

| Симптом | Причина | Решение |
|---------|---------|---------|
| DNS не отвечает | SmartDNS не запущен | `/opt/etc/init.d/S38smartdns start` |
| Зарубежные домены не резолвятся | DoH блокируется на сетевом уровне | Включить VPN-режим (см. ниже) |
| Медленный первый запрос | Кэш холодный после старта | Подождать — кэш прогреется |
| ndnproxy игнорирует SmartDNS | Остались DoT/DoH в настройках Keenetic | Удалить DoT/DoH или использовать smartdns-redirect |
| TLS-ошибки в логах | Нет ca-certificates | `opkg install ca-certificates` |

### Логи

```sh
# SmartDNS лог
cat /tmp/smartdns.log

# Системный лог
dmesg | grep smartdns
```

---

## VPN-интеграция (опционально)

Если зарубежные DNS недоступны напрямую (DoH блокируется MITM), направьте DNS через VPN:

### Настройка

1. Узнать имена VPN-интерфейсов:
   ```sh
   ip link show | grep -E 'nwg|ovpn|l2tp'
   ```

2. Открыть конфиг:
   ```sh
   vi /opt/keenetic-entware-extras/smartdns-geo-conf/config/config.conf
   ```

3. Указать VPN-интерфейсы для international DNS:
   ```sh
   OTHER_DNS_INTERFACES="nwg3 nwg4"
   ```

4. Применить:
   ```sh
   /opt/etc/init.d/S37smartdns-conf restart
   ```

### Как это работает

SmartDNS отправляет DNS-запросы к международным серверам через указанные VPN-интерфейсы параллельно. Первый ответ побеждает. Если все VPN недоступны — автоматический fallback на прямое соединение.

### Пример: два VPN для redundancy

```sh
OTHER_DNS_INTERFACES="nwg3 nwg4"
```

- `nwg3`: DNS через VPN1
- `nwg4`: DNS через VPN2
- Fallback: напрямую (без VPN)

---

## Обновление

```sh
opkg upgrade smartdns-geo-conf
```

Пользовательская конфигурация (`config/config.conf`) сохраняется при обновлении (conffile).
Data-файлы (`dns-providers.conf`, `zone-routing-rules.conf`) обновляются до новой версии.

---

## Удаление

```sh
opkg remove smartdns-geo-conf
```

SmartDNS (`smartdns` пакет) НЕ удаляется автоматически — удалите вручную если не нужен:
```sh
opkg remove smartdns
```

После удаления верните DNS-настройки Keenetic в прежнее состояние (или удалите `smartdns-redirect`).

# smartdns-geo-conf — Руководство пользователя

## Что это такое

**smartdns-geo-conf** — split-DNS конфигурация SmartDNS с настраиваемыми гео-зонами на роутерах Keenetic с Entware. Разделяет DNS-запросы по странам/регионам, обеспечивая оптимальную CDN-маршрутизацию и защиту от DNS-манипуляций.

### Как работает разделение

| Зона | DNS-серверы | Протокол |
|------|-------------|----------|
| Настраиваемые зоны (RU, ЕАЭС, СНГ, BRICS…) | Региональные (Yandex, AdGuard) | DoT + UDP fallback |
| Всё остальное (international) | Google, Cloudflare | DoH (HTTPS/443) |

### Зачем это нужно

- **Скорость для локальных доменов** — ответы от ближайших CDN-узлов через региональные DNS
- **Защита от DNS-манипуляций** для зарубежных доменов — шифрованные запросы через HTTPS/443
- **Гибкость** — любая комбинация стран или гео-союзов (35+ предустановлено)

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

### Конфигурация зон и интерфейсов

Файл: `/opt/keenetic-entware-extras/smartdns-geo-conf/config/config.conf`

> 📝 Этот файл объявлен как `conffile` — при обновлении пакета ваши изменения **сохраняются**.

```sh
# Зона — одна страна или гео-союз
DNS_ZONE="eas"

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
| ... | [Полный список](../config/unions.conf) | 35+ союзов |

> 📝 Активируются только зоны с пресетом `config/zones/<cc>.conf`. Отсутствующие — пропускаются с предупреждением.

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
| `ru` | Yandex, AdGuard | DoT + UDP | .ru/.рф/.su + российские .com |
| `by`, `kz`, `am`, `kg` | Yandex (+ AdGuard для BY/KZ) | DoT + UDP | Домены соотв. страны |
| `default` | Google, Cloudflare | DoH | Всё остальное (international) |

### Добавить домен в зону

Если нужно направить DNS-запросы домена через зону (для получения ближайшего CDN-IP):

```sh
vi /opt/keenetic-entware-extras/smartdns-geo-conf/config/zones/ru.conf
```

Добавить:
```conf
nameserver /example.com/ru
```

Применить:
```sh
/opt/etc/init.d/S37smartdns-conf restart
```

### Добавить новый пресет страны

1. Создать `config/zones/<cc>.conf` по образцу (`ru.conf`)
2. Добавить union в `config/unions.conf` (опционально)
3. Изменить `DNS_ZONE` в `config.conf`
4. `/opt/etc/init.d/S37smartdns-conf restart`

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

# Отключить (простой форвардер, всё → Google/CF)
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
| **default** | Всё → Google/CF DoH (без разделения) |

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
    Process:     running (pid 4921 via pidfile, RSS 5764kB) ✓
    Ports:       0.0.0.0:6053 ✓
                 0.0.0.0:6153 ✓
    Config:      /opt/etc/smartdns/smartdns.conf (14 servers, 10 rules) ✓
    Cache:       1.2M (/opt/var/cache/smartdns.cache) ✓

  System:
    Uptime:      2h 15m 30s ✓
    Version:     0.5.0

  DNS Tests:
    ya.ru:         5.255.255.242 (ru-group) ✓
    vk.com:        87.240.132.78 (ru-group (.com→ru)) ✓
    google.com:    142.250.150.100 (default-group) ✓
    github.com:    140.82.121.4 (default-group) ✓
```

**JSON-вывод** (для автоматизации):
```sh
/opt/keenetic-entware-extras/smartdns-geo-conf/scripts/status.sh --json
```

### DNS-тесты вручную

```sh
# RU домен (должен идти через ru-группу)
dig ya.ru @127.0.0.1 -p 6053 +short

# Российский .com (должен идти через ru-группу)
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

SmartDNS отправляет DNS-запросы к международным серверам (Google, Cloudflare) через указанные VPN-интерфейсы параллельно. Первый ответ побеждает. Если все VPN недоступны — автоматический fallback на прямое соединение.

### Пример: два VPN для redundancy

```sh
OTHER_DNS_INTERFACES="nwg3 nwg4"
```

- `nwg3`: Google DoH 8.8.8.8 через VPN1
- `nwg4`: Cloudflare DoH 1.0.0.1 через VPN2
- Fallback: Google + Cloudflare напрямую (без VPN)

---

## Обновление

```sh
opkg upgrade smartdns-geo-conf
```

Пользовательская конфигурация (`config/config.conf`) сохраняется при обновлении (conffile).
Пресеты зон и unions.conf обновляются до новой версии.

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

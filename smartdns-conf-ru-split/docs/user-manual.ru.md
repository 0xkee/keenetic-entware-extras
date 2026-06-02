# smartdns-conf-ru-split — Руководство пользователя

## Что это такое

**smartdns-conf-ru-split** — split-DNS конфигурация SmartDNS для российского интернета на роутерах Keenetic с Entware. Разделяет DNS-запросы по зонам, обеспечивая оптимальную маршрутизацию и защиту от провайдерских DNS-манипуляций.

### Как работает разделение

| Зона | DNS-серверы | Протокол |
|------|-------------|----------|
| `.ru` / `.рф` / `.su` | Yandex, AdGuard | DoT + UDP fallback |
| Российские `.com` (vk.com, yandex.com, sber и др.) | Yandex, AdGuard | DoT + UDP fallback |
| Всё остальное | Google, Cloudflare | DoH (HTTPS/443) |

### Зачем это нужно

- **Скорость для RU-доменов** — ответы от ближайших CDN-узлов через российские DNS
- **Защита от провайдерских DNS-манипуляций** для зарубежных доменов — шифрованные запросы через HTTPS/443

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
opkg install smartdns-conf-ru-split_<версия>_all.ipk
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

### Основной конфиг SmartDNS

Файл: `/opt/etc/smartdns/smartdns.conf`

Этот файл содержит полную конфигурацию SmartDNS: DNS-серверы, группы, правила маршрутизации, кэш, логи.

> 📝 `smartdns.conf` объявлен как conffile — при обновлении пакета ваши изменения сохраняются.

### Порты

| Порт | Назначение |
|------|-----------|
| `:6053` | Основной DNS (используется клиентами и ndnproxy) |
| `:6153` | Вспомогательный: без speed-check (для geo-split — возврат всех IP) |

### Группы DNS-серверов

| Группа | Серверы | Протокол | Для чего |
|--------|---------|----------|----------|
| `ru` | Yandex (77.88.8.8/1), AdGuard (94.140.14.140/141) | DoT + UDP | .ru/.рф/.su + российские .com |
| `default` | Google (8.8.8.8, 4.4), Cloudflare (1.1.1.1, 1.0.0.1) | DoH | Всё остальное |

### Добавить домен в ru-группу

Если нужно направить DNS-запросы домена через российские DNS (для получения ближайшего CDN-IP):

```sh
vi /opt/etc/smartdns/smartdns.conf
```

Добавить в секцию «RU routing rules»:
```conf
nameserver /example.com/ru
```

Применить:
```sh
/opt/etc/init.d/S38smartdns restart
```

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
# Запуск / остановка / перезапуск SmartDNS
/opt/etc/init.d/S38smartdns start|stop|restart
```

### Переключение split/default режима

Модуль поддерживает два режима:

| Режим | Описание |
|-------|----------|
| **split-DNS** (по умолч.) | .ru → Yandex/AdGuard, * → Google/CF DoH |
| **default** | Всё → Google/CF DoH (без разделения) |

Переключение:
```sh
# Включить split-DNS
/opt/keenetic-entware-extras/smartdns-conf-ru-split/scripts/toggle.sh enable

# Отключить (простой форвардер)
/opt/keenetic-entware-extras/smartdns-conf-ru-split/scripts/toggle.sh disable

# Проверить текущий режим
/opt/keenetic-entware-extras/smartdns-conf-ru-split/scripts/toggle.sh status
```

> 📝 При переключении SmartDNS перезапускается фоново. Порты (:6053, :6153) остаются теми же — smartdns-redirect и geo-split продолжают работать.

---

## Диагностика

### Проверка статуса

```sh
/opt/keenetic-entware-extras/smartdns-conf-ru-split/scripts/status.sh
```

Пример вывода:

```
smartdns-conf-ru-split status: ✓ Alive
  Service:
    Mode:        split-DNS (enabled) ✓
    Process:     running (pid 4921 via pidfile, RSS 5764kB) ✓
    Ports:       0.0.0.0:6053 ✓
                 0.0.0.0:6153 ✓
    Config:      /opt/etc/smartdns/smartdns.conf (14 servers, 10 rules) ✓
    Cache:       1.2M (/opt/var/cache/smartdns.cache) ✓

  System:
    Uptime:      2h 15m 30s ✓
    Version:     0.4.4

  DNS Tests:
    ya.ru:         5.255.255.242 (ru-group) ✓
    vk.com:        87.240.132.78 (ru-group (.com→ru)) ✓
    google.com:    142.250.150.100 (default-group) ✓
    github.com:    140.82.121.4 (default-group) ✓
```

**JSON-вывод** (для автоматизации):
```sh
/opt/keenetic-entware-extras/smartdns-conf-ru-split/scripts/status.sh --json
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

Если зарубежные DNS недоступны напрямую (DoH блокируется), можно направить DNS через VPN:

1. Открыть `/opt/etc/smartdns/smartdns.conf`
2. Закомментировать блок `Mode A: Direct`
3. Раскомментировать блок `Mode B: VPN-protected`
4. Заменить `nwg0` на имя вашего VPN-интерфейса:
   ```sh
   ip link show | grep -E 'nwg|ovpn|l2tp'
   ```
5. Перезапустить SmartDNS:
   ```sh
   /opt/etc/init.d/S38smartdns restart
   ```

---

## Обновление

```sh
opkg upgrade smartdns-conf-ru-split
```

Конфигурация SmartDNS (`smartdns.conf`) сохраняется при обновлении.

---

## Удаление

```sh
opkg remove smartdns-conf-ru-split
```

SmartDNS (`smartdns` пакет) НЕ удаляется автоматически — удалите вручную если не нужен:
```sh
opkg remove smartdns
```

После удаления верните DNS-настройки Keenetic в прежнее состояние (или удалите `smartdns-redirect`).

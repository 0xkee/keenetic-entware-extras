# smartdns-ru

SmartDNS split-DNS конфигурация для российского интернета на Keenetic/Entware.

## Что это

Split DNS: разделение DNS-запросов по зонам.

- **`.ru` / `.рф` / `.su`** → российские DNS (Yandex DoT, AdGuard DoT, UDP fallback)
- **Всё остальное** → зарубежные DNS (Google DoH, Cloudflare DoH)
- **Российские .com** (vk.com, yandex.com, sberbank.com и др.) → через российские DNS для CDN geo-optimization

**Зачем:**
- Скорость для RU-доменов — ближайшие CDN-узлы через российские DNS
- Обход ТСПУ-подмены для зарубежных доменов — DoH через HTTPS/443

## Требования

- Keenetic с Entware
- `opkg install smartdns` (устанавливается автоматически как зависимость)
- `opkg install ca-certificates` (устанавливается автоматически как зависимость)

## Установка

### Через .ipk (рекомендуется)

```sh
# Скопировать на роутер
scp -O smartdns-ru_0.1.2_all.ipk root@<router-ip>:/tmp/

# Установить
opkg install /tmp/smartdns-ru_0.1.2_all.ipk
```

### Из репозитория (для разработчиков)

```sh
./scripts/build-ipk.sh smartdns-ru
# Результат: dist/smartdns-ru_0.1.2_all.ipk
```

## Настройка Keenetic

После установки пакета нужно перенаправить DNS Keenetic на SmartDNS.

> **Важно:** Если в Keenetic настроены DoT/DoH серверы (dns-proxy tls/https) — ndnproxy будет использовать их и **игнорировать** plain DNS, включая SmartDNS. Сначала удалите все DoT/DoH.

**Через CLI (SSH/Telnet):**

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

**Или через веб-интерфейс:** Интернет-фильтры → DNS → убрать все DoT/DoH серверы, добавить `<IP роутера>:6053`.

DNS-серверы, привязанные к VPN-интерфейсам (`ip name-server ... on ...`), можно оставить — они используются только для трафика через этот интерфейс.

**Результат:** ndnproxy на :53 форвардит все DNS-запросы в SmartDNS на :6053.

**Проверка:**

```sh
dig ya.ru @127.0.0.1 -p 6053 +short    # SmartDNS напрямую
dig ya.ru +short                         # через ndnproxy → SmartDNS
```

## Конфигурация

Основной конфиг: `/opt/etc/smartdns/smartdns.conf`

| Порт | Назначение | Группа | Протокол |
|------|-----------|--------|----------|
| 6053 | Основной DNS | все запросы | — |
| 6153 | geo-split (все IP без speed-check) | все запросы | — |

### DNS-серверы

| Группа | Серверы | Протокол |
|--------|---------|----------|
| `ru` | Yandex (77.88.8.8/1), AdGuard (94.140.14.140/141) | DoT + UDP fallback |
| `default` | Google (8.8.8.8/4.4), Cloudflare (1.1.1.1/1.0.0.1) | DoH |

### Российские .com → ru-группа

Домены vk.com, mail.ru, yandex.com, yandex.net, sberbank.com, tinkoff.com, gosuslugi.ru маршрутизируются через ru-группу для получения IP ближайшего CDN-узла.

Добавить домен: в [`config/smartdns.conf`](config/smartdns.conf) секция "RU routing rules":

```conf
nameserver /example.com/ru
```

## Управление

```sh
# Старт / стоп / перезапуск
/opt/etc/init.d/S38smartdns start|stop|restart

# Диагностика
/opt/keenetic-entware-extras/smartdns-ru/scripts/status.sh
```

[`scripts/status.sh`](scripts/status.sh) показывает: процесс, порты, конфиг, кэш, uptime, DNS-тесты.

Пример вывода:

```
smartdns-ru status:
  Service:
    Process:     running (pid 4921 via pidfile, RSS 5764kB) ✓
    Ports:       0.0.0.0:6053 ✓
                 0.0.0.0:6153 ✓
    Config:      /opt/etc/smartdns/smartdns.conf (14 servers, 10 rules) ✓
    Cache:       1.2M (/opt/var/cache/smartdns.cache) ✓

  System:
    Uptime:      2h 15m 30s ✓
    Version:     0.1.2

  DNS Tests:
    ya.ru:         5.255.255.242 (ru-group) ✓
    vk.com:        87.240.132.78 (ru-group (.com→ru)) ✓
    google.com:    142.250.150.100 (default-group) ✓
    github.com:    140.82.121.4 (default-group) ✓
```

## VPN-интеграция (опционально)

Для маршрутизации foreign DNS через VPN-туннель:

1. Закомментировать блок `Mode A: Direct` в конфиге
2. Раскомментировать блок `Mode B: VPN-protected`
3. Заменить `nwg0` на имя VPN-интерфейса: `ip link show | grep -E 'nwg|ovpn|l2tp'`

Подробности: [docs/dns-landscape-research.md](docs/dns-landscape-research.md)

## Структура

```
smartdns-ru/
├── config/smartdns.conf   # конфигурация SmartDNS
├── scripts/
│   └── status.sh          # диагностика
└── docs/                  # документация, исследования
    ├── archive/
    │   └── current-state-assessment.md
    ├── improvement-plan.md
    └── dns-landscape-research.md
```

## Версионирование

Текущая версия: **0.1.2** ([packaging/smartdns-ru/control](../packaging/smartdns-ru/control))

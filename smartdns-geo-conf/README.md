# smartdns-geo-conf

> 📖 **[Руководство пользователя](docs/user-manual.ru.md)** — пошаговая установка, настройка, troubleshooting.

SmartDNS split-DNS конфигурация с настраиваемыми гео-зонами на Keenetic/Entware.

## Что это

Split DNS: разделение DNS-запросов по гео-зонам.

- **Зоны** (настраиваемые: RU, ЕАЭС, СНГ, BRICS, EU…) → региональные DNS (Yandex DoT, AdGuard DoT)
- **Всё остальное** → зарубежные DNS (Google DoH, Cloudflare DoH)
- **VPN-bypass** — опциональная привязка DNS-запросов к VPN-интерфейсам для обхода MITM

**Зачем:**
- Скорость для доменов в зоне — ближайшие CDN-узлы через региональные DNS
- Обход DNS-манипуляций для зарубежных доменов — DoH через HTTPS/443
- Гибкость — любая комбинация стран или гео-союзов

## Требования

- Keenetic с Entware
- `opkg install smartdns` (устанавливается автоматически как зависимость)
- `opkg install ca-certificates` (устанавливается автоматически как зависимость)

## Установка

### Через .ipk (рекомендуется)

```sh
# Скопировать на роутер
scp -O smartdns-geo-conf_<ver>_all.ipk root@<router-ip>:/tmp/

# Установить
opkg install /tmp/smartdns-geo-conf_<ver>_all.ipk
```

### Из репозитория (для разработчиков)

```sh
./scripts/build-ipk.sh smartdns-geo-conf
# Результат: dist/smartdns-geo-conf_<ver>_all.ipk
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

## Конфигурация зон

Файл: `config/config.conf`

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
| ... | [Полный список →](config/unions.conf) | 35+ союзов |

### Применение изменений

```sh
/opt/etc/init.d/S37smartdns-conf restart
```

### Примеры конфигурации

**ЕАЭС (по умолчанию):**
```sh
DNS_ZONE="eas"
```

**Только Россия:**
```sh
DNS_ZONE="ru"
```

**International DNS через VPN (обход MITM):**
```sh
OTHER_DNS_INTERFACES="nwg3 nwg4"
```

## Управление

```sh
# Включить split-DNS
/opt/etc/init.d/S37smartdns-conf enable

# Выключить (все запросы → Google/Cloudflare)
/opt/etc/init.d/S37smartdns-conf disable

# Статус
/opt/etc/init.d/S37smartdns-conf status

# Перегенерировать конфиги + перезапустить SmartDNS
/opt/etc/init.d/S37smartdns-conf restart

# Диагностика
/opt/keenetic-entware-extras/smartdns-geo-conf/scripts/status.sh
```

## Порты

| Порт | Назначение |
|------|-----------|
| 6053 | Основной DNS (все запросы) |
| 6153 | geo-split (все IP без speed-check) |

## Структура

```
smartdns-geo-conf/
├── config/
│   ├── config.conf            # 🔧 пользовательская настройка
│   ├── defaults.conf          # значения по умолчанию
│   ├── unions.conf            # справочник гео-союзов (35+)
│   ├── zones/                 # пресеты DNS по странам
│   │   ├── ru.conf
│   │   ├── by.conf
│   │   ├── kz.conf
│   │   ├── am.conf
│   │   └── kg.conf
│   ├── smartdns.conf          # шаблон split-DNS режима
│   └── smartdns-default.conf  # шаблон default режима
├── init.d/
│   └── S37smartdns-conf       # init-скрипт (enable/disable/restart)
├── scripts/
│   ├── generate-conf.sh       # генератор динамических конфигов
│   ├── status.sh              # диагностика
│   └── toggle.sh              # deprecated → S37
└── docs/
    └── user-manual.ru.md
```

## Добавление нового пресета зоны

1. Создать `config/zones/<cc>.conf` (серверы + nameserver rules)
2. При необходимости добавить union в `config/unions.conf`
3. `/opt/etc/init.d/S37smartdns-conf restart`

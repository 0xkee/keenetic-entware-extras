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

## Направить DNS-трафик на SmartDNS

После установки нужно направить DNS-запросы клиентов на SmartDNS. Два варианта:

### Вариант A: smartdns-redirect (рекомендуется)

Установить пакет [`smartdns-redirect`](../smartdns-redirect/) — он автоматически перехватывает DNS-запросы с LAN через iptables DNAT. Изменение настроек Keenetic (DNS, DoT/DoH) **не требуется**.

```sh
opkg install /tmp/smartdns-redirect_<ver>_all.ipk
```

### Вариант B: ручная настройка Keenetic DNS

Если не хотите DNAT-перехват:

> ⚠️ **Важно:** Если в Keenetic настроены DoT/DoH серверы (dns-proxy tls/https) — ndnproxy будет использовать их и **игнорировать** plain DNS, включая SmartDNS. Сначала удалите все DoT/DoH.

```sh
# 1. Удалить все DoT/DoH серверы (обязательно при варианте B!)
ndmc -c 'no dns-proxy tls upstream 1.1.1.1'
ndmc -c 'no dns-proxy https upstream https://1.1.1.1/dns-query'
# ... (удалить все свои DoT/DoH записи)

# 2. Добавить SmartDNS как DNS-сервер
ndmc -c 'ip name-server <IP роутера>:6053'

# 3. Сохранить
ndmc -c 'system configuration save'
```

**Или через веб-интерфейс:** *Интернет-фильтры → DNS* → убрать все DoT/DoH серверы, добавить `<IP роутера>:6053`.

## Конфигурация зон

Файл: `config/config.conf`

```sh
# Зона — одна страна или гео-союз
DNS_ZONE="eas"

# International DNS провайдеры (space-separated)
OTHER_DNS_PROVIDER="google cloudflare"

# Zone DNS провайдеры (space-separated)
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
| ... | [Полный список →](../lib/geo.sh) | 40+ союзов |

### DNS-провайдеры

Провайдеры настраиваются через `OTHER_DNS_PROVIDER` (international) и `ZONE_DNS_PROVIDER` (zone/regional).

**International** (`OTHER_DNS_PROVIDER`):

| Значение | Провайдер | Протокол |
|----------|-----------|----------|
| `system` | System (Keenetic) | UDP |
| `google` | Google Public DNS | DoH |
| `cloudflare` | Cloudflare | DoH |
| `quad9` | Quad9 (malware filter) | DoT |
| `quad9uf` | Quad9 Unfiltered | DoT |
| `mullvad` | Mullvad (no-log) | DoH |
| `mullvad_adblock` | Mullvad + adblock | DoH |
| `controld` | ControlD Free | DoH |
| `adguard` | AdGuard (ads filter) | DoH |

**Zone/Regional** (`ZONE_DNS_PROVIDER`):

| Значение | Провайдер | Протокол | Регион |
|----------|-----------|----------|--------|
| `system` | System (Keenetic) | UDP | — |
| `yandex` | Yandex DNS | DoT+UDP | RU/CIS |
| `yandex_safe` | Yandex Safe | DoT+UDP | RU/CIS |
| `yandex_family` | Yandex Family | DoT+UDP | RU/CIS |
| `adguard` | AdGuard Unfiltered | DoT | RU/CIS |
| `adguard_ads` | AdGuard Default | DoT | RU/CIS |
| `alidns` | AliDNS | DoT+UDP | China |
| `tencent` | Tencent DNSPod | DoT+UDP | China |

### Свои DNS-серверы

Файл `config/dns-providers-custom.conf` позволяет добавить произвольные DNS-серверы.
Не перезаписывается при обновлении пакета. Формат аналогичен `dns-providers.conf`:

```sh
# Plain UDP
OTHER_mydns_LABEL="My DNS"
OTHER_mydns_PROTO="udp"
OTHER_mydns_IP1="1.2.3.4"
OTHER_mydns_IP2=""

# Затем в config.conf:
OTHER_DNS_PROVIDER="google mydns"
```

Поддерживаются протоколы: `udp`, `dot` (DoT), `doh` (DoH). Подробнее — в [user-manual.ru.md](docs/user-manual.ru.md).

> Список провайдеров кешируется WebUI на 1 час. Для немедленного обновления:
> `/opt/etc/init.d/S80nginx-webui restart`

### Применение изменений

```sh
/opt/etc/init.d/S37smartdns-conf restart
```

### Примеры конфигурации

**ЕАЭС (по умолчанию):**
```sh
DNS_ZONE="eas"
OTHER_DNS_PROVIDER="google cloudflare"
ZONE_DNS_PROVIDER="yandex adguard"
```

**Только Россия + Quad9:**
```sh
DNS_ZONE="ru"
OTHER_DNS_PROVIDER="quad9"
ZONE_DNS_PROVIDER="yandex"
```

**Китай (AliDNS + Tencent):**
```sh
DNS_ZONE="cn"
ZONE_DNS_PROVIDER="alidns tencent"
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
│   ├── dns-providers.conf     # каталог DNS-провайдеров (15 шт)
│   ├── zone-routing-rules.conf # IDN TLDs + extra CDN-домены (80+ стран)
│   ├── test-domains.conf      # тестовые домены для status.sh
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

## Добавление домена в зону

To add extra domains to a zone's DNS routing (e.g. for CDN optimization):

1. Edit `config/zone-routing-rules.conf` — add domain to the appropriate country section
2. `/opt/etc/init.d/S37smartdns-conf restart`

Example (add `example.com` to RU zone):
```conf
# In zone-routing-rules.conf, under [extra:ru] section:
example.com
```

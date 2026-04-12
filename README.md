# Keenetic Entware Scripts

Shell-скрипты для Keenetic роутера с Entware.

## Структура

```
keenetic-entware-extras/
├── scripts/              # общие скрипты
├── lib/                  # переиспользуемые функции
│   └── common.sh
├── config/               # шаблоны конфигов
├── geo-split/           # подпроект: split routing — GeoIP/домены через разные интерфейсы
│   ├── scripts/
│   ├── config/
│   ├── lists/
│   └── README.md
├── smartdns-ru/             # подпроект: кастомный конфиг SmartDNS для RU zone DNS split
│   ├── scripts/
│   ├── config/
│   └── README.md
├── .project/             # targets для Roo
├── .roo/                 # конфигурация Roo
└── .vscode/              # конфигурация VSCode
```

## Подпроекты

### [geo-split](geo-split/README.md)

Split routing для Keenetic: маршрутизация трафика по GeoIP-подсетям и спискам доменов через разные сетевые интерфейсы (ISP/VPN). Поддерживает режимы bypass, vpn, auto.

### [smartdns-ru](smartdns-ru/README.md)

Кастомный конфиг SmartDNS для разделения DNS-запросов по зонам: `.ru`/`.рф`/`.su` → Yandex/AdGuard (DoT), остальное → Cloudflare/Google (DoT/DoH).

## Требования

- Keenetic с установленным Entware
- `bash` (`opkg install bash`)
- `curl` (`opkg install curl`)
- `smartdns` (`opkg install smartdns`)

## Деплой на роутер

```bash
scp -r scripts/ lib/ root@192.168.1.1:/opt/keenetic-entware-extras/
```

## Разработка

```bash
# Проверка скриптов shellcheck
shellcheck -x -s bash scripts/*.sh

# Проверить конкретный файл
shellcheck -x -s bash geo-split/scripts/update-domains.sh
```

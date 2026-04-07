# Keenetic Entware Scripts

Shell-скрипты для Keenetic роутера с Entware.

## Структура

```
keenetic-entware/
├── scripts/              # общие скрипты
├── lib/                  # переиспользуемые функции
│   └── common.sh
├── config/               # шаблоны конфигов
├── geo-bypass/           # подпроект: маршрутизация .ru мимо VPN
│   ├── scripts/
│   ├── config/
│   ├── lists/
│   └── README.md
├── smartdns/             # подпроект: DNS-сервер с группами ru/default
│   ├── scripts/
│   ├── config/
│   └── README.md
├── .project/             # targets для Roo
├── .roo/                 # конфигурация Roo
└── .vscode/              # конфигурация VSCode
```

## Подпроекты

### [geo-bypass](geo-bypass/README.md)

Прямая маршрутизация .ru доменов (и других российских ресурсов) в обход VPN.

### [smartdns](smartdns/README.md)

DNS-сервер с разделением запросов по доменным группам (`.ru` → Yandex/AdGuard, остальное → Cloudflare/Google).

## Требования

- Keenetic с установленным Entware
- `bash` (`opkg install bash`)
- `curl` (`opkg install curl`)
- `smartdns` (`opkg install smartdns`)

## Деплой на роутер

```bash
scp -r scripts/ lib/ root@192.168.1.1:/opt/keenetic-entware/
```

## Разработка

```bash
# Проверка скриптов shellcheck
shellcheck -x -s bash scripts/*.sh

# Проверить конкретный файл
shellcheck -x -s bash geo-bypass/scripts/update-domains.sh
```

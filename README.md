# Keenetic Entware Extras

Shell-скрипты и `.ipk` пакеты для Keenetic-роутеров с Entware.
Включает подпроекты: **geo-split** (split routing по GeoIP/доменам), **smartdns-ru** (DNS split).

## Пакеты

| Пакет | Версия | Описание |
|-------|--------|----------|
| `keenetic-entware-extras` | 0.4.1 | Базовый пакет — shared libraries: `lib/common.sh`, `lib/ip.sh`, `lib/lists.sh` |
| `geo-split` | 0.8.2 | Split routing по GeoIP + доменам. Зависит от `keenetic-entware-extras` |
| `geo-split-data` | 0.3.2 | Данные: списки доменов, GeoIP-зоны, whitelist. Conffiles — сохраняются при upgrade |
| `smartdns-ru` | 0.1.2 | Split DNS: .ru/.рф → российские DNS, остальное → Google/Cloudflare DoH. Зависит от `smartdns`, `ca-certificates` |

## Установка через opkg

Основной способ установки для пользователей.

```sh
# Скопировать .ipk файлы на роутер
scp *.ipk root@<router-ip>:/tmp/

# Установить (порядок важен — сначала base, потом data, потом geo-split)
opkg install /tmp/keenetic-entware-extras_0.4.1_all.ipk
opkg install /tmp/geo-split-data_0.3.2_all.ipk
opkg install /tmp/geo-split_0.8.2_all.ipk
```

Зависимости (`ip-full`, `curl`, `bind-dig`, `aggregate`) устанавливаются автоматически через opkg.

## Подпроекты

### [geo-split](geo-split/README.md)

Split routing для Keenetic: маршрутизация трафика по GeoIP-подсетям и спискам доменов через разные сетевые интерфейсы (ISP/VPN). Поддерживает режимы bypass, vpn, auto.

### [smartdns-ru](smartdns-ru/README.md)

Split DNS для российского интернета: `.ru`/`.рф`/`.su` → Yandex/AdGuard DoT, всё остальное → Google/Cloudflare DoH. Deployed, v0.1.2.

## Структура проекта

```
keenetic-entware-extras/
├── lib/                  # shared libraries
│   ├── common.sh         # logging, error handling
│   ├── ip.sh             # IP/interface utilities
│   └── lists.sh          # list processing (@include, dedup)
├── geo-split/            # split routing подпроект
│   ├── scripts/          # attach, detach, update, status, ndm-hook
│   ├── config/           # config.sh
│   ├── loaders/          # CIDR загрузчики (plain, RIPE JSON)
│   ├── rootfs/           # init.d/S99geo-split
│   └── docs/             # архитектура, сравнения
├── geo-split-data/       # данные (списки, GeoIP-зоны)
│   ├── lists/            # domains.txt, ru-whitelist.txt
│   └── scripts/          # fetch-zones.sh
├── smartdns-ru/          # DNS split (v0.1.2)
│   ├── config/           # smartdns.conf
│   ├── scripts/          # status.sh
├── packaging/            # .ipk метаданные
│   ├── keenetic-entware-extras/
│   ├── geo-split/
│   ├── geo-split-data/
│   └── smartdns-ru/
├── scripts/              # build-ipk.sh
├── docs/                 # документация
└── LICENSE               # MIT
```

## Требования

- Keenetic с установленным Entware
- Зависимости устанавливаются автоматически через opkg:
  - `ip-full` — iproute2 для policy routing
  - `curl` — загрузка GeoIP-данных
  - `bind-dig` — DNS-резолвинг доменов
  - `aggregate` — агрегация CIDR-подсетей

## Разработка

Для контрибьюторов и разработчиков.

**Полная процедура деплоя** (spike/full режимы, state control, rollback, troubleshooting): [`.project/deploy-workflow.md`](.project/deploy-workflow.md).

```sh
# Линтинг
shellcheck -x -s sh scripts/*.sh
shellcheck -x -s sh geo-split/scripts/*.sh

# Spike deploy (быстрая итерация, роутеры без sftp-server)
scp -O -r lib/ geo-split/ root@<router-ip>:/opt/keenetic-entware-extras/

# Full deploy: сборка всех .ipk пакетов
./scripts/build-ipk.sh all
```

## Лицензия

[MIT](LICENSE)

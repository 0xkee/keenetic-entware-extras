# Keenetic Entware Extras

> 📖 **[Руководство пользователя](docs/user-manual.ru.md)** — установка, kee-status, bug-report.

Shell-скрипты и `.ipk` пакеты для Keenetic-роутеров с Entware.
Включает подпроекты: **geo-split** (split routing по GeoIP/доменам), **smartdns-conf-ru-split** (DNS split), **smartdns-redirect** (DNAT LAN :53 → local DNS), **webui** (дашборд).

## Пакеты

| Пакет | Описание |
|-------|----------|
| `keenetic-entware-extras` | Базовый пакет — shared libraries (`lib/common.sh`, `lib/ip.sh`, `lib/lists.sh`, `lib/status.sh`) + CLI `kee-status` |
| `geo-split` | Split routing по GeoIP + доменам. Зависит от `keenetic-entware-extras` |
| `geo-split-data` | Данные: списки доменов, GeoIP-зоны, whitelist. Conffiles — сохраняются при upgrade |
| `smartdns-conf-ru-split` | Split DNS: .ru/.рф → российские DNS, остальное → Google/Cloudflare DoH |
| `smartdns-redirect` | Universal DNS DNAT: перехват LAN `:53` → local DNS |
| `webui` | Custom dashboard для Keenetic/Entware services на :8080 |

## Установка через opkg

Основной способ установки для пользователей.

```sh
# Скопировать .ipk файлы на роутер
scp *.ipk root@<router-ip>:/tmp/

# Установить (порядок важен — сначала base, потом data, потом geo-split)
opkg install /tmp/keenetic-entware-extras_<ver>_all.ipk
opkg install /tmp/geo-split-data_<ver>_all.ipk
opkg install /tmp/geo-split_<ver>_all.ipk
```

Зависимости (`ip-full`, `curl`, `bind-dig`, `aggregate`) устанавливаются автоматически через opkg.

## Диагностика

После установки пакета `keenetic-entware-extras` доступна команда
[`kee-status`](scripts/kee-status.sh:1) — агрегированный статус всех
подпакетов. Запускает `scripts/status.sh` каждого установленного пакета
(без стриминга), показывает одну строку на пакет (`Alive` / `FAIL`), а
под упавшими — только строки с `✗`, сгруппированные по подсекциям
(`Service:`, `Rules:`, `DNS Tests:` и т.д.).

```sh
kee-status                # цветной вывод в TTY
kee-status --no-color     # plain text для логов / ndmc
NO_COLOR=1 kee-status     # то же через env
```

Exit code: `0` если все `Alive`, `1` если есть `FAIL`.

## Подпроекты

### [geo-split](geo-split/README.md)

Split routing для Keenetic: маршрутизация трафика по GeoIP-подсетям и спискам доменов через разные сетевые интерфейсы (ISP/VPN). Поддерживает режимы bypass, vpn, auto.

### [smartdns-conf-ru-split](smartdns-conf-ru-split/README.md)

Split DNS для российского интернета: `.ru`/`.рф`/`.su` → Yandex/AdGuard DoT, всё остальное → Google/Cloudflare DoH.

### [smartdns-redirect](smartdns-redirect/README.md)

Universal DNS DNAT: `iptables PREROUTING REDIRECT` для LAN-клиентов (`br0`) — обход Keenetic ndnproxy, прямое резолвление через локальный DNS (SmartDNS/AdGuard Home/Unbound/dnsmasq). Persistence через NDM `netfilter.d` hook, watchdog по cron. Измеренный выигрыш latency: `~130ms → <80ms`.

## Структура проекта

```
keenetic-entware-extras/
├── lib/                  # shared libraries
│   ├── common.sh         # logging, error handling, JSON helpers
│   ├── ip.sh             # IP/interface utilities
│   ├── lists.sh          # list processing (@include, dedup)
│   └── status.sh         # status check/show helpers for diagnostics
├── geo-split/            # split routing подпроект
│   ├── scripts/          # attach, detach, update, status, ndm-hook
│   ├── config/           # config.conf
│   ├── loaders/          # CIDR загрузчики (plain, RIPE JSON)
│   ├── rootfs/           # init.d/S99geo-split
│   └── docs/             # архитектура, сравнения
├── geo-split-data/       # данные (списки, GeoIP-зоны)
│   ├── lists/            # domains.txt, ru-whitelist.txt
│   └── scripts/          # fetch-zones.sh
├── smartdns-conf-ru-split/          # DNS split
│   ├── config/           # smartdns.conf
│   ├── scripts/          # status.sh, toggle.sh
├── smartdns-redirect/    # DNS DNAT для LAN
│   ├── config/           # smartdns-redirect.conf (conffile)
│   ├── scripts/          # dns-redirect, watchdog, status, netfilter-hook
│   └── rootfs/           # init.d/S39smartdns-redirect
├── webui/                # custom dashboard (nginx + lua)
│   ├── config/           # nginx.conf, logrotate.conf
│   ├── scripts/          # status.sh, patch-stock-ui.sh
│   ├── lua/              # api-router, serve-index
│   └── rootfs/           # init.d/S80nginx-webui
├── packaging/            # .ipk метаданные
│   ├── keenetic-entware-extras/
│   ├── geo-split/
│   ├── geo-split-data/
│   ├── smartdns-conf-ru-split/
│   └── smartdns-redirect/
├── scripts/              # build-ipk.sh, kee-status.sh (aggregated status CLI)
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

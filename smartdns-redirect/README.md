# smartdns-redirect

Universal DNS DNAT для Keenetic/Entware — перехват LAN `:53` и редирект на локальный DNS-резолвер.

## Что это

iptables REDIRECT на `PREROUTING` для интерфейса `br0` (LAN): все DNS-запросы клиентов идут не в Keenetic ndnproxy, а напрямую в локальный DNS (SmartDNS `:6053` по умолчанию). Сам роутер (ndnproxy :53) **не затрагивается** — работает как раньше.

**Зачем:**
- **Latency** — измерено: ~130ms → <80ms на LAN-клиентах (минус hop через ndnproxy).
- **Split-DNS policy** работает для клиентов напрямую (SmartDNS решает через какой upstream идти).
- **Keenetic integrity** — ndnproxy не ломается, webui/diagnostics не страдают.

**Совместимо с:**
- [`smartdns-conf-ru-split`](../smartdns-conf-ru-split) (default upstream `:6053`)
- AdGuard Home (`UPSTREAM_PORT=5353`)
- Unbound (`UPSTREAM_PORT=5335`)
- dnsmasq (любой порт)
- [`geo-split`](../geo-split) — работает в связке.

## Требования

- Keenetic с Entware
- `opkg install iptables` (устанавливается автоматически как зависимость)
- Локальный DNS-резолвер на роутере, слушающий на UDP/TCP порту (по умолчанию `:6053`)

## Установка

### Через .ipk (рекомендуется)

```sh
scp -O smartdns-redirect_0.1.1_all.ipk root@<router-ip>:/tmp/
opkg install /tmp/smartdns-redirect_0.1.1_all.ipk
```

`postinst` автоматически:
- создаёт симлинк `/opt/etc/ndm/netfilter.d/smartdns-redirect-hook` (восстановление правил при `iptables flush` от NDM),
- добавляет cron-watchdog (`*/5 * * * *`) в `/opt/etc/crontab`,
- запускает `S39smartdns-redirect`.

## Конфигурация

Файл: `/opt/keenetic-entware-extras/smartdns-redirect/config/smartdns-redirect.conf` (помечен `conffile` — пользовательские правки сохраняются при обновлении пакета).

```sh
UPSTREAM_PORT=6053         # SmartDNS=6053, AGH=5353, Unbound=5335
INTERFACES="br0"           # LAN-интерфейсы (space-separated)
ENABLE_IPV6=no             # IPv6 DNAT (экспериментально)
WATCHDOG_SERVICE="S38smartdns"   # init-скрипт для рестарта при падении
PRESERVE_FILTER_PROFILES=no      # Phase 5 (не реализовано)
```

После изменения конфига:

```sh
/opt/etc/init.d/S39smartdns-redirect restart
```

## Проверка работы

```sh
# Правила в NAT PREROUTING
iptables -t nat -S PREROUTING | grep REDIRECT
# Ожидаем:
#   -A PREROUTING -i br0 -p udp -m udp --dport 53 -j REDIRECT --to-ports 6053
#   -A PREROUTING -i br0 -p tcp -m tcp --dport 53 -j REDIRECT --to-ports 6053

# Статус
/opt/etc/init.d/S39smartdns-redirect status

# Логи
logread | grep smartdns-redirect
```

## Как это работает

### Поток запроса LAN-клиента

```
Client (10.0.0.42) → UDP :53 → br0 →
  [iptables PREROUTING REDIRECT :6053] →
    SmartDNS (127.0.0.1:6053) → upstream (DoT/DoH/UDP)
```

Роутер сам (loopback `127.0.0.1:53`) ходит в ndnproxy — правила `br0` его не касаются.

### NDM-устойчивость

Keenetic периодически flush'ит iptables через свои netfilter hooks. Симлинк в `/opt/etc/ndm/netfilter.d/` вызывает [`netfilter-hook.sh`](scripts/netfilter-hook.sh) каждый раз, когда NDM трогает таблицы — правила немедленно восстанавливаются.

### Watchdog

Cron раз в 5 минут запускает [`watchdog.sh`](scripts/watchdog.sh):

1. Проверяет наличие правил в `PREROUTING` — если нет, восстанавливает.
2. Шлёт тестовый DNS-запрос на `UPSTREAM_PORT`. Если upstream молчит — рестартует `WATCHDOG_SERVICE` (по умолчанию `S38smartdns`).

## Удаление

```sh
opkg remove smartdns-redirect
```

`prerm` / `postrm` откатят всё: init-скрипт, симлинк, iptables, cron, PID-файл, установочный каталог.

## Архитектура

```
smartdns-redirect/
├── config/
│   └── smartdns-redirect.conf      # conffile (сохраняется при upgrade)
├── rootfs/opt/etc/init.d/
│   └── S39smartdns-redirect        # init (start/stop/restart/status)
└── scripts/
    ├── dns-redirect.sh             # apply/remove iptables rules
    ├── netfilter-hook.sh           # NDM hook: restore on flush
    ├── watchdog.sh                 # cron: rule presence + upstream health
    └── status.sh                   # диагностика
```

## Лицензия

MIT — см. [LICENSE](../LICENSE).

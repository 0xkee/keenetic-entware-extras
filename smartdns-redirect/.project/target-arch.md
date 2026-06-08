# Architecture Targets — smartdns-redirect

Inherits all rules from root [`.project/target-arch.md`](../../.project/target-arch.md).

## Purpose

Universal DNS DNAT overlay для Keenetic/Entware: перехват LAN `:53` (br0) и редирект на локальный DNS-резолвер через `iptables -t nat -I PREROUTING 1 ... REDIRECT --to-ports <UPSTREAM_PORT>`.

**Независимый пакет** — работает с любым local DNS (SmartDNS, AdGuard Home, Unbound, dnsmasq) через параметр `UPSTREAM_PORT` в конфиге. Не зависит от [`smartdns-geo-conf/`](../../smartdns-geo-conf/).

**Измеренный выигрыш** на router-1 (2026-04-17): latency `~130ms → <80ms` для LAN-клиентов (минус hop через ndnproxy).

## Key Design Decisions

### DNAT на PREROUTING index 1, НЕ fwmark

Keenetic NDM активно использует `fwmark` для per-policy routing (Policy0-5) и filter profiles. Попытки вставлять `fwmark`-aware правила конфликтуют с NDM-chain'ами. См. [`docs/knowledge/keenetic-fwmark-analysis.md`](../../docs/knowledge/keenetic-fwmark-analysis.md).

Решение: **stateless REDIRECT** на `PREROUTING` с индексом 1 (ДО `_NDM_DNS_REDIRECT`). Это исключает конфликт с NDM и перехватывает трафик раньше.

### Независимость от smartdns-geo-conf

Пакет может работать с любым local DNS. По умолчанию `UPSTREAM_PORT=6053` (совпадает с [`smartdns-geo-conf`](../../smartdns-geo-conf/)), но пользователь может указать любой порт:

| Upstream | `UPSTREAM_PORT` | `WATCHDOG_SERVICE` |
|----------|-----------------|---------------------|
| SmartDNS (smartdns-geo-conf) | `6053` | `S38smartdns` |
| AdGuard Home | `5353` | `S80adguardhome` (пример) |
| Unbound | `5335` | `S60unbound` (пример) |
| dnsmasq | свободный | `S56dnsmasq` (пример) |

### Router's own DNS не затрагивается

Правило привязано к `-i br0` — касается только LAN-трафика. Роутер (loopback `127.0.0.1:53`) ходит в ndnproxy как раньше: KeenDNS, NDM filter profiles для роутера, diagnostic `dig @127.0.0.1` — работают штатно.

### Persistence через NDM netfilter hook

NDM периодически flush'ит `iptables` при policy changes, WAN up/down, config reload. Установленный симлинк `/opt/etc/ndm/netfilter.d/smartdns-redirect-hook → scripts/netfilter-hook.sh` — каждый раз вызывает `dns-redirect.sh start` (idempotent), моментально восстанавливая правила.

### Idempotency

`start` проверяет `iptables -C` перед `-I` → не дублирует правила при повторных вызовах (cron watchdog, NDM hook trigger).

`stop`/`reload` используют функцию `del_all_rules`: парсит `iptables -S PREROUTING` и удаляет ВСЕ правила с сигнатурой `--dport 53 -j REDIRECT --to-ports <N>`. Это гарантирует полную очистку при смене `UPSTREAM_PORT` или `INTERFACES` через конфиг.

### Watchdog: rule + upstream

Cron `*/5 min` запускает [`scripts/watchdog.sh`](../scripts/watchdog.sh):

1. **Rule check** — `iptables -C PREROUTING ...` для каждого expected rule. Missing → `dns-redirect.sh reload`.
2. **Upstream liveness** — `dig @127.0.0.1 -p $UPSTREAM_PORT +time=2 +tries=1 example.com`. Fail → `$WATCHDOG_SERVICE restart` (если service указан в конфиге).

Watchdog **не трогает правила** если upstream down — задача вернуть upstream к жизни, а не переключить на ndnproxy.

### Filter profiles — out of scope (Phase 5, отложено)

Keenetic filter profiles (`dns-proxy filter profile host <mac>`) требуют прохождения DNS через ndnproxy. Наш DNAT обходит ndnproxy для LAN → filter profiles перестают работать.

**Phase 5** (не реализовано) предусматривает MAC-exclusion: чтение `show running-config` + генерация `iptables ... -m mac --mac-source ... -j ACCEPT` правил ДО REDIRECT. Параметр `PRESERVE_FILTER_PROFILES=no` зарезервирован в конфиге.

## Integration

### With [`smartdns-geo-conf/`](../../smartdns-geo-conf/)

- Независимость: пакет **не зависит** от `smartdns-geo-conf` в opkg metadata (`Depends: keenetic-entware-extras, iptables`).
- `UPSTREAM_PORT=6053` по умолчанию совпадает с тем, что слушает SmartDNS → out-of-the-box работает в связке.
- `WATCHDOG_SERVICE="S38smartdns"` по умолчанию — при падении SmartDNS watchdog его поднимает.

### With [`geo-split/`](../../geo-split/)

- Не затрагивается. SmartDNS `:6153` для `update-domains.sh` остаётся как есть (другой bind-address в конфиге SmartDNS).
- Geo-split использует `dig @localhost` для resolving доменов из списков — это запросы с роутера, НЕ с LAN → DNAT их не касается.

### With Keenetic NDM

- Работает «поверх» NDM без модификаций ndnproxy.
- NDM filter profiles для роутера и KeenDNS (`*.keenetic.link` для router-self) — не ломаются.
- Filter profiles для LAN-клиентов — обходятся (см. Phase 5).

## Project Structure

```
smartdns-redirect/
├── .project/
│   ├── target-arch.md            # this file
│   └── target-code.md            # code standards
├── config/
│   └── smartdns-redirect.conf    # UPSTREAM_PORT, INTERFACES, ENABLE_IPV6, ...
├── scripts/
│   ├── dns-redirect.sh           # core: start|stop|reload
│   ├── watchdog.sh               # cron */5 min: rule + upstream health
│   ├── status.sh                 # диагностика (Mode/Rules/Upstream/System)
│   └── netfilter-hook.sh         # NDM hook (устанавливается симлинком)
├── rootfs/opt/etc/init.d/
│   └── S39smartdns-redirect      # init wrapper (S39 после S38smartdns)
├── README.md
└── TODO.md

packaging/smartdns-redirect/
├── control                        # metadata (Version, Depends)
├── conffiles                      # /opt/keenetic-entware-extras/.../smartdns-redirect.conf
├── postinst                       # symlink hook + cron + service start
├── prerm                          # stop + unlink + cron clean
└── postrm                         # pid + rmdir
```

## Deploy Layout on Router

```
/opt/keenetic-entware-extras/smartdns-redirect/config/smartdns-redirect.conf   # conffile
/opt/keenetic-entware-extras/smartdns-redirect/scripts/*.sh                   # scripts
/opt/keenetic-entware-extras/smartdns-redirect/LICENSE
/opt/keenetic-entware-extras/smartdns-redirect/README.md
/opt/etc/init.d/S39smartdns-redirect                                          # init wrapper
/opt/etc/ndm/netfilter.d/smartdns-redirect-hook                               # symlink → scripts/netfilter-hook.sh
/opt/etc/crontab                                                               # "*/5 * * * * root .../watchdog.sh"
/opt/var/run/smartdns-redirect.pid                                            # runtime (optional)
```

## Quality Metrics

Inherits root targets (simplicity 90%+, shellcheck 100%, over-engineering ≤5%).

Subproject-specific:

| Metric | Target | Actual (v0.1.1) |
|--------|--------|-----------------|
| Total LoC (scripts + init + hook) | ≤300 | ~330 (dns-redirect 138 + watchdog 92 + status 175 + netfilter-hook 20 + init 44) |
| Single script LoC | ≤200 | all pass (max status.sh ~175) |
| Shellcheck violations | 0 | 0 |
| Maintainer script complexity | minimal | postinst 25 lines, prerm 12, postrm 10 |
| Runtime dependencies | iptables only | ✓ |

## References

- [`docs/smartdns-redirect-plan.md`](../../docs/smartdns-redirect-plan.md) — полный план реализации (Phase 1-5)
- [`docs/smartdns-replacement-options.md`](../../docs/smartdns-replacement-options.md) — анализ альтернатив (Вариант 8 — наш)
- [`docs/_research/router-1-dns-recon.txt`](../../docs/_research/router-1-dns-recon.txt) — замеры latency до/после
- [`docs/knowledge/keenetic-fwmark-analysis.md`](../../docs/knowledge/keenetic-fwmark-analysis.md) — почему не fwmark

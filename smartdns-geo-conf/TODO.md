# smartdns-geo-conf — TODO

**Updated:** 2026-06-09

---

## Завершено ✅

### Packaging + Init (Этап A)

- [x] `packaging/smartdns-geo-conf/` — control, conffiles, postinst, prerm, postrm
- [x] `scripts/build-ipk.sh` — поддержка `smartdns-geo-conf`
- [x] `smartdns-geo-conf/scripts/status.sh` — диагностика (процесс, порты, DNS-тесты)
- [x] `.ipk` собирается и устанавливается через `opkg install`
- [x] Используется стоковый `S38smartdns` (вместо кастомного S60)
- [x] postinst перезапускает SmartDNS после установки
- [x] BUG-7: +x на packaging-скрипты в `build-ipk.sh`

### Конфиг улучшения (Этап B)

- [x] Yandex DoT: hostname обновлён → `common.dot.dns.yandex.net`
- [x] AdGuard: IP исправлены → `94.140.14.140/141` (unfiltered)
- [x] AdGuard: hostname исправлён → `unfiltered.adguard-dns.com`
- [x] Убран `-k` (skip TLS verify) — `ca-certificates` в зависимостях
- [x] International DNS: DoH only (Google + Cloudflare), DoT/UDP убраны
- [x] `cache-persist yes` + `cache-file` — кэш выживает перезагрузку
- [x] `force-qtype-SOA 65` — блокировка HTTPS/SVCB records
- [x] TTL bounds: `rr-ttl-min 60`, `rr-ttl-max 86400`
- [x] Логирование: `log-file`, `log-size 128K`, `log-num 2`
- [x] Российские .com домены (vk.com, yandex.com и др.) → ru-группа

### Деплой

- [x] Деплой на router-1 через `opkg install`
- [x] DNS-тесты: yandex.ru, google.com, github.com — работают
- [x] `status.sh` отображает корректную диагностику

---

## В работе / Pending ⏳

### Multi-zone DNS + VPN interfaces (Этап C) ✅

**Реализовано (v0.5.0, 2026-06-06):**

- [x] `config/config.conf` — пользовательская настройка: `DNS_ZONE`, `OTHER_DNS_INTERFACES`, `ZONE_DNS_INTERFACE`
- [x] `config/unions.conf` — справочник 35+ гео-союзов (eas, cis, brics, nato, eu, schengen…)
- [x] `config/zones/{ru,by,kz,am,kg}.conf` — статические пресеты DNS-серверов + nameserver rules
- [x] `config/zones/test-domains.conf` — тестовые домены для 100+ стран
- [x] `scripts/generate-conf.sh` — генератор `dns-servers-other.conf` + `dns-zones-active.conf`
- [x] `init.d/S37smartdns-conf` — init-скрипт (enable/disable/restart/status, генерирует при старте)
- [x] `smartdns.conf` / `smartdns-default.conf` — `conf-file` includes вместо hardcoded серверов
- [x] `postinst` / `postrm` / `prerm` — обновлены для S37
- [x] `status.sh` — выводит зону/союз, динамические DNS-тесты, JSON с `dns_tests` массивом
- [x] WebUI: обновлены `shared.js`, `app.js` (SUMMARY_KEYS + CONFIG_SCHEMAS)
- [x] Документация обновлена (README, user-manual, CHANGELOG)


### Известные проблемы

- [x] ~~**conffile conflict при установке**~~ — решено: `opkg install --force-maintainer` по умолчанию (см. [deploy-workflow.md §4.6](../.project/deploy-workflow.md))
- [x] ~~**BUG-6: `restart-on-crash`**~~ — SmartDNS `execv()` fails с relative `argv[0]` при запуске через `S38`/`rc.func`. Upstream SmartDNS bug. **Mitigated (2026-05-15):** опция закомментирована в конфиге + `smartdns-redirect/scripts/watchdog.sh` перезапускает при падении через cron.

### Исследовать

- [ ] **Нужен ли `ndmc -c 'ip name-server <IP>:6053'` при наличии smartdns-redirect?** Если DNAT (br0:53→:6053) покрывает все LAN-клиенты, то настройка ndnproxy через `ip name-server` может быть избыточна. Вопрос: что происходит с DNS-запросами **самого роутера** (loopback, он ходит через ndnproxy:53) — для них DNAT не работает, нужен forward через ndnproxy. Разобрать сценарии: (a) только smartdns-redirect, (b) только ip name-server, (c) оба.

### Улучшения (backlog)

- [x] ~~**Конфигурируемые international DNS-серверы**~~ — **Сделано (v0.8.0, 2026-06-09):** `OTHER_DNS_PROVIDER` / `ZONE_DNS_PROVIDER` в `config.conf`. Каталог 15 провайдеров в `dns-providers.conf`. Динамическая генерация зон из `zone-routing-rules.conf` (заменено 235 статических zone-файлов).
- [x] ~~**`default` (ISP DNS) провайдер**~~ — **Сделано (v0.9.0, 2026-06-15):** `default` в обоих провайдер-списках. Proto `udp` в generate-conf.sh, динамическое чтение из `/tmp/ndnproxymain.conf`. WebUI, README, user-manual обновлены.
- [ ] **Exclude-список для зонового DNS-роутинга** — возможность исключить домен из обработки зоны (`nameserver /specific-host.ru/default`). Реализация: файл `config/dns-zone-exclude.conf` с правилами, include в конец zone-конфига. Документировать в user-manual.
- [ ] **FAQ: ECS (EDNS Client Subnet) не передаётся** — добавить в user-manual пояснение что SmartDNS не отправляет подсеть клиента upstream-серверам. Google/Cloudflare видят только IP роутера (WAN или VPN-выхода). Фидбэк: cryoPanda.
- [x] ~~DNS DNAT redirect: `iptables PREROUTING` br0:53 → SmartDNS:6053 (обход ndnproxy)~~ — реализовано в отдельном пакете [`smartdns-redirect`](../smartdns-redirect/) v0.1.1 (deployed на router-1, latency ~130ms → <80ms)
- [x] ~~Мониторинг: cron watchdog для перезапуска SmartDNS при падении~~ — реализовано в [`smartdns-redirect/scripts/watchdog.sh`](../smartdns-redirect/scripts/watchdog.sh) (через `WATCHDOG_SERVICE="S38smartdns"`)
- [x] ~~Интеграция SmartDNS `ipset` directive с geo-split~~ — **Отменено:** `ip rule fwmark` не работает на Keenetic, ipset-based routing невозможен. Текущий подход (1h poll + cmp) достаточен.
- [x] ~~`bind-tcp 127.0.0.1:6053` в `smartdns.conf`~~ — **Сделано (2026-05-15):** добавлен `bind-tcp` для :6053 и :6153 в smartdns.conf, smartdns-default.conf, postinst bind-addrs.conf

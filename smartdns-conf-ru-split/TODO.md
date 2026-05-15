# smartdns-conf-ru-split — TODO

**Updated:** 2026-04-16

---

## Завершено ✅

### Packaging + Init (Этап A)

- [x] `packaging/smartdns-conf-ru-split/` — control, conffiles, postinst, prerm, postrm
- [x] `scripts/build-ipk.sh` — поддержка `smartdns-conf-ru-split`
- [x] `smartdns-conf-ru-split/scripts/status.sh` — диагностика (процесс, порты, DNS-тесты)
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

### VPN-интеграция (Этап C)

- [ ] Настроить VPN (WireGuard/OpenVPN) на роутере
- [ ] Раскомментировать Mode B в `smartdns.conf`
- [ ] Протестировать DNS через VPN-туннель
- [ ] Проверить fallback при падении VPN

### Известные проблемы

- [x] ~~**conffile conflict при установке**~~ — решено: `opkg install --force-maintainer` по умолчанию (см. [deploy-workflow.md §4.6](../.project/deploy-workflow.md))
- [x] ~~**BUG-6: `restart-on-crash`**~~ — SmartDNS `execv()` fails с relative `argv[0]` при запуске через `S38`/`rc.func`. Upstream SmartDNS bug. **Mitigated (2026-05-15):** опция закомментирована в конфиге + `smartdns-redirect/scripts/watchdog.sh` перезапускает при падении через cron.

### Улучшения (backlog)

- [x] ~~DNS DNAT redirect: `iptables PREROUTING` br0:53 → SmartDNS:6053 (обход ndnproxy)~~ — реализовано в отдельном пакете [`smartdns-redirect`](../smartdns-redirect/) v0.1.1 (deployed на router-1, latency ~130ms → <80ms)
- [x] ~~Мониторинг: cron watchdog для перезапуска SmartDNS при падении~~ — реализовано в [`smartdns-redirect/scripts/watchdog.sh`](../smartdns-redirect/scripts/watchdog.sh) (через `WATCHDOG_SERVICE="S38smartdns"`)
- [x] ~~Интеграция SmartDNS `ipset` directive с geo-split~~ — **Отменено:** `ip rule fwmark` не работает на Keenetic, ipset-based routing невозможен. Текущий подход (1h poll + cmp) достаточен.
- [x] ~~`bind-tcp 127.0.0.1:6053` в `smartdns.conf`~~ — **Сделано (2026-05-15):** добавлен `bind-tcp` для :6053 и :6153 в smartdns.conf, smartdns-default.conf, postinst bind-addrs.conf

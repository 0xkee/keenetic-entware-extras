# smartdns-ru — TODO

**Updated:** 2026-04-16

---

## Завершено ✅

### Packaging + Init (Этап A)

- [x] `packaging/smartdns-ru/` — control, conffiles, postinst, prerm, postrm
- [x] `scripts/build-ipk.sh` — поддержка `smartdns-ru`
- [x] `smartdns-ru/scripts/status.sh` — диагностика (процесс, порты, DNS-тесты)
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

- [ ] **BUG-6: `restart-on-crash`** — SmartDNS `execv()` fails с relative `argv[0]` при запуске через `S38`/`rc.func`. Upstream SmartDNS bug. Workaround: опция закомментирована; при необходимости — cron watchdog.

### Улучшения (backlog)

- [x] ~~DNS DNAT redirect: `iptables PREROUTING` br0:53 → SmartDNS:6053 (обход ndnproxy)~~ — реализовано в отдельном пакете [`smartdns-redirect`](../smartdns-redirect/) v0.1.1 (deployed на router-1, latency ~130ms → <80ms)
- [x] ~~Мониторинг: cron watchdog для перезапуска SmartDNS при падении~~ — реализовано в [`smartdns-redirect/scripts/watchdog.sh`](../smartdns-redirect/scripts/watchdog.sh) (через `WATCHDOG_SERVICE="S38smartdns"`)
- [ ] Интеграция SmartDNS `ipset` directive с geo-split (вместо `dig` в `update-domains.sh`)
- [ ] Деплой на второй роутер (router-2)
- [ ] `bind-tcp 127.0.0.1:6053` в `smartdns.conf` — SmartDNS сейчас слушает только UDP, TCP-редирект в `smartdns-redirect` безвреден но бесполезен (EDNS0 fallback на больших ответах)

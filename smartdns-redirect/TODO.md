# smartdns-redirect — TODO

**Updated:** 2026-04-17

---

## Завершено ✅

### Phase 1 — Spike

- [x] `scripts/dns-redirect.sh` — минимальный DNAT (hardcoded br0, 6053, udp+tcp)
- [x] `shellcheck -x -s sh` clean
- [x] Deploy на router-1, `start`/`stop`/`status`
- [x] Validation gate: LAN-клиент query time <80ms (было ~130ms через ndnproxy)

### Phase 2 — Core

- [x] `config/smartdns-redirect.conf` — параметры (UPSTREAM_PORT, INTERFACES, ENABLE_IPV6, WATCHDOG_SERVICE, PIDFILE)
- [x] `scripts/dns-redirect.sh` v2 — source config, idempotency через `iptables -C`, `del_all_rules` (clean при смене порта/интерфейсов)
- [x] `scripts/status.sh` — диагностика (Mode / Rules / Upstream / System)
- [x] `scripts/netfilter-hook.sh` — NDM netfilter hook (устанавливается симлинком)
- [x] `rootfs/opt/etc/init.d/S39smartdns-redirect` — init wrapper + PIDFILE
- [x] Валидация: double start idempotent, reload/restart, UPSTREAM_PORT change через config, empty INTERFACES = noop
- [x] NDM hook тест: iptables flush → hook восстанавливает правила

### Phase 3 — Resilience

- [x] `scripts/watchdog.sh` — проверка (1) rules presence, (2) upstream responsiveness
- [x] IPv6 поддержка (`ENABLE_IPV6=yes` + `ip6tables`)
- [x] Multi-interface (br0 + br1 через `INTERFACES="br0 br1"`)
- [x] Recovery: missing rule → `dns-redirect.sh reload`; upstream down → `$WATCHDOG_SERVICE restart`

### Phase 4 — Packaging

- [x] `packaging/smartdns-redirect/{control, conffiles, postinst, prerm, postrm}`
- [x] `scripts/build-ipk.sh` — `build_smartdns_redirect()` + dispatcher
- [x] `.ipk v0.1.1` собирается
- [x] `opkg install` — все файлы разложены, симлинк NDM hook, cron watchdog, сервис запущен
- [x] `opkg install --force-reinstall` — conffile сохраняется
- [x] `opkg remove` — полный cleanup (init, hook, iptables, cron, pid, install dir)
- [x] **Production deploy на router-1 (0.1.1)** — LAN DNS идёт через SmartDNS :6053, latency <80ms
- [x] `smartdns-redirect/README.md` — overview, installation, configuration, troubleshooting

---

## Pending ⏳

### Phase 5 — Preserve Keenetic filter profiles (optional)

**Отложено по решению пользователя.** Подробности — [`docs/archive/smartdns-redirect-plan.md`](../docs/archive/smartdns-redirect-plan.md) раздел «Phase 5».

- [ ] `scripts/filter-profile-exclusions.sh` — парсер `show running-config` → список MAC, привязанных к filter profile
- [ ] Интеграция в `dns-redirect.sh`: при `PRESERVE_FILTER_PROFILES=yes` — ACCEPT-правила для excluded MAC ДО REDIRECT
- [ ] Обновление `status.sh` — показ excluded MAC
- [ ] Hook на изменение NDM config (или periodic re-read через watchdog)
- [ ] Документирование limitation: MAC-randomization у iOS private MAC

### Backlog (minor)

- [ ] **SmartDNS TCP on :6053** — в recon обнаружено что SmartDNS слушает только UDP. TCP-редирект в iptables безвреден но бесполезен. Либо добавить `bind-tcp 127.0.0.1:6053` в [`smartdns-ru/config/smartdns.conf`](../smartdns-ru/config/smartdns.conf), либо убрать TCP-правило из `dns-redirect.sh`. Сейчас — оставлено TCP-правило для forward-compat.
- [ ] **Deploy на router-2** — второй роутер.
- [x] ~~Uptime через pidfile~~ — поведение через PIDFILE оставлено как есть (сброс при reload — acceptable).
- [ ] **AGH / Unbound preset configs** — в `config/` добавить закомментированные примеры `UPSTREAM_PORT=5353 WATCHDOG_SERVICE=S80adguardhome` и `UPSTREAM_PORT=5335 WATCHDOG_SERVICE=S60unbound`.
- [ ] **router-2 deploy** через `opkg install`.

### Documentation

- [x] README.md (overview, install, config, usage, troubleshooting)
- [x] TODO.md (этот файл)
- [x] `.project/target-arch.md`
- [x] `.project/target-code.md`
- [x] ~~Ссылка с корневого README.md~~ — уже есть в [`README.md`](../README.md:59) (секция «Подпроекты»)
- [x] ~~Упоминание в smartdns-replacement-options.md~~ — **Сделано (2026-04-17):** [`Вариант 8`](../docs/archive/smartdns-replacement-options.md:588) получил статус-баннер «✅ РЕАЛИЗОВАНО как пакет smartdns-redirect v0.1.1»

---

## Known issues 🐛

- **NDM iptables flush снимает также и `_NDM_DNS_REDIRECT`-цепочку** — если `iptables -t nat -F PREROUTING` вызывается извне (не через NDM policy change), NDM-правила не восстанавливаются автоматически. `netfilter-hook.sh` восстанавливает только наши правила. Решение требуется только если это причиняет неудобства в реальной эксплуатации (на router-1 не наблюдалось).
- **MAC-randomization** (iOS, Android ≥10) для Phase 5 — клиент после randomization перестаёт попадать в MAC-exclusion list, filter profile перестаёт работать до обновления привязки.

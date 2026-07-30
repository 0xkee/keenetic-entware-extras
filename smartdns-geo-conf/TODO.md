# smartdns-geo-conf — TODO

**Updated:** 2026-07-28

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
- [x] ~~`force-qtype-SOA 65`~~ — **Удалено (2026-07):** блокировало HTTPS/SVCB записи (тип 65), из-за чего браузеры не могли получить ECH-параметры и Encrypted Client Hello не работал. Без этой директивы SmartDNS проксирует HTTPS-записи к upstream, Chromium/Firefox получают ech= ключ и шифруют SNI.
- [x] TTL bounds: `rr-ttl-min 60`, `rr-ttl-max 86400`
- [x] Логирование: `log-file`, `log-size 128K`, `log-num 2`
- [x] Российские .com домены (vk.com, yandex.com и др.) → ru-группа

### Деплой

- [x] Деплой на router-1 через `opkg install`
- [x] DNS-тесты: yandex.ru, google.com, github.com — работают
- [x] `status.sh` отображает корректную диагностику

### Multi-zone DNS + tunnel interfaces (Этап C, v0.5.0)

- [x] `config/config.conf` — пользовательская настройка: `DNS_ZONE`, `OTHER_DNS_INTERFACES`, `ZONE_DNS_INTERFACE`
- [x] `scripts/generate-conf.sh` — генератор `dns-servers-other.conf` + `dns-zones-active.conf`
- [x] `init.d/S37smartdns-conf` — init-скрипт (enable/disable/restart/status, генерирует при старте)
- [x] `status.sh` — выводит зону/союз, динамические DNS-тесты, JSON с `dns_tests` массивом

### Провайдеры / конфиг-генерация (v0.8.0–v0.10.0)

- [x] **Конфигурируемые international DNS** — `OTHER_DNS_PROVIDER` / `ZONE_DNS_PROVIDER`. Каталог 15 провайдеров в `dns-providers.conf`. Динамическая генерация зон из `zone-routing-rules.conf` (заменены 235 статических zone-файлов)
- [x] **`system` (Keenetic DNS) провайдер** — plain UDP из `/tmp/ndnproxymain.conf`
- [x] **Custom DNS providers** (`dns-providers-custom.conf`) — сохраняются при обновлении, видны в WebUI
- [x] WebUI: `ZONE_DNS_STRICT`, `OTHER_DNS_STRICT` toggles; `ENABLE_IPV6` из redirect удалён

### Жизненный цикл сервиса (v0.11.0–v0.13.0)

- [x] ~~**Strict tunnel mode** (`OTHER_DNS_STRICT`, `ZONE_DNS_STRICT`)~~ — **Удалено (v0.13.0, 2026-07-29):** заменено на iptables enforcement в smartdns-redirect (`DNS_STRICT`). Поведение "tunnel-only" теперь встроено: если `OTHER_DNS_INTERFACES` задан → direct fallback не генерируется.
- [x] **Disable = full shutdown**: `S37 disable` переименовывает S38, останавливает smartdns-redirect, DNS reverting to system
- [x] **`do_bind_addrs()`** — авто-детект IPv6, генерация bind-addrs.conf при каждом restart

### Известные проблемы (решены)

- [x] ~~**conffile conflict при установке**~~ — решено: `opkg install --force-maintainer` по умолчанию
- [x] ~~**BUG-6: `restart-on-crash`**~~ — SmartDNS `execv()` fails с relative `argv[0]` при запуске через `S38`/`rc.func`. **Mitigated (2026-05-15):** опция закомментирована + `smartdns-redirect/scripts/watchdog.sh` перезапускает при падении через cron
- [x] ~~**`smartdns-default.conf` (мёртвый код)**~~ — **Удалено (2026-07):** при `disable` SmartDNS полностью останавливается, default-конфиг никогда не активировался
- [x] ~~**checker bug когда сервис выключен**~~ — **Исправлено (v0.11.1, 2026-07-27):** dns_tests пропускаются, uptime/pid сбрасываются, checks возвращают `"skip"` вместо `"fail"`
- [x] ~~**dns-check.sh не работал когда SmartDNS выключен**~~ — **Исправлено (v0.11.4, 2026-07-28):** авто-детект порта через `/proc/net/tcp` (`:6053` → `:53` fallback). `SMARTDNS_PORT` override сохранён.
- [x] ~~**dns-check.sh вычислял DNS-пути из конфига, а не проверял по факту**~~ — **Реализовано (v0.11.4, 2026-07-28):** новое поле `"verified"` — прямой UDP probe к upstream ожидаемой группы, сравнение с ответом SmartDNS. `get_probe_ip()` helper. JSON: `"verified":true/false/null`. Text: `Verified: ✓/✗`.

### Архитектурные решения (intentional)

- **`log-file /tmp/smartdns.log`** — осознанный выбор. `/tmp` достаточно для операционных логов (level=error → пишет редко). Персистентные логи не нужны: при проблемах диагностику делают онлайн. Не менять.
- **Автосброс кэша при смене конфига не реализован** — решено через UX: кнопка "Очистить кэш DNS" в WebUI (`S37 flush-cache`). Автоматический сброс при каждом `enable/restart` замедлял бы cold start без необходимости.

---

## Backlog ⏳

- [x] **`DNS_TRANSPORT` — глобальная политика шифрования upstream DNS (auto / strict).** (2026-07-30)
  - `auto` (default) — DoT/DoH preferred, UDP fallback для zone-провайдеров с `UDP_FALLBACK=yes` (Yandex, AliDNS). Текущее поведение.
  - `strict` — только DoT/DoH, **без UDP fallback** для всех провайдеров. ISP не видит DNS-запросы ни для zone, ни для international группы.
  Реализация: 1 строка в `generate-conf.sh` (условие на `DNS_TRANSPORT`), параметр в `defaults.conf`, поле в `config-editor.js` + `api-router.lua`.
- [ ] **Персистентный кэш SmartDNS — возможный источник плавающих поломок DNS.** При смене конфига DNS может ломаться из-за устаревших записей. **Действия:** (a) добавить в user-manual рекомендацию удалить файл кэша (`/opt/var/cache/smartdns.cache`) при проблемах после смены конфига; (b) рассмотреть автоочистку в `generate-conf.sh` при смене провайдера; (c) задокументировать расположение файла кэша в troubleshooting. (источник: nikolay1980, 2026-07-12)
- [ ] **Exclude-список для DNS-роутинга** — файл `config/dns-zone-exclude.conf` с правилами (`nameserver /specific-host.ru/default`), include в конец zone-конфига. Документировать в user-manual. По запросу.
- [ ] **dns-check.sh: bootstrap resolution marker** — для DoH провайдеров без IP1/IP2 добавить `"resolution": "bootstrap"` маркер в JSON-вывод `get_upstream_info()`, чтобы WebUI-диаграмма визуально отличала bootstrap-resolved от IP-pinned путей. Косметика.
- [ ] **FAQ: ECS не передаётся** — добавить в user-manual пояснение что SmartDNS не отправляет EDNS Client Subnet upstream-серверам. (источник: cryoPanda)
- [x] **Удалён `SMARTDNS_PORT` из UI** (`config-editor.js` + `api-router.lua`). (2026-07-30) Параметр в скриптах/defaults.conf остаётся. Default `0` = auto-detect.

## Someday / Maybe 🔮

- [ ] **Нужен ли `ndmc -c 'ip name-server <IP>:6053'` при наличии smartdns-redirect?** DNAT покрывает LAN, но DNS-запросы самого роутера (loopback→ndnproxy) проходят без DNAT. Разобрать три сценария: (a) только smartdns-redirect, (b) только ip name-server, (c) оба.

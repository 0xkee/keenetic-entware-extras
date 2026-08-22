# Глубокое сравнение: keenetic-entware-extras vs keen-pbr

**Дата обновления**: 2026-08-22  
**keen-pbr**: v3.3.0 stable ([maksimkurb/keen-pbr](https://github.com/maksimkurb/keen-pbr))  
**keenetic-entware-extras**: v0.12.x (экосистема из 6 пакетов)

---

## 1. Обзор проектов

| | **keenetic-entware-extras** | **keen-pbr** |
|---|---|---|
| **Назначение** | GEO-маршрутизация + DNS split + DNS redirect + WebUI | Universal policy-based routing daemon |
| **Архитектура** | 6 .ipk пакетов с shared libs | Единый C++ демон + TypeScript WebUI |
| **Язык (back-end)** | POSIX sh (~2800 строк) + Lua API (~540) | C++ (~57% кодовой базы) |
| **Язык (front-end)** | JS/HTML/CSS (~1800 строк, vanilla) | TypeScript (~32% кодовой базы) |
| **Тесты** | shellcheck | ~60 C++ unit tests + integration (QEMU VM + container topology) |
| **Конфиг** | shell vars (defaults.conf + config.conf per-package) | JSON (config.json) |
| **Платформа** | Keenetic + Entware | Keenetic + OpenWrt + Debian |
| **Лицензия** | MIT | GPL-3.0 |
| **Сообщество** | 1 автор | 3+ contributors, 122+ stars, Telegram, Ko-fi, CloudTips, GitHub Sponsors |
| **CI/CD** | Makefile (build/lint/release) | GitHub Actions (multi-arch build) |
| **opkg-репо** | нет (ручная сборка .ipk) | ✅ Собственный: repo.keen-pbr.fyi |
| **Документация** | Markdown docs в репо | ✅ keen-pbr.fyi (Hugo сайт, EN/RU) |
| **WebUI** | ✅ Nginx+Lua дашборд + stock injection | ✅ TypeScript SPA (встроен в бинарник) |
| **Headless вариант** | — | ✅ `keen-pbr-headless` (~1.2 MB без WebUI/API) |
| **REST API** | ✅ (nginx-lua, per-service) | ✅ (C++ HTTP server, :12121, Argon2id auth) |
| **DNS управление** | ✅ SmartDNS split-DNS + DNS redirect | ✅ DNS rules + `type: keenetic` (DoH/DoT!) + dnsmasq ipset |
| **Keenetic NDM** | ✅ ndmc CLI для interface labels | ✅ RCI HTTP API для interface health |
| **Brand support** | — | ✅ Keenetic + NetCraze |

### Состав экосистемы keenetic-entware-extras

| Пакет | Версия | Назначение |
|--------|--------|------------|
| `keenetic-entware-extras` | 0.12.1 | Базовый: shared libs (`common.sh`, `ip.sh`, `lists.sh`, `status.sh`) + `kee-status` CLI |
| `geo-split` | 0.12.5 | GEO route-based маршрутизация (dual tables: domains + subnets) |
| `geo-split-data` | 0.4.0 | Курированные данные: 140+ RU доменов, GeoIP зоны (EAEU: RU/BY/KZ/AM/KG) |
| `smartdns-geo-conf` | 0.4.4 | Split-DNS: .ru/.рф/.su → Yandex/AdGuard DoT; * → Google/CF DoH |
| `smartdns-redirect` | 0.3.1 | DNS DNAT: LAN :53 → SmartDNS :6053 (iptables nat REDIRECT, не mangle!) |
| `webui` | 0.17.0 | Nginx+Lua дашборд на :8080, REST API, config editor, stock Keenetic sidebar |

---

## 2. Архитектура маршрутизации (ФУНДАМЕНТАЛЬНОЕ отличие)

### keenetic-entware-extras: route-based (без fwmark)

```
ip rule add iif br0 table 1000 priority 50   # domains (/32 host routes)
ip rule add iif br0 table 1001 priority 51   # subnets (GeoIP CIDRs)
ip route add 8.8.8.8/32 via 176.65.44.1 dev eth3 table 1000       # domain route
ip route add 185.73.192.0/22 via 176.65.44.1 dev eth3 table 1001  # subnet route × 8K
```

**Механизм**: Dual-table per-subnet маршруты. Table 1000 (priority 50) — /32 host routes из DNS-resolution. Table 1001 (priority 51) — GeoIP CIDRs. Весь LAN-трафик (iif br0) проверяется сначала по table 1000, затем 1001.

**Плюсы**:
- ✅ **Полная совместимость с Keenetic NDM per-device routing** — `skb->mark` не затронут
- ✅ HW NAT сохранён (throughput не деградирует)
- ✅ Нет зависимости от iptables mangle/raw
- ✅ Gateway auto-detect (Ethernet ISP `via <gw>`, LTE/PPP dev-only)

**Минусы**:
- ❌ ~8K маршрутов в kernel route table (после CIDR aggregation, was 13K)
- ❌ Нет per-domain routing в реальном времени (обновление раз в час)
- ❌ Невозможно маршрутизировать per-source IP (только per-interface: `iif`)

### keen-pbr: fwmark-based (iptables mangle/raw / nftables)

```
# Режим mangle (по умолчанию):
iptables -t mangle -A PREROUTING -m set --match-set kpbr0 dst -j MARK --set-mark 0x00010000
# Режим RAW PREROUTING (Keenetic-specific, v3.1+):
iptables -t raw -A PREROUTING -m set --match-set kpbr0 dst -j MARK --set-mark 0x00010000
ip rule add fwmark 0x00010000/0x00FF0000 table 150
ip route add default dev nwg0 table 150
```

**Механизм**: IP/домены → ipset/nftables sets → fwmark → ip rule → custom table с default route.

**RAW PREROUTING** (v3.1+, Keenetic-specific): использует `iptable_raw` вместо mangle, чтобы пережить **NDM mangle rebuilds**. Keenetic NDM периодически перестраивает таблицу mangle, удаляя сторонние правила. Режимы: `auto` (default), `enable`, `disable`, `ipv4-only`, `ipv6-only`.

**Плюсы**:
- ✅ Только 1 default route в таблице (не 8K per-subnet routes)
- ✅ Мгновенный domain routing через dnsmasq ipset
- ✅ **6 outbound типов**: `interface`, `table`, `blackhole`, `ignore`, `urltest`, `icmptest`
- ✅ Kill switch (blackhole outbound)
- ✅ Health checks + failover chains (urltest, icmptest)
- ✅ `skip_marked_packets: true` — пропускает пакеты с чужими marks
- ✅ **RAW PREROUTING** — выживает NDM mangle rebuilds (v3.1+)
- ✅ **Circuit breaker** в urltest (closed → open → half_open)
- ✅ `ignore` outbound — pass-through/exception правила

**Минусы**:
- ❌ fwmark **всё равно** конфликтует с Keenetic NDM per-device routing (хотя `skip_marked_packets` уменьшает проблему)
- ❌ RAW PREROUTING vs mangle — trade-off: RAW выживает NDM mangle rebuilds, но **Keenetic Connection Policies перезаписывают fwmark**; mangle — наоборот
- ❌ Требует отключения HW NAT
- ❌ Зависимость от iptables/nftables kernel modules
- ❌ Устройства должны быть в «Политике доступа по умолчанию» (подтверждено в keen-pbr docs)

### Использование iptables: принципиальная разница

| | **keenetic-entware-extras** | **keen-pbr** |
|---|---|---|
| **iptables таблица** | `nat` (PREROUTING REDIRECT — только DNS) | `mangle` или `raw` (PREROUTING MARK — весь routing) |
| **RAW PREROUTING** | — | ✅ v3.1+ (Keenetic-specific, выживает NDM mangle rebuilds) |
| **Цель** | DNS redirect :53 → SmartDNS :6053 | Routing decision (fwmark → table) |
| **Трогает skb->mark?** | ❌ Нет — REDIRECT не меняет mark | ✅ Да — `--set-mark` перезаписывает mark |
| **Firewall backend** | iptables nat only | auto: nftables, iptables, или без (config) |
| **Влияние на HW NAT** | ❌ Нет | ✅ Отключает |

---

## 3. DNS pipeline

### keenetic-entware-extras: полный DNS-стек (3 пакета)

```
LAN client → :53 → [smartdns-redirect: iptables nat REDIRECT] → SmartDNS :6053
SmartDNS:
  .ru/.рф/.su → Yandex DoT (77.88.8.8:853) + AdGuard DoT
  *           → Google DoH + Cloudflare DoH
  port :6153  → no-speed-check (для geo-split update-domains.sh)
```

**Преимущества**:
- DoT/DoH шифрование DNS-запросов (защита от DPI)
- Split по доменным зонам (.ru→российские DNS для правильной CDN геолокации)
- Полная резолюция (max 16 A-records для каждого домена)
- Не подменяет dnsmasq — безопаснее
- Cache 20K + serve-expired + prefetch
- Watchdog cron (проверка здоровья upstream DNS + iptables правил)
- NDM netfilter hook (автовосстановление правил после iptables flush)

### keen-pbr v3.3.0: DNS rules + `type: keenetic` + dnsmasq ipset

```json
"dns": {
  "servers": [
    { "tag": "keenetic", "type": "keenetic" },
    { "tag": "quad9", "address": "9.9.9.9", "detour": "vpn_outbound" },
    { "tag": "google", "address": "8.8.8.8" }
  ],
  "rules": [
    { "list": "ru_domains", "server": "keenetic" },
    { "list": "vpn_domains", "server": "quad9" }
  ],
  "fallback": ["keenetic", "google"],
  "allow_domain_rebinding": false
}
```

keen-pbr v3.3.0 имеет **полноценный DNS pipeline** — значительное развитие по сравнению с v3.0.6:

- **`type: keenetic`** — переиспользует встроенные DNS роутера, **включая DoH/DoT**, если настроены на уровне Keenetic! Это означает, что keen-pbr **может** использовать шифрованный DNS через роутерный resolver
- **DNS rules** — маппинг списков доменов на конкретные DNS-серверы (аналог split-DNS kee, но через dnsmasq)
- **`detour`** — DNS-запросы маршрутизируются через конкретный outbound (важно для VPN DNS, который недоступен напрямую)
- **`fallback`** — упорядоченные DNS-серверы для немэтченных запросов
- **`allow_domain_rebinding`** — разрешить приватные IP в ответах (для внутренних доменов, корпоративных VPN)
- DNS test server (для health checks)

**Ограничения keen-pbr DNS**:
- DNS rules работают через dnsmasq — на уровне dnsmasq нет DoT/DoH (шифрование только через `type: keenetic` + DoH/DoT на роутере)
- Подменяет `/opt/etc/dnsmasq.conf`
- `type: keenetic` зависит от настроек роутера — если DoH/DoT не включён на Keenetic, DNS остаётся plain
- Нет собственного DNS cache/prefetch (полагается на dnsmasq)
- Документация keen-pbr теперь **рекомендует** настроить DoH/DoT на уровне роутера

### Сравнение DNS pipeline

| | **keenetic-entware-extras** | **keen-pbr v3.3.0** |
|---|---|---|
| **Domain → route** | dig → /32 routes (hourly) | dnsmasq ipset (real-time) |
| **Скорость подхвата** | ~1 час | Мгновенно |
| **DNS шифрование** | ✅ DoT/DoH (SmartDNS, собственный стек) | ⚠️ Через `type: keenetic` (зависит от настроек роутера) |
| **Split-DNS по зонам** | ✅ .ru→Yandex, *→Google/CF | ✅ DNS rules (list→server маппинг) |
| **DNS detour** | — | ✅ DNS через конкретный outbound |
| **DNS fallback** | ✅ (SmartDNS upstream groups) | ✅ Упорядоченный fallback |
| **CDN геолокация** | ✅ Корректная (собственный split) | ⚠️ Зависит от конфигурации DNS rules |
| **Подменяет dnsmasq** | ❌ Нет | ✅ Да |
| **Private IP filtering** | ✅ | ⚠️ `allow_domain_rebinding` (opt-in) |
| **DNS health check** | ✅ Watchdog cron | ✅ DNS test server + SSE stream |
| **Cache/Prefetch** | ✅ SmartDNS 20K + serve-expired | ❌ dnsmasq стандартный |

---

## 4. Поддержка GEO маршрутизации

### keenetic-entware-extras: нативная GEO-специализация

```sh
SUBNET_URL="https://www.ipdeny.com/ipblocks/data/countries/ru.zone"
SUBNET_LOADER="cidr-plain"     # или ripe-json
SUBNET_AGGREGATE=1             # 13K → 8K после merge overlapping
```

- **Нативная GEO-задача**: специально построен для маршрутизации целых страновых зон
- Pluggable loaders (cidr-plain, ripe-json)
- CIDR aggregation (merge adjacent/overlapping → меньше маршрутов)
- Multi-interface download failover с retries
- Курированные данные: EAEU зоны (RU/BY/KZ/AM/KG) в пакете `geo-split-data`
- 140+ RU доменов с geoblocking в whitelist

### keen-pbr: GEO через universal list mechanism

```json
"lists": {
  "ru_geo": {
    "url": "https://www.ipdeny.com/ipblocks/data/countries/ru.zone",
    "file": "/opt/etc/keen-pbr/custom-lists/local.zone",
    "ip_cidrs": [],
    "detour": "vpn_outbound",
    "max_file_size_bytes": 8388608,
    "ttl_ms": 86400000
  }
},
"lists_autoupdate": {
  "enabled": true,
  "cron": "0 4 * * 0"
}
```

keen-pbr v3.3.0 развил механизм списков:
- Загрузка CIDR-списков по URL
- **`file`** — локальный файл как источник (можно комбинировать с `url`)
- **`detour`** — загрузка remote списков через конкретный outbound (аналог multi-interface download kee: если основной канал заблокирован, можно скачать через VPN)
- **`If-Modified-Since`/`ETag`** — smart caching для remote lists (не перекачивает, если не изменился)
- **`max_file_size_bytes`** — лимит 8 MiB
- **`ttl_ms`** — TTL для dynamic DNS entries (default 24h)
- Автообновление по cron (еженедельно по умолчанию)

**Но**: keen-pbr не специализирован на GEO — нет CIDR aggregation, нет size validation (≥100 строк), нет pluggable loaders. Это **generic list mechanism**, который подходит для GEO, но без оптимизаций для больших (10K+) наборов.

---

## 5. WebUI и управление

### keenetic-entware-extras: WebUI (nginx + Lua)

- **Технология**: Nginx + nginx-mod-lua + vanilla JS/CSS/HTML
- **Порт**: :8080 (конфигурируемый)
- **Эндпоинты**: `/api/<service>/status|config|start|stop`
- **Config editor**: per-service, save + auto-restart
- **Dashboard**: status cards, system info (CPU/RAM/disk), auto-polling 30s
- **Stock Keenetic injection**: inject.js добавляет sidebar секцию в stock router UI
- **NDM integration**: `ndmc -c "show interface"` для human-readable interface labels
- **Архитектура**: external nginx процесс, Lua скрипты запускают shell status.sh

### keen-pbr v3.3.0: WebUI (встроенный в daemon)

- **Технология**: C++ HTTP server + TypeScript SPA (встроен в бинарник)
- **Порт**: :12121 (по умолчанию на localhost)
- **Headless**: `keen-pbr-headless` пакет (~1.2 MB) без WebUI/API (vs ~2.8 MB полный)
- **Authentication**: Argon2id пароли, Basic auth, Bearer tokens (24h session)
- **CORS**: конфигурируемый
- **`device_name`**: отображается в browser title (удобно при нескольких роутерах)
- **Config staging**: draft → save → apply workflow (конфиг не применяется сразу, можно проверить)
- **DNS test widget**: SSE stream DNS queries (`GET /api/dns/test`)
- **Routing test widget**: проверка routing для IP/домена (`POST /api/routing/test`)
- **Health dashboard**: live outbound state, latency, circuit breaker (`GET /api/runtime/outbounds`)
- **i18n**: интернационализация (EN + RU)
- **Архитектура**: single-process daemon, WebUI served from embedded assets

### Сравнение WebUI

| | **keenetic-entware-extras** | **keen-pbr v3.3.0** |
|---|---|---|
| **Технология** | Nginx + Lua + vanilla JS | C++ server + TypeScript SPA |
| **Интеграция** | Внешний процесс (nginx) | Встроен в daemon |
| **Stock Keenetic injection** | ✅ inject.js в sidebar | ❌ Отдельная страница |
| **Config editor** | ✅ Per-service | ✅ Полный конфиг + config staging |
| **Authentication** | ❌ | ✅ Argon2id + Bearer tokens |
| **Routing test** | ❌ | ✅ Widget + API |
| **DNS test** | ❌ | ✅ SSE stream widget |
| **System info (CPU/RAM/Disk)** | ✅ | Неизвестно |
| **Service start/stop** | ✅ Per-package enable/disable | ✅ |
| **i18n** | ❌ (только RU) | ✅ (EN + RU) |
| **Headless вариант** | — | ✅ keen-pbr-headless (~1.2 MB) |
| **Размер frontend** | ~1800 строк (vanilla) | TypeScript (~32% кодовой базы) |
| **Bundled** | Отдельный .ipk (webui) | Встроен в бинарник |

---

## 6. Интеграция с Keenetic

| | **keenetic-entware-extras** | **keen-pbr v3.3.0** |
|---|---|---|
| **NDM ifstatechanged** | ✅ `ndm-hook.sh` (debounce + parallel refill) | ✅ hook (routing re-apply) |
| **NDM netfilter** | ✅ `netfilter-hook.sh` (DNS rule recovery) | ✅ hook (fwmark re-apply) |
| **RAW PREROUTING** | — | ✅ Выживает NDM mangle rebuilds (v3.1+) |
| **Keenetic NDM CLI** | ✅ `ndmc -c "show interface"` (WebUI labels) | — |
| **Keenetic RCI HTTP API** | — | ✅ `localhost:79/rci/` (interface health) |
| **dns-override** | — | ✅ Интеграция с Keenetic DNS settings |
| **Interface failover** | ✅ NDM hook auto-mode + re-attach | ✅ Health checks + failover chains |
| **HW NAT** | ✅ Не трогает | ❌ Отключает |
| **skip_marked_packets** | — (не нужно, нет marks) | ✅ Уменьшает конфликт с NDM |
| **Connection Policies** | ✅ Полная совместимость | ⚠️ Connection Policies перезаписывают fwmark (RAW mode) |
| **`src_addr` routing** | ❌ (только `iif`) | ✅ Альтернатива Connection Policies |
| **Stock UI injection** | ✅ sidebar group | ❌ |
| **OpenWrt support** | ❌ Только Keenetic/Entware | ✅ |
| **Debian support** | ❌ | ✅ |
| **NetCraze support** | ❌ | ✅ |

**Важно**: оба проекта используют Keenetic NDM для интеграции, но по-разному:
- **kee** использует `ndmc` CLI (получение interface descriptions для WebUI display)
- **keen-pbr** использует RCI HTTP API `localhost:79/rci/` (получение interface state/health для routing decisions)

**RAW vs mangle trade-off в keen-pbr v3.1+**:
- **RAW PREROUTING**: выживает NDM mangle rebuilds, но Keenetic **Connection Policies перезаписывают fwmark** → устройства с явной политикой проигнорируют keen-pbr routing
- **mangle PREROUTING**: не выживает NDM rebuilds (правила удаляются), но Connection Policies не конфликтуют напрямую
- keen-pbr предлагает `src_addr` правила как альтернативу Connection Policies (per-device routing через config вместо Keenetic UI)

---

## 7. Data pipeline и надёжность

### keenetic-entware-extras

```
[cron 15min — smart cache check]
  → update-subnets.sh:
    - multi-interface failover (DOWNLOAD_INTERFACES: "default *")
    - retry per interface (DOWNLOAD_RETRIES=2, DOWNLOAD_RETRY_DELAY=3s)
    - size validation (≥100 lines = reject if too small)
    - CIDR aggregation: 13K → 8K (via `aggregate` tool)
    - last-iface cache (priority on next run)
  → update-domains.sh:
    - DNS auto-detect (SmartDNS :6153 → :6053 → system)
    - dig all A-records (up to 16 per domain)
    - private IP filtering (10.x, 172.x, 192.168.x)
    - diff check (skip route update if IPs unchanged)
    - deduplication by IP
[S99geo-split start]
  → parallel: update-subnets.sh & update-domains.sh & wait
  → attach-rules.sh → ip rule iif br0 table 1000,1001
```

### keen-pbr v3.3.0

```
[daemon startup]
  → keen-pbr apply: parse config → ipset restore → fwmark rules
  → health checks: periodic urltest/icmptest + interface UP verification
  → failover: circuit breaker (closed → open → half_open) → switch outbound
  → conntrack_on_switch: preserve (default) или delete entries
[lists_autoupdate cron "0 4 * * 0"]
  → download lists by URL:
    - If-Modified-Since/ETag smart caching
    - list.detour: загрузка через конкретный outbound
    - max_file_size_bytes: 8 MiB лимит
  → SIGHUP: hot reload config
  → SIGUSR1: reload lists
  → download --reload: загрузка + применение (CLI)
[dnsmasq integration]
  → real-time: DNS query → ipset → routing (immediate)
```

### Сравнение надёжности

| | **keenetic-entware-extras** | **keen-pbr v3.3.0** |
|---|---|---|
| **Download failover** | ✅ Multi-interface с retries | ✅ `list.detour` (через конкретный outbound) |
| **Smart caching** | ✅ diff check (skip if unchanged) | ✅ `If-Modified-Since`/`ETag` |
| **Size validation** | ✅ (≥100 lines reject) | ⚠️ `max_file_size_bytes` (верхний лимит, не нижний) |
| **Data aggregation** | ✅ CIDR merge (reduces count) | ❌ Нет |
| **Health checks** | ✅ Watchdog (DNS + iptables) | ✅ urltest + icmptest + circuit breaker |
| **Interface failover (routing)** | ✅ NDM hook re-attach | ✅ Health check → switch outbound |
| **Outbound failover chains** | ❌ (single target) | ✅ Configurable chains |
| **Circuit breaker** | ❌ | ✅ (failure_threshold, success_threshold, timeout_ms, half_open) |
| **Kill switch** | ❌ | ✅ Blackhole outbound |
| **strict_enforcement** | ❌ | ✅ `unreachable` или `blackhole` (global + per-outbound override) |
| **Conntrack on switch** | — | ✅ `preserve` или `delete` |
| **Hot reload** | ✅ `refresh` command (no ip rule re-attach) | ✅ SIGHUP + SIGUSR1 + API reload |
| **PID lock** | ✅ (prevent parallel runs) | ✅ (daemon single instance) |

---

## 8. Что есть в keen-pbr, чего нет в kee

| Фича | Значимость |
|-------|:---:|
| **Real-time domain routing** (dnsmasq ipset) | 🔴 Высокая |
| **RAW PREROUTING** (переживает NDM mangle rebuilds) | 🔴 Высокая |
| **DNS rules** (split-DNS через dnsmasq, list→server маппинг) | 🔴 Высокая |
| **`type: keenetic` DNS** (переиспользует роутерный DoH/DoT) | 🟡 Средняя |
| **Kill switch** (blackhole outbound) | 🟡 Средняя |
| **Failover chains** (automatic outbound switch + circuit breaker) | 🟡 Средняя |
| **DSCP matching** (per-application routing через DSCP tags) | 🟡 Средняя |
| **Port/Address filtering** (src_port, dest_port, src_addr, dest_addr, negation) | 🟡 Средняя |
| **`ignore` outbound** (pass-through/exception правила) | 🟡 Средняя |
| **`icmptest` outbound** (ICMP Echo probing для failover) | 🟡 Средняя |
| **`inbound_interfaces`** (per-rule interface filter) | 🟡 Средняя |
| **IPv6 routing** (toggleable) | 🟡 Средняя |
| **Multi-outbound** (разные списки → разные VPN) | 🟡 Средняя |
| **Health checks** (urltest + icmptest + circuit breaker) | 🟡 Средняя |
| **`test-routing` CLI** (expected vs actual routing check) | 🟡 Средняя |
| **Authentication** (Argon2id, Bearer tokens) | 🟡 Средняя |
| **Config staging** (draft → save → apply) | 🟡 Средняя |
| **`list.detour`** (загрузка списков через конкретный outbound) | 🟡 Средняя |
| **`allow_domain_rebinding`** (приватные IP в DNS ответах) | 🟢 Малая |
| **Rules без `list`** (match по dscp, src_addr, dest_port) | 🟢 Малая |
| **`enabled` field** (disable rules без удаления) | 🟢 Малая |
| **OpenWrt/Debian support** | 🟢 Малая (другой use case) |
| **i18n** (EN + RU) | 🟢 Малая |
| **Headless variant** (~1.2 MB без WebUI) | 🟢 Малая |
| **strict_enforcement** (unreachable/blackhole + per-outbound) | 🟢 Малая |
| **DNS detour** (DNS через конкретный outbound) | 🟢 Малая |
| **Protocol matching** (tcp, udp, tcp/udp) | 🟢 Малая |

---

## 9. Что есть в kee, чего нет в keen-pbr

| Фича | Категория |
|-------|--|
| **fwmark-free routing** (NDM per-device совместимость) | Архитектура |
| **HW NAT сохранён** | Performance |
| **Полный собственный DNS-стек** (SmartDNS + split-DNS + redirect) | DNS |
| **Гарантированный DoT/DoH** (собственный стек, не зависит от настроек роутера) | Безопасность |
| **Correct CDN geolocation** (split resolves через региональные DNS) | DNS |
| **Stock Keenetic sidebar injection** | UX |
| **CIDR aggregation** (13K → 8K, reduces memory) | Performance |
| **Download size validation** (reject corrupted, ≥100 lines) | Надёжность |
| **Pluggable loaders** (cidr-plain, ripe-json, custom) | Модульность |
| **Multi-country GeoIP zones** (EAEU: RU/BY/KZ/AM/KG) | Данные |
| **Curated domain whitelist** (140+ RU domains) | Данные |
| **Private IP filtering** in domain resolution | Correctness |
| **DNS watchdog** (upstream health + iptables recovery) | Reliability |
| **NDM netfilter hook** (DNS rule auto-recovery) | Reliability |
| **Diff check** (skip route update if IPs unchanged) | Efficiency |
| **ip-full -batch** (8K routes за ~1 сек) | Performance |
| **Parallel execution** (subnets + domains simultaneously) | Performance |
| **FIB trie stats** (instant route count, zero-cost status) | Performance |
| **bug-report.sh** (safe diagnostics for forums) | Operations |
| **Aggregated kee-status CLI** (all packages at once) | Operations |
| **Enable/Disable persistent state** (hooks respect) | UX |
| **Modular packages** (install only what you need) | Architecture |
| **Zero binary footprint** (all interpreted scripts) | Resources |
| **SmartDNS cache** (20K + serve-expired + prefetch) | Performance |

> **Примечание**: в v3.0.6 keen-pbr не имел DoH/DoT и download failover. В v3.3.0 эти gaps частично закрыты: `type: keenetic` позволяет использовать DoH/DoT роутера (но не собственный стек), `list.detour` обеспечивает download через альтернативный outbound (но не multi-interface retry с fallback).

---

## 10. Количественное сравнение

| Метрика | **keenetic-entware-extras** | **keen-pbr v3.3.0** |
|---------|:-:|:-:|
| Версия | v0.12.x | v3.3.0 (stable) |
| Packages | 6 .ipk | 1 .ipk (+ headless вариант) |
| Backend language | POSIX sh + Lua | C++ |
| Frontend language | Vanilla JS/HTML/CSS | TypeScript |
| Config format | Shell vars | JSON |
| Binary size | 0 (scripts) | ~2.8 MB (full) / ~1.2 MB (headless) |
| Runtime deps | ip-full, curl, dig, aggregate, SmartDNS, nginx, iptables | iptables/nftables, dnsmasq |
| NDM hooks | 2 (ifstatechanged + netfilter) | 2 (ifstatechanged + netfilter) |
| Cron jobs | 2 (geo-split */15, watchdog */5) | 1 (lists autoupdate weekly) |
| Route table entries | ~8K (aggregated CIDRs) + ~300 (/32 domains) | 1 default route per outbound |
| Cold start (from cache) | ~1-2 сек (ip -batch parallel) | ~мгновенно (ipset restore) |
| DNS security | DoT/DoH (SmartDNS, собственный стек) | ⚠️ Через `type: keenetic` (зависит от настроек роутера) |
| Outbound types | 1 (interface) | 6 (interface, table, blackhole, ignore, urltest, icmptest) |
| Tests | shellcheck | ~60 C++ unit + integration (QEMU VM + container) |
| Stars on GitHub | — (private repo) | 122+ |
| License | MIT | GPL-3.0 |
| Platforms | Keenetic/Entware | Keenetic + OpenWrt + Debian |
| opkg repository | нет | ✅ repo.keen-pbr.fyi |
| Documentation site | нет | ✅ keen-pbr.fyi (Hugo, EN/RU) |

---

## 11. Ключевые архитектурные решения

### Почему kee не использует fwmark

Keenetic NDM использует `skb->mark` для per-device routing. keen-pbr конфликтует с этим:
- `iptables mangle/raw MARK` перезаписывает тот же mark
- `skip_marked_packets: true` в keen-pbr v3 уменьшает проблему (пропускает пакеты с чужими marks), но **не решает** её полностью — mark для keen-pbr всё равно затрагивает пакеты из "default policy"
- Устройства **должны быть** в «Политике доступа по умолчанию» (документировано в keen-pbr docs)
- HW NAT всё равно отключается

keenetic-entware-extras использует `ip rule iif br0` + per-subnet routes → **mark не затронут**, per-device routing Keenetic работает полностью.

### RAW vs mangle trade-off (keen-pbr v3.1+)

keen-pbr v3.1 представил RAW PREROUTING — **Keenetic-specific** решение, использующее `iptable_raw` вместо `iptable_mangle`:

| | **RAW PREROUTING** | **mangle PREROUTING** |
|---|---|---|
| **NDM mangle rebuilds** | ✅ Выживает | ❌ Правила удаляются |
| **Connection Policies** | ❌ Перезаписывают fwmark | ✅ Не конфликтуют |
| **Рекомендация** | `auto` (default) — включён при наличии `iptable_raw` | Fallback при отсутствии raw |

Это **неразрешимый trade-off**: RAW решает одну проблему Keenetic (mangle rebuilds), но создаёт другую (Connection Policies conflict). keen-pbr предлагает `src_addr` правила как альтернативу Connection Policies.

kee **не имеет** ни одной из этих проблем — route-based подход не зависит от iptables таблиц.

### Почему keen-pbr использует fwmark

fwmark позволяет:
- 1 default route vs 8K per-subnet маршрутов (экономия памяти)
- ipset match для real-time domain routing
- Множество outbounds с разными правилами
- Health checks + automatic failover
- 6 типов outbound (interface, table, blackhole, ignore, urltest, icmptest)

В v3.3.0 добавлены `skip_marked_packets`, configurable fwmark mask (`0x00FF0000`), RAW PREROUTING и `ignore` outbound для уменьшения конфликтов.

### Почему kee — модульная экосистема из 6 пакетов

1. **Независимые update циклы** — WebUI v0.17 не требует пересборки geo-split
2. **Опциональность** — можно ставить только geo-split без DNS стека
3. **Zero binaries** — нет 2-4 MB native бинарника, нет cross-compilation
4. **Shared libs** — нет дублирования (common.sh, ip.sh, lists.sh, status.sh)
5. **Отсутствие Go/C++ build chain** — shell scripts работают на любой arch без сборки

### Почему keen-pbr перешёл с Go на C++

keen-pbr v2.x был на Go, v3.x переписан на C++:
1. Размер бинарника: Go ~6-8 MB → C++ ~2.8 MB (critical для роутеров с 128MB flash)
2. Daemon mode: C++ daemon с event loop эффективнее Go process
3. WebUI: embedded compiled TypeScript assets в бинарник (Go использовал отдельный React)
4. Performance: C++ на embedded (MIPS/ARM) быстрее Go runtime
5. nftables support: C++ проще интегрируется с netfilter через libmnl/libnftnl
6. Headless variant: `keen-pbr-headless` ~1.2 MB без WebUI/API

---

## 12. Заключение

**keen-pbr v3.3.0** и **keenetic-entware-extras** — это **разные парадигмы**, каждая со своими объективными преимуществами:

| | **keen-pbr v3.3.0** | **keenetic-entware-extras** |
|---|---|---|
| **Парадигма** | Universal PBR daemon (все задачи) | Specialized GEO routing + DNS ecosystem |
| **Маршрутизация** | fwmark + ipset (1 route per outbound) | route-based (8K per-subnet routes) |
| **iptables таблица** | mangle или raw (выбор) | nat only (DNS redirect) |
| **DNS** | DNS rules + `type: keenetic` + dnsmasq | SmartDNS (DoT/DoH, split, redirect) |
| **DNS шифрование** | ⚠️ Через роутер (зависит от настройки) | ✅ Собственный стек (гарантированный) |
| **WebUI** | ✅ Встроен в daemon (TypeScript, auth) | ✅ Nginx+Lua + stock injection |
| **NDM compatibility** | ⚠️ Частичная (skip_marked + RAW trade-off) | ✅ Полная (no fwmark) |
| **HW NAT** | ❌ Отключен | ✅ Сохранён |
| **Domain routing** | ✅ Real-time (dnsmasq) | ⚠️ Hourly (dig + cron) |
| **GEO routing** | ✅ Через загрузку CIDR-списков | ✅ Нативная специализация (aggregation, loaders) |
| **Failover** | ✅ Health checks + chains + circuit breaker | ⚠️ NDM hook re-attach (single target) |
| **Kill switch** | ✅ Blackhole outbound | ❌ Нет |
| **Advanced filtering** | ✅ DSCP, ports, addrs, protocol, inbound_iface | ❌ Только `iif br0` |
| **Cross-platform** | ✅ Keenetic + OpenWrt + Debian | ❌ Только Keenetic |
| **Install complexity** | 🟢 `opkg install keen-pbr` | 🟡 6 пакетов ручная установка |
| **Зрелость** | 🟢 v3.3.0 stable, 122+ stars, active community | 🟡 v0.12.x, 1 author, active development |
| **Тесты** | 🟢 ~60 unit + integration (QEMU) | 🟡 shellcheck |

### Когда выбрать keen-pbr

- Нужен **per-service VPN** (разные сервисы через разные VPN)
- Нужен **мгновенный** domain routing (страница не загрузится до cron — неприемлемо)
- Нужен **kill switch** (blackhole при падении VPN)
- Нужна кросс-платформенность (OpenWrt, Debian)
- Нужен **advanced filtering** (DSCP, ports, addresses, protocol matching)
- Нужна **аутентификация** WebUI
- **Не** используется per-device routing Keenetic (все устройства в default policy)
- Допустимо отключение HW NAT

### Когда выбрать keenetic-entware-extras

- Критична **NDM per-device routing совместимость** (разные устройства → разные политики)
- Критична **производительность** (HW NAT не должен быть отключен)
- Нужен **гарантированный DNS privacy** (собственный DoT/DoH стек, не зависящий от настроек роутера)
- Задача — **GEO routing целой страны** (а не per-service VPN)
- Нужна **интеграция в stock Keenetic WebUI** (sidebar injection)
- Нужна **корректная CDN геолокация** (split-DNS: .ru через российские DNS)
- Допустима **задержка** domain routing (~1 час, для GEO это приемлемо)

### Теоретическая совместимость

Оба проекта **можно** использовать одновременно: разные ip rule priorities, разные таблицы. smartdns-redirect (`nat REDIRECT`) не конфликтует с keen-pbr (`mangle/raw MARK`). Но keen-pbr всё равно отключит HW NAT и fwmark-конфликт с NDM останется.

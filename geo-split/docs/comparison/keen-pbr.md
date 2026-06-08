# Глубокое сравнение: keenetic-entware-extras vs keen-pbr

**Дата обновления**: 2026-06-04  
**keen-pbr**: v3.0.6 BETA ([maksimkurb/keen-pbr](https://github.com/maksimkurb/keen-pbr))  
**keenetic-entware-extras**: v0.12.x (экосистема из 6 пакетов)

---

## 1. Обзор проектов

| | **keenetic-entware-extras** | **keen-pbr** |
|---|---|---|
| **Назначение** | GEO-маршрутизация + DNS split + DNS redirect + WebUI | Universal policy-based routing daemon |
| **Архитектура** | 6 .ipk пакетов с shared libs | Единый C++ демон + TypeScript WebUI |
| **Язык (back-end)** | POSIX sh (~2800 строк) + Lua API (~540) | C++ (~57% кодовой базы) |
| **Язык (front-end)** | JS/HTML/CSS (~1800 строк, vanilla) | TypeScript (~32% кодовой базы) |
| **Тесты** | shellcheck | C++ unit tests |
| **Конфиг** | shell vars (defaults.conf + config.conf per-package) | JSON (config.json) |
| **Платформа** | Keenetic + Entware | Keenetic + OpenWrt + Debian |
| **Лицензия** | MIT | GPL-3.0 |
| **Сообщество** | 1 автор | 3 contributors, 122 stars, Telegram |
| **CI/CD** | Makefile (build/lint/release) | GitHub Actions (multi-arch build) |
| **opkg-репо** | нет (ручная сборка .ipk) | Собственный opkg-репозиторий |
| **WebUI** | ✅ Nginx+Lua дашборд + stock injection | ✅ TypeScript SPA (встроен в бинарник) |
| **REST API** | ✅ (nginx-lua, per-service) | ✅ (C++ HTTP server, :12121) |
| **DNS управление** | ✅ SmartDNS split-DNS + DNS redirect | ❌ Только dnsmasq ipset |
| **Keenetic NDM** | ✅ ndmc CLI для interface labels | ✅ RCI HTTP API для interface health |

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
- ✅ Нет зависимости от iptables mangle
- ✅ Gateway auto-detect (Ethernet ISP `via <gw>`, LTE/PPP dev-only)

**Минусы**:
- ❌ ~8K маршрутов в kernel route table (после CIDR aggregation, was 13K)
- ❌ Нет per-domain routing в реальном времени (обновление раз в час)
- ❌ Невозможно маршрутизировать per-source IP (только per-interface: `iif`)

### keen-pbr: fwmark-based (iptables mangle / nftables)

```
iptables -t mangle -A PREROUTING -m set --match-set kpbr0 dst -j MARK --set-mark 0x00010000
ip rule add fwmark 0x00010000/0x00FF0000 table 150
ip route add default dev nwg0 table 150
```

**Механизм**: IP/домены → ipset/nftables sets → fwmark → ip rule → custom table с default route.

**Плюсы**:
- ✅ Только 1 default route в таблице (не 8K per-subnet routes)
- ✅ Мгновенный domain routing через dnsmasq ipset
- ✅ Множество outbounds с разными правилами
- ✅ Kill switch (blackhole outbound)
- ✅ Health checks + failover chains
- ✅ `skip_marked_packets: true` — пропускает пакеты с чужими marks (уменьшает конфликт с NDM)

**Минусы**:
- ❌ fwmark **всё равно** конфликтует с Keenetic NDM per-device routing (хотя `skip_marked_packets` уменьшает проблему)
- ❌ Требует отключения HW NAT
- ❌ Зависимость от iptables/nftables kernel modules
- ❌ Устройства должны быть в «Политике доступа по умолчанию» (подтверждено в keen-pbr docs)

### Использование iptables: принципиальная разница

| | **keenetic-entware-extras** | **keen-pbr** |
|---|---|---|
| **iptables таблица** | `nat` (PREROUTING REDIRECT — только DNS) | `mangle` (PREROUTING MARK — весь routing) |
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

### keen-pbr: dnsmasq ipset integration

```json
"dns": {
  "system_resolver": { "address": "127.0.0.1" },
  "dns_test_server": { "listen": "127.0.0.88:12153" },
  "servers": [{ "tag": "quad9", "address": "9.9.9.9" }]
}
```

keen-pbr в v3 имеет собственный DNS test server и может проверять доступность серверов для health checks. Основная DNS-интеграция — через dnsmasq ipset: при DNS-запросе resolved IP автоматически попадает в ipset.

**Преимущества keen-pbr**:
- Мгновенный domain routing при первом DNS-запросе
- Не требует периодического dig-resolution
- DNS test server для health checks

**Недостатки keen-pbr DNS**:
- Подменяет `/opt/etc/dnsmasq.conf`
- Нет собственного DNS forward/resolve (только dnsmasq)
- Нет DoT/DoH шифрования
- Нет split-DNS по зонам

### Сравнение domain routing

| | **keenetic-entware-extras** | **keen-pbr** |
|---|---|---|
| **Domain → route** | dig → /32 routes (hourly) | dnsmasq ipset (real-time) |
| **Скорость подхвата** | ~1 час | Мгновенно |
| **DNS шифрование** | ✅ DoT/DoH | ❌ Plain UDP (dnsmasq) |
| **Split-DNS по зонам** | ✅ .ru→Yandex, *→Google/CF | ❌ Нет |
| **CDN геолокация** | ✅ Корректная | ❌ Может быть некорректной |
| **Подменяет dnsmasq** | ❌ Нет | ✅ Да |
| **Private IP filtering** | ✅ | ❌ |
| **DNS health check** | ✅ Watchdog cron | ✅ DNS test server |

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
    "ip_cidrs": []
  }
},
"lists_autoupdate": {
  "enabled": true,
  "cron": "0 4 * * 0"
}
```

keen-pbr v3 **может** загружать GEO-списки IP через URL (поле `url` в списках + `lists_autoupdate`). Это позволяет реализовать GEO routing через единый механизм списков:
- Загрузка CIDR-списков по URL
- Автообновление по cron (еженедельно по умолчанию)
- Те же ip_cidrs → ipset → fwmark routing

**Но**: keen-pbr не специализирован на GEO — нет CIDR aggregation, нет multi-interface failover, нет size validation, нет pluggable loaders. Это **generic list mechanism**, который подходит для GEO, но без оптимизаций для больших (10K+) наборов.

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

### keen-pbr: WebUI (встроенный в daemon)

- **Технология**: C++ HTTP server + TypeScript SPA (встроен в бинарник)
- **Порт**: :12121 (по умолчанию на localhost)
- **API**: REST для управления конфигурацией и мониторинга
- **Особенность**: WebUI встроен прямо в keen-pbr daemon — один бинарник, всё включено
- **i18n**: интернационализация (commit: "Update i18n")
- **Архитектура**: single-process daemon, WebUI served from embedded assets

### Сравнение WebUI

| | **keenetic-entware-extras** | **keen-pbr** |
|---|---|---|
| **Технология** | Nginx + Lua + vanilla JS | C++ server + TypeScript SPA |
| **Интеграция** | Внешний процесс (nginx) | Встроен в daemon |
| **Stock Keenetic injection** | ✅ inject.js в sidebar | ❌ Отдельная страница |
| **Config editor** | ✅ Per-service | ✅ Полный конфиг |
| **System info (CPU/RAM/Disk)** | ✅ | Неизвестно |
| **Service start/stop** | ✅ Per-package enable/disable | ✅ |
| **i18n** | ❌ (только RU) | ✅ (EN + RU) |
| **Размер frontend** | ~1800 строк (vanilla) | TypeScript (~32% кодовой базы) |
| **Bundled** | Отдельный .ipk (webui) | Встроен в бинарник |

---

## 6. Интеграция с Keenetic

| | **keenetic-entware-extras** | **keen-pbr** |
|---|---|---|
| **NDM ifstatechanged** | ✅ `ndm-hook.sh` (debounce + parallel refill) | ✅ hook (routing re-apply) |
| **NDM netfilter** | ✅ `netfilter-hook.sh` (DNS rule recovery) | ✅ hook (fwmark re-apply) |
| **Keenetic NDM CLI** | ✅ `ndmc -c "show interface"` (WebUI labels) | — |
| **Keenetic RCI HTTP API** | — | ✅ `localhost:79/rci/` (interface health) |
| **Interface failover** | ✅ NDM hook auto-mode + re-attach | ✅ Health checks + failover chains |
| **HW NAT** | ✅ Не трогает | ❌ Отключает |
| **skip_marked_packets** | — (не нужно, нет marks) | ✅ Уменьшает конфликт с NDM |
| **Stock UI injection** | ✅ sidebar group | ❌ |
| **OpenWrt support** | ❌ Только Keenetic/Entware | ✅ |
| **Debian support** | ❌ | ✅ |

**Важно**: оба проекта используют Keenetic NDM для интеграции, но по-разному:
- **kee** использует `ndmc` CLI (получение interface descriptions для WebUI display)
- **keen-pbr** использует RCI HTTP API `localhost:79/rci/` (получение interface state/health для routing decisions)

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

### keen-pbr

```
[daemon startup]
  → keen-pbr apply: parse config → ipset restore → fwmark rules
  → health checks: periodic DNS test + interface UP verification
  → failover: switch outbound if health check fails
[lists_autoupdate cron "0 4 * * 0"]
  → download lists by URL → apply
[dnsmasq integration]
  → real-time: DNS query → ipset → routing (immediate)
```

### Сравнение надёжности

| | **keenetic-entware-extras** | **keen-pbr** |
|---|---|---|
| **Download failover** | ✅ Multi-interface с retries | ❌ Нет (single attempt) |
| **Size validation** | ✅ (≥100 lines reject) | ❌ Нет |
| **Data aggregation** | ✅ CIDR merge (reduces count) | ❌ Нет |
| **Health checks** | ✅ Watchdog (DNS + iptables) | ✅ Health checks + failover |
| **Interface failover (routing)** | ✅ NDM hook re-attach | ✅ Health check → switch outbound |
| **Outbound failover chains** | ❌ (single target) | ✅ Configurable chains |
| **Kill switch** | ❌ | ✅ Blackhole outbound |
| **strict_enforcement** | ❌ | ✅ (strict mode config) |
| **PID lock** | ✅ (prevent parallel runs) | ✅ (daemon single instance) |
| **Hot reload** | ✅ `refresh` command (no ip rule re-attach) | ✅ Config reload via API |

---

## 8. Что есть в keen-pbr, чего нет в kee

| Фича | Значимость |
|-------|:---:|
| **Real-time domain routing** (dnsmasq ipset) | 🔴 Высокая |
| **Kill switch** (blackhole outbound) | 🟡 Средняя |
| **Failover chains** (automatic outbound switch) | 🟡 Средняя |
| **IPv6 routing** (toggleable) | 🟡 Средняя |
| **Multi-outbound** (разные списки → разные VPN) | 🟡 Средняя |
| **Health checks** (DNS test + interface) | 🟡 Средняя |
| **OpenWrt/Debian support** | 🟢 Малая (другой use case) |
| **i18n** (EN + RU) | 🟢 Малая |
| **WebUI встроен в daemon** (zero-dep) | 🟢 Малая (trade-off) |
| **strict_enforcement** | 🟢 Малая |
| **Config hot-reload via API** | 🟢 Малая |
| **Embedded WebUI assets** (gzip served) | 🟢 Малая |

---

## 9. Что есть в kee, чего нет в keen-pbr

| Фича | Категория |
|-------|--|
| **fwmark-free routing** (NDM per-device совместимость) | Архитектура |
| **HW NAT сохранён** | Performance |
| **Полный DNS-стек** (SmartDNS + split-DNS + redirect) | DNS |
| **DoT/DoH шифрование DNS** | Безопасность |
| **Split-DNS по зонам** (.ru→RU DNS, *→INT DNS) | DNS |
| **Correct CDN geolocation** (split resolves) | DNS |
| **Stock Keenetic sidebar injection** | UX |
| **CIDR aggregation** (13K → 8K, reduces memory) | Performance |
| **Multi-interface download failover** с retries | Надёжность |
| **Download size validation** (reject corrupted) | Надёжность |
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

---

## 10. Количественное сравнение

| Метрика | **keenetic-entware-extras** | **keen-pbr** |
|---------|:-:|:-:|
| Packages | 6 .ipk | 1 .ipk |
| Backend language | POSIX sh + Lua | C++ |
| Frontend language | Vanilla JS/HTML/CSS | TypeScript |
| Config format | Shell vars | JSON |
| Binary size | 0 (scripts) | ~2-4 MB (C++ + embedded WebUI) |
| Runtime deps | ip-full, curl, dig, aggregate, SmartDNS, nginx, iptables | iptables/nftables, dnsmasq |
| NDM hooks | 2 (ifstatechanged + netfilter) | 2 (ifstatechanged + netfilter) |
| Cron jobs | 2 (geo-split */15, watchdog */5) | 1 (lists autoupdate weekly) |
| Route table entries | ~8K (aggregated CIDRs) + ~300 (/32 domains) | 1 default route per outbound |
| Cold start (from cache) | ~1-2 сек (ip -batch parallel) | ~мгновенно (ipset restore) |
| DNS security | DoT/DoH (SmartDNS) | None (dnsmasq plain) |
| Stars on GitHub | — (private repo) | 122 |
| License | MIT | GPL-3.0 |
| Platforms | Keenetic/Entware | Keenetic + OpenWrt + Debian |

---

## 11. Ключевые архитектурные решения

### Почему kee не использует fwmark

Keenetic NDM использует `skb->mark` для per-device routing. keen-pbr конфликтует с этим:
- `iptables mangle MARK` перезаписывает тот же mark
- `skip_marked_packets: true` в keen-pbr v3 уменьшает проблему (пропускает пакеты с чужими marks), но **не решает** её полностью — mark для keen-pbr всё равно затрагивает пакеты из "default policy"
- Устройства **должны быть** в «Политике доступа по умолчанию» (документировано в keen-pbr docs)
- HW NAT всё равно отключается

keenetic-entware-extras использует `ip rule iif br0` + per-subnet routes → **mark не затронут**, per-device routing Keenetic работает полностью.

### Почему keen-pbr использует fwmark

fwmark позволяет:
- 1 default route vs 8K per-subnet маршрутов (экономия памяти)
- ipset match для real-time domain routing
- Множество outbounds с разными правилами
- Health checks + automatic failover

В v3 добавлен `skip_marked_packets` и configurable fwmark mask (`0x00FF0000`) для уменьшения конфликтов.

### Почему kee — модульная экосистема из 6 пакетов

1. **Независимые update циклы** — WebUI v0.17 не требует пересборки geo-split
2. **Опциональность** — можно ставить только geo-split без DNS стека
3. **Zero binaries** — нет 2-4 MB native бинарника, нет cross-compilation
4. **Shared libs** — нет дублирования (common.sh, ip.sh, lists.sh, status.sh)
5. **Отсутствие Go/C++ build chain** — shell scripts работают на любой arch без сборки

### Почему keen-pbr перешёл с Go на C++

keen-pbr v2.x был на Go, v3.x переписан на C++:
1. Размер бинарника: Go ~6-8 MB → C++ ~2-4 MB (critical для роутеров с 128MB flash)
2. Daemon mode: C++ daemon с event loop эффективнее Go process
3. WebUI: embedded compiled TypeScript assets в бинарник (Go использовал отдельный React)
4. Performance: C++ на embedded (MIPS/ARM) быстрее Go runtime
5. nftables support: C++ проще интегрируется с netfilter через libmnl/libnftnl

---

## 12. Заключение

**keen-pbr v3** и **keenetic-entware-extras** — это **разные парадигмы**, каждая со своими объективными преимуществами:

| | **keen-pbr** | **keenetic-entware-extras** |
|---|---|---|
| **Парадигма** | Universal PBR daemon (все задачи) | Specialized GEO routing + DNS ecosystem |
| **Маршрутизация** | fwmark + ipset (1 route per outbound) | route-based (8K per-subnet routes) |
| **DNS** | dnsmasq ipset (подмена конфига) | SmartDNS (DoT/DoH, split, redirect) |
| **WebUI** | ✅ Встроен в daemon (TypeScript) | ✅ Nginx+Lua + stock injection |
| **NDM compatibility** | ⚠️ Частичная (skip_marked_packets) | ✅ Полная (no fwmark) |
| **HW NAT** | ❌ Отключен | ✅ Сохранён |
| **Domain routing** | ✅ Real-time (dnsmasq) | ⚠️ Hourly (dig + cron) |
| **GEO routing** | ✅ Через загрузку CIDR-списков | ✅ Нативная специализация (aggregation, loaders) |
| **Failover** | ✅ Health checks + chains | ⚠️ NDM hook re-attach (single target) |
| **Kill switch** | ✅ Blackhole outbound | ❌ Нет |
| **DNS security** | ❌ Plain DNS | ✅ DoT/DoH |
| **Cross-platform** | ✅ Keenetic + OpenWrt + Debian | ❌ Только Keenetic |
| **Install complexity** | 🟢 `opkg install keen-pbr` | 🟡 6 пакетов ручная установка |
| **Зрелость** | 🟢 v3.0.6, 122 stars, active community | 🟡 v0.12.x, 1 author, active development |

### Когда выбрать keen-pbr

- Нужен **per-service VPN** (разные сервисы через разные VPN)
- Нужен **мгновенный** domain routing (страница не загрузится до cron —неприемлемо)
- Нужен **kill switch** (blackhole при падении VPN)
- Нужна кросс-платформенность (OpenWrt, Debian)
- **Не** используется per-device routing Keenetic (все устройства в default policy)
- Допустимо отключение HW NAT

### Когда выбрать keenetic-entware-extras

- Критична **NDM per-device routing совместимость** (разные устройства → разные политики)
- Критична **производительность** (HW NAT не должен быть отключен)
- Нужен **DNS privacy** (DoT/DoH шифрование, split по зонам)
- Задача — **GEO routing целой страны** (а не per-service VPN)
- Нужна **интеграция в stock Keenetic WebUI** (sidebar injection)
- Нужна **корректная CDN геолокация** (split-DNS: .ru через российские DNS)
- Допустима **задержка** domain routing (~1 час, для GEO это приемлемо)

### Теоретическая совместимость

Оба проекта **можно** использовать одновременно: разные ip rule priorities, разные таблицы. smartdns-redirect (`nat REDIRECT`) не конфликтует с keen-pbr (`mangle MARK`). Но keen-pbr всё равно отключит HW NAT и fwmark-конфликт с NDM останется.

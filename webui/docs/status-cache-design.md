# Status API Cache — дизайн и анализ CPU-нагрузки

## Проблема

GUI-дашборд даёт значительную нагрузку на CPU роутера из-за частого поллинга
status-скриптов, которые внутри форкают тяжёлые процессы (dig, iptables, netstat).

### Текущие интервалы поллинга

| UI | Интервал (visible) | Background | Запросы за цикл |
|----|--------------------|------------|-----------------|
| Custom dashboard (`app.js`) | 5 сек | 60 сек | 5 (4 status + system/info) |
| Stock card (`inject.js`) | 30 сек (настраивается DASH_POLL_INTERVAL) | — | 4 |

### Стоимость одного poll-цикла (custom dashboard)

Каждый цикл запускает через `io.popen()` (блокирующий!):

| Эндпоинт | Скрипт | Тяжёлые операции | Worst-case время |
|-----------|--------|-----------------|------------------|
| `/api/geo-split/status` | `geo-split/scripts/status.sh --json` | `ip route show` ×2, `ip rule show`, **`dig`** ×2 (detect_dns_port), `ps w`, `opkg status` | ~2-3s |
| `/api/smartdns/status` | `smartdns-geo-conf/scripts/status.sh --json` | `netstat`, `grep -rch` ×2, `du` ×2, **`dig +time=3`** ×N (DNS тесты) | **3-15s** |
| `/api/smartdns-redirect/status` | `smartdns-redirect/scripts/status.sh --json` | `netstat`, **`iptables -C`** ×4, `opkg status` | ~1s |
| `/api/webui/status` | `webui/scripts/status.sh --json` | `netstat -tln`, `pidof`, `opkg status` | ~0.5s |
| `/api/system/info` | Lua inline (api-router.lua) | `df -k /opt` (единственный fork) | ~0.1s |

**Критический момент:** `io.popen()` блокирует nginx worker. При `worker_processes 2`
максимум 2 запроса обрабатываются параллельно. Если скрипт висит на dig 3 секунды —
все остальные запросы в очереди.

### Мультипликация от нескольких вкладок

- 1 вкладка custom dashboard = 60 форков/мин
- N вкладок = N × 60 форков/мин (без дедупликации!)
- Stock card добавляет ещё 8 форков/мин per tab

### Важно: status.sh — двойного назначения

Скрипты `status.sh` — CLI-инструменты первого класса (вызываются через SSH, cron,
kee-status и т.д.). Кеширование работает **только на уровне nginx/Lua**, не затрагивая
сами скрипты. CLI `status.sh` всегда показывают свежие данные.

---

## Решение: lua_shared_dict кеш (реализовано)

### Архитектура

```
┌──────────┐     ┌─────────────────────────────────┐     ┌──────────┐
│ Tab 1    │────▶│ nginx-lua                       │     │ shell    │
│ Tab 2    │────▶│   lua_shared_dict status_cache  │────▶│ status.sh│
│ Tab 3    │────▶│   TTL = 5-15s per endpoint      │     │          │
│ ...      │────▶│   stale fallback = 30s          │     │          │
└──────────┘     └─────────────────────────────────┘     └──────────┘
                  ▲ все клиенты читают из кеша
                    только 1 воркер запускает скрипт при cache miss
```

### Поведение

1. **Cache HIT** (< TTL since last fetch): мгновенный ответ из shared dict
2. **Cache MISS**: один воркер берёт "lock" (atomic `add`), запускает скрипт,
   обновляет кеш. Другие воркеры в это время получают stale-данные (до 30s)
3. **CLI (ssh)**: `status.sh --json` вызывается напрямую, кеш не участвует

### Параметры

| Параметр | Значение | Применяется к | Обоснование |
|----------|----------|---------------|-------------|
| `CACHE_TTL` | 5 сек (default) | fallback для эндпоинтов без override | Базовое значение |
| `ENDPOINT_TTLS` | 5-15 сек | per-endpoint override | Тяжёлые скрипты (dig) кешируются дольше |
| `STALE_TTL` | 30 сек | status endpoints | Fallback при блокировке (dig timeout) |
| `LOCK_TTL` | 15 сек | status endpoints | Max время ожидания io.popen (dig worst-case) |
| `STATIC_TTL` | 3600 сек (1 час) | system/zones | Зоны/союзы — статические файлы, парсятся 1 раз |
| `IFACE_TTL` | 60 сек | system/interfaces | Интерфейсы меняются редко (tunnel connect/disconnect) |
| `dict size` | 1 MB | всё | Хватит на ~100 JSON-ответов по 5-10KB |

### Инвалидация

Кеш инвалидируется автоматически при:
- **POST action** (start/stop/update) → сбрасывает status кеш соответствующего сервиса
- **POST config** (save & restart) → сбрасывает status кеш сервиса
- **nginx restart/reload** → вся shared memory обнуляется (fresh start)

### Важно: status.sh — CLI-инструменты первого класса

Скрипты `status.sh` — полноценные CLI-утилиты, вызываемые через SSH, cron,
`kee-status` и прочие скрипты **напрямую** (без nginx). Кеширование работает
**исключительно на уровне nginx/Lua** и не затрагивает поведение скриптов.
CLI `status.sh --json` или `status.sh` (text mode) всегда возвращают свежие данные.

### Эффект

| Сценарий | Было (форки/мин) | Стало (форки/мин) | Снижение |
|----------|------------------|-------------------|----------|
| 1 tab custom | 60 | 26 (per-endpoint TTL) | **−57%** |
| 3 tabs custom | 180 | 26 | **−86%** |
| 5 tabs mixed | 300+ | 26 | **−91%** |

Фиксированная верхняя граница: **~26 fork'ов/мин** (6+4+12+12 для geo/smartdns/redirect/webui)
независимо от числа клиентов.

---

## CLI Invariants (нельзя нарушать)

Скрипты `status.sh` — CLI-инструменты первого класса. Любая оптимизация должна
сохранять следующие контракты:

| Контракт | Описание |
|----------|----------|
| `status.sh` (без аргументов) | Text human-readable output, **всегда свежие данные** |
| `status.sh --json` | JSON output, **всегда свежие данные** (кеш — на стороне nginx/Lua) |
| Exit code | 0 = all OK, 1 = something failed. Используется `kee-status.sh` |
| Параллельные вызовы | Безопасны (shell — stateless, кеш — в shared_dict nginx) |

### Раздельные code paths: text vs JSON

```
geo-split/scripts/status.sh:
  --json → json_output() → check_dns_resolver() → detect_dns_port()  [TTL=10s в Lua]
  text   → show_dns_resolver() → check_dns_resolver() → detect_dns_port()

smartdns-geo-conf/scripts/status.sh:
  --json → collect_dns_tests_json() ← тяжёлая (N×dig); Lua кеширует ответ TTL=15s
  text   → show_dns_tests()         ← всегда fresh (CLI = свежие данные)
```

**Правило:** Shell скрипты остаются stateless. Весь кеш — исключительно
в `ngx.shared.dict` (Lua layer). CLI `status.sh` всегда возвращает fresh данные.

---

## Дополнительные оптимизации (следующий этап)

### Механизм: True In-Memory кеш через `lua_shared_dict`

> ⚠️ На любом(!) Keenetic `/tmp` **сохраняется между перезагрузками** (не tmpfs).
> Файловый кеш в `/tmp` не является volatile — это НЕ настоящий in-memory.

Настоящий in-memory кеш — `ngx.shared.dict` (уже используется для status responses):
- Выделяется из POSIX shared memory (SysV или mmap anon)
- **Гарантированно volatile** — обнуляется при restart nginx
- Доступен всем worker'ам одновременно (zero-copy read)
- TTL на уровне ключа — автоматическое истечение
- Атомарные операции (add/set/delete) — нет race conditions

```
┌─────────────────────────────────────────────────────────────────────┐
│ ngx.shared.status_cache (lua_shared_dict, 1MB RAM)                  │
│                                                                     │
│  key="/api/geo-split/status"        val=<json>  TTL=10s             │
│  key="/api/smartdns/status"         val=<json>  TTL=15s             │
│  key="/api/smartdns-redirect/status" val=<json> TTL=5s              │
│  key="/api/webui/status"            val=<json>  TTL=5s              │
│  key="...::stale"                   val=<json>  TTL=60s             │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

**Преимущества над файловым кешем:**
- Нет filesystem I/O (даже если `/tmp` — flash)
- Нет race conditions с `stat`/`cat`/`printf`
- Атомарный TTL (не зависит от системных часов / mtime)
- Уже настроен и работает — просто добавляем ключи и TTL

---

### Приоритет 2+3: Per-endpoint TTL (единственное изменение)

Весь кеш — **на стороне сервера (Lua)**. Shell скрипты не трогаем.
Сервер просто держит ответ в shared_dict дольше для тяжёлых скриптов.

**Реализация — per-endpoint TTL в `cached_run()`:**

```lua
-- api-router.lua: per-endpoint cache TTL (вместо единого CACHE_TTL=5)
local ENDPOINT_TTLS = {
    ["/api/geo-split/status"]        = 10,  -- detect_dns_port внутри = 2 dig
    ["/api/smartdns/status"]          = 15,  -- collect_dns_tests_json = N×dig +time=3
    ["/api/smartdns-redirect/status"] = 5,   -- iptables -C (быстро)
    ["/api/webui/status"]             = 5,  -- netstat + pidof
}

local function cached_run(key, cmd)
    local ttl = ENDPOINT_TTLS[key] or CACHE_TTL

    -- Fast path: fresh cache hit
    local cached = cache:get(key)
    if cached then return cached end

    -- Lock + execute (existing logic)
    local lock_key = key .. "::lock"
    local ok, _ = cache:add(lock_key, true, LOCK_TTL)
    if not ok then
        local stale = cache:get(key .. "::stale")
        if stale then return stale end
    end

    local output, _, _ = run_cmd(cmd)
    output = output:gsub("%s+$", "")

    if output:sub(1, 1) == "{" then
        cache:set(key, output, ttl)              -- ← per-endpoint TTL
        cache:set(key .. "::stale", output, STALE_TTL)
    end

    cache:delete(lock_key)
    return output
end
```

**Обоснование TTL:**

| Endpoint | TTL | Почему | Staleness при аварии |
|----------|-----|--------|---------------------|
| geo-split | 10s | detect_dns_port = 2 dig; порт меняется только при restart SmartDNS | max 10s |
| smartdns | 15s | DNS tests = до 6 dig × 3s timeout; компромисс fresh/CPU | max 15s |
| smartdns-redirect | 5s | iptables checks — быстрые (~0.3s), разумно держать свежими | max 5s |
| webui | 5s | netstat + pidof — быстрые; совпадает с POLL_ACTIVE | max 5s |

**POST action (start/stop/config) инвалидирует кеш мгновенно** → после toggle
пользователь видит fresh данные на следующем poll, независимо от TTL.

**CLI совместимость:** ✓ Полная. Shell скрипты **не изменяются** — кеширование
происходит исключительно в nginx/Lua. CLI вызывает `status.sh` напрямую,
всегда получает fresh данные.

**Эффект:**

| Метрика | Было (TTL=5s uniform) | Стало (per-endpoint) |
|---------|----------------------|---------------------|
| geo-split fork'и/мин | 12 | **6** (−50%) |
| smartdns fork'и/мин | 12 | **4** (−67%) |
| smartdns worker blocking/мин | 36-216s | **12-72s** (−67%) |
| Общие fork'и/мин (4 скрипта) | 48 | **26** (−46%) |

---

### Приоритет 4: POLL_ACTIVE → 10-15s

Текущие 5s — агрессивно. С кешем CACHE_TTL=5s и ticker'ом для uptime —
можно безболезненно увеличить до 10-15s (пользователь не заметит разницы).

С smartdns TTL=15s и geo-split TTL=10s эффект ещё сильнее:
при POLL=10s smartdns запускается ~4 раз/мин, geo-split ~6 раз/мин.

---

### ~~Приоритет 5: Batch эндпоинт /api/status/all~~ (отклонён)

**Анализ: batch endpoint ВРЕДЕН в текущей архитектуре.**

| Аспект | Текущее (4 параллельных fetch) | Batch `/api/status/all` |
|--------|-------------------------------|-------------------------|
| HTTP overhead | 4 connections (localhost!) | 1 connection |
| `io.popen()` | **параллельно** (2 workers) | **последовательно** в 1 worker! |
| Blocking время | max(2s, 15s, 1s, 0.5s) ≈ 3-15s | sum = **4-20s** |
| UX (time-to-first-render) | 0.5s (webui/status первый) | 4-20s (всё или ничего) |

**Причина:** `io.popen()` — блокирующий. Batch endpoint сериализует все 4 скрипта
последовательно в одном nginx worker. Результат:
- Пользователь ждёт 4-20s вместо progressive rendering (карточки по 0.5s, 1s, 2s…)
- nginx worker блокирован весь суммарный период (вместо параллельной обработки)

**HTTP overhead на localhost пренебрежим:** 4 fetch к 127.0.0.1 = <1ms сетевого
overhead. Нет смысла оптимизировать то, что занимает 0.001% от общего времени.

**Когда batch станет полезен:**
- При переходе на non-blocking I/O (`ngx.pipe` / `lua-resty-shell` / cosocket)
- Тогда все 4 скрипта запускаются параллельно внутри одного HTTP-ответа
- Но это требует OpenResty или nginx ≥1.25 с lua-resty-pipe (не доступен на Entware)

**Решение:** Убрано из плана. Текущий подход (параллельные fetch + shared dict cache)
оптимален для blocking io.popen архитектуры.

---

## Суммарный план реализации

| # | Оптимизация | TTL | Где | Сложность | Эффект |
|---|-------------|-----|-----|-----------|--------|
| 1 | ✅ nginx shared_dict cache (uniform) | 5s | api-router.lua | Готово | −73-84% форков |
| 2 | Per-endpoint TTL (geo-split) | 10s | api-router.lua | Trivial | −50% fork'ов geo-split |
| 3 | Per-endpoint TTL (smartdns) | 15s | api-router.lua | Trivial | −67% fork'ов smartdns |
| 4 | POLL_ACTIVE увеличить | 10-15s | app.js + inject.js | Low | −50-66% poll requests |
| 5 | ~~Batch endpoint~~ | — | — | — | Отклонён (см. выше) |

**Порядок внедрения:** 2+3 одним коммитом (3 строки в api-router.lua) → 4.

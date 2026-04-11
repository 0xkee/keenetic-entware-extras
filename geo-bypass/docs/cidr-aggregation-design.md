# Строгая CIDR-агрегация подсетей — Дизайн

## 1. Цель

Уменьшить количество CIDR-записей в `ru-subnets.txt` путём слияния
перекрывающихся и смежных подсетей. Меньше записей → быстрее загрузка в ipset,
меньше потребление памяти на роутере.

**Строгая агрегация** = только точное слияние смежных/перекрывающихся диапазонов.
НЕ supernetting до ближайшей степени двойки (не расширяем покрытие ни на один IP).

### Верифицированный результат (router-1, BusyBox v1.37.0)

| Метрика | Значение |
|---------|----------|
| Исходный `ru-subnets.txt` (ipdeny.com) | 11 286 CIDR |
| После агрегации | 8 307 CIDR |
| Сокращение | **−2 979 (26%)** |
| Время выполнения на роутере | **2 сек** (с pow2-оптимизацией) |

## 2. Алгоритм

### 2.1. Обзор

Трёхстадийный pipeline (stdin → stdout):

```
stdin (CIDRs) → [awk: parse → ranges] → [sort -n] → [awk: merge → CIDRs] → stdout
```

### 2.2. Стадия 1 — Парсинг CIDR → числовые диапазоны

Каждая строка `A.B.C.D/prefix` преобразуется в пару `start end` (десятичные числа):

```
ip_num   = A×16777216 + B×65536 + C×256 + D
mask_size = 2^(32 − prefix)
start    = ip_num − (ip_num % mask_size)     ← нормализация: сброс host-битов
end      = start + mask_size − 1
```

**Нормализация host-битов:** `10.0.0.5/24` → `start = 10.0.0.0` (сбрасываем биты правее маски).

Невалидные строки (не CIDR, prefix вне 0–32, не 4 октета, октет > 255) — пропускаются.

### 2.3. Стадия 2 — Сортировка

```sh
sort -n
```

Сортировка по `start` (первое число). При равном `start` — по `end`.

**Обязательна:** хотя вход (ipdeny.com) визуально отсортирован по IP, числовая
сортировка перемещает ~1135 из 11286 записей (~10%). Без `sort -n` результат
будет **некорректным** (проверено на router-1: single-pass без sort выдаёт
5930 вместо 8307 — ошибочная сверх-агрегация).

### 2.4. Стадия 3 — Слияние и обратная конвертация

**Слияние** — жадный merge отсортированных диапазонов:

```
для каждого следующего (s, e):
  если s ≤ merged_end + 1:          ← перекрытие ИЛИ смежность
    merged_end = max(merged_end, e)
  иначе:
    emit_cidrs(merged_start, merged_end)
    начинаем новый диапазон (s, e)
```

**Конвертация** диапазона `[s, e]` → минимальный набор CIDR:

```
пока s ≤ e:
  align_bits = кол-во младших нулевых бит в s  (для s=0: 32)
  size_bits  = floor(log₂(e − s + 1))          ← через таблицу pow2[]
  k          = min(align_bits, size_bits)
  ↳ вывести: num_to_ip(s) / (32 − k)
  ↳ s += pow2[k]
```

Это гарантирует **точное** покрытие `[s, e]` — ни одним IP больше/меньше.

### 2.5. Диаграмма потока данных

```
stdin ──→ _cidr_to_ranges (awk) ──→ sort -n ──→ _merge_and_emit_cidrs (awk) ──→ stdout
           parse + normalize          сортировка     merge + convert back
           "start end" per line       по start        CIDR per line
```

## 3. Платформа: BusyBox awk v1.37.0

**Верифицировано на router-1 (Keenetic Hero 5G):**

| Тест | Результат |
|------|-----------|
| IP-арифметика (255.255.255.255 = 4294967295) | ✅ точно |
| Модуль больших чисел (`167772160 % 1024`) | ✅ точно |
| 2^32 = 4294967296 | ✅ точно |
| Alignment detection (`5.8.42.0` → 9 бит) | ✅ |
| num → IP конвертация (включая 255.255.255.255) | ✅ |
| Сравнения `<=` для значений > 2^31 | ✅ |

### ⚠️ Ограничение: `printf "%d"` переполняется для IP > 128.x

```
printf "%d", 4294967295  →  2147483647   ← НЕВЕРНО (int32 overflow)
printf "%.0f", 4294967295  →  4294967295  ← верно
print 4294967295            →  4294967295  ← верно (default format)
```

**Решение в алгоритме:**
- Стадия 1 использует `print start, end` (default format → корректно)
- Стадия 3 выводит `printf "%d.%d.%d.%d/%d"` — октеты всегда 0–255,
  prefix всегда 0–32, переполнения нет
- Промежуточные значения **нигде** не печатаются через `%d`

## 4. Спецификация функций

### 4.1. Публичная: `list_aggregate_cidrs`

Размещение: [`lib/lists.sh`](../../lib/lists.sh) — после [`list_count()`](../../lib/lists.sh:101) (строка 106).

```
stdin:   CIDR-строки (одна на строку, допускаются комментарии/пустые)
stdout:  агрегированные CIDR-строки
stderr:  ничего (невалидные строки молча пропускаются)
exit 0:  всегда (пустой вход → пустой выход)
```

```sh
# Pipe filter: aggregate (merge overlapping/adjacent) CIDR subnets.
# Strict: only exact merges, no supernetting.
# stdin: CIDR lines (one per line, comments/blanks skipped)
# stdout: minimal set of CIDRs covering the same IP space
list_aggregate_cidrs() {
  _cidr_to_ranges | sort -n | _merge_and_emit_cidrs
}
```

### 4.2. Приватный хелпер: `_cidr_to_ranges`

```sh
# Parse CIDR lines to numeric ranges.
# stdin: CIDR lines; stdout: "start end" decimal per line.
# Invalid lines silently skipped.
_cidr_to_ranges() {
  awk '
    /^[[:space:]]*($|#)/ { next }
    {
      sub(/#.*/, "")
      gsub(/[[:space:]]/, "")
      if ($0 == "") next

      n = split($0, parts, "/")
      if (n != 2) next
      prefix = int(parts[2])
      if (prefix < 0 || prefix > 32) next

      m = split(parts[1], o, ".")
      if (m != 4) next
      for (i = 1; i <= 4; i++)
        if (o[i] < 0 || o[i] > 255) next

      ip = o[1]*16777216 + o[2]*65536 + o[3]*256 + o[4]

      ms = 1
      for (i = 0; i < 32 - prefix; i++) ms *= 2

      start = ip - (ip % ms)
      print start, start + ms - 1
    }
  '
}
```

~25 строк. В лимите 50 строк/функция.

### 4.3. Приватный хелпер: `_merge_and_emit_cidrs`

```sh
# Merge sorted ranges, emit minimal CIDRs.
# stdin: sorted "start end" lines; stdout: CIDR lines.
# Uses precomputed pow2[] table — saves ~33% time vs loop computation.
_merge_and_emit_cidrs() {
  awk '
    BEGIN { p2[0] = 1; for (i = 1; i <= 32; i++) p2[i] = p2[i-1] * 2 }

    function emit(s, e,    ab, sb, k, a, b, c, d, tmp) {
      while (s <= e) {
        if (s == 0) { ab = 32 }
        else { ab = 0; tmp = s; while (tmp % 2 == 0) { ab++; tmp /= 2 } }

        sb = 0
        while (p2[sb + 1] <= e - s + 1) sb++

        k = (ab < sb) ? ab : sb

        a = int(s / 16777216) % 256
        b = int(s / 65536) % 256
        c = int(s / 256) % 256
        d = int(s) % 256
        printf "%d.%d.%d.%d/%d\n", a, b, c, d, 32 - k

        s = s + p2[k]
      }
    }

    NR == 1 { ms = $1; me = $2; next }
    {
      if ($1 <= me + 1) { if ($2 > me) me = $2 }
      else { emit(ms, me); ms = $1; me = $2 }
    }
    END { if (NR > 0) emit(ms, me) }
  '
}
```

~35 строк. В лимите 50 строк/функция.

### 4.4. Профилирование и отвергнутые альтернативы (router-1)

| Вариант | Время | Корректность | Причина отказа |
|---------|-------|--------------|----------------|
| **3-stage + pow2 (выбран)** | **2s** | ✅ | — |
| 3-stage без pow2 | 3s | ✅ | Медленнее на 33% |
| Single-awk + shellsort | 6s | ❌ баги | Медленнее 3×, сложнее, некорректно |
| Single-pass без sort | 1s | ❌ | Вход не строго числово отсортирован (~10% записей переставлены `sort -n`) → ошибочная сверх-агрегация (5930 вместо 8307) |

**Почему `sort -n` обязателен:** ipdeny.com выдаёт CIDR, визуально отсортированные по IP. Но после конвертации в числовые диапазоны, ~1135 из 11286 записей оказываются не на своём месте. Без sort результат **некорректен**.

**Почему 3-stage pipeline оптимален:**
- BusyBox `sort -n` (C-реализация) быстрее любого awk-sort ~3×
- Два лёгких awk-процесса лучше одного тяжёлого с внутренней сортировкой
- Pipeline проще для чтения, отладки, тестирования

## 5. Интеграция

### 5.1. `update-subnets.sh` — точка вставки

Файл: [`geo-bypass/scripts/update-subnets.sh`](../scripts/update-subnets.sh)

В функции [`try_download()`](../scripts/update-subnets.sh:64), между проверкой размера
(строка 83, `else`-ветка) и перемещением файла (строка 85, `mv`).

**Текущий код (строки 80–88):**

```sh
80:       if [ "$count" -lt 100 ]; then
81:         log_error "Downloaded list too small ..."
82:         rm -f "$tmp_file"
83:       else
84:         mv "$tmp_file" "$SUBNET_LIST_FILE"      # ← вставка ПЕРЕД
85:         log "Updated subnet list: $count subnets (via $iface)"
86:         return 0
87:       fi
```

**Вставить между строками 83 и 84:**

```sh
        # Aggregate overlapping/adjacent CIDRs if enabled
        if [ "${SUBNET_AGGREGATE:-0}" = "1" ]; then
          local before_count="$count"
          list_aggregate_cidrs < "$tmp_file" > "${tmp_file}.agg"
          mv "${tmp_file}.agg" "$tmp_file"
          count=$(wc -l < "$tmp_file")
          log "Aggregated CIDRs: $before_count -> $count"
        fi
```

### 5.2. `config.sh` — новая переменная

Файл: [`geo-bypass/config/config.sh`](../config/config.sh)

Вставить после строки 53 (`SUBNET_LOADER`):

```sh
# Aggregate (merge overlapping/adjacent) downloaded subnets to reduce ipset size.
# Strict: only exact merges, no supernetting. 0 = disabled, 1 = enabled.
SUBNET_AGGREGATE=0
```

Новые строки 54–56 (сдвиг последующих на +3).

Значение `0` по умолчанию — поведение не меняется без явного включения.

## 6. Edge Cases и тестовые примеры

### 6.1. Смежные /24 → /23

```
Вход:               Выход:
10.0.0.0/24          10.0.0.0/23
10.0.1.0/24
```

`10.0.0.0–10.0.0.255` + `10.0.1.0–10.0.1.255` = `10.0.0.0–10.0.1.255`.
Размер 512 = 2^9. `10.0.0.0` выровнен по 2^9. → `/23`. ✓

### 6.2. Перекрытие — поглощение

```
Вход:               Выход:
10.0.0.0/16          10.0.0.0/16
10.0.1.0/24
```

`/24` целиком внутри `/16`. Merged range ≡ `/16`. ✓

### 6.3. Несмежные — без изменений

```
Вход:               Выход:
10.0.0.0/24          10.0.0.0/24
10.0.2.0/24          10.0.2.0/24
```

Gap: `10.0.1.0/24` отсутствует → диапазоны не сливаются. ✓

### 6.4. Одиночный /32

```
Вход:               Выход:
1.2.3.4/32           1.2.3.4/32
```

### 6.5. Цепочка /24 → /22

```
Вход:               Выход:
10.0.0.0/24          10.0.0.0/22
10.0.1.0/24
10.0.2.0/24
10.0.3.0/24
```

Merged: `10.0.0.0–10.0.3.255` = 1024 IP = 2^10. Выравнивание `10.0.0.0` по 2^10 ✓. → `/22`.

### 6.6. Неполная цепочка (3 × /24) → разбиение

```
Вход:               Выход:
10.0.0.0/24          10.0.0.0/23
10.0.1.0/24          10.0.2.0/24
10.0.2.0/24
```

Merged: `10.0.0.0–10.0.2.255` = 768 IP. Не степень двойки.
- `s=10.0.0.0`, align=25 бит (10.0.0.0 = 2^25 × 5), size 768 → size_bits=9, k=min(25,9)=9 → `/23` (512 IP)
- `s=10.0.2.0`, remain=256 → `/24`

Итого: 3 CIDR → 2. ✓

### 6.7. Пустой вход → пустой выход

awk END: проверка `NR > 0` → при пустом входе ничего не выводится. ✓

### 6.8. Невалидные строки → пропускаются

```
not_a_cidr           (пусто)
256.1.2.3/24
10.0.0.0/33
```

### 6.9. Дубликаты → одна запись

```
Вход:               Выход:
10.0.0.0/24          10.0.0.0/24
10.0.0.0/24
```

### 6.10. Ненормализованный CIDR

```
Вход:               Выход:
10.0.0.5/24          10.0.0.0/24
```

Host-биты сбрасываются при парсинге: `start = ip − (ip % mask_size)`.

### 6.11. Верификация на реальных данных (ipdeny.com ru.zone)

```
Вход:  2.56.24.0/23 + 2.56.26.0/23    →  Выход: 2.56.24.0/22   ✓ (первый merge в файле)
```

## 7. Сводка изменений

| Файл | Действие | Строки |
|------|----------|--------|
| [`lib/lists.sh`](../../lib/lists.sh) | 3 функции после строки 106 | +~70 строк |
| [`geo-bypass/scripts/update-subnets.sh`](../scripts/update-subnets.sh) | Блок агрегации между строками 83–84 | +~7 строк |
| [`geo-bypass/config/config.sh`](../config/config.sh) | `SUBNET_AGGREGATE` после строки 53 | +~3 строки |

## 8. Соответствие стандартам

| Требование (`.project/`) | Реализация |
|---------------------------|------------|
| POSIX sh (BusyBox ash) | `#!/opt/bin/sh`, `set -eu`, `[ ]`, нет bashизмов |
| Функция ≤ 50 строк | `list_aggregate_cidrs`: 3, `_cidr_to_ranges`: ~25, `_merge_and_emit_cidrs`: ~35 |
| Скрипт ≤ 200 строк | `lib/lists.sh` после добавления: ~175 строк |
| Shellcheck | awk в одинарных кавычках, нет warn-конструкций |
| Pipe-friendly | stdin → stdout, композиция через `\|` |
| Стиль `lib/lists.sh` | Публичная `list_*` + приватные `_*` хелперы |
| Over-engineering ≤ 5% | Нет лишних абстракций; одна опция в config |
| BusyBox awk совместимость | Нет `%d` для больших чисел, только `print` / `%.0f` |

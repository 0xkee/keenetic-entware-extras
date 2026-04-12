# Архитектура библиотеки `lib/lists.sh`

## 1. Назначение

Общая POSIX sh библиотека для чтения, нормализации и обработки текстовых list-файлов (домены, подсети, IP) с поддержкой `@include` — используется всеми подпроектами.

## 2. Публичный API

### 2.1. `list_read <file>` — основная функция

Читает list-файл, обрабатывает `@include`-директивы, нормализует строки.

```
Аргументы: $1 — путь к файлу
stdin:     не используется
stdout:    чистые строки (по одной на строку)
stderr:    предупреждения (@include ошибки)
exit 0:    успех
exit 1:    файл не найден
```

Что делает:
- Читает файл построчно
- Trim пробелов с обоих концов строки
- Пропускает пустые строки и комментарии (`# ...`)
- Обрабатывает `@include`-директивы (см. раздел 3.1)
- Выводит чистые строки в stdout

Пример:
```sh
# Прочитать список с @include, дедуплицировать, отсортировать
list_read "$DOMAINS_LIST_FILE" | list_dedup | sort

# Прочитать и обработать построчно
list_read "$LIST_FILE" | while read -r line; do
  ipset add myset "$line" -exist
done
```

### 2.2. `list_strip` — pipe-фильтр нормализации

Нормализует поток строк: убирает комментарии, пустые строки, trim пробелов. Pipe-версия логики очистки из `list_read`, но без `@include`.

```
stdin:     сырые строки
stdout:    чистые строки
exit 0:    всегда
```

Реализация (одна строка):
```sh
list_strip() {
  sed 's/[[:space:]]*#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$'
}
```

Пример:
```sh
# Фильтрация скачанного списка подсетей
curl -sS "$URL" | grep -v ':' | list_strip

# Вместо повторяющегося grep -vE '^#|^$'
list_strip < "$SUBNET_LIST_FILE" | while read -r subnet; do
  echo "route add $subnet dev $IFACE table $TABLE"
done
```

> **Отличие от `list_read`:** `list_strip` работает с stdin (pipe), не обрабатывает `@include`, не покажет ошибку при отсутствии файла. Используется когда данные уже в потоке (curl, другая команда) или не нужны @include.

### 2.3. `list_dedup` — pipe-фильтр дедупликации

Удаляет дублирующиеся строки, сохраняя порядок первого вхождения.

```
stdin:     строки (после list_strip или list_read)
stdout:    уникальные строки в порядке первого вхождения
exit 0:    всегда
```

Реализация:
```sh
list_dedup() {
  awk '!seen[$0]++'
}
```

### 2.4. `list_count <file>` — подсчёт значащих строк

Считает строки в list-файле, пропуская комментарии и пустые строки. Не обрабатывает `@include` (считает только прямые строки файла).

```
Аргументы: $1 — путь к файлу
stdout:    число (количество строк)
exit 0:    успех
exit 1:    файл не найден
```

Реализация:
```sh
list_count() {
  grep -cvE '^[[:space:]]*(#|$)' "$1" || echo 0
}
```

> Заменяет повторяющийся паттерн `grep -cvE '^#|^$' "$file"` в `attach-rules.sh` (строки 76, 79).

## 3. Ключевые решения

### 3.1. @include синтаксис

**Формат:** строка начинающаяся с `@` — директива включения файла.

```
@filename            → <dir текущего файла>/filename
@subdir/filename     → <dir текущего файла>/subdir/filename
```

**Правила:**
- Путь **всегда относителен** к директории включающего файла
- Абсолютные пути (`@/opt/...`) — **не поддерживаются** (безопасность, переносимость)
- `@` без имени файла — ошибка (warning на stderr, строка пропускается)

**Пример структуры:**
```
geo-split-data/lists/
  domains.txt          # @common/banks.txt
  custom-domains.txt   # обычные домены
  common/
    banks.txt          # sberbank.ru, tinkoff.ru, ...
    government.txt     # gosuslugi.ru, nalog.ru, ...
```

```
# domains.txt
@common/banks.txt
@common/government.txt
custom-domain.ru
another-domain.com
```

**Защита от циклов:**
- Отслеживание посещённых файлов (по абсолютному пути)
- При обнаружении цикла: warning на stderr, файл пропускается
- Лимит глубины вложенности: 10 уровней (предотвращает случайную рекурсию)

**Обработка ошибок @include:**
- Файл не найден → warning на stderr, **продолжаем** (graceful degradation)
- Цикл → warning на stderr, пропускаем
- Превышена глубина → warning на stderr, пропускаем

> Обоснование: graceful degradation для @include, потому что частичный список лучше, чем полный отказ. Но сам `list_read` возвращает exit 1, если корневой файл не найден.

### 3.2. Стратегия дедупликации

**`awk '!seen[$0]++'`** — стандартный POSIX-совместимый подход:
- Сохраняет порядок первого вхождения
- O(n) по памяти, O(n) по времени
- Работает с BusyBox awk
- Решение: выделена в отдельную функцию `list_dedup`, а не встроена в `list_read` — позволяет использовать выборочно (ipset handle дедупликацию сам)

### 3.3. Обработка inline-комментариев

`list_strip` удаляет inline-комментарии: `domain.com # пояснение` → `domain.com`.
`list_read` делает то же. Это безопасно для доменов и CIDR, но стоит документировать.

### 3.4. Нормализация vs. валидация

Библиотека **нормализует** (strip, trim, dedup), но **не валидирует** формат (CIDR, домены). Причина: валидация формата специфична для потребителя — подсети и домены имеют разные правила. При необходимости, валидаторы добавляются как отдельные pipe-фильтры вне этой библиотеки (Phase 2).

### 3.5. is_cache_fresh → lib/common.sh

`is_cache_fresh()` дублируется в `update-domains.sh` и `update-subnets.sh`, но это функция работы с кэшем, а не списками. Рекомендация: перенести в [`lib/common.sh`](lib/common.sh) вместе с этим рефакторингом.

```sh
# Добавить в lib/common.sh:
# Check if file is fresh (younger than max_age seconds)
# Args: $1 - file path, $2 - max age in seconds
is_cache_fresh() {
  local file="$1" max_age="$2"
  [ -f "$file" ] || return 1
  local file_age
  file_age=$(( $(date +%s) - $(file_mtime "$file") ))
  [ "$file_age" -lt "$max_age" ]
}
```

## 4. Миграционный план

### 4.0. `lib/common.sh` — добавить `is_cache_fresh()`

Перенести из дублированных скриптов:
- [`update-domains.sh:14-20`](geo-split/scripts/update-domains.sh:14) — удалить локальную копию
- [`update-subnets.sh:15-21`](geo-split/scripts/update-subnets.sh:15) — удалить локальную копию

### 4.1. `update-domains.sh` — основной бенефициар

| Строки | Текущий код | Замена |
|--------|-------------|--------|
| 14-20 | Локальная `is_cache_fresh()` | Удалить (из `common.sh`) |
| 75-83 | `while read + sed trim + case skip` | `list_read "$DOMAINS_LIST_FILE" \| while read -r line` |

### 4.2. `load-ipset.sh` — два места фильтрации

| Строки | Текущий код | Замена |
|--------|-------------|--------|
| 68-72 | `while read + case ""|\#*` | `list_strip < "$SUBNET_LIST_FILE" \| while read -r subnet` |
| 103-106 | `while read + case ""|\#*` | `list_strip < "$src_file" \| while read -r ip` |

### 4.3. `attach-rules.sh` — повторяющийся grep

| Строки | Текущий код | Замена |
|--------|-------------|--------|
| 76, 79 | `grep -cvE '^#\|^$' "$file"` | `list_count "$file"` |
| 89 | `grep -vE '^#\|^$' "$SUBNET_LIST_FILE"` | `list_strip < "$SUBNET_LIST_FILE"` |
| 94 | `grep -vE '^#\|^$' "$DOMAINS_CACHE_FILE"` | `list_strip < "$DOMAINS_CACHE_FILE"` |
| 113 | `grep -vE '^#\|^$' "$SUBNET_LIST_FILE"` | `list_strip < "$SUBNET_LIST_FILE"` |
| 118 | `grep -vE '^#\|^$' "$DOMAINS_CACHE_FILE"` | `list_strip < "$DOMAINS_CACHE_FILE"` |

### 4.4. `cidr-plain.sh` — фильтрация комментариев

| Строки | Текущий код | Замена |
|--------|-------------|--------|
| 17 | `grep -v ':' \| grep -v '^#' \| grep -v '^$'` | `grep -v ':' \| list_strip` |

### 4.5. Подключение библиотеки

Все скрипты уже подключают `lib/common.sh`:
```sh
. "$SCRIPT_DIR/../../lib/common.sh"
```

Добавить аналогично:
```sh
. "$SCRIPT_DIR/../../lib/lists.sh"
```

> **Поэтапность:** можно мигрировать скрипт за скриптом. Каждая замена — отдельный коммит, проверяемый независимо.

## 5. Границы scope — что НЕ входит в lib/lists.sh

| Область | Причина исключения |
|---------|--------------------|
| **Скачивание** (curl, wget) | Это задача loader-скриптов, не обработки списков |
| **ipset операции** (create, add, swap) | Специфика geo-split, не общая обработка |
| **ip route операции** | Специфика geo-split routing |
| **DNS-резолвинг** (dig) | Специфика update-domains.sh |
| **filter_private_ips()** | Специфика geo-split, используется в одном месте |
| **is_cache_fresh()** | Вынести в `lib/common.sh` (кэш ≠ списки) |
| **Валидация CIDR/доменов** | Phase 2 (если потребуется), формат-специфичная логика |
| **Сортировка** | `sort` — стандартная утилита, обёртка не нужна |
| **Генерация/запись списков** | Библиотека только читает и обрабатывает |

## Размер библиотеки

Ожидаемый размер `lib/lists.sh`: **~60-70 строк** (включая комментарии и header).
4 публичные функции. Соответствует target-code.md: <200 строк на скрипт, <50 строк на функцию.

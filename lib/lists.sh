#!/opt/bin/sh
# lib/lists.sh — list processing library (read, normalize, dedup)
# Source: . ./lib/lists.sh (after common.sh which provides log_error)
# shellcheck disable=SC3043  # 'local' supported by ash/busybox sh
set -eu

# Maximum @include nesting depth
_LIST_READ_MAX_DEPTH=10

# Read list file with @include support, normalize lines.
# Strips comments, empty lines, trims whitespace.
# Supports @filename includes relative to the including file's directory.
# Protected against circular includes and excessive nesting (depth 10).
# Args: $1 - file path
# stdout: clean lines (one per line)
# stderr: warnings for @include errors
# Returns: 0 on success, 1 if file not found
list_read() {
  local file="$1"
  [ -f "$file" ] || { log_error "list_read: file not found: $file"; return 1; }
  _list_read_visited=""
  _list_read_impl "$file" 0
}

# Internal recursive implementation for list_read.
# Args: $1 - file path, $2 - current nesting depth
_list_read_impl() {
  local file="$1" depth="$2"
  local abs_path dir line include_file

  abs_path="$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"

  # Check depth limit
  if [ "$depth" -gt "$_LIST_READ_MAX_DEPTH" ]; then
    log_error "list_read: max include depth exceeded: $file"
    return 0
  fi

  # Check for circular includes via visited set
  case "$_list_read_visited" in
    *"|${abs_path}|"*)
      log_error "list_read: circular include detected: $file"
      return 0
      ;;
  esac

  _list_read_visited="${_list_read_visited}|${abs_path}|"
  dir="$(dirname "$abs_path")"

  while read -r line; do
    # read -r with default IFS trims leading/trailing whitespace

    # Skip empty lines and full-line comments
    case "$line" in
      "" | \#*) continue ;;
    esac

    # Remove inline comments (everything from ' #' onward)
    line="${line%% #*}"

    # Handle @include directives
    case "$line" in
      "@")
        log_error "list_read: empty @include in $file"
        continue
        ;;
      @*)
        include_file="${dir}/${line#@}"
        if [ ! -f "$include_file" ]; then
          log_error "list_read: include not found: ${line#@} (from $file)"
          continue
        fi
        _list_read_impl "$include_file" $((depth + 1))
        continue
        ;;
    esac

    printf '%s\n' "$line"
  done < "$file"
}

# Pipe filter: strip comments, empty lines, trim whitespace.
# Does not process @include directives.
# stdin: raw lines
# stdout: clean lines
list_strip() {
  sed 's/[[:space:]]*#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$'
}

# Pipe filter: deduplicate lines preserving first occurrence order.
# stdin: lines (typically after list_strip or list_read)
# stdout: unique lines in order of first occurrence
list_dedup() {
  awk '!seen[$0]++'
}

# list_count <file>
# Counts non-comment/non-empty lines in <file> WITHOUT expanding @include
# directives. For recursive count use list_count_expanded().
# Args: $1 - file path
# stdout: number of meaningful lines
# Returns: 0 on success, 1 if file not found
list_count() {
  [ -f "$1" ] || { log_error "list_count: file not found: $1"; return 1; }
  _cnt=$(grep -cvE '^[[:space:]]*(#|$)' "$1" 2>/dev/null) || _cnt=0
  echo "$_cnt"
}

# list_count_expanded <file>
# Count domain/value entries recursively expanding @include directives.
# Prints count to stdout.
list_count_expanded() {
  [ -n "${1:-}" ] || { echo 0; return 0; }
  [ -f "$1" ] || { echo 0; return 0; }
  list_read "$1" 2>/dev/null | wc -l | tr -d ' '
}

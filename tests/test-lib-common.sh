#!/bin/sh
# Unit tests for deterministic helpers in lib/common.sh.
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." && pwd)

# shellcheck disable=SC1091
. "$SCRIPT_DIR/testlib.sh"
. "$ROOT/lib/common.sh"

assert_eq 'format_age formats seconds' '5s' "$(format_age 5)"
assert_eq 'format_age formats minutes' '8m 42s' "$(format_age 522)"
assert_eq 'format_age formats hours' '1h 15m 3s' "$(format_age 4503)"
assert_eq 'format_age formats days' '2d 5h 30m' "$(format_age 192600)"

assert_eq 'format_size_kb formats kilobytes' '432 KB' "$(format_size_kb 432)"
assert_eq 'format_size_kb formats megabytes' '11.1 MB' "$(format_size_kb 11366)"
assert_eq 'format_size_kb formats gigabytes' '1.2 GB' "$(format_size_kb 1258291)"

assert_eq 'json_escape_val escapes quotes' 'a\"b' "$(json_escape_val 'a"b')"
assert_eq 'json_escape_val escapes backslashes' 'a\\b' "$(json_escape_val 'a\b')"
assert_eq 'json_escape_val escapes newlines' 'a\nb' "$(json_escape_val 'a
b')"
assert_eq 'json_escape_val escapes tabs' 'a\tb' "$(json_escape_val "$(printf 'a\tb')")"
assert_eq 'json_kv emits an escaped string' '"name":"a\"b"' "$(json_kv 'name' 'a"b')"
assert_eq 'json_kv_num emits a number' '"count":42' "$(json_kv_num 'count' 42)"
assert_eq 'json_kv_bool emits true for zero' '"enabled":true' "$(json_kv_bool 'enabled' 0)"
assert_eq 'json_kv_bool emits false for non-zero' '"enabled":false' "$(json_kv_bool 'enabled' 1)"
assert_eq 'json_kv_bool defaults to false when arg omitted' '"enabled":false' "$(json_kv_bool 'enabled')"
assert_eq 'json_check emits status' '"cache":"warn"' "$(json_check 'cache' 'warn')"

items=''
json_arr_add items '"one"'
json_arr_add items '"two"'
assert_eq 'json_arr_add appends values' '"one","two"' "$items"

test_summary 'lib/common.sh'

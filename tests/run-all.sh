#!/bin/sh
# Run all development-time unit tests.
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
FAILED=0

for test_file in "$SCRIPT_DIR"/test-*.sh; do
    [ -x "$test_file" ] || continue
    printf '\n=== %s ===\n' "$(basename "$test_file")"
    "$test_file" || FAILED=1
done

exit "$FAILED"

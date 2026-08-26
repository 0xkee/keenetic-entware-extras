#!/bin/sh
# Run all development-time unit tests.
set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
FAILED=0

for test_file in "$SCRIPT_DIR"/test-*.sh; do
    if [ ! -x "$test_file" ]; then
        printf 'SKIP (not executable): %s\n' "$(basename "$test_file")"
        continue
    fi
    printf '\n=== %s ===\n' "$(basename "$test_file")"
    "$test_file" || FAILED=1
done

exit "$FAILED"

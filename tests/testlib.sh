#!/bin/sh
# Shared assertion helpers for development-time unit tests.
set -eu

TEST_PASS=0
TEST_FAIL=0

pass() {
    TEST_PASS=$((TEST_PASS + 1))
    printf '  ✓ %s\n' "$1"
}

fail() {
    TEST_FAIL=$((TEST_FAIL + 1))
    printf '  ✗ %s\n' "$1"
}

assert_ok() {
    test_name="$1"
    shift
    if "$@"; then
        pass "$test_name"
    else
        fail "$test_name"
    fi
}

assert_fail() {
    test_name="$1"
    shift
    if "$@"; then
        fail "$test_name (expected failure)"
    else
        pass "$test_name"
    fi
}

assert_eq() {
    test_name="$1"
    expected="$2"
    actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$test_name"
    else
        fail "$test_name: expected '$expected', got '$actual'"
    fi
}

test_summary() {
    printf '%s: %s passed, %s failed\n' "$1" "$TEST_PASS" "$TEST_FAIL"
    [ "$TEST_FAIL" -eq 0 ]
}

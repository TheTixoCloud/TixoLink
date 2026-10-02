#!/usr/bin/env bash
# TixoLink NEXUS - minimal TAP-style unit test harness.
#
# No external test runner dependency (bats, etc.) is pulled in; this is
# intentionally small. Source this file, then call th::run for each test
# function, then th::summary at the end.

TH_PASS=0
TH_FAIL=0

th::assert_eq() {
    local actual="$1" expected="$2" msg="${3:-}"
    if [[ "$actual" == "$expected" ]]; then
        return 0
    fi
    printf '    assert_eq failed%s: expected [%s], got [%s]\n' \
        "${msg:+ ($msg)}" "$expected" "$actual" >&2
    return 1
}

th::assert_true() {
    local msg="${2:-}"
    if "$1"; then
        return 0
    fi
    printf '    assert_true failed%s\n' "${msg:+ ($msg)}" >&2
    return 1
}

th::assert_false() {
    local msg="${2:-}"
    if ! "$1"; then
        return 0
    fi
    printf '    assert_false failed%s\n' "${msg:+ ($msg)}" >&2
    return 1
}

# th::run <test-function-name>
th::run() {
    local name="$1"
    if "$name"; then
        TH_PASS=$((TH_PASS + 1))
        printf '  ok - %s\n' "$name"
    else
        TH_FAIL=$((TH_FAIL + 1))
        printf '  FAIL - %s\n' "$name"
    fi
}

# th::summary - prints totals, returns 1 if any test failed.
th::summary() {
    printf '%d passed, %d failed\n' "$TH_PASS" "$TH_FAIL"
    [[ "$TH_FAIL" -eq 0 ]]
}

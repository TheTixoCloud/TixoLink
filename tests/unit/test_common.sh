#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$TEST_DIR/../.." && pwd)"
TIXOLINK_LIB_DIR="$REPO_ROOT/lib"
export TIXOLINK_LIB_DIR

# shellcheck source=tests/lib/test_harness.sh
source "$REPO_ROOT/tests/lib/test_harness.sh"
# shellcheck source=lib/common.sh
source "$TIXOLINK_LIB_DIR/common.sh"

test_version_reads_version_file() {
    local v
    v="$(common::version)"
    th::assert_eq "$v" "0.1.0-dev"
}

test_trim_strips_whitespace() {
    th::assert_eq "$(common::trim '   hello world   ')" "hello world"
}

test_lower_lowercases() {
    th::assert_eq "$(common::lower 'MixedCASE')" "mixedcase"
}

test_join_joins_with_separator() {
    th::assert_eq "$(common::join ',' a b c)" "a,b,c"
}

test_join_single_element() {
    th::assert_eq "$(common::join ',' onlyone)" "onlyone"
}

test_is_integer_accepts_digits() {
    common::is_integer "12345"
}

test_is_integer_rejects_non_digits() {
    ! common::is_integer "12a45"
}

test_exit_codes_are_distinct() {
    local -a codes=("$EXIT_OK" "$EXIT_GENERIC" "$EXIT_USAGE" "$EXIT_VALIDATION" \
        "$EXIT_CONFLICT" "$EXIT_NOT_FOUND" "$EXIT_PERMISSION" "$EXIT_DEPENDENCY" \
        "$EXIT_LOCK_TIMEOUT" "$EXIT_ROLLED_BACK")
    local -A seen=()
    local c
    for c in "${codes[@]}"; do
        [[ -n "${seen[$c]:-}" ]] && return 1
        seen[$c]=1
    done
    return 0
}

test_mktemp_file_creates_private_file() {
    local f
    f="$(common::mktemp_file)"
    [[ -f "$f" ]] || return 1
    local mode
    mode="$(stat -c '%a' "$f")"
    th::assert_eq "$mode" "600"
}

th::run test_version_reads_version_file
th::run test_trim_strips_whitespace
th::run test_lower_lowercases
th::run test_join_joins_with_separator
th::run test_join_single_element
th::run test_is_integer_accepts_digits
th::run test_is_integer_rejects_non_digits
th::run test_exit_codes_are_distinct
th::run test_mktemp_file_creates_private_file

th::summary

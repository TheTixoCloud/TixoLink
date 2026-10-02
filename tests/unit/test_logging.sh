#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$TEST_DIR/../.." && pwd)"
TIXOLINK_LIB_DIR="$REPO_ROOT/lib"
export TIXOLINK_LIB_DIR

TIXOLINK_TEST_ROOT="$(mktemp -d /tmp/tixolink-test.XXXXXXXX)"
export TIXOLINK_LOG_FILE="$TIXOLINK_TEST_ROOT/tixolink.log"
export TIXOLINK_HISTORY_FILE="$TIXOLINK_TEST_ROOT/history.jsonl"

cleanup() { rm -rf -- "$TIXOLINK_TEST_ROOT"; }
trap cleanup EXIT

# shellcheck source=tests/lib/test_harness.sh
source "$REPO_ROOT/tests/lib/test_harness.sh"
# shellcheck source=lib/common.sh
source "$TIXOLINK_LIB_DIR/common.sh"
# shellcheck source=lib/logging.sh
source "$TIXOLINK_LIB_DIR/logging.sh"

test_info_is_recorded_in_log_file_by_default() {
    log::info "hello from test" >/dev/null
    grep -q "hello from test" "$TIXOLINK_LOG_FILE"
}

test_debug_is_not_recorded_in_log_file_by_default() {
    : >"$TIXOLINK_LOG_FILE"
    log::debug "should not appear" >/dev/null 2>&1 || true
    ! grep -q "should not appear" "$TIXOLINK_LOG_FILE"
}

test_error_goes_to_stderr_not_stdout() {
    local out
    out="$(log::error "boom" 2>/dev/null)"
    th::assert_eq "$out" ""
}

test_set_debug_raises_terminal_threshold() {
    log::set_debug
    local out
    out="$(log::debug "now visible" 2>&1)"
    log::set_verbose >/dev/null 2>&1 || true
    TIXOLINK_LOG_TERMINAL_LEVEL=$LOG_LEVEL_WARN
    [[ "$out" == *"now visible"* ]]
}

test_history_writes_valid_json_line() {
    log::history "create" "abc12345" "success"
    local line
    line="$(tail -n1 "$TIXOLINK_HISTORY_FILE")"
    th::assert_eq "$(printf '%s' "$line" | jq -r '.operation')" "create"
}

th::run test_info_is_recorded_in_log_file_by_default
th::run test_debug_is_not_recorded_in_log_file_by_default
th::run test_error_goes_to_stderr_not_stdout
th::run test_set_debug_raises_terminal_threshold
th::run test_history_writes_valid_json_line

th::summary

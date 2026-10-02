#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$TEST_DIR/../.." && pwd)"
TIXOLINK_LIB_DIR="$REPO_ROOT/lib"
export TIXOLINK_LIB_DIR

TIXOLINK_TEST_ROOT="$(mktemp -d /tmp/tixolink-test.XXXXXXXX)"
export TIXOLINK_RUN_DIR="$TIXOLINK_TEST_ROOT/run"
export TIXOLINK_LOG_FILE="$TIXOLINK_TEST_ROOT/tixolink.log"

cleanup() { rm -rf -- "$TIXOLINK_TEST_ROOT"; }
trap cleanup EXIT

# shellcheck source=tests/lib/test_harness.sh
source "$REPO_ROOT/tests/lib/test_harness.sh"
# shellcheck source=lib/common.sh
source "$TIXOLINK_LIB_DIR/common.sh"
# shellcheck source=lib/logging.sh
source "$TIXOLINK_LIB_DIR/logging.sh"
# shellcheck source=lib/config.sh
source "$TIXOLINK_LIB_DIR/config.sh"
# shellcheck source=lib/locking.sh
source "$TIXOLINK_LIB_DIR/locking.sh"

test_acquire_and_release_succeeds() {
    locking::acquire "test-lock-a" 2 || return 1
    locking::release "test-lock-a"
    return 0
}

test_second_acquire_after_release_succeeds() {
    locking::acquire "test-lock-b" 2 || return 1
    locking::release "test-lock-b"
    locking::acquire "test-lock-b" 2 || return 1
    locking::release "test-lock-b"
    return 0
}

test_concurrent_lock_from_other_process_times_out() {
    # Hold the lock in a background subshell for longer than our timeout.
    (
        TIXOLINK_LOCK_FDS=()
        locking::acquire "test-lock-c" 5
        sleep 2
    ) &
    local bg_pid=$!
    sleep 0.3
    local status=0
    locking::acquire "test-lock-c" 1 || status=$?
    if [[ "$status" -eq 0 ]]; then
        locking::release "test-lock-c"
        wait "$bg_pid" 2>/dev/null || true
        return 1
    fi
    wait "$bg_pid" 2>/dev/null || true
    th::assert_eq "$status" "$EXIT_LOCK_TIMEOUT"
}

test_with_lock_releases_after_failing_command() {
    locking::with_lock "test-lock-d" 2 false || true
    locking::acquire "test-lock-d" 1
    locking::release "test-lock-d"
}

th::run test_acquire_and_release_succeeds
th::run test_second_acquire_after_release_succeeds
th::run test_concurrent_lock_from_other_process_times_out
th::run test_with_lock_releases_after_failing_command

th::summary

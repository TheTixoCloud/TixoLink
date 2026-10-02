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
# shellcheck source=lib/transaction.sh
source "$TIXOLINK_LIB_DIR/transaction.sh"

test_happy_path_commits() {
    local marker="$TIXOLINK_TEST_ROOT/applied"
    tx::begin "test-tx-a" 2 || return 1
    tx::precheck true || { tx::rollback; return 1; }
    tx::backup true || { tx::rollback; return 1; }
    tx::plan true || { tx::rollback; return 1; }
    tx::apply touch "$marker" || { tx::rollback; return 1; }
    tx::verify test -f "$marker" || { tx::rollback; return 1; }
    tx::commit
    [[ -f "$marker" ]]
}

test_failed_verify_triggers_rollback() {
    local rollback_ran="$TIXOLINK_TEST_ROOT/rollback_ran"
    # Invoked indirectly below via `tx::rollback do_rollback` ("$@" dispatch).
    # shellcheck disable=SC2317
    do_rollback() { touch "$rollback_ran"; }

    tx::begin "test-tx-b" 2 || return 1
    tx::apply true
    if tx::verify false; then
        tx::commit
        return 1
    fi
    tx::rollback do_rollback
    [[ -f "$rollback_ran" ]]
}

test_dry_run_skips_apply() {
    local marker="$TIXOLINK_TEST_ROOT/dry_run_marker"
    tx::begin "test-tx-c" 2 || return 1
    tx::set_dry_run 1
    tx::apply touch "$marker"
    tx::verify true
    tx::commit
    tx::set_dry_run 0
    [[ ! -f "$marker" ]]
}

test_lock_is_released_after_commit() {
    tx::begin "test-tx-d" 2 || return 1
    tx::commit
    locking::acquire "test-tx-d" 1 || return 1
    locking::release "test-tx-d"
}

test_lock_is_released_after_rollback() {
    tx::begin "test-tx-e" 2 || return 1
    tx::rollback
    locking::acquire "test-tx-e" 1 || return 1
    locking::release "test-tx-e"
}

th::run test_happy_path_commits
th::run test_failed_verify_triggers_rollback
th::run test_dry_run_skips_apply
th::run test_lock_is_released_after_commit
th::run test_lock_is_released_after_rollback

th::summary

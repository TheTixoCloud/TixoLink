#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$TEST_DIR/../.." && pwd)"
TIXOLINK_LIB_DIR="$REPO_ROOT/lib"
export TIXOLINK_LIB_DIR

TIXOLINK_TEST_ROOT="$(mktemp -d /tmp/tixolink-test.XXXXXXXX)"
export TIXOLINK_ETC_DIR="$TIXOLINK_TEST_ROOT/etc"
export TIXOLINK_VAR_DIR="$TIXOLINK_TEST_ROOT/var"
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
# shellcheck source=lib/state.sh
source "$TIXOLINK_LIB_DIR/state.sh"

test_init_app_config_creates_file() {
    config::init_app_config
    [[ -f "$TIXOLINK_APP_CONFIG_FILE" ]]
}

test_init_app_config_is_idempotent() {
    config::init_app_config
    local first second
    first="$(cat "$TIXOLINK_APP_CONFIG_FILE")"
    config::init_app_config
    second="$(cat "$TIXOLINK_APP_CONFIG_FILE")"
    th::assert_eq "$first" "$second"
}

test_app_config_has_default_subnet_pool() {
    config::init_app_config
    th::assert_eq "$(config::get '.subnet_pool')" "10.200.0.0/16"
}

test_write_json_atomic_rejects_invalid_json() {
    ! config::write_json_atomic "$TIXOLINK_TEST_ROOT/bad.json" "not json"
}

test_write_json_atomic_writes_valid_json() {
    config::write_json_atomic "$TIXOLINK_TEST_ROOT/good.json" '{"a":1}'
    th::assert_eq "$(jq -r '.a' "$TIXOLINK_TEST_ROOT/good.json")" "1"
}

test_write_json_atomic_sets_mode() {
    config::write_json_atomic "$TIXOLINK_TEST_ROOT/modes.json" '{"a":1}' 0600
    th::assert_eq "$(stat -c '%a' "$TIXOLINK_TEST_ROOT/modes.json")" "600"
}

test_write_json_atomic_leaves_no_tmp_file_behind() {
    config::write_json_atomic "$TIXOLINK_TEST_ROOT/clean.json" '{"a":1}'
    local leftovers
    leftovers="$(find "$TIXOLINK_TEST_ROOT" -maxdepth 1 -name '.tixolink.*' | wc -l)"
    th::assert_eq "$leftovers" "0"
}

test_state_init_creates_file() {
    state::init
    [[ -f "$TIXOLINK_STATE_FILE" ]]
}

test_state_set_and_get_roundtrip() {
    state::init
    state::set '.tunnels["abc12345"] = {"owns": ["iface"]}'
    th::assert_eq "$(state::get '.tunnels["abc12345"].owns[0]')" "iface"
}

th::run test_init_app_config_creates_file
th::run test_init_app_config_is_idempotent
th::run test_app_config_has_default_subnet_pool
th::run test_write_json_atomic_rejects_invalid_json
th::run test_write_json_atomic_writes_valid_json
th::run test_write_json_atomic_sets_mode
th::run test_write_json_atomic_leaves_no_tmp_file_behind
th::run test_state_init_creates_file
th::run test_state_set_and_get_roundtrip

th::summary

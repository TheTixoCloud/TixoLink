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
source "$TIXOLINK_LIB_DIR/common.sh"
source "$TIXOLINK_LIB_DIR/logging.sh"
source "$TIXOLINK_LIB_DIR/config.sh"
source "$TIXOLINK_LIB_DIR/migration.sh"

# The production registry is empty (nothing has ever needed to migrate
# yet). These tests register a FIXTURE-only component ("widget") with its
# own fixture migrations, never touching the real config/tunnel/state
# registry, to prove the mechanism works independent of whether any real
# migration currently exists.
migration::current_version() {
    [[ "$1" == "widget" ]] && printf '3'
}

fixture_migrate_widget_0_to_1() {
    jq -c '.schema_version = 1 | .name = (.name // "unnamed")' <<<"$1"
}
fixture_migrate_widget_1_to_2() {
    jq -c '.schema_version = 2 | .color = (.color // "red")' <<<"$1"
}
fixture_migrate_widget_2_to_3() {
    jq -c '.schema_version = 3 | .size = (.size // "medium")' <<<"$1"
}
migration::register widget 0 fixture_migrate_widget_0_to_1
migration::register widget 1 fixture_migrate_widget_1_to_2
migration::register widget 2 fixture_migrate_widget_2_to_3

test_detect_version_defaults_to_zero() {
    th::assert_eq "$(migration::detect_version '{}')" "0"
}

test_plan_lists_all_steps() {
    local plan; plan="$(migration::plan widget '{"schema_version":0}')"
    th::assert_eq "$(wc -l <<<"$plan")" "3"
}

test_plan_empty_when_current() {
    local plan; plan="$(migration::plan widget '{"schema_version":3}')"
    th::assert_eq "$plan" ""
}

test_upgrade_applies_chain_in_order() {
    local result; result="$(migration::upgrade widget '{"schema_version":0}')"
    th::assert_eq "$(jq -r '.schema_version' <<<"$result")" "3"
    th::assert_eq "$(jq -r '.name' <<<"$result")" "unnamed"
    th::assert_eq "$(jq -r '.color' <<<"$result")" "red"
    th::assert_eq "$(jq -r '.size' <<<"$result")" "medium"
}

test_upgrade_is_noop_at_current_version() {
    local result; result="$(migration::upgrade widget '{"schema_version":3,"name":"keep"}')"
    th::assert_eq "$(jq -r '.name' <<<"$result")" "keep"
}

test_upgrade_fails_safe_on_newer_schema() {
    ! migration::upgrade widget '{"schema_version":99}' >/dev/null 2>&1
}

test_upgrade_fails_on_gap_in_chain() {
    # No migration registered from version 5 for this fixture component.
    ! migration::upgrade widget '{"schema_version":5}' >/dev/null 2>&1
}

test_migrate_file_backs_up_and_upgrades() {
    local f="$TIXOLINK_TEST_ROOT/widget.json"
    printf '{"schema_version":0}' >"$f"
    migration::migrate_file widget "$f" 0 0640
    th::assert_eq "$(jq -r '.schema_version' "$f")" "3"
}

test_migrate_file_is_idempotent() {
    local f="$TIXOLINK_TEST_ROOT/widget2.json"
    printf '{"schema_version":3,"name":"stable"}' >"$f"
    migration::migrate_file widget "$f" 0 0640
    th::assert_eq "$(jq -r '.name' "$f")" "stable"
}

test_migrate_file_refuses_newer_schema() {
    local f="$TIXOLINK_TEST_ROOT/widget3.json"
    printf '{"schema_version":99,"name":"future"}' >"$f"
    ! migration::migrate_file widget "$f" 0 0640 >/dev/null 2>&1
    th::assert_eq "$(jq -r '.name' "$f")" "future"
}

test_migrate_file_dry_run_does_not_write() {
    local f="$TIXOLINK_TEST_ROOT/widget4.json"
    printf '{"schema_version":0}' >"$f"
    migration::migrate_file widget "$f" 1 0640 >/dev/null
    th::assert_eq "$(jq -r '.schema_version' "$f")" "0"
}

th::run test_detect_version_defaults_to_zero
th::run test_plan_lists_all_steps
th::run test_plan_empty_when_current
th::run test_upgrade_applies_chain_in_order
th::run test_upgrade_is_noop_at_current_version
th::run test_upgrade_fails_safe_on_newer_schema
th::run test_upgrade_fails_on_gap_in_chain
th::run test_migrate_file_backs_up_and_upgrades
th::run test_migrate_file_is_idempotent
th::run test_migrate_file_refuses_newer_schema
th::run test_migrate_file_dry_run_does_not_write

th::summary

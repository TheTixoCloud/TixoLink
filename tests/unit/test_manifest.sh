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
source "$TIXOLINK_LIB_DIR/manifest.sh"

test_manifest_does_not_exist_initially() {
    th::assert_false manifest::exists
}

test_manifest_new_has_schema_version() {
    local m; m="$(manifest::new "1.0.0" "/bin/x" "/lib/x" "/etc/x" "/var/x" "/log/x" "/run/x" "/unit/x")"
    th::assert_eq "$(jq -r '.schema_version' <<<"$m")" "1"
    th::assert_eq "$(jq -r '.tixolink_version' <<<"$m")" "1.0.0"
}

test_manifest_add_file_and_owns_file() {
    local m; m="$(manifest::new "1.0.0" "/bin/x" "/lib/x" "/etc/x" "/var/x" "/log/x" "/run/x" "/unit/x")"
    m="$(manifest::add_file "$m" "/some/path" "deadbeef" "0644")"
    manifest::write "$m"
    th::assert_true manifest::exists
    manifest::owns_file "/some/path" || return 1
    ! manifest::owns_file "/other/path" || return 1
}

test_manifest_add_dir_dedupes() {
    local m; m="$(manifest::new "1.0.0" "/bin/x" "/lib/x" "/etc/x" "/var/x" "/log/x" "/run/x" "/unit/x")"
    m="$(manifest::add_dir "$m" "/some/dir")"
    m="$(manifest::add_dir "$m" "/some/dir")"
    th::assert_eq "$(jq -r '.dirs | length' <<<"$m")" "1"
}

test_manifest_verify_detects_missing_file() {
    local target="$TIXOLINK_TEST_ROOT/tracked.txt"
    printf 'hello' >"$target"
    local m; m="$(manifest::new "1.0.0" "/bin/x" "/lib/x" "/etc/x" "/var/x" "/log/x" "/run/x" "/unit/x")"
    m="$(manifest::add_file "$m" "$target" "$(manifest::sha256 "$target")" "0644")"
    manifest::write "$m"
    th::assert_true manifest::verify
    rm -f -- "$target"
    th::assert_false manifest::verify
}

test_manifest_verify_detects_modification() {
    local target="$TIXOLINK_TEST_ROOT/tracked2.txt"
    printf 'hello' >"$target"
    local m; m="$(manifest::new "1.0.0" "/bin/x" "/lib/x" "/etc/x" "/var/x" "/log/x" "/run/x" "/unit/x")"
    m="$(manifest::add_file "$m" "$target" "$(manifest::sha256 "$target")" "0644")"
    manifest::write "$m"
    printf 'tampered' >"$target"
    th::assert_false manifest::verify
}

test_manifest_bump_preserves_previous_version() {
    local m; m="$(manifest::new "1.0.0" "/bin/x" "/lib/x" "/etc/x" "/var/x" "/log/x" "/run/x" "/unit/x")"
    m="$(manifest::add_file "$m" "/some/path" "deadbeef" "0644")"
    m="$(manifest::bump "$m" "2.0.0")"
    th::assert_eq "$(jq -r '.previous_version' <<<"$m")" "1.0.0"
    th::assert_eq "$(jq -r '.tixolink_version' <<<"$m")" "2.0.0"
    th::assert_eq "$(jq -r '.files | length' <<<"$m")" "0"
}

th::run test_manifest_does_not_exist_initially
th::run test_manifest_new_has_schema_version
th::run test_manifest_add_file_and_owns_file
th::run test_manifest_add_dir_dedupes
th::run test_manifest_verify_detects_missing_file
th::run test_manifest_verify_detects_modification
th::run test_manifest_bump_preserves_previous_version

th::summary

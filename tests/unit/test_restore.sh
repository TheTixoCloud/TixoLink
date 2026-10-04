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
export TIXOLINK_TMP_DIR="$TIXOLINK_TEST_ROOT/tmp"
mkdir -p "$TIXOLINK_TMP_DIR"

cleanup() { rm -rf -- "$TIXOLINK_TEST_ROOT"; }
trap cleanup EXIT

source "$REPO_ROOT/tests/lib/test_harness.sh"
source "$TIXOLINK_LIB_DIR/common.sh"
source "$TIXOLINK_LIB_DIR/logging.sh"
source "$TIXOLINK_LIB_DIR/ui.sh"
source "$TIXOLINK_LIB_DIR/validation.sh"
source "$TIXOLINK_LIB_DIR/config.sh"
source "$TIXOLINK_LIB_DIR/state.sh"
source "$TIXOLINK_LIB_DIR/manifest.sh"
source "$TIXOLINK_LIB_DIR/migration.sh"
source "$REPO_ROOT/modules/backup.sh"
source "$REPO_ROOT/modules/restore.sh"

make_valid_backup() {
    config::init_app_config
    config::tunnel_write "deadbeef" '{"schema_version":1,"name":"t1","engine":"gre"}'
    backup::create --output "$1" --force >/dev/null
}

test_restore_rejects_missing_archive() {
    ! restore::run "$TIXOLINK_TEST_ROOT/does-not-exist.tar.gz" --force >/dev/null 2>&1
}

test_restore_rejects_malformed_archive() {
    printf 'not a tarball' >"$TIXOLINK_TEST_ROOT/bad.tar.gz"
    ! restore::run "$TIXOLINK_TEST_ROOT/bad.tar.gz" --force >/dev/null 2>&1
}

test_restore_rejects_checksum_mismatch() {
    local archive="$TIXOLINK_TEST_ROOT/tamper.tar.gz"
    make_valid_backup "$archive"
    local stage="$TIXOLINK_TEST_ROOT/tamper-stage"
    mkdir -p "$stage"
    tar -xzf "$archive" -C "$stage"
    printf '{"schema_version":1,"tampered":true}' >"$stage/backup/payload/config.json"
    tar --owner=0 --group=0 -czf "$archive" -C "$stage" backup
    ! restore::run "$archive" --force >/dev/null 2>&1
}

test_restore_rejects_entries_outside_backup_root() {
    local stage="$TIXOLINK_TEST_ROOT/abs-stage"
    mkdir -p "$stage/backup/payload"
    echo '{"schema_version":1,"included":[],"component_schema_versions":{"config":1,"tunnel":1,"state":1}}' >"$stage/backup/manifest.json"
    : >"$stage/backup/checksums.sha256"
    local archive="$TIXOLINK_TEST_ROOT/abs.tar.gz"
    # Archive root is "$stage/backup", not "backup" - every member name is
    # therefore rooted outside the expected "backup/" prefix.
    tar -czf "$archive" -C / "${stage#/}/backup"
    ! restore::run "$archive" --force >/dev/null 2>&1
}

test_restore_rejects_unsupported_backup_schema() {
    local archive="$TIXOLINK_TEST_ROOT/futureschema.tar.gz"
    make_valid_backup "$archive"
    local stage="$TIXOLINK_TEST_ROOT/future-stage"
    mkdir -p "$stage"
    tar -xzf "$archive" -C "$stage"
    local m; m="$(jq '.schema_version = 999' "$stage/backup/manifest.json")"
    printf '%s' "$m" >"$stage/backup/manifest.json"
    ( cd "$stage/backup" && find payload -type f | sort | xargs sha256sum ) >"$stage/backup/checksums.sha256"
    tar --owner=0 --group=0 -czf "$archive" -C "$stage" backup
    ! restore::run "$archive" --force >/dev/null 2>&1
}

test_restore_dry_run_changes_nothing() {
    local archive="$TIXOLINK_TEST_ROOT/dryrun.tar.gz"
    make_valid_backup "$archive"
    rm -f -- "$(config::tunnel_path deadbeef)"
    restore::run "$archive" --dry-run >/dev/null
    [[ ! -f "$(config::tunnel_path deadbeef)" ]]
}

test_restore_applies_exact_backed_up_state() {
    local archive="$TIXOLINK_TEST_ROOT/exact.tar.gz"
    make_valid_backup "$archive"
    # Mutate current state after taking the backup: add an extra tunnel
    # not in the backup, and change the existing one.
    config::tunnel_write "deadbeef" '{"schema_version":1,"name":"CHANGED","engine":"gre"}'
    config::tunnel_write "cafebabe" '{"schema_version":1,"name":"extra","engine":"gre"}'
    restore::run "$archive" --force >/dev/null
    [[ "$(jq -r '.name' "$(config::tunnel_path deadbeef)")" == "t1" ]] || return 1
    [[ ! -f "$(config::tunnel_path cafebabe)" ]] || return 1
}

test_restore_failure_rolls_back_to_pre_restore_snapshot() {
    local archive="$TIXOLINK_TEST_ROOT/rollback.tar.gz"
    make_valid_backup "$archive"
    config::tunnel_write "deadbeef" '{"schema_version":1,"name":"before-restore","engine":"gre"}'

    # Inject a failure at the VALIDATE stage, after APPLY has already
    # overwritten the tunnel file with the backup's content - this proves
    # rollback actively restores the pre-restore snapshot, not merely that
    # apply never got far enough to touch anything.
    restore::_validate_applied() { return 1; }

    local status=0
    restore::run "$archive" --force >/dev/null 2>&1 || status=$?

    [[ "$status" -ne 0 ]] || return 1
    [[ "$(jq -r '.name' "$(config::tunnel_path deadbeef)")" == "before-restore" ]]
}

th::run test_restore_rejects_missing_archive
th::run test_restore_rejects_malformed_archive
th::run test_restore_rejects_checksum_mismatch
th::run test_restore_rejects_entries_outside_backup_root
th::run test_restore_rejects_unsupported_backup_schema
th::run test_restore_dry_run_changes_nothing
th::run test_restore_applies_exact_backed_up_state
th::run test_restore_failure_rolls_back_to_pre_restore_snapshot

th::summary

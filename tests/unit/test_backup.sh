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

test_backup_create_produces_archive() {
    config::init_app_config
    local out; out="$(backup::create --output "$TIXOLINK_TEST_ROOT/b1.tar.gz")"
    [[ -f "$out" ]]
}

test_backup_archive_contains_backup_root() {
    config::init_app_config
    local out; out="$(backup::create --output "$TIXOLINK_TEST_ROOT/b2.tar.gz")"
    tar -tzf "$out" | grep -q '^backup/manifest.json$'
}

test_backup_refuses_overwrite_without_force() {
    config::init_app_config
    backup::create --output "$TIXOLINK_TEST_ROOT/b3.tar.gz" >/dev/null
    ! backup::create --output "$TIXOLINK_TEST_ROOT/b3.tar.gz" >/dev/null 2>&1
}

test_backup_force_overwrites() {
    config::init_app_config
    backup::create --output "$TIXOLINK_TEST_ROOT/b4.tar.gz" >/dev/null
    backup::create --output "$TIXOLINK_TEST_ROOT/b4.tar.gz" --force >/dev/null
}

test_backup_includes_tunnel_configs() {
    config::init_app_config
    config::tunnel_write "deadbeef" '{"schema_version":1,"name":"t1","engine":"gre"}'
    local out; out="$(backup::create --output "$TIXOLINK_TEST_ROOT/b5.tar.gz" --force)"
    tar -tzf "$out" | grep -q '^backup/payload/tunnels/deadbeef.json$'
}

test_backup_checksums_cover_every_payload_file() {
    config::init_app_config
    local out; out="$(backup::create --output "$TIXOLINK_TEST_ROOT/b6.tar.gz" --force)"
    local stage="$TIXOLINK_TEST_ROOT/extract6"
    mkdir -p "$stage"
    tar -xzf "$out" -C "$stage"
    (cd "$stage/backup" && sha256sum -c checksums.sha256 --status)
}

th::run test_backup_create_produces_archive
th::run test_backup_archive_contains_backup_root
th::run test_backup_refuses_overwrite_without_force
th::run test_backup_force_overwrites
th::run test_backup_includes_tunnel_configs
th::run test_backup_checksums_cover_every_payload_file

th::summary

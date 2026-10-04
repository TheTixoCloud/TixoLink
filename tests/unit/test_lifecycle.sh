#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$TEST_DIR/../.." && pwd)"
TIXOLINK_LIB_DIR="$REPO_ROOT/lib"
TIXOLINK_ENGINES_DIR="$REPO_ROOT/engines"
TIXOLINK_MODULES_DIR="$REPO_ROOT/modules"
TIXOLINK_FORWARDERS_DIR="$REPO_ROOT/forwarders"
export TIXOLINK_LIB_DIR TIXOLINK_ENGINES_DIR TIXOLINK_MODULES_DIR TIXOLINK_FORWARDERS_DIR

TIXOLINK_TEST_ROOT="$(mktemp -d /tmp/tixolink-test.XXXXXXXX)"
export TIXOLINK_ETC_DIR="$TIXOLINK_TEST_ROOT/etc"
export TIXOLINK_VAR_DIR="$TIXOLINK_TEST_ROOT/var"
export TIXOLINK_RUN_DIR="$TIXOLINK_TEST_ROOT/run"
export TIXOLINK_LOG_FILE="$TIXOLINK_TEST_ROOT/tixolink.log"
export TIXOLINK_TMP_DIR="$TIXOLINK_TEST_ROOT/tmp"
export TIXOLINK_SYSCTL_D_FILE="$TIXOLINK_TEST_ROOT/99-tixolink.conf"
mkdir -p "$TIXOLINK_TMP_DIR"

cleanup() { rm -rf -- "$TIXOLINK_TEST_ROOT"; }
trap cleanup EXIT

source "$REPO_ROOT/tests/lib/test_harness.sh"
source "$TIXOLINK_LIB_DIR/common.sh"
source "$TIXOLINK_LIB_DIR/logging.sh"
source "$TIXOLINK_LIB_DIR/ui.sh"
source "$TIXOLINK_LIB_DIR/validation.sh"
source "$TIXOLINK_LIB_DIR/platform.sh"
source "$TIXOLINK_LIB_DIR/locking.sh"
source "$TIXOLINK_LIB_DIR/config.sh"
source "$TIXOLINK_LIB_DIR/state.sh"
source "$TIXOLINK_LIB_DIR/subnet.sh"
source "$TIXOLINK_LIB_DIR/ports.sh"
source "$TIXOLINK_LIB_DIR/dependency.sh"
source "$TIXOLINK_LIB_DIR/transaction.sh"
source "$TIXOLINK_LIB_DIR/sysinfo.sh"
source "$TIXOLINK_LIB_DIR/manifest.sh"
source "$TIXOLINK_LIB_DIR/migration.sh"
source "$TIXOLINK_ENGINES_DIR/engine_api.sh"
source "$TIXOLINK_ENGINES_DIR/gre.sh"
source "$TIXOLINK_FORWARDERS_DIR/forwarder_api.sh"
source "$TIXOLINK_FORWARDERS_DIR/none.sh"
source "$TIXOLINK_MODULES_DIR/tunnel.sh"
source "$TIXOLINK_MODULES_DIR/forwarding.sh"
source "$TIXOLINK_MODULES_DIR/optimizer.sh"
source "$TIXOLINK_MODULES_DIR/bbr.sh"
source "$TIXOLINK_MODULES_DIR/backup.sh"
source "$TIXOLINK_MODULES_DIR/lifecycle.sh"

# Fixture tunnel: a valid config/state pair referencing an interface name
# that does not exist on this host, so engine_gre_delete's existence check
# makes deletion a config/state-only no-op - no real networking touched.
make_fixture_tunnel() {
    local id="$1" name="$2"
    config::tunnel_write "$id" "$(jq -nc --arg name "$name" --arg iface "tixo-${id}" '{
        schema_version: 1, name: $name, engine: "gre",
        engine_config: {interface: $iface, local_public_ip: "192.0.2.1", remote_public_ip: "192.0.2.2",
            inner_subnet: "10.200.0.0/30", inner_local_ip: "10.200.0.1", inner_remote_ip: "10.200.0.2",
            mtu: 1300, ttl: 255},
        forwarding: {engine: "none", mappings: []}
    }')"
}

test_factory_reset_dry_run_changes_nothing() {
    config::init_app_config
    state::init
    make_fixture_tunnel deadbeef t1
    lifecycle::factory_reset --dry-run --skip-backup >/dev/null
    [[ -f "$(config::tunnel_path deadbeef)" ]]
}

test_factory_reset_removes_tunnels_and_resets_config() {
    config::init_app_config
    state::init
    make_fixture_tunnel deadbeef t1
    config::write_json_atomic "$TIXOLINK_APP_CONFIG_FILE" '{"schema_version":1,"subnet_pool":"172.16.0.0/16"}' 0640
    lifecycle::factory_reset --force --skip-backup >/dev/null
    [[ ! -f "$(config::tunnel_path deadbeef)" ]] || return 1
    [[ "$(config::get '.subnet_pool')" == "10.200.0.0/16" ]]
}

test_factory_reset_requires_confirmation_without_force() {
    config::init_app_config
    state::init
    make_fixture_tunnel deadbeef t1
    ! lifecycle::factory_reset --skip-backup </dev/null >/dev/null 2>&1
    [[ -f "$(config::tunnel_path deadbeef)" ]]
}

test_teardown_reports_failed_ids_without_aborting_others() {
    config::init_app_config
    state::init
    make_fixture_tunnel aaaaaaaa t1
    make_fixture_tunnel bbbbbbbb t2
    tunnel::delete() { [[ "$1" == "aaaaaaaa" ]] && return 1; config::tunnel_delete "$1"; return 0; }
    local -a failed=()
    lifecycle::teardown_owned_resources failed
    th::assert_eq "${failed[*]:-}" "aaaaaaaa"
    [[ ! -f "$(config::tunnel_path bbbbbbbb)" ]]
}

th::run test_factory_reset_dry_run_changes_nothing
th::run test_factory_reset_removes_tunnels_and_resets_config
th::run test_factory_reset_requires_confirmation_without_force
th::run test_teardown_reports_failed_ids_without_aborting_others

th::summary

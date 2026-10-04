#!/usr/bin/env bash
# TixoLink NEXUS - concurrency/locking regression (Phase 7 Step 8).
#
# Proves, at the actual operational lock name production code uses
# ("tunnel-<id>", acquired by tx::begin from modules/tunnel.sh), that two
# concurrent mutations on the SAME tunnel either serialize (the second
# waits for the first to finish, then proceeds) or fail deterministically
# with EXIT_LOCK_TIMEOUT - never run concurrently and never silently
# corrupt state. Uses a real background process holding the lock, not a
# mock, so this is testing the real flock-based primitive end to end.
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
source "$TIXOLINK_ENGINES_DIR/engine_api.sh"
source "$TIXOLINK_ENGINES_DIR/gre.sh"
source "$TIXOLINK_FORWARDERS_DIR/forwarder_api.sh"
source "$TIXOLINK_FORWARDERS_DIR/none.sh"
source "$TIXOLINK_MODULES_DIR/tunnel.sh"

make_fixture_tunnel() {
    local id="$1"
    config::tunnel_write "$id" "$(jq -nc --arg iface "tixo-${id}" '{
        schema_version: 1, name: "concurrency-test", engine: "gre",
        engine_config: {interface: $iface, local_public_ip: "192.0.2.1", remote_public_ip: "192.0.2.2",
            inner_subnet: "10.200.0.0/30", inner_local_ip: "10.200.0.1", inner_remote_ip: "10.200.0.2",
            mtu: 1300, ttl: 255},
        forwarding: {engine: "none", mappings: []}
    }')"
}

# hold_lock_in_background <name> <seconds>
# Backgrounds a direct child of the CURRENT shell (never called via
# command substitution, which would run it in a subshell and reparent
# the job it backgrounds, making `wait` on it fail under `set -e`) and
# sets HOLD_BG_PID to its PID.
hold_lock_in_background() {
    local name="$1" seconds="$2"
    (
        # shellcheck disable=SC2034  # read by locking::acquire/release in lib/locking.sh
        TIXOLINK_LOCK_FDS=()
        locking::acquire "$name" 5
        sleep "$seconds"
        locking::release "$name"
    ) &
    HOLD_BG_PID=$!
}

test_second_mutation_waits_for_first_then_succeeds() {
    config::init_app_config
    state::init
    make_fixture_tunnel "deadbeef"

    hold_lock_in_background "tunnel-deadbeef" 1.5
    local bg_pid=$HOLD_BG_PID
    sleep 0.3

    local start end status=0
    start="$(date +%s%3N)"
    tunnel::delete "deadbeef" 0 1 || status=$?
    end="$(date +%s%3N)"
    wait "$bg_pid" 2>/dev/null || true

    th::assert_eq "$status" "0" "delete should succeed once the lock is free" || return 1
    [[ -f "$(config::tunnel_path deadbeef)" ]] && return 1  # must actually be deleted, not skipped
    (( end - start >= 1000 )) || { printf '    expected the operation to wait for the held lock (took %dms)\n' "$((end-start))" >&2; return 1; }
    return 0
}

test_tx_begin_fails_deterministically_on_timeout() {
    hold_lock_in_background "tunnel-cafebabe" 3
    local bg_pid=$HOLD_BG_PID
    sleep 0.3

    local status=0
    tx::begin "tunnel-cafebabe" 1 || status=$?
    wait "$bg_pid" 2>/dev/null || true

    th::assert_eq "$status" "$EXIT_LOCK_TIMEOUT"
}

test_lock_is_fully_released_for_next_operation_after_timeout() {
    # After a timed-out acquisition attempt, the lock name must still be
    # cleanly acquirable once the real holder releases it - a timeout must
    # never leak a stale, permanently-held lock slot.
    hold_lock_in_background "tunnel-feedface" 2
    local bg_pid=$HOLD_BG_PID
    sleep 0.2
    # Background holds for 2s total, head start 0.2s -> at least ~1.8s
    # remain, comfortably longer than this 1s timeout: the attempt below
    # is guaranteed to time out, not accidentally succeed.
    local first_status=0
    tx::begin "tunnel-feedface" 1 >/dev/null 2>&1 || first_status=$?
    [[ "$first_status" -eq "$EXIT_LOCK_TIMEOUT" ]] || { tx::commit; printf '    first tx::begin unexpectedly succeeded instead of timing out\n' >&2; return 1; }
    wait "$bg_pid" 2>/dev/null || true

    tx::begin "tunnel-feedface" 2 || return 1
    tx::commit
    return 0
}

test_concurrent_create_and_delete_different_tunnels_do_not_block_each_other() {
    config::init_app_config
    state::init
    make_fixture_tunnel "11111111"
    make_fixture_tunnel "22222222"

    hold_lock_in_background "tunnel-11111111" 1.5
    local bg_pid=$HOLD_BG_PID
    sleep 0.2

    local start end status=0
    start="$(date +%s%3N)"
    tunnel::delete "22222222" 0 1 || status=$?
    end="$(date +%s%3N)"
    wait "$bg_pid" 2>/dev/null || true

    th::assert_eq "$status" "0" || return 1
    # Different tunnel ID -> different lock name -> must NOT have waited.
    (( end - start < 1000 )) || { printf '    operation on a different tunnel should not have waited (took %dms)\n' "$((end-start))" >&2; return 1; }
    return 0
}

th::run test_second_mutation_waits_for_first_then_succeeds
th::run test_tx_begin_fails_deterministically_on_timeout
th::run test_lock_is_fully_released_for_next_operation_after_timeout
th::run test_concurrent_create_and_delete_different_tunnels_do_not_block_each_other

th::summary

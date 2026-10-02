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
# shellcheck source=lib/validation.sh
source "$TIXOLINK_LIB_DIR/validation.sh"
# shellcheck source=lib/config.sh
source "$TIXOLINK_LIB_DIR/config.sh"
# shellcheck source=lib/subnet.sh
source "$TIXOLINK_LIB_DIR/subnet.sh"

test_ip_int_roundtrip() {
    th::assert_eq "$(subnet::_int_to_ip "$(subnet::_ip_to_int '10.200.3.4')")" "10.200.3.4"
}

test_network_int_masks_host_bits() {
    th::assert_eq "$(subnet::_int_to_ip "$(subnet::_network_int '10.200.0.5/30')")" "10.200.0.4"
}

test_overlaps_detects_identical_blocks() {
    subnet::_overlaps "10.200.0.0/30" "10.200.0.0/30"
}

test_overlaps_detects_containment() {
    subnet::_overlaps "10.200.0.0/30" "10.200.0.0/16"
}

test_overlaps_rejects_disjoint_blocks() {
    ! subnet::_overlaps "10.200.0.0/30" "10.200.0.4/30"
}

test_enumerate_blocks_first_entry() {
    th::assert_eq "$(subnet::_enumerate_blocks '10.200.0.0/24' | head -n1)" "10.200.0.0/30"
}

test_enumerate_blocks_count_for_slash24() {
    th::assert_eq "$(subnet::_enumerate_blocks '10.200.0.0/24' | wc -l)" "64"
}

# --- Required Phase 3 allocator scenarios -----------------------------------

test_allocate_first_block_on_empty_pool() {
    th::assert_eq "$(subnet::allocate_from_pool '10.200.0.0/24')" "10.200.0.0/30"
}

test_allocate_skips_configured_tunnel_collision() {
    th::assert_eq "$(subnet::allocate_from_pool '10.200.0.0/24' '10.200.0.0/30')" "10.200.0.4/30"
}

test_allocate_skips_route_collision() {
    # Simulates a live route covering the first two candidate blocks.
    th::assert_eq "$(subnet::allocate_from_pool '10.200.0.0/24' '10.200.0.0/29')" "10.200.0.8/30"
}

test_allocate_skips_live_address_collision() {
    # A single host address (/32) inside the first block should exclude
    # only that block, not the whole pool.
    th::assert_eq "$(subnet::allocate_from_pool '10.200.0.0/24' '10.200.0.1/32')" "10.200.0.4/30"
}

test_allocate_skips_manually_occupied_middle_block() {
    # A tunnel manually configured in the middle of the pool must still be
    # respected even though nothing precedes it sequentially.
    th::assert_eq "$(subnet::allocate_from_pool '10.200.0.0/24' '10.200.0.40/30')" "10.200.0.0/30"
}

test_allocate_reuses_freed_subnet_when_no_longer_excluded() {
    local with_exclusion without_exclusion
    with_exclusion="$(subnet::allocate_from_pool '10.200.0.0/24' '10.200.0.0/30')"
    without_exclusion="$(subnet::allocate_from_pool '10.200.0.0/24')"
    th::assert_eq "$with_exclusion" "10.200.0.4/30"
    th::assert_eq "$without_exclusion" "10.200.0.0/30"
}

test_allocate_pool_exhaustion_returns_conflict() {
    local status=0
    subnet::allocate_from_pool '10.200.0.0/30' '10.200.0.0/30' >/dev/null 2>&1 || status=$?
    th::assert_eq "$status" "$EXIT_CONFLICT"
}

# --- Integration with the tunnel config store (no real network I/O) --------

test_tunnel_subnets_are_collected_as_exclusions() {
    config::tunnel_write "aaaaaaaa" \
        '{"id":"aaaaaaaa","name":"existing","engine":"gre","engine_config":{"inner_subnet":"10.200.0.0/30"}}'
    th::assert_eq "$(subnet::allocate_from_pool '10.200.0.0/24' "$(subnet::_tunnel_subnets)")" "10.200.0.4/30"
}

test_collect_exclusions_uses_overridable_live_data() {
    # Override the live-data probes (bash allows redefining a sourced
    # function) instead of touching the real network stack.
    subnet::_live_addresses() { printf '10.200.0.6/32\n'; }
    subnet::_live_routes() { printf '10.200.0.9/32\n'; }
    local excl
    excl="$(subnet::collect_exclusions)"
    [[ "$excl" == *"10.200.0.6/32"* && "$excl" == *"10.200.0.9/32"* ]]
}

th::run test_ip_int_roundtrip
th::run test_network_int_masks_host_bits
th::run test_overlaps_detects_identical_blocks
th::run test_overlaps_detects_containment
th::run test_overlaps_rejects_disjoint_blocks
th::run test_enumerate_blocks_first_entry
th::run test_enumerate_blocks_count_for_slash24
th::run test_allocate_first_block_on_empty_pool
th::run test_allocate_skips_configured_tunnel_collision
th::run test_allocate_skips_route_collision
th::run test_allocate_skips_live_address_collision
th::run test_allocate_skips_manually_occupied_middle_block
th::run test_allocate_reuses_freed_subnet_when_no_longer_excluded
th::run test_allocate_pool_exhaustion_returns_conflict
th::run test_tunnel_subnets_are_collected_as_exclusions
th::run test_collect_exclusions_uses_overridable_live_data

th::summary

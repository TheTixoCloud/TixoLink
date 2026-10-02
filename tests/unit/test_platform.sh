#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$TEST_DIR/../.." && pwd)"
TIXOLINK_LIB_DIR="$REPO_ROOT/lib"
export TIXOLINK_LIB_DIR

# shellcheck source=tests/lib/test_harness.sh
source "$REPO_ROOT/tests/lib/test_harness.sh"
# shellcheck source=lib/common.sh
source "$TIXOLINK_LIB_DIR/common.sh"
# shellcheck source=lib/platform.sh
source "$TIXOLINK_LIB_DIR/platform.sh"

# These tests only assert that each read-only probe runs and returns a
# non-empty, sane-looking result on this development host. They never
# modify anything.

test_os_id_is_known() {
    local id
    id="$(platform::os_id)"
    [[ "$id" == "ubuntu" || "$id" == "debian" ]]
}

test_os_version_is_nonempty() {
    [[ -n "$(platform::os_version)" ]]
}

test_is_supported_os_on_this_dev_host() {
    platform::is_supported_os
}

test_kernel_is_nonempty() {
    [[ -n "$(platform::kernel)" ]]
}

test_arch_is_x86_64() {
    th::assert_eq "$(platform::arch)" "x86_64"
}

test_gre_module_available_on_this_dev_host() {
    platform::gre_module_available
}

test_iptables_backend_is_known_value() {
    local backend
    backend="$(platform::iptables_backend)"
    [[ "$backend" == "nf_tables" || "$backend" == "legacy" || "$backend" == "unknown" || "$backend" == "absent" ]]
}

test_has_nft_on_this_dev_host() {
    platform::has_nft
}

test_congestion_control_is_nonempty() {
    [[ -n "$(platform::congestion_control)" ]]
}

test_public_ipv4_addresses_returns_something() {
    [[ -n "$(platform::public_ipv4_addresses)" ]]
}

th::run test_os_id_is_known
th::run test_os_version_is_nonempty
th::run test_is_supported_os_on_this_dev_host
th::run test_kernel_is_nonempty
th::run test_arch_is_x86_64
th::run test_gre_module_available_on_this_dev_host
th::run test_iptables_backend_is_known_value
th::run test_has_nft_on_this_dev_host
th::run test_congestion_control_is_nonempty
th::run test_public_ipv4_addresses_returns_something

th::summary

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
# shellcheck source=lib/validation.sh
source "$TIXOLINK_LIB_DIR/validation.sh"

test_ipv4_accepts_valid() {
    validate::ipv4 "192.168.1.1" && validate::ipv4 "87.107.114.90" && validate::ipv4 "0.0.0.0"
}

test_ipv4_rejects_out_of_range() {
    ! validate::ipv4 "256.1.1.1"
}

test_ipv4_rejects_leading_zeros() {
    ! validate::ipv4 "192.168.001.1"
}

test_ipv4_rejects_too_few_octets() {
    ! validate::ipv4 "192.168.1"
}

test_ipv4_rejects_non_numeric() {
    ! validate::ipv4 "a.b.c.d"
}

test_cidr_accepts_valid() {
    validate::cidr "10.200.0.0/16" && validate::cidr "10.200.0.0/30"
}

test_cidr_rejects_bad_prefix() {
    ! validate::cidr "10.200.0.0/33"
}

test_cidr_rejects_missing_prefix() {
    ! validate::cidr "10.200.0.0"
}

test_port_accepts_boundaries() {
    validate::port "1" && validate::port "65535"
}

test_port_rejects_zero() {
    ! validate::port "0"
}

test_port_rejects_out_of_range() {
    ! validate::port "65536"
}

test_port_range_accepts_valid() {
    validate::port_range "8000-9000"
}

test_port_range_rejects_reversed() {
    ! validate::port_range "9000-8000"
}

test_port_spec_accepts_mixed_list() {
    validate::port_spec "80,443,2052,8000-9000"
}

test_port_spec_rejects_invalid_entry() {
    ! validate::port_spec "80,99999"
}

test_port_spec_rejects_empty() {
    ! validate::port_spec ""
}

test_protocol_accepts_known_values() {
    validate::protocol "tcp" && validate::protocol "UDP" && validate::protocol "tcp+udp"
}

test_protocol_rejects_unknown() {
    ! validate::protocol "icmp"
}

test_mtu_accepts_default() {
    validate::mtu "1300"
}

test_mtu_rejects_too_small() {
    ! validate::mtu "10"
}

test_ttl_accepts_boundaries() {
    validate::ttl "1" && validate::ttl "255"
}

test_ttl_rejects_zero() {
    ! validate::ttl "0"
}

test_ttl_rejects_out_of_range() {
    ! validate::ttl "256"
}

test_iface_name_accepts_valid() {
    validate::iface_name "tixo-a1b2c3d4"
}

test_iface_name_rejects_too_long() {
    ! validate::iface_name "this-name-is-way-too-long-for-ifnamsiz"
}

test_iface_name_rejects_bad_chars() {
    ! validate::iface_name "tixo;rm -rf"
}

test_tunnel_name_accepts_valid() {
    validate::tunnel_name "germany-1" && validate::tunnel_name "customer.de"
}

test_tunnel_name_rejects_spaces() {
    ! validate::tunnel_name "germany 1"
}

test_tunnel_id_accepts_valid() {
    validate::tunnel_id "a1b2c3d4"
}

test_tunnel_id_rejects_uppercase() {
    ! validate::tunnel_id "A1B2C3D4"
}

test_tunnel_id_rejects_wrong_length() {
    ! validate::tunnel_id "a1b2c3"
}

test_path_within_accepts_nested_path() {
    local root="/tmp"
    validate::path_within "/tmp/subdir/file" "$root"
}

test_path_within_rejects_escape() {
    ! validate::path_within "/tmp/../etc/passwd" "/tmp"
}

th::run test_ipv4_accepts_valid
th::run test_ipv4_rejects_out_of_range
th::run test_ipv4_rejects_leading_zeros
th::run test_ipv4_rejects_too_few_octets
th::run test_ipv4_rejects_non_numeric
th::run test_cidr_accepts_valid
th::run test_cidr_rejects_bad_prefix
th::run test_cidr_rejects_missing_prefix
th::run test_port_accepts_boundaries
th::run test_port_rejects_zero
th::run test_port_rejects_out_of_range
th::run test_port_range_accepts_valid
th::run test_port_range_rejects_reversed
th::run test_port_spec_accepts_mixed_list
th::run test_port_spec_rejects_invalid_entry
th::run test_port_spec_rejects_empty
th::run test_protocol_accepts_known_values
th::run test_protocol_rejects_unknown
th::run test_mtu_accepts_default
th::run test_mtu_rejects_too_small
th::run test_ttl_accepts_boundaries
th::run test_ttl_rejects_zero
th::run test_ttl_rejects_out_of_range
th::run test_iface_name_accepts_valid
th::run test_iface_name_rejects_too_long
th::run test_iface_name_rejects_bad_chars
th::run test_tunnel_name_accepts_valid
th::run test_tunnel_name_rejects_spaces
th::run test_tunnel_id_accepts_valid
th::run test_tunnel_id_rejects_uppercase
th::run test_tunnel_id_rejects_wrong_length
th::run test_path_within_accepts_nested_path
th::run test_path_within_rejects_escape

th::summary

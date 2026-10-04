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
# shellcheck source=lib/logging.sh
source "$TIXOLINK_LIB_DIR/logging.sh"
# shellcheck source=lib/validation.sh
source "$TIXOLINK_LIB_DIR/validation.sh"
# shellcheck source=lib/ports.sh
source "$TIXOLINK_LIB_DIR/ports.sh"

test_parse_single_port() {
    th::assert_eq "$(ports::parse_token "443")" "443|443"
}

test_parse_range_no_remap() {
    th::assert_eq "$(ports::parse_token "8000-9000")" "8000-9000|8000-9000"
}

test_parse_single_remap() {
    th::assert_eq "$(ports::parse_token "8443:443")" "8443|443"
}

test_parse_range_remap_matching_cardinality() {
    th::assert_eq "$(ports::parse_token "8000-8010:9000-9010")" "8000-8010|9000-9010"
}

test_parse_range_remap_mismatched_cardinality_rejected() {
    local status=0
    ports::parse_token "8000-8010:9000" >/dev/null 2>&1 || status=$?
    th::assert_eq "$status" "$EXIT_VALIDATION"
}

test_parse_rejects_range_to_single() {
    ! ports::parse_token "8000-8010:443" 2>/dev/null
}

test_parse_rejects_single_to_range() {
    ! ports::parse_token "443:9000-9010" 2>/dev/null
}

test_parse_rejects_zero() {
    ! ports::parse_token "0" 2>/dev/null
}

test_parse_rejects_negative() {
    ! ports::parse_token "-5" 2>/dev/null
}

test_parse_rejects_above_65535() {
    ! ports::parse_token "70000" 2>/dev/null
}

test_parse_rejects_reversed_range() {
    ! ports::parse_token "9000-8000" 2>/dev/null
}

test_parse_rejects_double_colon() {
    ! ports::parse_token "80::443" 2>/dev/null
}

test_parse_rejects_trailing_dash() {
    ! ports::parse_token "80-" 2>/dev/null
}

test_parse_rejects_leading_dash() {
    ! ports::parse_token "-443" 2>/dev/null
}

test_parse_rejects_empty() {
    ! ports::parse_token "" 2>/dev/null
}

test_expand_spec_multiple_ports() {
    local out
    out="$(ports::expand_spec "80,443,2052,2082")"
    th::assert_eq "$(printf '%s\n' "$out" | wc -l)" "4"
    th::assert_eq "$(printf '%s\n' "$out" | sed -n '3p')" "2052|2052"
}

test_expand_spec_mixed_ranges_and_remap() {
    local out
    out="$(ports::expand_spec "80,8443:443,9500-9600")"
    th::assert_eq "$(printf '%s\n' "$out" | sed -n '2p')" "8443|443"
}

test_expand_spec_rejects_duplicate_ports() {
    local status=0
    ports::expand_spec "80,80" >/dev/null 2>&1 || status=$?
    th::assert_eq "$status" "$EXIT_VALIDATION"
}

test_expand_spec_rejects_overlapping_ranges() {
    local status=0
    ports::expand_spec "8000-9000,8500" >/dev/null 2>&1 || status=$?
    th::assert_eq "$status" "$EXIT_VALIDATION"
}

test_expand_spec_rejects_one_bad_token_in_list() {
    local status=0
    ports::expand_spec "80,443,99999" >/dev/null 2>&1 || status=$?
    th::assert_eq "$status" "$EXIT_VALIDATION"
}

test_expand_spec_rejects_empty() {
    local status=0
    ports::expand_spec "" >/dev/null 2>&1 || status=$?
    th::assert_eq "$status" "$EXIT_VALIDATION"
}

# `read` stops at the first newline regardless of IFS - an embedded
# newline must be rejected outright, never silently truncated into
# "expand only the part before it, report success anyway."
test_expand_spec_rejects_embedded_newline() {
    local status=0
    ports::expand_spec $'80,443\nDROP TABLE' >/dev/null 2>&1 || status=$?
    th::assert_eq "$status" "$EXIT_VALIDATION"
}

test_mapping_conflicts_same_protocol_overlap() {
    ports::mapping_conflicts_with "80" "tcp" "80" "tcp"
}

test_mapping_conflicts_tcp_udp_do_not_conflict() {
    ! ports::mapping_conflicts_with "80" "tcp" "80" "udp"
}

test_mapping_conflicts_tcp_udp_combo_conflicts_with_either() {
    ports::mapping_conflicts_with "80" "tcp+udp" "80" "udp"
    ports::mapping_conflicts_with "80" "tcp+udp" "80" "tcp"
}

test_mapping_conflicts_disjoint_ports_no_conflict() {
    ! ports::mapping_conflicts_with "80" "tcp" "443" "tcp"
}

test_mapping_conflicts_overlapping_ranges() {
    ports::mapping_conflicts_with "8000-9000" "tcp" "8500-8600" "tcp"
}

th::run test_parse_single_port
th::run test_parse_range_no_remap
th::run test_parse_single_remap
th::run test_parse_range_remap_matching_cardinality
th::run test_parse_range_remap_mismatched_cardinality_rejected
th::run test_parse_rejects_range_to_single
th::run test_parse_rejects_single_to_range
th::run test_parse_rejects_zero
th::run test_parse_rejects_negative
th::run test_parse_rejects_above_65535
th::run test_parse_rejects_reversed_range
th::run test_parse_rejects_double_colon
th::run test_parse_rejects_trailing_dash
th::run test_parse_rejects_leading_dash
th::run test_parse_rejects_empty
th::run test_expand_spec_multiple_ports
th::run test_expand_spec_mixed_ranges_and_remap
th::run test_expand_spec_rejects_duplicate_ports
th::run test_expand_spec_rejects_overlapping_ranges
th::run test_expand_spec_rejects_one_bad_token_in_list
th::run test_expand_spec_rejects_empty
th::run test_expand_spec_rejects_embedded_newline
th::run test_mapping_conflicts_same_protocol_overlap
th::run test_mapping_conflicts_tcp_udp_do_not_conflict
th::run test_mapping_conflicts_tcp_udp_combo_conflicts_with_either
th::run test_mapping_conflicts_disjoint_ports_no_conflict
th::run test_mapping_conflicts_overlapping_ranges

th::summary

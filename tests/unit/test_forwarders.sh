#!/usr/bin/env bash
# Unit tests for the pure, non-mutating generation functions in
# forwarders/netfilter.sh and forwarders/haproxy.sh (command/identifier/
# config-text generation, change detection via hashing). Real rule
# application and real HAProxy process behavior are covered by
# tests/integration/test_netfilter_forwarding.sh,
# tests/integration/test_haproxy_forwarding.sh, and
# tests/integration/test_forwarding_migration.sh.
set -Eeuo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$TEST_DIR/../.." && pwd)"
TIXOLINK_LIB_DIR="$REPO_ROOT/lib"
TIXOLINK_FORWARDERS_DIR="$REPO_ROOT/forwarders"
export TIXOLINK_LIB_DIR TIXOLINK_FORWARDERS_DIR

TIXOLINK_TEST_ROOT="$(mktemp -d /tmp/tixolink-test.XXXXXXXX)"
export TIXOLINK_ETC_DIR="$TIXOLINK_TEST_ROOT/etc"
export TIXOLINK_VAR_DIR="$TIXOLINK_TEST_ROOT/var"
export TIXOLINK_LOG_FILE="$TIXOLINK_TEST_ROOT/tixolink.log"
export TIXOLINK_HAPROXY_CFG="$TIXOLINK_TEST_ROOT/haproxy.cfg"

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
# shellcheck source=lib/state.sh
source "$TIXOLINK_LIB_DIR/state.sh"
# shellcheck source=lib/ports.sh
source "$TIXOLINK_LIB_DIR/ports.sh"
# shellcheck source=forwarders/forwarder_api.sh
source "$TIXOLINK_FORWARDERS_DIR/forwarder_api.sh"
# shellcheck source=forwarders/netfilter.sh
source "$TIXOLINK_FORWARDERS_DIR/netfilter.sh"
# shellcheck source=forwarders/haproxy.sh
source "$TIXOLINK_FORWARDERS_DIR/haproxy.sh"

sample_tunnel() {
    jq -nc '{id:"aaaaaaaa", engine_config:{interface:"tixo-aaaaaaaa", inner_remote_ip:"10.250.0.2"}}'
}
sample_mapping() {
    jq -nc '{id:"bbbbbbbb", protocol:"tcp", listen_address:"0.0.0.0", local_port:"8443",
             remote_address:null, remote_port:"443", nat_mode:"nat"}'
}

# --- netfilter: port argument / rule-arg generation --------------------------

test_netfilter_port_arg_converts_range_hyphen_to_colon() {
    th::assert_eq "$(netfilter::_port_arg "8000-9000")" "8000:9000"
}

test_netfilter_port_arg_leaves_single_port_unchanged() {
    th::assert_eq "$(netfilter::_port_arg "443")" "443"
}

test_netfilter_dnat_args_include_dport_and_destination() {
    local args; args="$(netfilter::_dnat_args tcp 0.0.0.0 8443 10.250.0.2 443 "tixolink:a:b")"
    [[ "$args" == *"--dport"*"8443"* ]] && [[ "$args" == *"DNAT"*"10.250.0.2:443"* ]]
}

test_netfilter_dnat_args_scope_to_listen_address_when_not_any() {
    local args; args="$(netfilter::_dnat_args tcp 203.0.113.5 443 10.250.0.2 443 "tixolink:a:b")"
    [[ "$args" == *"-d"*"203.0.113.5"* ]]
}

test_netfilter_dnat_args_omit_dest_match_for_0_0_0_0() {
    local args; args="$(netfilter::_dnat_args tcp 0.0.0.0 443 10.250.0.2 443 "tixolink:a:b")"
    [[ "$args" != *"-d"*"0.0.0.0"* ]]
}

test_netfilter_fwd_args_match_destination_and_port() {
    local args; args="$(netfilter::_fwd_args tcp 10.250.0.2 443 "tixolink:a:b")"
    [[ "$args" == *"-d"*"10.250.0.2"* ]] && [[ "$args" == *"ACCEPT"* ]]
}

test_netfilter_snat_args_scope_to_output_interface() {
    local args; args="$(netfilter::_snat_args tcp 10.250.0.2 443 tixo-aaaaaaaa "tixolink:a:b")"
    [[ "$args" == *"-o"*"tixo-aaaaaaaa"* ]] && [[ "$args" == *"MASQUERADE"* ]]
}

test_netfilter_protocols_expands_tcp_udp_combo() {
    local mapping; mapping="$(jq -nc '{protocol:"tcp+udp"}')"
    local out; out="$(netfilter::_protocols "$mapping")"
    th::assert_eq "$out" "$(printf 'tcp\nudp')"
}

test_netfilter_protocols_single_protocol_unchanged() {
    local mapping; mapping="$(jq -nc '{protocol:"udp"}')"
    th::assert_eq "$(netfilter::_protocols "$mapping")" "udp"
}

test_netfilter_resolve_remote_address_uses_tunnel_inner_ip_by_default() {
    th::assert_eq "$(netfilter::_resolve_remote_address "$(sample_tunnel)" "$(sample_mapping)")" "10.250.0.2"
}

test_netfilter_resolve_remote_address_honors_override() {
    local mapping; mapping="$(sample_mapping | jq '.remote_address = "10.9.9.9"')"
    th::assert_eq "$(netfilter::_resolve_remote_address "$(sample_tunnel)" "$mapping")" "10.9.9.9"
}

test_netfilter_backend_reports_known_value() {
    local backend; backend="$(netfilter::backend)"
    [[ "$backend" == "nf_tables" || "$backend" == "legacy" || "$backend" == "unknown" ]]
}

# --- haproxy: identifier generation -------------------------------------------

test_haproxy_sanitize_id_accepts_valid_hex() {
    th::assert_eq "$(haproxy::_sanitize_id "a1b2c3d4")" "a1b2c3d4"
}

test_haproxy_sanitize_id_rejects_non_hex() {
    ! haproxy::_sanitize_id "not-an-id" 2>/dev/null
}

test_haproxy_object_name_format() {
    th::assert_eq "$(haproxy::_object_name "aaaaaaaa" "bbbbbbbb" fe)" "tixolink_aaaaaaaa_bbbbbbbb_fe"
}

test_haproxy_object_names_unique_per_mapping() {
    local a b
    a="$(haproxy::_object_name "aaaaaaaa" "bbbbbbbb" be)"
    b="$(haproxy::_object_name "aaaaaaaa" "cccccccc" be)"
    [[ "$a" != "$b" ]]
}

# --- haproxy: config generation -----------------------------------------------

test_haproxy_render_mapping_contains_ownership_comment() {
    local out; out="$(haproxy::_render_mapping "$(sample_tunnel)" "$(sample_mapping)")"
    [[ "$out" == *"tixolink:aaaaaaaa:bbbbbbbb"* ]]
}

test_haproxy_render_mapping_binds_listen_port() {
    local out; out="$(haproxy::_render_mapping "$(sample_tunnel)" "$(sample_mapping)")"
    [[ "$out" == *"bind 0.0.0.0:8443"* ]]
}

test_haproxy_render_mapping_server_targets_remote() {
    local out; out="$(haproxy::_render_mapping "$(sample_tunnel)" "$(sample_mapping)")"
    [[ "$out" == *"server bbbbbbbb 10.250.0.2:443"* ]]
}

test_haproxy_render_mapping_uses_inner_remote_ip_when_no_override() {
    local mapping; mapping="$(sample_mapping)"  # remote_address is null
    local out; out="$(haproxy::_render_mapping "$(sample_tunnel)" "$mapping")"
    [[ "$out" == *"10.250.0.2:443"* ]]
}

test_haproxy_render_block_has_markers() {
    local out; out="$(haproxy::_render_block "$(sample_tunnel)|$(sample_mapping)")"
    [[ "$out" == "$HAPROXY_BEGIN_MARKER"* ]] && [[ "$out" == *"$HAPROXY_END_MARKER" ]]
}

test_haproxy_base_content_has_global_and_defaults_when_no_file_exists() {
    local out; out="$(haproxy::_base_content)"
    [[ "$out" == *"global"* && "$out" == *"defaults"* ]]
}

test_haproxy_base_content_strips_managed_block_preserves_rest() {
    cat > "$TIXOLINK_HAPROXY_CFG" <<EOF
global
    log /dev/log local0
$HAPROXY_BEGIN_MARKER
frontend old_stuff
$HAPROXY_END_MARKER
defaults
    mode tcp
EOF
    local out; out="$(haproxy::_base_content)"
    [[ "$out" == *"global"* && "$out" == *"defaults"* ]]
    [[ "$out" != *"old_stuff"* ]]
}

test_haproxy_detect_malformed_blocks_rejects_duplicate_begin() {
    cat > "$TIXOLINK_HAPROXY_CFG" <<EOF
$HAPROXY_BEGIN_MARKER
$HAPROXY_BEGIN_MARKER
$HAPROXY_END_MARKER
EOF
    local status=0
    haproxy::_detect_malformed_blocks 2>/dev/null || status=$?
    th::assert_eq "$status" "$EXIT_GENERIC"
}

test_haproxy_detect_malformed_blocks_accepts_well_formed_file() {
    cat > "$TIXOLINK_HAPROXY_CFG" <<EOF
global
$HAPROXY_BEGIN_MARKER
$HAPROXY_END_MARKER
EOF
    haproxy::_detect_malformed_blocks
}

test_haproxy_detect_malformed_blocks_accepts_no_file() {
    rm -f "$TIXOLINK_HAPROXY_CFG"
    haproxy::_detect_malformed_blocks
}

# --- haproxy: bind-conflict preflight -----------------------------------------

reset_store() { rm -rf -- "$TIXOLINK_ETC_DIR" "$TIXOLINK_VAR_DIR"; rm -f "$TIXOLINK_HAPROXY_CFG"; }

test_addrs_overlap_wildcard_matches_anything() {
    haproxy::_addrs_overlap "0.0.0.0" "203.0.113.5"
}

test_addrs_overlap_distinct_specific_addresses_do_not_overlap() {
    ! haproxy::_addrs_overlap "203.0.113.5" "203.0.113.6"
}

test_addrs_overlap_identical_specific_addresses_overlap() {
    haproxy::_addrs_overlap "203.0.113.5" "203.0.113.5"
}

test_bind_in_base_config_detects_matching_port() {
    cat > "$TIXOLINK_HAPROXY_CFG" <<EOF
global
defaults
frontend admin
    bind 0.0.0.0:19999
EOF
    haproxy::_bind_in_base_config "0.0.0.0" "19999"
}

test_bind_in_base_config_ignores_different_port() {
    cat > "$TIXOLINK_HAPROXY_CFG" <<EOF
global
frontend admin
    bind 0.0.0.0:19999
EOF
    ! haproxy::_bind_in_base_config "0.0.0.0" "443"
}

test_bind_in_base_config_ignores_commented_bind() {
    cat > "$TIXOLINK_HAPROXY_CFG" <<EOF
global
    # bind 0.0.0.0:443
EOF
    ! haproxy::_bind_in_base_config "0.0.0.0" "443"
}

test_bind_occupied_by_other_process_free_port_reports_free() {
    # Port 1 in the 1xxxx range is extremely unlikely to have a real
    # listener in any test environment.
    th::assert_eq "$(haproxy::_bind_occupied_by_other_process "0.0.0.0" "18237")" "free"
}

test_bind_occupied_by_other_process_reports_unknown_when_ss_missing() {
    # Run in a subshell so clobbering PATH to hide `ss` never escapes
    # into the rest of the test run.
    local result
    result="$(PATH="/nonexistent-bin-dir-for-test" haproxy::_bind_occupied_by_other_process "0.0.0.0" "443")"
    th::assert_eq "$result" "unknown"
}

test_check_conflicts_blocks_when_base_config_already_binds_port() {
    reset_store
    cat > "$TIXOLINK_HAPROXY_CFG" <<EOF
global
frontend admin
    bind 0.0.0.0:8443
EOF
    local mapping; mapping="$(jq -nc '{id:"m0000001", protocol:"tcp", listen_address:"0.0.0.0", local_port:"8443", remote_address:null, remote_port:"443", nat_mode:"nat"}')"
    local status=0
    forwarder_haproxy_check_conflicts "aaaaaaaa" "$mapping" 2>/dev/null || status=$?
    th::assert_eq "$status" "$EXIT_CONFLICT"
}

test_check_conflicts_allows_free_port() {
    reset_store
    local mapping; mapping="$(jq -nc '{id:"m0000002", protocol:"tcp", listen_address:"0.0.0.0", local_port:"18238", remote_address:null, remote_port:"443", nat_mode:"nat"}')"
    forwarder_haproxy_check_conflicts "aaaaaaaa" "$mapping"
}

test_check_conflicts_self_exclusion_does_not_reject_unchanged_bind() {
    reset_store
    local tunnel_json; tunnel_json="$(jq -nc '{id:"aaaaaaaa", name:"t", engine:"gre", forwarding:{engine:"haproxy", mappings:[
        {id:"m0000003", protocol:"tcp", listen_address:"0.0.0.0", local_port:"9999", remote_address:null, remote_port:"443", nat_mode:"nat"}
    ]}}')"
    config::tunnel_write "aaaaaaaa" "$tunnel_json"
    # Editing mapping m0000003 without changing its bind: same tunnel,
    # same mapping id excluded, same listen_address/local_port - must
    # not be rejected as "already represented elsewhere".
    local candidate; candidate="$(jq -nc '{id:"m0000003", protocol:"tcp", listen_address:"0.0.0.0", local_port:"9999", remote_address:null, remote_port:"8080", nat_mode:"nat"}')"
    forwarder_haproxy_check_conflicts "aaaaaaaa" "$candidate" "m0000003"
}

th::run test_netfilter_port_arg_converts_range_hyphen_to_colon
th::run test_netfilter_port_arg_leaves_single_port_unchanged
th::run test_netfilter_dnat_args_include_dport_and_destination
th::run test_netfilter_dnat_args_scope_to_listen_address_when_not_any
th::run test_netfilter_dnat_args_omit_dest_match_for_0_0_0_0
th::run test_netfilter_fwd_args_match_destination_and_port
th::run test_netfilter_snat_args_scope_to_output_interface
th::run test_netfilter_protocols_expands_tcp_udp_combo
th::run test_netfilter_protocols_single_protocol_unchanged
th::run test_netfilter_resolve_remote_address_uses_tunnel_inner_ip_by_default
th::run test_netfilter_resolve_remote_address_honors_override
th::run test_netfilter_backend_reports_known_value
th::run test_haproxy_sanitize_id_accepts_valid_hex
th::run test_haproxy_sanitize_id_rejects_non_hex
th::run test_haproxy_object_name_format
th::run test_haproxy_object_names_unique_per_mapping
th::run test_haproxy_render_mapping_contains_ownership_comment
th::run test_haproxy_render_mapping_binds_listen_port
th::run test_haproxy_render_mapping_server_targets_remote
th::run test_haproxy_render_mapping_uses_inner_remote_ip_when_no_override
th::run test_haproxy_render_block_has_markers
th::run test_haproxy_base_content_has_global_and_defaults_when_no_file_exists
th::run test_haproxy_base_content_strips_managed_block_preserves_rest
th::run test_haproxy_detect_malformed_blocks_rejects_duplicate_begin
th::run test_haproxy_detect_malformed_blocks_accepts_well_formed_file
th::run test_haproxy_detect_malformed_blocks_accepts_no_file
th::run test_addrs_overlap_wildcard_matches_anything
th::run test_addrs_overlap_distinct_specific_addresses_do_not_overlap
th::run test_addrs_overlap_identical_specific_addresses_overlap
th::run test_bind_in_base_config_detects_matching_port
th::run test_bind_in_base_config_ignores_different_port
th::run test_bind_in_base_config_ignores_commented_bind
th::run test_bind_occupied_by_other_process_free_port_reports_free
th::run test_bind_occupied_by_other_process_reports_unknown_when_ss_missing
th::run test_check_conflicts_blocks_when_base_config_already_binds_port
th::run test_check_conflicts_allows_free_port
th::run test_check_conflicts_self_exclusion_does_not_reject_unchanged_bind

th::summary

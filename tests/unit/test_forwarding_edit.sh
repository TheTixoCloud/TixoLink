#!/usr/bin/env bash
# Unit tests for the Phase 4 hardening fix: forwarding::edit must detect a
# semantic no-op edit BEFORE calling any forwarder verb, and must not be
# fooled into treating a real change as a no-op by normalization.
set -Eeuo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$TEST_DIR/../.." && pwd)"
TIXOLINK_LIB_DIR="$REPO_ROOT/lib"
TIXOLINK_ENGINES_DIR="$REPO_ROOT/engines"
TIXOLINK_FORWARDERS_DIR="$REPO_ROOT/forwarders"
TIXOLINK_MODULES_DIR="$REPO_ROOT/modules"
export TIXOLINK_LIB_DIR TIXOLINK_ENGINES_DIR TIXOLINK_FORWARDERS_DIR TIXOLINK_MODULES_DIR

TIXOLINK_TEST_ROOT="$(mktemp -d /tmp/tixolink-test.XXXXXXXX)"
export TIXOLINK_ETC_DIR="$TIXOLINK_TEST_ROOT/etc"
export TIXOLINK_VAR_DIR="$TIXOLINK_TEST_ROOT/var"
export TIXOLINK_RUN_DIR="$TIXOLINK_TEST_ROOT/run"
export TIXOLINK_LOG_FILE="$TIXOLINK_TEST_ROOT/tixolink.log"

cleanup() { rm -rf -- "$TIXOLINK_TEST_ROOT"; }
trap cleanup EXIT

# shellcheck source=tests/lib/test_harness.sh
source "$REPO_ROOT/tests/lib/test_harness.sh"
# shellcheck source=lib/common.sh
source "$TIXOLINK_LIB_DIR/common.sh"
# shellcheck source=lib/logging.sh
source "$TIXOLINK_LIB_DIR/logging.sh"
# shellcheck source=lib/ui.sh
source "$TIXOLINK_LIB_DIR/ui.sh"
# shellcheck source=lib/validation.sh
source "$TIXOLINK_LIB_DIR/validation.sh"
# shellcheck source=lib/locking.sh
source "$TIXOLINK_LIB_DIR/locking.sh"
# shellcheck source=lib/config.sh
source "$TIXOLINK_LIB_DIR/config.sh"
# shellcheck source=lib/state.sh
source "$TIXOLINK_LIB_DIR/state.sh"
# shellcheck source=lib/subnet.sh
source "$TIXOLINK_LIB_DIR/subnet.sh"
# shellcheck source=lib/ports.sh
source "$TIXOLINK_LIB_DIR/ports.sh"
# shellcheck source=lib/transaction.sh
source "$TIXOLINK_LIB_DIR/transaction.sh"
# shellcheck source=engines/engine_api.sh
source "$TIXOLINK_ENGINES_DIR/engine_api.sh"
# shellcheck source=engines/gre.sh
source "$TIXOLINK_ENGINES_DIR/gre.sh"
# shellcheck source=forwarders/forwarder_api.sh
source "$TIXOLINK_FORWARDERS_DIR/forwarder_api.sh"
# shellcheck source=forwarders/none.sh
source "$TIXOLINK_FORWARDERS_DIR/none.sh"
# shellcheck source=modules/tunnel.sh
source "$TIXOLINK_MODULES_DIR/tunnel.sh"
# shellcheck source=modules/forwarding.sh
source "$TIXOLINK_MODULES_DIR/forwarding.sh"

# A fake forwarder that counts every verb call, so tests can assert
# "zero engine calls happened" directly rather than inferring it from
# side effects. Registered under its own name so it never collides with
# the real netfilter/haproxy forwarders.
declare -gA CALL_COUNTS=()
forwarder_fake_validate()        { CALL_COUNTS[validate]=$((${CALL_COUNTS[validate]:-0}+1)); return 0; }
forwarder_fake_check_conflicts() { CALL_COUNTS[check_conflicts]=$((${CALL_COUNTS[check_conflicts]:-0}+1)); return 0; }
forwarder_fake_apply()           { CALL_COUNTS[apply]=$((${CALL_COUNTS[apply]:-0}+1)); return 0; }
forwarder_fake_remove()          { CALL_COUNTS[remove]=$((${CALL_COUNTS[remove]:-0}+1)); return 0; }
forwarder_fake_status()          { CALL_COUNTS[status]=$((${CALL_COUNTS[status]:-0}+1)); printf 'STATE=ACTIVE\n'; }
forwarder::register "fake"

reset_all() {
    rm -rf -- "$TIXOLINK_ETC_DIR" "$TIXOLINK_VAR_DIR"
    CALL_COUNTS=()
}

# make_tunnel_with_mapping <local_port> <remote_port> -> prints tunnel id
make_tunnel_with_mapping() {
    local local_port="$1" remote_port="$2"
    local id="dddddddd"
    local tunnel_json
    tunnel_json="$(jq -nc --arg lp "$local_port" --arg rp "$remote_port" '{
        schema_version: 1, id: "dddddddd", name: "edit-test", engine: "gre",
        engine_config: {interface: "tixo-dddddddd", local_public_ip: "198.51.100.1",
            remote_public_ip: "198.51.100.2", inner_subnet: "10.250.0.0/30",
            inner_local_ip: "10.250.0.1", inner_remote_ip: "10.250.0.2", mtu: 1300, ttl: 255},
        forwarding: {engine: "fake", mappings: [{
            id: "eeeeeeee", protocol: "tcp", listen_address: "0.0.0.0",
            local_port: $lp, remote_address: null, remote_port: $rp, nat_mode: "nat",
            created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z"
        }]},
        persistence: {enabled: false, boot_enabled: false}, status: {operational: "unknown"},
        created_at: "2026-01-01T00:00:00Z", updated_at: "2026-01-01T00:00:00Z"
    }')"
    config::tunnel_write "$id" "$tunnel_json"
    printf '%s' "$id"
}

# --- No-op detection -----------------------------------------------------------

test_identical_edit_calls_no_forwarder_verbs() {
    reset_all
    local id; id="$(make_tunnel_with_mapping "443" "443")"
    forwarding::edit "$id" "eeeeeeee" "443" 0 >/dev/null
    local status=$?
    th::assert_eq "$status" "0"
    th::assert_eq "${CALL_COUNTS[validate]:-0}" "0"
    th::assert_eq "${CALL_COUNTS[check_conflicts]:-0}" "0"
    th::assert_eq "${CALL_COUNTS[apply]:-0}" "0"
    th::assert_eq "${CALL_COUNTS[remove]:-0}" "0"
}

test_identical_edit_preserves_mapping_id() {
    reset_all
    local id; id="$(make_tunnel_with_mapping "443" "443")"
    forwarding::edit "$id" "eeeeeeee" "443" 0 >/dev/null
    local mid; mid="$(config::tunnel_read "$id" | jq -r '.forwarding.mappings[0].id')"
    th::assert_eq "$mid" "eeeeeeee"
}

test_identical_edit_does_not_rewrite_config_file() {
    reset_all
    local id; id="$(make_tunnel_with_mapping "443" "443")"
    local before after
    before="$(config::tunnel_read "$id")"
    forwarding::edit "$id" "eeeeeeee" "443" 0 >/dev/null
    after="$(config::tunnel_read "$id")"
    th::assert_eq "$before" "$after"
}

test_identical_edit_preserves_ownership_ledger() {
    reset_all
    local id; id="$(make_tunnel_with_mapping "443" "443")"
    state::set ".tunnels[\"$id\"] = {\"interface\": \"tixo-${id}\"}"
    local before after
    before="$(state::get ".tunnels[\"$id\"]")"
    forwarding::edit "$id" "eeeeeeee" "443" 0 >/dev/null
    after="$(state::get ".tunnels[\"$id\"]")"
    th::assert_eq "$before" "$after"
}

test_identical_remap_token_is_also_a_noop() {
    reset_all
    local id; id="$(make_tunnel_with_mapping "8443" "443")"
    # "8443:443" explicitly re-states the same local/remote ports already
    # in effect - still a true no-op even though the token includes an
    # explicit remap rather than a bare port.
    forwarding::edit "$id" "eeeeeeee" "8443:443" 0 >/dev/null
    th::assert_eq "${CALL_COUNTS[apply]:-0}" "0"
}

# --- Normalization must not hide a real change --------------------------------

test_different_local_port_is_not_a_noop() {
    reset_all
    local id; id="$(make_tunnel_with_mapping "443" "443")"
    forwarding::edit "$id" "eeeeeeee" "8443" 0 >/dev/null
    th::assert_eq "${CALL_COUNTS[apply]:-0}" "1"
    local new_port; new_port="$(config::tunnel_read "$id" | jq -r '.forwarding.mappings[0].local_port')"
    th::assert_eq "$new_port" "8443"
}

test_different_remap_target_is_not_a_noop() {
    reset_all
    local id; id="$(make_tunnel_with_mapping "8443" "443")"
    forwarding::edit "$id" "eeeeeeee" "8443:8080" 0 >/dev/null
    th::assert_eq "${CALL_COUNTS[apply]:-0}" "1"
}

test_normalize_mapping_ignores_key_order_and_timestamps() {
    local a b
    a="$(jq -nc '{id:"x", protocol:"tcp", listen_address:"0.0.0.0", local_port:"80",
        remote_address:null, remote_port:"80", nat_mode:"nat",
        created_at:"2026-01-01T00:00:00Z", updated_at:"2026-01-01T00:00:00Z"}')"
    b="$(jq -nc '{updated_at:"2026-06-01T00:00:00Z", nat_mode:"nat", remote_port:"80",
        remote_address:null, local_port:"80", listen_address:"0.0.0.0",
        protocol:"tcp", id:"y", created_at:"2025-01-01T00:00:00Z"}')"
    th::assert_eq "$(forwarding::_normalize_mapping "$a")" "$(forwarding::_normalize_mapping "$b")"
}

test_normalize_mapping_detects_nat_mode_change() {
    local a b
    a="$(jq -nc '{protocol:"tcp", listen_address:"0.0.0.0", local_port:"80", remote_address:null, remote_port:"80", nat_mode:"nat"}')"
    b="$(jq -nc '{protocol:"tcp", listen_address:"0.0.0.0", local_port:"80", remote_address:null, remote_port:"80", nat_mode:"source-preserving"}')"
    ! [[ "$(forwarding::_normalize_mapping "$a")" == "$(forwarding::_normalize_mapping "$b")" ]]
}

test_normalize_mapping_detects_explicit_vs_implicit_remote_address() {
    # An explicit remote_address, even if it happens to match what the
    # tunnel's inner_remote_ip would resolve to, is a materially
    # different stored value from "null" (implicit) - normalization
    # must not perform that resolution and silently equate them.
    local a b
    a="$(jq -nc '{protocol:"tcp", listen_address:"0.0.0.0", local_port:"80", remote_address:null, remote_port:"80", nat_mode:"nat"}')"
    b="$(jq -nc '{protocol:"tcp", listen_address:"0.0.0.0", local_port:"80", remote_address:"10.250.0.2", remote_port:"80", nat_mode:"nat"}')"
    ! [[ "$(forwarding::_normalize_mapping "$a")" == "$(forwarding::_normalize_mapping "$b")" ]]
}

th::run test_identical_edit_calls_no_forwarder_verbs
th::run test_identical_edit_preserves_mapping_id
th::run test_identical_edit_does_not_rewrite_config_file
th::run test_identical_edit_preserves_ownership_ledger
th::run test_identical_remap_token_is_also_a_noop
th::run test_different_local_port_is_not_a_noop
th::run test_different_remap_target_is_not_a_noop
th::run test_normalize_mapping_ignores_key_order_and_timestamps
th::run test_normalize_mapping_detects_nat_mode_change
th::run test_normalize_mapping_detects_explicit_vs_implicit_remote_address

th::summary

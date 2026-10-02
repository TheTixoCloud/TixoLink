#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$TEST_DIR/../.." && pwd)"
TIXOLINK_LIB_DIR="$REPO_ROOT/lib"
TIXOLINK_ENGINES_DIR="$REPO_ROOT/engines"
TIXOLINK_MODULES_DIR="$REPO_ROOT/modules"
export TIXOLINK_LIB_DIR TIXOLINK_ENGINES_DIR TIXOLINK_MODULES_DIR

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
# shellcheck source=lib/transaction.sh
source "$TIXOLINK_LIB_DIR/transaction.sh"
# shellcheck source=engines/engine_api.sh
source "$TIXOLINK_ENGINES_DIR/engine_api.sh"
# shellcheck source=engines/gre.sh
source "$TIXOLINK_ENGINES_DIR/gre.sh"
# shellcheck source=modules/tunnel.sh
source "$TIXOLINK_MODULES_DIR/tunnel.sh"
# shellcheck source=modules/peer.sh
source "$TIXOLINK_MODULES_DIR/peer.sh"

# gre::_ip must never be invoked by anything peer.sh does (import never
# starts a tunnel unless --start is given); fail loudly if it is.
gre::_ip() { echo "UNEXPECTED ip(8) CALL: $*" >&2; return 1; }

reset_store() {
    rm -rf -- "$TIXOLINK_ETC_DIR" "$TIXOLINK_VAR_DIR"
}

valid_peer_doc() {
    jq -nc '{
        tixolink_peer_schema_version: 1, document_type: "tixolink-peer-config",
        engine: "gre", name: "peer-tunnel",
        engine_config: {local_public_ip: "203.0.113.1", remote_public_ip: "203.0.113.2",
            inner_subnet: "10.250.0.0/30", inner_local_ip: "10.250.0.1",
            inner_remote_ip: "10.250.0.2", mtu: 1300, ttl: 255}
    }'
}

test_validate_document_accepts_valid() {
    peer::_validate_document "$(valid_peer_doc)"
}

test_validate_document_rejects_wrong_doctype() {
    local doc; doc="$(valid_peer_doc | jq '.document_type = "something-else"')"
    ! peer::_validate_document "$doc" 2>/dev/null
}

test_validate_document_rejects_wrong_schema_version() {
    local doc; doc="$(valid_peer_doc | jq '.tixolink_peer_schema_version = 99')"
    ! peer::_validate_document "$doc" 2>/dev/null
}

test_validate_document_rejects_unsupported_engine() {
    local doc; doc="$(valid_peer_doc | jq '.engine = "ipip"')"
    ! peer::_validate_document "$doc" 2>/dev/null
}

test_validate_document_rejects_invalid_name() {
    local doc; doc="$(valid_peer_doc | jq '.name = "has a space"')"
    ! peer::_validate_document "$doc" 2>/dev/null
}

test_import_rejects_malformed_json_file() {
    local f="$TIXOLINK_TEST_ROOT/bad1.json"
    printf 'not json at all' >"$f"
    local status=0
    peer::import "$f" --force >/dev/null 2>&1 || status=$?
    th::assert_eq "$status" "$EXIT_VALIDATION"
}

test_import_rejects_missing_file() {
    local status=0
    peer::import "$TIXOLINK_TEST_ROOT/does-not-exist.json" --force >/dev/null 2>&1 || status=$?
    th::assert_eq "$status" "$EXIT_NOT_FOUND"
}

test_import_writes_new_config_with_fresh_id() {
    reset_store
    local f="$TIXOLINK_TEST_ROOT/good1.json"
    valid_peer_doc >"$f"
    local id; id="$(peer::import "$f" --force)"
    validate::tunnel_id "$id"
}

test_import_never_reuses_a_field_named_id_from_the_document() {
    reset_store
    # The peer document has no "id" field at all (by design - see
    # modules/peer.sh header comment) - confirm the written tunnel config
    # has a freshly generated id anyway, not any value from the input.
    local f="$TIXOLINK_TEST_ROOT/good2.json"
    valid_peer_doc >"$f"
    local id; id="$(peer::import "$f" --force)"
    local written_id; written_id="$(jq -r '.id' <<<"$(config::tunnel_read "$id")")"
    th::assert_eq "$written_id" "$id"
}

test_import_does_not_start_tunnel_without_start_flag() {
    reset_store
    local f="$TIXOLINK_TEST_ROOT/good3.json"
    valid_peer_doc >"$f"
    local id; id="$(peer::import "$f" --force)"
    local status=0
    state::get ".tunnels[\"$id\"]" >/dev/null 2>&1 || status=$?
    [[ "$status" -ne 0 ]]
}

test_import_dry_run_writes_nothing() {
    reset_store
    local f="$TIXOLINK_TEST_ROOT/good4.json"
    valid_peer_doc >"$f"
    local before after
    before="$(config::tunnel_list | wc -l)"
    peer::import "$f" --force --dry-run >/dev/null
    after="$(config::tunnel_list | wc -l)"
    th::assert_eq "$before" "$after"
}

test_export_import_roundtrip_inverts_and_reinverts() {
    reset_store
    config::tunnel_write "f0f0f0f0" '{"id":"f0f0f0f0","name":"orig","engine":"gre",
        "engine_config":{"interface":"tixo-f0f0f0f0","local_public_ip":"203.0.113.1",
        "remote_public_ip":"203.0.113.2","inner_subnet":"10.250.0.0/30",
        "inner_local_ip":"10.250.0.1","inner_remote_ip":"10.250.0.2","mtu":1300,"ttl":255}}'
    local doc; doc="$(peer::_build "f0f0f0f0")"
    local f="$TIXOLINK_TEST_ROOT/roundtrip.json"
    printf '%s' "$doc" >"$f"
    # Importing is always onto a *different* host than the one that
    # exported; clear the store to simulate that (otherwise this would
    # correctly - and uninterestingly - collide with the original tunnel's
    # own identical subnet, as engine_gre_check_conflicts should reject).
    config::tunnel_delete "f0f0f0f0"
    local new_id; new_id="$(peer::import "$f" --force)"
    local new_ec; new_ec="$(jq -c '.engine_config' <<<"$(config::tunnel_read "$new_id")")"
    th::assert_eq "$(jq -r '.local_public_ip' <<<"$new_ec")" "203.0.113.2"
    th::assert_eq "$(jq -r '.remote_public_ip' <<<"$new_ec")" "203.0.113.1"
}

th::run test_validate_document_accepts_valid
th::run test_validate_document_rejects_wrong_doctype
th::run test_validate_document_rejects_wrong_schema_version
th::run test_validate_document_rejects_unsupported_engine
th::run test_validate_document_rejects_invalid_name
th::run test_import_rejects_malformed_json_file
th::run test_import_rejects_missing_file
th::run test_import_writes_new_config_with_fresh_id
th::run test_import_never_reuses_a_field_named_id_from_the_document
th::run test_import_does_not_start_tunnel_without_start_flag
th::run test_import_dry_run_writes_nothing
th::run test_export_import_roundtrip_inverts_and_reinverts

th::summary

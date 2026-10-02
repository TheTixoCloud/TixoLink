#!/usr/bin/env bash
# Unit tests for engines/gre.sh with `ip` fully mocked out (no real kernel
# calls, no root/namespaces required). See tests/integration/test_gre_netns.sh
# for the real-kernel exercise of the exact same engine code.
set -Eeuo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$TEST_DIR/../.." && pwd)"
TIXOLINK_LIB_DIR="$REPO_ROOT/lib"
TIXOLINK_ENGINES_DIR="$REPO_ROOT/engines"
export TIXOLINK_LIB_DIR TIXOLINK_ENGINES_DIR

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

# --- Fake kernel/ip(8) backend ----------------------------------------------
declare -gA FAKE_EXISTS=() FAKE_LOCAL=() FAKE_REMOTE=() FAKE_TTL=() \
    FAKE_MTU=() FAKE_INNER_IP=() FAKE_INNER_PREFIX=() FAKE_UP=()
declare -ga FAKE_IP_CALLS=()

fake_reset() {
    FAKE_EXISTS=(); FAKE_LOCAL=(); FAKE_REMOTE=(); FAKE_TTL=()
    FAKE_MTU=(); FAKE_INNER_IP=(); FAKE_INNER_PREFIX=(); FAKE_UP=()
    FAKE_IP_CALLS=()
    # Each test gets its own clean slate of tunnel configs and state, so
    # fixtures reusing the same default inner_subnet across tests never
    # collide with each other.
    rm -rf -- "$TIXOLINK_ETC_DIR" "$TIXOLINK_VAR_DIR"
}

gre::_iface_exists() { [[ -n "${FAKE_EXISTS[$1]:-}" ]]; }

gre::_read_runtime() {
    local iface="$1"
    [[ -n "${FAKE_EXISTS[$iface]:-}" ]] || return 1
    jq -n \
        --arg local "${FAKE_LOCAL[$iface]:-}" \
        --arg remote "${FAKE_REMOTE[$iface]:-}" \
        --argjson ttl "${FAKE_TTL[$iface]:-0}" \
        --argjson mtu "${FAKE_MTU[$iface]:-0}" \
        --arg inner_ip "${FAKE_INNER_IP[$iface]:-}" \
        --argjson inner_prefix "${FAKE_INNER_PREFIX[$iface]:-0}" \
        --argjson up "${FAKE_UP[$iface]:-false}" \
        '{local:$local, remote:$remote, ttl:$ttl, mtu:$mtu, up:$up,
          inner_ip:$inner_ip, inner_prefix:$inner_prefix}'
}

# Simulates exactly the ip(8) invocations engines/gre.sh issues.
gre::_ip() {
    FAKE_IP_CALLS+=("$*")
    local a1="$1" a2="$2" a3="$3"
    case "$a1 $a2" in
        "link add")
            local iface="$a3" local_ip="" remote_ip="" ttl=0
            shift 3
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    local) local_ip="$2"; shift 2 ;;
                    remote) remote_ip="$2"; shift 2 ;;
                    ttl) ttl="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
            FAKE_EXISTS[$iface]=1
            FAKE_LOCAL[$iface]="$local_ip"
            FAKE_REMOTE[$iface]="$remote_ip"
            FAKE_TTL[$iface]="$ttl"
            FAKE_MTU[$iface]=1476
            FAKE_UP[$iface]=false
            ;;
        "link del")
            local iface="$a3"
            unset "FAKE_EXISTS[$iface]" "FAKE_LOCAL[$iface]" "FAKE_REMOTE[$iface]" \
                  "FAKE_TTL[$iface]" "FAKE_MTU[$iface]" "FAKE_UP[$iface]" \
                  "FAKE_INNER_IP[$iface]" "FAKE_INNER_PREFIX[$iface]"
            ;;
        "link set")
            local iface="$a3"
            case "$4" in
                mtu)  FAKE_MTU[$iface]="$5" ;;
                up)   FAKE_UP[$iface]=true ;;
                down) FAKE_UP[$iface]=false ;;
            esac
            ;;
        "addr add")
            local addrspec="$a3" iface="$5"
            FAKE_INNER_IP[$iface]="${addrspec%/*}"
            FAKE_INNER_PREFIX[$iface]="${addrspec#*/}"
            ;;
        "addr del")
            local iface="$5"
            FAKE_INNER_IP[$iface]=""
            FAKE_INNER_PREFIX[$iface]=0
            ;;
    esac
    return 0
}

# --- Fixtures ----------------------------------------------------------------

good_config() {
    jq -nc \
        --arg id "$1" \
        '{id: $id, name: "test-tunnel", engine: "gre", engine_config: {
            interface: ("tixo-" + $id), local_public_ip: "198.51.100.1",
            remote_public_ip: "198.51.100.2", inner_subnet: "10.250.0.0/30",
            inner_local_ip: "10.250.0.1", inner_remote_ip: "10.250.0.2",
            mtu: 1300, ttl: 255}}'
}

# --- Validation ---------------------------------------------------------------

test_validate_accepts_good_config() {
    engine_gre_validate "$(good_config "aaaaaaaa")"
}

test_validate_rejects_bad_local_ip() {
    local cfg; cfg="$(good_config "aaaaaaaa" | jq '.engine_config.local_public_ip = "999.1.1.1"')"
    ! engine_gre_validate "$cfg" 2>/dev/null
}

test_validate_rejects_identical_endpoints() {
    local cfg; cfg="$(good_config "aaaaaaaa" | jq '.engine_config.remote_public_ip = .engine_config.local_public_ip')"
    ! engine_gre_validate "$cfg" 2>/dev/null
}

test_validate_rejects_non_30_inner_subnet() {
    local cfg; cfg="$(good_config "aaaaaaaa" | jq '.engine_config.inner_subnet = "10.250.0.0/29"')"
    ! engine_gre_validate "$cfg" 2>/dev/null
}

test_validate_rejects_inner_ip_outside_subnet() {
    local cfg; cfg="$(good_config "aaaaaaaa" | jq '.engine_config.inner_local_ip = "10.250.5.1"')"
    ! engine_gre_validate "$cfg" 2>/dev/null
}

test_validate_rejects_bad_mtu() {
    local cfg; cfg="$(good_config "aaaaaaaa" | jq '.engine_config.mtu = 10')"
    ! engine_gre_validate "$cfg" 2>/dev/null
}

test_validate_rejects_wrong_engine() {
    local cfg; cfg="$(good_config "aaaaaaaa" | jq '.engine = "ipip"')"
    ! engine_gre_validate "$cfg" 2>/dev/null
}

# --- Conflict detection --------------------------------------------------------

test_check_conflicts_detects_interface_collision() {
    fake_reset
    config::tunnel_write "aaaaaaaa" "$(good_config "aaaaaaaa")"
    local cfg_b; cfg_b="$(good_config "bbbbbbbb" | jq --arg i "tixo-aaaaaaaa" '.engine_config.interface = $i | .engine_config.inner_subnet = "10.251.0.0/30" | .engine_config.inner_local_ip = "10.251.0.1" | .engine_config.inner_remote_ip = "10.251.0.2"')"
    local status=0
    engine_gre_check_conflicts "bbbbbbbb" "$cfg_b" 2>/dev/null || status=$?
    th::assert_eq "$status" "$EXIT_CONFLICT"
}

test_check_conflicts_detects_subnet_overlap() {
    fake_reset
    config::tunnel_write "aaaaaaaa" "$(good_config "aaaaaaaa")"
    local cfg_b; cfg_b="$(good_config "bbbbbbbb")"  # same inner_subnet as aaaaaaaa
    local status=0
    engine_gre_check_conflicts "bbbbbbbb" "$cfg_b" 2>/dev/null || status=$?
    th::assert_eq "$status" "$EXIT_CONFLICT"
}

test_check_conflicts_allows_distinct_tunnels() {
    fake_reset
    config::tunnel_write "aaaaaaaa" "$(good_config "aaaaaaaa")"
    local cfg_b; cfg_b="$(good_config "bbbbbbbb" | jq '.engine_config.inner_subnet = "10.251.0.0/30" | .engine_config.inner_local_ip = "10.251.0.1" | .engine_config.inner_remote_ip = "10.251.0.2"')"
    engine_gre_check_conflicts "bbbbbbbb" "$cfg_b"
}

test_check_conflicts_rejects_unowned_existing_interface() {
    fake_reset
    FAKE_EXISTS["tixo-cccccccc"]=1  # exists, but no state ownership record
    local cfg; cfg="$(good_config "cccccccc")"
    local status=0
    engine_gre_check_conflicts "cccccccc" "$cfg" 2>/dev/null || status=$?
    th::assert_eq "$status" "$EXIT_CONFLICT"
}

# --- Create / idempotency / drift --------------------------------------------

test_create_is_idempotent() {
    fake_reset
    config::tunnel_write "dddddddd" "$(good_config "dddddddd")"
    engine_gre_create "dddddddd" 0 || return 1
    local calls_after_first=${#FAKE_IP_CALLS[@]}
    engine_gre_create "dddddddd" 0 || return 1
    th::assert_eq "${#FAKE_IP_CALLS[@]}" "$calls_after_first"
}

test_create_sets_ownership_in_state() {
    fake_reset
    config::tunnel_write "eeeeeeee" "$(good_config "eeeeeeee")"
    engine_gre_create "eeeeeeee" 0
    th::assert_eq "$(state::get '.tunnels["eeeeeeee"].interface')" "tixo-eeeeeeee"
}

test_create_repairs_mtu_drift_without_recreating() {
    fake_reset
    config::tunnel_write "ffffffff" "$(good_config "ffffffff")"
    engine_gre_create "ffffffff" 0
    FAKE_MTU["tixo-ffffffff"]=9000
    engine_gre_create "ffffffff" 0
    th::assert_eq "${FAKE_MTU[tixo-ffffffff]}" "1300"
}

test_create_recreates_on_ttl_drift() {
    fake_reset
    config::tunnel_write "11111111" "$(good_config "11111111")"
    engine_gre_create "11111111" 0
    FAKE_TTL["tixo-11111111"]=64
    engine_gre_create "11111111" 0
    th::assert_eq "${FAKE_TTL[tixo-11111111]}" "255"
}

test_dry_run_create_never_calls_ip() {
    fake_reset
    config::tunnel_write "22222222" "$(good_config "22222222")"
    engine_gre_create "22222222" 1
    th::assert_eq "${#FAKE_IP_CALLS[@]}" "0"
}

test_dry_run_create_does_not_create_interface() {
    fake_reset
    config::tunnel_write "33333333" "$(good_config "33333333")"
    engine_gre_create "33333333" 1
    [[ -z "${FAKE_EXISTS[tixo-33333333]:-}" ]]
}

# --- Delete / idempotency -----------------------------------------------------

test_delete_is_idempotent_on_missing_interface() {
    fake_reset
    config::tunnel_write "44444444" "$(good_config "44444444")"
    engine_gre_delete "44444444" 0
}

test_delete_refuses_unowned_interface() {
    fake_reset
    config::tunnel_write "55555555" "$(good_config "55555555")"
    FAKE_EXISTS["tixo-55555555"]=1  # exists but no ownership record
    local status=0
    engine_gre_delete "55555555" 0 2>/dev/null || status=$?
    th::assert_eq "$status" "$EXIT_CONFLICT"
}

test_delete_removes_state_ownership_record() {
    fake_reset
    config::tunnel_write "66666666" "$(good_config "66666666")"
    engine_gre_create "66666666" 0
    engine_gre_delete "66666666" 0
    local status=0
    state::get '.tunnels["66666666"]' >/dev/null 2>&1 || status=$?
    [[ "$status" -ne 0 ]]
}

# --- Status --------------------------------------------------------------------

test_status_reports_configured_before_create() {
    fake_reset
    config::tunnel_write "77777777" "$(good_config "77777777")"
    local state_val; state_val="$(engine_gre_status "77777777" | awk -F= '/^STATE=/{print substr($0,7)}')"
    th::assert_eq "$state_val" "CONFIGURED"
}

test_status_reports_up_after_create() {
    fake_reset
    config::tunnel_write "88888888" "$(good_config "88888888")"
    engine_gre_create "88888888" 0
    local state_val; state_val="$(engine_gre_status "88888888" | awk -F= '/^STATE=/{print substr($0,7)}')"
    th::assert_eq "$state_val" "UP"
}

test_status_reports_down_after_stop() {
    fake_reset
    config::tunnel_write "99999999" "$(good_config "99999999")"
    engine_gre_create "99999999" 0
    engine_gre_stop "99999999" 0
    local state_val; state_val="$(engine_gre_status "99999999" | awk -F= '/^STATE=/{print substr($0,7)}')"
    th::assert_eq "$state_val" "DOWN"
}

test_status_reports_drifted_on_external_change() {
    fake_reset
    config::tunnel_write "a0a0a0a0" "$(good_config "a0a0a0a0")"
    engine_gre_create "a0a0a0a0" 0
    FAKE_MTU["tixo-a0a0a0a0"]=9000
    local state_val; state_val="$(engine_gre_status "a0a0a0a0" | awk -F= '/^STATE=/{print substr($0,7)}')"
    th::assert_eq "$state_val" "DRIFTED"
}

test_status_reports_conflict_on_unowned_interface() {
    fake_reset
    config::tunnel_write "b0b0b0b0" "$(good_config "b0b0b0b0")"
    FAKE_EXISTS["tixo-b0b0b0b0"]=1
    local state_val; state_val="$(engine_gre_status "b0b0b0b0" | awk -F= '/^STATE=/{print substr($0,7)}')"
    th::assert_eq "$state_val" "CONFLICT"
}

test_status_reports_missing_when_ledger_entry_has_no_interface() {
    fake_reset
    config::tunnel_write "c0c0c0c0" "$(good_config "c0c0c0c0")"
    engine_gre_create "c0c0c0c0" 0
    engine_gre_delete "c0c0c0c0" 0 >/dev/null 2>&1
    # Re-write the config (delete only removes state, not config, in this
    # unit test since we call the engine verb directly rather than
    # modules/tunnel.sh::delete) and simulate a stale ledger entry.
    config::tunnel_write "c0c0c0c0" "$(good_config "c0c0c0c0")"
    state::set '.tunnels["c0c0c0c0"] = {"interface": "tixo-c0c0c0c0"}'
    local state_val; state_val="$(engine_gre_status "c0c0c0c0" | awk -F= '/^STATE=/{print substr($0,7)}')"
    th::assert_eq "$state_val" "MISSING"
}

# --- Peer export (role inversion) --------------------------------------------

test_export_peer_inverts_roles() {
    fake_reset
    config::tunnel_write "d0d0d0d0" "$(good_config "d0d0d0d0")"
    local peer_ec; peer_ec="$(engine_gre_export_peer "d0d0d0d0")"
    th::assert_eq "$(jq -r '.local_public_ip' <<<"$peer_ec")" "198.51.100.2"
    th::assert_eq "$(jq -r '.remote_public_ip' <<<"$peer_ec")" "198.51.100.1"
    th::assert_eq "$(jq -r '.inner_local_ip' <<<"$peer_ec")" "10.250.0.2"
    th::assert_eq "$(jq -r '.inner_remote_ip' <<<"$peer_ec")" "10.250.0.1"
}

test_export_peer_preserves_subnet_mtu_ttl() {
    fake_reset
    config::tunnel_write "e0e0e0e0" "$(good_config "e0e0e0e0")"
    local peer_ec; peer_ec="$(engine_gre_export_peer "e0e0e0e0")"
    th::assert_eq "$(jq -r '.inner_subnet' <<<"$peer_ec")" "10.250.0.0/30"
    th::assert_eq "$(jq -r '.mtu' <<<"$peer_ec")" "1300"
    th::assert_eq "$(jq -r '.ttl' <<<"$peer_ec")" "255"
}

th::run test_validate_accepts_good_config
th::run test_validate_rejects_bad_local_ip
th::run test_validate_rejects_identical_endpoints
th::run test_validate_rejects_non_30_inner_subnet
th::run test_validate_rejects_inner_ip_outside_subnet
th::run test_validate_rejects_bad_mtu
th::run test_validate_rejects_wrong_engine
th::run test_check_conflicts_detects_interface_collision
th::run test_check_conflicts_detects_subnet_overlap
th::run test_check_conflicts_allows_distinct_tunnels
th::run test_check_conflicts_rejects_unowned_existing_interface
th::run test_create_is_idempotent
th::run test_create_sets_ownership_in_state
th::run test_create_repairs_mtu_drift_without_recreating
th::run test_create_recreates_on_ttl_drift
th::run test_dry_run_create_never_calls_ip
th::run test_dry_run_create_does_not_create_interface
th::run test_delete_is_idempotent_on_missing_interface
th::run test_delete_refuses_unowned_interface
th::run test_delete_removes_state_ownership_record
th::run test_status_reports_configured_before_create
th::run test_status_reports_up_after_create
th::run test_status_reports_down_after_stop
th::run test_status_reports_drifted_on_external_change
th::run test_status_reports_conflict_on_unowned_interface
th::run test_status_reports_missing_when_ledger_entry_has_no_interface
th::run test_export_peer_inverts_roles
th::run test_export_peer_preserves_subnet_mtu_ttl

th::summary

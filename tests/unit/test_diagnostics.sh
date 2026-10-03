#!/usr/bin/env bash
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
# shellcheck source=lib/validation.sh
source "$TIXOLINK_LIB_DIR/validation.sh"
# shellcheck source=lib/platform.sh
source "$TIXOLINK_LIB_DIR/platform.sh"
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
# shellcheck source=lib/sysinfo.sh
source "$TIXOLINK_LIB_DIR/sysinfo.sh"
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
# shellcheck source=modules/diagnostics.sh
source "$TIXOLINK_MODULES_DIR/diagnostics.sh"

# --- Ping parsing --------------------------------------------------------------

test_parse_ping_successful_output() {
    local text="PING 1.1.1.1 (1.1.1.1) 56(84) bytes of data.
64 bytes from 1.1.1.1: icmp_seq=1 ttl=64 time=12.3 ms
64 bytes from 1.1.1.1: icmp_seq=2 ttl=64 time=12.9 ms
64 bytes from 1.1.1.1: icmp_seq=3 ttl=64 time=12.1 ms

--- 1.1.1.1 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2003ms
rtt min/avg/max/mdev = 12.100/12.433/12.900/0.345 ms"
    local out; out="$(diagnostics::parse_ping "$text")"
    th::assert_eq "$(jq -r '.transmitted' <<<"$out")" "3"
    th::assert_eq "$(jq -r '.received' <<<"$out")" "3"
    th::assert_eq "$(jq -r '.loss_pct' <<<"$out")" "0"
    th::assert_eq "$(jq -r '.avg_ms' <<<"$out")" "12.433"
}

test_parse_ping_total_loss() {
    local text="PING 10.0.0.9 (10.0.0.9) 56(84) bytes of data.

--- 10.0.0.9 ping statistics ---
3 packets transmitted, 0 received, 100% packet loss, time 2050ms"
    local out; out="$(diagnostics::parse_ping "$text")"
    th::assert_eq "$(jq -r '.loss_pct' <<<"$out")" "100"
    th::assert_eq "$(jq -r '.avg_ms' <<<"$out")" "null"
}

test_parse_ping_garbage_returns_nulls_not_crash() {
    local out; out="$(diagnostics::parse_ping "not ping output at all")"
    th::assert_eq "$(jq -r '.transmitted' <<<"$out")" "null"
}

# --- MTU recommendation --------------------------------------------------------

test_mtu_recommendation_subtracts_gre_overhead() {
    th::assert_eq "$(diagnostics::mtu_recommendation 1500)" "1476"
}

test_mtu_recommendation_rejects_non_numeric() {
    local status=0
    diagnostics::mtu_recommendation "unknown" >/dev/null 2>&1 || status=$?
    th::assert_eq "$status" "1"
}

# --- Health classification -----------------------------------------------------

test_classify_loss_pass_on_zero() {
    th::assert_eq "$(diagnostics::classify_loss 0)" "PASS"
}
test_classify_loss_warn_on_partial() {
    th::assert_eq "$(diagnostics::classify_loss 15)" "WARN"
}
test_classify_loss_fail_on_total() {
    th::assert_eq "$(diagnostics::classify_loss 100)" "FAIL"
}
test_classify_loss_unknown_when_unmeasured() {
    th::assert_eq "$(diagnostics::classify_loss "")" "UNKNOWN"
    th::assert_eq "$(diagnostics::classify_loss "null")" "UNKNOWN"
}

test_classify_resource_pressure_pass_under_thresholds() {
    th::assert_eq "$(diagnostics::classify_resource_pressure 50 60 1.0 4)" "PASS"
}
test_classify_resource_pressure_warn_high_cpu() {
    th::assert_eq "$(diagnostics::classify_resource_pressure 95 50 1.0 4)" "WARN"
}
test_classify_resource_pressure_warn_high_loadavg_ratio() {
    th::assert_eq "$(diagnostics::classify_resource_pressure 10 10 10.0 4)" "WARN"
}
test_classify_resource_pressure_unknown_when_nothing_measured() {
    th::assert_eq "$(diagnostics::classify_resource_pressure "" "" "" 0)" "UNKNOWN"
}

test_classify_iface_drops_pass_on_zero() {
    th::assert_eq "$(diagnostics::classify_iface_drops 0)" "PASS"
}
test_classify_iface_drops_warn_on_increase() {
    th::assert_eq "$(diagnostics::classify_iface_drops 3)" "WARN"
}
test_classify_iface_drops_unknown_when_unmeasured() {
    th::assert_eq "$(diagnostics::classify_iface_drops "")" "UNKNOWN"
}

test_classify_forwarding_state_active_is_pass() {
    th::assert_eq "$(diagnostics::classify_forwarding_state ACTIVE)" "PASS"
}
test_classify_forwarding_state_drifted_is_warn() {
    th::assert_eq "$(diagnostics::classify_forwarding_state DRIFTED)" "WARN"
}
test_classify_forwarding_state_conflict_is_fail() {
    th::assert_eq "$(diagnostics::classify_forwarding_state CONFLICT)" "FAIL"
}
test_classify_forwarding_state_none_is_pass() {
    th::assert_eq "$(diagnostics::classify_forwarding_state NONE)" "PASS"
}

test_classify_gre_state_up_is_pass() {
    th::assert_eq "$(diagnostics::classify_gre_state UP)" "PASS"
}
test_classify_gre_state_missing_is_fail() {
    th::assert_eq "$(diagnostics::classify_gre_state MISSING)" "FAIL"
}
test_classify_gre_state_drifted_is_warn() {
    th::assert_eq "$(diagnostics::classify_gre_state DRIFTED)" "WARN"
}

test_worst_of_fail_beats_everything() {
    th::assert_eq "$(diagnostics::worst_of PASS WARN FAIL UNKNOWN)" "FAIL"
}
test_worst_of_warn_beats_unknown_and_pass() {
    th::assert_eq "$(diagnostics::worst_of PASS WARN UNKNOWN)" "WARN"
}
test_worst_of_all_pass_is_pass() {
    th::assert_eq "$(diagnostics::worst_of PASS PASS PASS)" "PASS"
}

test_redact_ips_replaces_with_stable_tokens() {
    local out; out="$(diagnostics::_redact_ips "peer is 203.0.113.5 and backend is 10.250.0.2, also 203.0.113.5 again" "203.0.113.5" "10.250.0.2")"
    [[ "$out" == *"REDACTED-IP-1"* && "$out" == *"REDACTED-IP-2"* ]]
    [[ "$out" != *"203.0.113.5"* && "$out" != *"10.250.0.2"* ]]
}

test_redact_ips_ignores_empty_entries() {
    local out; out="$(diagnostics::_redact_ips "203.0.113.5 stays" "" "9.9.9.9")"
    [[ "$out" == *"203.0.113.5"* ]]
}

test_generate_report_privacy_mode_redacts_tunnel_ips() {
    config::tunnel_write "aaaaaaaa" '{"schema_version":1,"id":"aaaaaaaa","name":"t","engine":"gre",
        "engine_config":{"interface":"tixo-aaaaaaaa","local_public_ip":"203.0.113.9",
        "remote_public_ip":"203.0.113.10","inner_subnet":"10.250.0.0/30",
        "inner_local_ip":"10.250.0.1","inner_remote_ip":"10.250.0.2","mtu":1300,"ttl":255},
        "forwarding":{"engine":"none","mappings":[]},
        "persistence":{"enabled":false,"boot_enabled":false},"status":{"operational":"unknown"},
        "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}'
    local report; report="$(diagnostics::generate_report --privacy)"
    local tunnel_text; tunnel_text="$(tar xzOf "$report" --wildcards '*/tunnels/aaaaaaaa.txt' 2>/dev/null)"
    [[ "$tunnel_text" != *"203.0.113.9"* ]]
    [[ "$tunnel_text" == *"REDACTED-IP"* ]]
    rm -f "$report"
    config::tunnel_delete "aaaaaaaa"
}

test_generate_report_sets_restrictive_permissions() {
    local report; report="$(diagnostics::generate_report)"
    th::assert_eq "$(stat -c '%a' "$report")" "600"
    rm -f "$report"
}

test_generate_report_manifest_never_lists_etc_or_env() {
    local report; report="$(diagnostics::generate_report)"
    local manifest; manifest="$(tar xzOf "$report" --wildcards '*/manifest.txt' 2>/dev/null)"
    [[ "$manifest" == *"does NOT contain"* ]]
    rm -f "$report"
}

th::run test_redact_ips_replaces_with_stable_tokens
th::run test_redact_ips_ignores_empty_entries
th::run test_generate_report_privacy_mode_redacts_tunnel_ips
th::run test_generate_report_sets_restrictive_permissions
th::run test_generate_report_manifest_never_lists_etc_or_env
th::run test_parse_ping_successful_output
th::run test_parse_ping_total_loss
th::run test_parse_ping_garbage_returns_nulls_not_crash
th::run test_mtu_recommendation_subtracts_gre_overhead
th::run test_mtu_recommendation_rejects_non_numeric
th::run test_classify_loss_pass_on_zero
th::run test_classify_loss_warn_on_partial
th::run test_classify_loss_fail_on_total
th::run test_classify_loss_unknown_when_unmeasured
th::run test_classify_resource_pressure_pass_under_thresholds
th::run test_classify_resource_pressure_warn_high_cpu
th::run test_classify_resource_pressure_warn_high_loadavg_ratio
th::run test_classify_resource_pressure_unknown_when_nothing_measured
th::run test_classify_iface_drops_pass_on_zero
th::run test_classify_iface_drops_warn_on_increase
th::run test_classify_iface_drops_unknown_when_unmeasured
th::run test_classify_forwarding_state_active_is_pass
th::run test_classify_forwarding_state_drifted_is_warn
th::run test_classify_forwarding_state_conflict_is_fail
th::run test_classify_forwarding_state_none_is_pass
th::run test_classify_gre_state_up_is_pass
th::run test_classify_gre_state_missing_is_fail
th::run test_classify_gre_state_drifted_is_warn
th::run test_worst_of_fail_beats_everything
th::run test_worst_of_warn_beats_unknown_and_pass
th::run test_worst_of_all_pass_is_pass

th::summary

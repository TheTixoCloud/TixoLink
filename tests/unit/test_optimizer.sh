#!/usr/bin/env bash
# Unit tests for modules/optimizer.sh. The real /proc/sys and the real
# `sysctl` binary are NEVER touched: optimizer::_read_current and
# optimizer::_write_value are overridden here with an in-memory fake
# sysctl store, the same test-seam pattern used for forwarders/haproxy.sh.
set -Eeuo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$TEST_DIR/../.." && pwd)"
TIXOLINK_LIB_DIR="$REPO_ROOT/lib"
TIXOLINK_MODULES_DIR="$REPO_ROOT/modules"
export TIXOLINK_LIB_DIR TIXOLINK_MODULES_DIR

TIXOLINK_TEST_ROOT="$(mktemp -d /tmp/tixolink-test.XXXXXXXX)"
export TIXOLINK_ETC_DIR="$TIXOLINK_TEST_ROOT/etc"
export TIXOLINK_VAR_DIR="$TIXOLINK_TEST_ROOT/var"
export TIXOLINK_LOG_FILE="$TIXOLINK_TEST_ROOT/tixolink.log"
export TIXOLINK_SYSCTL_D_FILE="$TIXOLINK_TEST_ROOT/99-tixolink.conf"

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
# shellcheck source=lib/sysinfo.sh
source "$TIXOLINK_LIB_DIR/sysinfo.sh"
# shellcheck source=modules/optimizer.sh
source "$TIXOLINK_MODULES_DIR/optimizer.sh"

# --- Fake sysctl store (in-memory, never touches the real host) -------------
declare -gA FAKE_SYSCTL=(
    [net.ipv4.tcp_fin_timeout]="60"
    [net.ipv4.tcp_slow_start_after_idle]="1"
    [net.core.somaxconn]="128"
    [net.ipv4.tcp_max_syn_backlog]="256"
    [net.core.netdev_max_backlog]="1000"
)
FAKE_WRITE_FAIL_KEY=""
FAKE_VERIFY_LIE_KEY=""   # if set, _read_current reports a value that does NOT match what was written, for this key only

optimizer::_read_current() {
    local k="$1"
    if [[ "$k" == "$FAKE_VERIFY_LIE_KEY" ]]; then
        printf 'LIED'
        return 0
    fi
    printf '%s' "${FAKE_SYSCTL[$k]:-}"
}
optimizer::_write_value() {
    local k="$1" v="$2"
    [[ "$k" == "$FAKE_WRITE_FAIL_KEY" ]] && return 1
    FAKE_SYSCTL["$k"]="$v"
    return 0
}

reset_all() {
    rm -rf -- "$TIXOLINK_ETC_DIR" "$TIXOLINK_VAR_DIR" "$TIXOLINK_SYSCTL_D_FILE"
    FAKE_SYSCTL=(
        [net.ipv4.tcp_fin_timeout]="60"
        [net.ipv4.tcp_slow_start_after_idle]="1"
        [net.core.somaxconn]="128"
        [net.ipv4.tcp_max_syn_backlog]="256"
        [net.core.netdev_max_backlog]="1000"
    )
    FAKE_WRITE_FAIL_KEY=""
    FAKE_VERIFY_LIE_KEY=""
}

# --- Resource-aware proposed values --------------------------------------------

test_proposed_value_fin_timeout_caps_at_30() {
    th::assert_eq "$(optimizer::proposed_value net.ipv4.tcp_fin_timeout 60 4194304)" "30"
}
test_proposed_value_fin_timeout_leaves_already_low_value() {
    th::assert_eq "$(optimizer::proposed_value net.ipv4.tcp_fin_timeout 15 4194304)" "15"
}
test_proposed_value_somaxconn_low_ram_tier() {
    th::assert_eq "$(optimizer::proposed_value net.core.somaxconn 128 524288)" "2048"
}
test_proposed_value_somaxconn_mid_ram_tier() {
    th::assert_eq "$(optimizer::proposed_value net.core.somaxconn 128 4194304)" "4096"
}
test_proposed_value_somaxconn_high_ram_tier() {
    th::assert_eq "$(optimizer::proposed_value net.core.somaxconn 128 16777216)" "8192"
}
test_proposed_value_never_lowers_an_already_higher_value() {
    # A 64GB host administrator who already set somaxconn to 16384
    # should not have it lowered by TixoLink.
    th::assert_eq "$(optimizer::proposed_value net.core.somaxconn 16384 16777216)" "16384"
}
test_proposed_value_does_not_propose_same_value_for_different_ram() {
    local low_tier high_tier
    low_tier="$(optimizer::proposed_value net.core.netdev_max_backlog 1000 524288)"
    high_tier="$(optimizer::proposed_value net.core.netdev_max_backlog 1000 16777216)"
    [[ "$low_tier" != "$high_tier" ]]
}

# --- Plan (read-only) -----------------------------------------------------------

test_plan_is_read_only() {
    reset_all
    local before; before="$(jq -nc --argjson m "$(declare -p FAKE_SYSCTL)" '$m' 2>/dev/null || echo '{}')"
    optimizer::plan balanced >/dev/null
    # No baseline/applied files should exist merely from planning.
    [[ ! -f "$(optimizer::_baseline_file)" ]] || [[ "$(cat "$(optimizer::_baseline_file)")" == "{}" ]]
    [[ ! -f "$TIXOLINK_SYSCTL_D_FILE" ]]
}

test_plan_marks_unchanged_tunables() {
    reset_all
    FAKE_SYSCTL[net.ipv4.tcp_slow_start_after_idle]="0"  # already at proposed value
    local out; out="$(optimizer::plan balanced | jq -c 'select(.key=="net.ipv4.tcp_slow_start_after_idle")')"
    th::assert_eq "$(jq -r '.changed' <<<"$out")" "false"
}

# --- Apply / verify --------------------------------------------------------------

test_apply_profile_writes_expected_values() {
    reset_all
    optimizer::apply_profile balanced 0 >/dev/null
    th::assert_eq "${FAKE_SYSCTL[net.ipv4.tcp_fin_timeout]}" "30"
    th::assert_eq "${FAKE_SYSCTL[net.ipv4.tcp_slow_start_after_idle]}" "0"
}

test_apply_profile_dry_run_writes_nothing() {
    reset_all
    optimizer::apply_profile balanced 1 >/dev/null
    th::assert_eq "${FAKE_SYSCTL[net.ipv4.tcp_fin_timeout]}" "60"
    [[ ! -f "$(optimizer::_applied_file)" ]] || [[ "$(cat "$(optimizer::_applied_file)")" == "{}" ]]
}

test_apply_profile_regenerates_managed_file() {
    reset_all
    optimizer::apply_profile balanced 0 >/dev/null
    [[ -f "$TIXOLINK_SYSCTL_D_FILE" ]]
    grep -q "net.ipv4.tcp_fin_timeout = 30" "$TIXOLINK_SYSCTL_D_FILE"
}

# --- Baseline first-write-wins (the mandatory invariant) ----------------------

test_baseline_recorded_on_first_apply() {
    reset_all
    optimizer::apply_profile balanced 0 >/dev/null
    th::assert_eq "$(optimizer::_baseline_get net.ipv4.tcp_fin_timeout)" "60"
}

test_baseline_not_overwritten_by_second_apply() {
    reset_all
    optimizer::apply_profile balanced 0 >/dev/null   # original 60 -> 30, baseline=60
    FAKE_SYSCTL[net.ipv4.tcp_fin_timeout]="45"        # simulate something else changed it to 45
    # Re-apply balanced again: current=45, proposed=30, baseline already recorded as 60.
    optimizer::apply_profile balanced 0 >/dev/null
    th::assert_eq "$(optimizer::_baseline_get net.ipv4.tcp_fin_timeout)" "60"
    th::assert_eq "${FAKE_SYSCTL[net.ipv4.tcp_fin_timeout]}" "30"
}

test_restore_returns_to_original_baseline_not_intermediate_value() {
    reset_all
    # original A=60 -> TixoLink changes to B=30 -> (simulated) something
    # else changes it to C=45 -> restore must return to A=60, not B=30.
    optimizer::apply_profile balanced 0 >/dev/null
    FAKE_SYSCTL[net.ipv4.tcp_fin_timeout]="45"
    optimizer::restore net.ipv4.tcp_fin_timeout >/dev/null
    th::assert_eq "${FAKE_SYSCTL[net.ipv4.tcp_fin_timeout]}" "60"
}

test_restore_all_clears_applied_and_removes_managed_file() {
    reset_all
    optimizer::apply_profile balanced 0 >/dev/null
    optimizer::restore >/dev/null
    th::assert_eq "${FAKE_SYSCTL[net.ipv4.tcp_fin_timeout]}" "60"
    th::assert_eq "${FAKE_SYSCTL[net.ipv4.tcp_slow_start_after_idle]}" "1"
    [[ ! -f "$TIXOLINK_SYSCTL_D_FILE" ]]
}

test_restore_does_not_touch_tunable_with_no_baseline() {
    reset_all
    local status=0
    optimizer::restore "net.core.somaxconn" >/dev/null 2>&1 || status=$?
    th::assert_eq "$status" "$EXIT_NOT_FOUND"
    th::assert_eq "${FAKE_SYSCTL[net.core.somaxconn]}" "128"
}

# --- Failure injection: BACKUP / APPLY / VERIFY --------------------------------

test_apply_failure_rolls_back_this_runs_changes() {
    reset_all
    FAKE_WRITE_FAIL_KEY="net.ipv4.tcp_slow_start_after_idle"
    local status=0
    optimizer::apply_profile balanced 0 >/dev/null 2>&1 || status=$?
    th::assert_eq "$status" "$EXIT_ROLLED_BACK"
    # tcp_fin_timeout was applied before the failing key - must be rolled back too.
    th::assert_eq "${FAKE_SYSCTL[net.ipv4.tcp_fin_timeout]}" "60"
}

test_apply_failure_does_not_corrupt_baseline() {
    reset_all
    FAKE_WRITE_FAIL_KEY="net.ipv4.tcp_slow_start_after_idle"
    optimizer::apply_profile balanced 0 >/dev/null 2>&1 || true
    # fin_timeout's baseline WAS recorded (backup happens before write);
    # that is correct and must not be "corrupted" by the later failure.
    th::assert_eq "$(optimizer::_baseline_get net.ipv4.tcp_fin_timeout)" "60"
}

test_apply_failure_subsequent_retry_succeeds() {
    reset_all
    FAKE_WRITE_FAIL_KEY="net.ipv4.tcp_slow_start_after_idle"
    optimizer::apply_profile balanced 0 >/dev/null 2>&1 || true
    FAKE_WRITE_FAIL_KEY=""
    local status=0
    optimizer::apply_profile balanced 0 >/dev/null 2>&1 || status=$?
    th::assert_eq "$status" "0"
    th::assert_eq "${FAKE_SYSCTL[net.ipv4.tcp_fin_timeout]}" "30"
    th::assert_eq "${FAKE_SYSCTL[net.ipv4.tcp_slow_start_after_idle]}" "0"
}

test_verify_failure_rolls_back() {
    reset_all
    FAKE_VERIFY_LIE_KEY="net.ipv4.tcp_fin_timeout"
    local status=0
    optimizer::apply_profile balanced 0 >/dev/null 2>&1 || status=$?
    th::assert_eq "$status" "$EXIT_ROLLED_BACK"
}

test_verify_failure_does_not_record_applied_state() {
    reset_all
    FAKE_VERIFY_LIE_KEY="net.ipv4.tcp_fin_timeout"
    optimizer::apply_profile balanced 0 >/dev/null 2>&1 || true
    local status=0
    optimizer::_applied_get net.ipv4.tcp_fin_timeout >/dev/null 2>&1 || status=$?
    [[ "$status" -ne 0 ]]
}

test_verify_failure_subsequent_retry_succeeds() {
    reset_all
    FAKE_VERIFY_LIE_KEY="net.ipv4.tcp_fin_timeout"
    optimizer::apply_profile balanced 0 >/dev/null 2>&1 || true
    FAKE_VERIFY_LIE_KEY=""
    local status=0
    optimizer::apply_profile balanced 0 >/dev/null 2>&1 || status=$?
    th::assert_eq "$status" "0"
}

# --- Status -----------------------------------------------------------------

test_status_reports_no_managed_tunables_initially() {
    reset_all
    local out; out="$(optimizer::status)"
    [[ "$out" == *"No TixoLink-managed tunables"* ]]
}

test_status_reports_match_after_apply() {
    reset_all
    optimizer::apply_profile balanced 0 >/dev/null
    local out; out="$(optimizer::status)"
    [[ "$out" == *"KEY=net.ipv4.tcp_fin_timeout"*"MATCH=yes"* ]]
}

th::run test_proposed_value_fin_timeout_caps_at_30
th::run test_proposed_value_fin_timeout_leaves_already_low_value
th::run test_proposed_value_somaxconn_low_ram_tier
th::run test_proposed_value_somaxconn_mid_ram_tier
th::run test_proposed_value_somaxconn_high_ram_tier
th::run test_proposed_value_never_lowers_an_already_higher_value
th::run test_proposed_value_does_not_propose_same_value_for_different_ram
th::run test_plan_is_read_only
th::run test_plan_marks_unchanged_tunables
th::run test_apply_profile_writes_expected_values
th::run test_apply_profile_dry_run_writes_nothing
th::run test_apply_profile_regenerates_managed_file
th::run test_baseline_recorded_on_first_apply
th::run test_baseline_not_overwritten_by_second_apply
th::run test_restore_returns_to_original_baseline_not_intermediate_value
th::run test_restore_all_clears_applied_and_removes_managed_file
th::run test_restore_does_not_touch_tunable_with_no_baseline
th::run test_apply_failure_rolls_back_this_runs_changes
th::run test_apply_failure_does_not_corrupt_baseline
th::run test_apply_failure_subsequent_retry_succeeds
th::run test_verify_failure_rolls_back
th::run test_verify_failure_does_not_record_applied_state
th::run test_verify_failure_subsequent_retry_succeeds
th::run test_status_reports_no_managed_tunables_initially
th::run test_status_reports_match_after_apply

th::summary

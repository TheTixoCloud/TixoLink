#!/usr/bin/env bash
# Unit tests for modules/bbr.sh. Same in-memory fake-sysctl pattern as
# tests/unit/test_optimizer.sh - the real host's congestion control is
# never touched.
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
# shellcheck source=modules/bbr.sh
source "$TIXOLINK_MODULES_DIR/bbr.sh"

declare -g FAKE_CC="cubic"
declare -g FAKE_AVAILABLE="reno cubic bbr"
optimizer::_read_current() { [[ "$1" == "net.ipv4.tcp_congestion_control" ]] && printf '%s' "$FAKE_CC"; }
optimizer::_write_value() { [[ "$1" == "net.ipv4.tcp_congestion_control" ]] && FAKE_CC="$2"; return 0; }
platform::congestion_control() { printf '%s' "$FAKE_CC"; }
platform::available_congestion_control() { printf '%s' "$FAKE_AVAILABLE"; }
platform::default_qdisc() { printf 'fq_codel 0: root'; }

reset_all() {
    rm -rf -- "$TIXOLINK_ETC_DIR" "$TIXOLINK_VAR_DIR" "$TIXOLINK_SYSCTL_D_FILE"
    FAKE_CC="cubic"
    FAKE_AVAILABLE="reno cubic bbr"
}

# --- Enable from non-BBR --------------------------------------------------------

test_enable_from_cubic_switches_to_bbr() {
    reset_all
    bbr::enable 0 >/dev/null
    th::assert_eq "$FAKE_CC" "bbr"
}

test_enable_from_cubic_records_baseline() {
    reset_all
    bbr::enable 0 >/dev/null
    th::assert_eq "$(optimizer::_baseline_get net.ipv4.tcp_congestion_control)" "cubic"
}

test_enable_refuses_when_kernel_lacks_bbr() {
    reset_all
    FAKE_AVAILABLE="reno cubic"
    # bbr::_bbr_available also corroborates via `modinfo tcp_bbr`, which
    # may genuinely succeed on the machine running this test suite even
    # though FAKE_AVAILABLE says the list doesn't expose bbr; hide
    # modinfo too so this test genuinely exercises "kernel lacks bbr"
    # rather than "this dev host happens to have the module available".
    local status=0
    PATH="/nonexistent-bin-dir-for-test" bbr::enable 0 >/dev/null 2>&1 || status=$?
    th::assert_eq "$status" "$EXIT_VALIDATION"
    th::assert_eq "$FAKE_CC" "cubic"
}

test_enable_dry_run_makes_no_change() {
    reset_all
    bbr::enable 1 >/dev/null
    th::assert_eq "$FAKE_CC" "cubic"
}

# --- Already-active behavior ----------------------------------------------------

test_enable_when_already_bbr_is_a_recognized_noop() {
    reset_all
    FAKE_CC="bbr"
    bbr::enable 0 >/dev/null
    th::assert_eq "$FAKE_CC" "bbr"
}

test_enable_when_already_bbr_records_no_baseline() {
    reset_all
    FAKE_CC="bbr"
    bbr::enable 0 >/dev/null
    local status=0
    optimizer::_baseline_get net.ipv4.tcp_congestion_control >/dev/null 2>&1 || status=$?
    [[ "$status" -ne 0 ]]
}

test_status_notes_when_already_active() {
    reset_all
    FAKE_CC="bbr"
    local out; out="$(bbr::status)"
    [[ "$out" == *"already the active congestion control"* ]]
}

# --- Restore ---------------------------------------------------------------------

test_restore_after_enable_returns_to_original() {
    reset_all
    bbr::enable 0 >/dev/null
    th::assert_eq "$FAKE_CC" "bbr"
    bbr::restore >/dev/null
    th::assert_eq "$FAKE_CC" "cubic"
}

test_restore_without_any_tixolink_change_is_refused() {
    # Host originally bbr; TixoLink never touched it (enable recognized
    # it as already active, per above) - restore must NOT change
    # administrator-owned BBR state, and must fail clearly rather than
    # silently doing nothing ambiguous.
    reset_all
    FAKE_CC="bbr"
    bbr::enable 0 >/dev/null  # recognized no-op, no baseline recorded
    local status=0
    bbr::restore >/dev/null 2>&1 || status=$?
    th::assert_eq "$status" "$EXIT_NOT_FOUND"
    th::assert_eq "$FAKE_CC" "bbr"
}

test_disable_is_equivalent_to_restore() {
    reset_all
    bbr::enable 0 >/dev/null
    bbr::disable >/dev/null
    th::assert_eq "$FAKE_CC" "cubic"
}

test_ownership_flag_reflects_applied_state() {
    reset_all
    local before; before="$(bbr::status | grep '^TIXOLINK_OWNS_CHANGE=')"
    th::assert_eq "$before" "TIXOLINK_OWNS_CHANGE=no"
    bbr::enable 0 >/dev/null
    local after; after="$(bbr::status | grep '^TIXOLINK_OWNS_CHANGE=')"
    th::assert_eq "$after" "TIXOLINK_OWNS_CHANGE=yes"
}

th::run test_enable_from_cubic_switches_to_bbr
th::run test_enable_from_cubic_records_baseline
th::run test_enable_refuses_when_kernel_lacks_bbr
th::run test_enable_dry_run_makes_no_change
th::run test_enable_when_already_bbr_is_a_recognized_noop
th::run test_enable_when_already_bbr_records_no_baseline
th::run test_status_notes_when_already_active
th::run test_restore_after_enable_returns_to_original
th::run test_restore_without_any_tixolink_change_is_refused
th::run test_disable_is_equivalent_to_restore
th::run test_ownership_flag_reflects_applied_state

th::summary

#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$TEST_DIR/../.." && pwd)"
TIXOLINK_LIB_DIR="$REPO_ROOT/lib"
TIXOLINK_MODULES_DIR="$REPO_ROOT/modules"
export TIXOLINK_LIB_DIR TIXOLINK_MODULES_DIR

# shellcheck source=tests/lib/test_harness.sh
source "$REPO_ROOT/tests/lib/test_harness.sh"
# shellcheck source=lib/common.sh
source "$TIXOLINK_LIB_DIR/common.sh"
# shellcheck source=modules/monitor.sh
source "$TIXOLINK_MODULES_DIR/monitor.sh"

test_rate_computes_bps_and_pps_from_delta_over_elapsed() {
    local before after out
    before='{"rx_bytes":1000,"rx_packets":10,"rx_drop":0,"tx_bytes":2000,"tx_packets":20,"tx_drop":0}'
    after='{"rx_bytes":9000,"rx_packets":90,"rx_drop":0,"tx_bytes":10000,"tx_packets":100,"tx_drop":0}'
    out="$(monitor::rate "$before" "$after" 2)"
    th::assert_eq "$(jq -r '.valid' <<<"$out")" "true"
    # rx delta=8000 bytes over 2s -> bps = 8000*8/2 = 32000
    th::assert_eq "$(jq -r '.rx_bps' <<<"$out")" "32000"
    th::assert_eq "$(jq -r '.rx_pps' <<<"$out")" "40"
}

test_rate_uses_actual_elapsed_not_an_assumed_interval() {
    local before after
    before='{"rx_bytes":0,"rx_packets":0,"rx_drop":0,"tx_bytes":0,"tx_packets":0,"tx_drop":0}'
    after='{"rx_bytes":1000,"rx_packets":10,"rx_drop":0,"tx_bytes":0,"tx_packets":0,"tx_drop":0}'
    local out_fast out_slow
    out_fast="$(monitor::rate "$before" "$after" 1)"
    out_slow="$(monitor::rate "$before" "$after" 10)"
    [[ "$(jq -r '.rx_bps' <<<"$out_fast")" != "$(jq -r '.rx_bps' <<<"$out_slow")" ]]
}

test_rate_detects_counter_reset() {
    local before after out
    before='{"rx_bytes":9000,"rx_packets":90,"rx_drop":0,"tx_bytes":0,"tx_packets":0,"tx_drop":0}'
    after='{"rx_bytes":100,"rx_packets":1,"rx_drop":0,"tx_bytes":0,"tx_packets":0,"tx_drop":0}'
    out="$(monitor::rate "$before" "$after" 2)"
    th::assert_eq "$(jq -r '.valid' <<<"$out")" "false"
    th::assert_eq "$(jq -r '.rx_bps' <<<"$out")" "null"
}

test_rate_detects_zero_or_negative_elapsed() {
    local before after out
    before='{"rx_bytes":0,"rx_packets":0,"rx_drop":0,"tx_bytes":0,"tx_packets":0,"tx_drop":0}'
    after='{"rx_bytes":100,"rx_packets":1,"rx_drop":0,"tx_bytes":0,"tx_packets":0,"tx_drop":0}'
    out="$(monitor::rate "$before" "$after" 0)"
    th::assert_eq "$(jq -r '.valid' <<<"$out")" "false"
}

test_rate_reports_drop_delta() {
    local before after out
    before='{"rx_bytes":0,"rx_packets":0,"rx_drop":3,"tx_bytes":0,"tx_packets":0,"tx_drop":1}'
    after='{"rx_bytes":0,"rx_packets":0,"rx_drop":7,"tx_bytes":0,"tx_packets":0,"tx_drop":1}'
    out="$(monitor::rate "$before" "$after" 1)"
    th::assert_eq "$(jq -r '.rx_drop_delta' <<<"$out")" "4"
    th::assert_eq "$(jq -r '.tx_drop_delta' <<<"$out")" "0"
}

test_rate_zero_traffic_is_valid_zero_not_invalid() {
    local snap='{"rx_bytes":500,"rx_packets":5,"rx_drop":0,"tx_bytes":500,"tx_packets":5,"tx_drop":0}'
    local out; out="$(monitor::rate "$snap" "$snap" 2)"
    th::assert_eq "$(jq -r '.valid' <<<"$out")" "true"
    th::assert_eq "$(jq -r '.rx_bps' <<<"$out")" "0"
}

th::run test_rate_computes_bps_and_pps_from_delta_over_elapsed
th::run test_rate_uses_actual_elapsed_not_an_assumed_interval
th::run test_rate_detects_counter_reset
th::run test_rate_detects_zero_or_negative_elapsed
th::run test_rate_reports_drop_delta
th::run test_rate_zero_traffic_is_valid_zero_not_invalid

th::summary

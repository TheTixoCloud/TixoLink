#!/usr/bin/env bash
# Unit tests for lib/sysinfo.sh's pure parsers, using canned fixture text
# (not the real host) so results are deterministic regardless of what
# machine the test suite runs on.
set -Eeuo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$TEST_DIR/../.." && pwd)"
TIXOLINK_LIB_DIR="$REPO_ROOT/lib"
export TIXOLINK_LIB_DIR

# shellcheck source=tests/lib/test_harness.sh
source "$REPO_ROOT/tests/lib/test_harness.sh"
# shellcheck source=lib/common.sh
source "$TIXOLINK_LIB_DIR/common.sh"
# shellcheck source=lib/sysinfo.sh
source "$TIXOLINK_LIB_DIR/sysinfo.sh"

test_parse_loadavg() {
    local out; out="$(sysinfo::parse_loadavg "0.11 0.22 0.33 2/512 12345")"
    th::assert_eq "$(jq -r '.load1' <<<"$out")" "0.11"
    th::assert_eq "$(jq -r '.running' <<<"$out")" "2"
    th::assert_eq "$(jq -r '.total_tasks' <<<"$out")" "512"
}

test_parse_cpu_stat_aggregate_line() {
    local text="cpu  100 0 50 800 20 0 5 0 0 0
cpu0 50 0 25 400 10 0 2 0 0 0"
    local out; out="$(sysinfo::parse_cpu_stat "$text")"
    th::assert_eq "$(jq -r '.user' <<<"$out")" "100"
    th::assert_eq "$(jq -r '.idle' <<<"$out")" "800"
}

test_parse_cpu_stat_percpu_multiple_cores() {
    local text="cpu  150 0 75 1200 30 0 7 0 0 0
cpu0 50 0 25 400 10 0 2 0 0 0
cpu1 100 0 50 800 20 0 5 0 0 0"
    local out; out="$(sysinfo::parse_cpu_stat_percpu "$text")"
    th::assert_eq "$(jq -s 'length' <<<"$out")" "2"
    th::assert_eq "$(jq -s '.[1].core' <<<"$out")" "1"
}

test_cpu_util_from_samples_computes_percentages() {
    local before after out
    before='{"user":0,"nice":0,"system":0,"idle":0,"iowait":0,"irq":0,"softirq":0,"steal":0}'
    after='{"user":50,"nice":0,"system":25,"idle":400,"iowait":25,"irq":0,"softirq":0,"steal":0}'
    out="$(sysinfo::cpu_util_from_samples "$before" "$after")"
    th::assert_eq "$(jq -r '.valid' <<<"$out")" "true"
    # total delta = 500, idle delta = 400 -> total_pct = 100*(1-400/500) = 20
    th::assert_eq "$(jq -r '.total_pct' <<<"$out")" "20"
    th::assert_eq "$(jq -r '.user_pct' <<<"$out")" "10"
}

test_cpu_util_from_samples_detects_counter_reset() {
    local before after out
    before='{"user":1000,"nice":0,"system":0,"idle":0,"iowait":0,"irq":0,"softirq":0,"steal":0}'
    after='{"user":10,"nice":0,"system":0,"idle":0,"iowait":0,"irq":0,"softirq":0,"steal":0}'
    out="$(sysinfo::cpu_util_from_samples "$before" "$after")"
    th::assert_eq "$(jq -r '.valid' <<<"$out")" "false"
}

test_cpu_util_from_samples_zero_elapsed_is_invalid() {
    local snap='{"user":10,"nice":0,"system":0,"idle":90,"iowait":0,"irq":0,"softirq":0,"steal":0}'
    local out; out="$(sysinfo::cpu_util_from_samples "$snap" "$snap")"
    th::assert_eq "$(jq -r '.valid' <<<"$out")" "false"
}

test_parse_meminfo() {
    local text="MemTotal:        8000000 kB
MemFree:         3000000 kB
MemAvailable:    5000000 kB
Buffers:          100000 kB
Cached:          1500000 kB
SwapTotal:       4000000 kB
SwapFree:        2500000 kB"
    local out; out="$(sysinfo::parse_meminfo "$text")"
    th::assert_eq "$(jq -r '.total_kb' <<<"$out")" "8000000"
    th::assert_eq "$(jq -r '.used_kb' <<<"$out")" "3000000"
    th::assert_eq "$(jq -r '.swap_used_kb' <<<"$out")" "1500000"
}

test_parse_net_dev_extracts_fields() {
    local text="Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 1000       10    0    0    0     0          0         0     1000       10    0    0    0     0       0          0
  eth0: 500000    400    1    2    0     0          0         0   300000      300    0    1    0     0       0          0"
    local out
    out="$(sysinfo::parse_net_dev "$text")"
    th::assert_eq "$(jq -s 'length' <<<"$out")" "2"
    local eth0; eth0="$(jq -c 'select(.iface=="eth0")' <<<"$out")"
    th::assert_eq "$(jq -r '.rx_bytes' <<<"$eth0")" "500000"
    th::assert_eq "$(jq -r '.rx_errs' <<<"$eth0")" "1"
    th::assert_eq "$(jq -r '.tx_drop' <<<"$eth0")" "1"
}

test_parse_net_dev_handles_missing_interface() {
    local text="Inter-|   Receive
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 1000       10    0    0    0     0          0         0     1000       10    0    0    0     0       0          0"
    local out; out="$(sysinfo::parse_net_dev "$text" | jq -c 'select(.iface=="doesnotexist")')"
    th::assert_eq "$out" ""
}

test_parse_ss_summary_extracts_known_fields() {
    local text="Total: 100
TCP:   50 (estab 30, closed 10, orphaned 1, timewait 5)

Transport Total     IP        IPv6
UDP	  7         5         2
TCP	  40        20        20"
    local out; out="$(sysinfo::parse_ss_summary "$text")"
    th::assert_eq "$(jq -r '.total' <<<"$out")" "100"
    th::assert_eq "$(jq -r '.tcp_established' <<<"$out")" "30"
    th::assert_eq "$(jq -r '.tcp_timewait' <<<"$out")" "5"
    th::assert_eq "$(jq -r '.udp_total' <<<"$out")" "7"
}

test_parse_ss_summary_tolerates_missing_fields() {
    local out; out="$(sysinfo::parse_ss_summary "garbage output format")"
    th::assert_eq "$(jq -r '.total' <<<"$out")" "null"
}

test_parse_snmp_proto_pairs_header_and_values() {
    local text="Ip: Forwarding DefaultTTL
Ip: 1 64
Tcp: RtoAlgorithm RtoMin RetransSegs CurrEstab
Tcp: 1 200 42 7"
    local out; out="$(sysinfo::parse_snmp_proto "$text" "Tcp")"
    th::assert_eq "$(jq -r '.RetransSegs' <<<"$out")" "42"
    th::assert_eq "$(jq -r '.CurrEstab' <<<"$out")" "7"
}

th::run test_parse_loadavg
th::run test_parse_cpu_stat_aggregate_line
th::run test_parse_cpu_stat_percpu_multiple_cores
th::run test_cpu_util_from_samples_computes_percentages
th::run test_cpu_util_from_samples_detects_counter_reset
th::run test_cpu_util_from_samples_zero_elapsed_is_invalid
th::run test_parse_meminfo
th::run test_parse_net_dev_extracts_fields
th::run test_parse_net_dev_handles_missing_interface
th::run test_parse_ss_summary_extracts_known_fields
th::run test_parse_ss_summary_tolerates_missing_fields
th::run test_parse_snmp_proto_pairs_header_and_values

th::summary

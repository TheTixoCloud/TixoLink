#!/usr/bin/env bash
# TixoLink NEXUS - benchmarking
#
# Distinct from modules/diagnostics.sh: benchmarking can generate
# sustained traffic and therefore always requires explicit user action
# (a specific command/menu confirmation) - nothing here runs as a side
# effect of opening a menu or running diagnostics.

if [[ -n "${TIXOLINK_MODULE_BENCHMARK_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_MODULE_BENCHMARK_SH_LOADED=1

readonly TIXOLINK_BENCHMARK_SCHEMA_VERSION=1

# benchmark::latency <target> [count] [timeout_s]
# Thin, explicitly-named wrapper over diagnostics::ping - kept separate
# so benchmark call sites read as "running a benchmark", not reusing a
# diagnostics internal by coincidence.
benchmark::latency() {
    diagnostics::ping "$@"
}

# --- Throughput (iperf3) ------------------------------------------------------

# benchmark::_iperf3_available
benchmark::_iperf3_available() { command -v iperf3 >/dev/null 2>&1; }

# benchmark::parse_iperf3_json <iperf3-json-output>
# Pure parser. Prints {throughput_bps, retransmits, duration_s, streams,
# direction}. Any field iperf3 didn't report (e.g. retransmits for a
# UDP test) is null.
benchmark::parse_iperf3_json() {
    local text="$1"
    jq -c '
        if (.error? // null) != null then
            {error: .error}
        else
            {
                throughput_bps: (.end.sum_sent.bits_per_second // .end.sum.bits_per_second // null),
                retransmits: (.end.sum_sent.retransmits // null),
                duration_s: (.end.sum_sent.seconds // .end.sum.seconds // null),
                streams: (.start.test_start.num_streams // null),
                direction: (if .start.test_start.reverse == 1 then "reverse" else "forward" end)
            }
        end
    ' <<<"$text" 2>/dev/null || jq -nc '{error: "could not parse iperf3 output"}'
}

# benchmark::throughput <server-ip> [port] [duration_s] [streams] [reverse:0|1]
# Requires iperf3 (OPTIONAL dependency - never installed implicitly) and
# an explicitly provided server endpoint; TixoLink never assumes the
# remote peer runs an iperf3 server. duration bounded to [1,30]s,
# streams bounded to [1,8] - safe limits, never an open-ended flood.
benchmark::throughput() {
    local server="$1" port="${2:-5201}" duration="${3:-5}" streams="${4:-1}" reverse="${5:-0}"

    benchmark::_iperf3_available || {
        log::error "iperf3 is not installed. Install it explicitly (FEATURE:diagnostics dependency) before running a throughput benchmark."
        return "$EXIT_DEPENDENCY"
    }
    validate::ipv4 "$server" || return "$EXIT_VALIDATION"
    validate::port "$port" || return "$EXIT_VALIDATION"
    [[ "$duration" =~ ^[0-9]+$ && "$duration" -ge 1 && "$duration" -le 30 ]] || duration=5
    [[ "$streams" =~ ^[0-9]+$ && "$streams" -ge 1 && "$streams" -le 8 ]] || streams=1

    local -a cmd=(iperf3 -c "$server" -p "$port" -t "$duration" -P "$streams" -J)
    [[ "$reverse" == "1" ]] && cmd+=(-R)

    local out
    out="$("${cmd[@]}" 2>&1)" || true
    benchmark::parse_iperf3_json "$out"
}

# --- Snapshot format -----------------------------------------------------------

# benchmark::snapshot <tunnel-id> <public-latency-json> <inner-latency-json> \
#     <throughput-json-or-null>
# A reusable record for before/after optimizer comparisons: timestamp,
# tunnel id/config, both latency results, optional throughput, a CPU
# utilization sample, the tunnel interface's counters, and the
# currently-active kernel network settings (congestion control/qdisc) -
# everything optimizer verification needs to make a factual comparison,
# nothing more.
benchmark::snapshot() {
    local tunnel_id="$1" public_latency="$2" inner_latency="$3" throughput="${4:-null}"
    local tunnel_json engine_config iface cpu_before cpu_after cpu_util iface_counters

    tunnel_json="$(config::tunnel_read "$tunnel_id" 2>/dev/null)" || tunnel_json="null"
    engine_config="$(jq -c '.engine_config // null' <<<"$tunnel_json")"
    iface="$(jq -r '.engine_config.interface // empty' <<<"$tunnel_json")"

    cpu_before="$(sysinfo::cpu_stat 2>/dev/null)" || cpu_before=""
    if [[ -n "$cpu_before" ]]; then
        sleep 0.3
        cpu_after="$(sysinfo::cpu_stat 2>/dev/null)" || cpu_after=""
        [[ -n "$cpu_after" ]] && cpu_util="$(sysinfo::cpu_util_from_samples "$cpu_before" "$cpu_after")"
    fi

    if [[ -n "$iface" ]]; then
        iface_counters="$(sysinfo::iface_counters "$iface" 2>/dev/null)"
    fi

    jq -nc \
        --argjson schema_version "$TIXOLINK_BENCHMARK_SCHEMA_VERSION" \
        --arg timestamp "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --arg tunnel_id "$tunnel_id" \
        --argjson engine_config "${engine_config:-null}" \
        --argjson public_latency "${public_latency:-null}" \
        --argjson inner_latency "${inner_latency:-null}" \
        --argjson throughput "$throughput" \
        --argjson cpu_util "${cpu_util:-null}" \
        --argjson iface_counters "${iface_counters:-null}" \
        --arg congestion_control "$(platform::congestion_control 2>/dev/null)" \
        --arg qdisc "$(platform::default_qdisc 2>/dev/null)" \
        '{
            schema_version: $schema_version,
            timestamp: $timestamp,
            tunnel_id: $tunnel_id,
            engine_config: $engine_config,
            public_latency: $public_latency,
            inner_latency: $inner_latency,
            throughput: $throughput,
            cpu_util: $cpu_util,
            iface_counters: $iface_counters,
            congestion_control: $congestion_control,
            qdisc: $qdisc
        }'
}

# benchmark::compare <before-snapshot-json> <after-snapshot-json>
# Prints a factual side-by-side comparison. Never claims "better"/"worse" -
# only ever states the measured before/after values; any judgment is left
# to the reader (or to a caller applying its own documented threshold,
# e.g. modules/optimizer.sh's verification step).
benchmark::compare() {
    local before="$1" after="$2"
    local b_avg a_avg b_loss a_loss b_thr a_thr b_cpu a_cpu

    b_avg="$(jq -r '.inner_latency.avg_ms // .public_latency.avg_ms // "n/a"' <<<"$before")"
    a_avg="$(jq -r '.inner_latency.avg_ms // .public_latency.avg_ms // "n/a"' <<<"$after")"
    b_loss="$(jq -r '.inner_latency.loss_pct // .public_latency.loss_pct // "n/a"' <<<"$before")"
    a_loss="$(jq -r '.inner_latency.loss_pct // .public_latency.loss_pct // "n/a"' <<<"$after")"
    b_thr="$(jq -r '.throughput.throughput_bps // "n/a"' <<<"$before")"
    a_thr="$(jq -r '.throughput.throughput_bps // "n/a"' <<<"$after")"
    b_cpu="$(jq -r '.cpu_util.total_pct // "n/a"' <<<"$before")"
    a_cpu="$(jq -r '.cpu_util.total_pct // "n/a"' <<<"$after")"

    printf 'Latency avg (ms):   before %s   after %s\n' "$b_avg" "$a_avg"
    printf 'Packet loss (%%):    before %s   after %s\n' "$b_loss" "$a_loss"
    [[ "$b_thr" != "n/a" || "$a_thr" != "n/a" ]] && \
        printf 'Throughput (bps):   before %s   after %s\n' "$b_thr" "$a_thr"
    printf 'CPU utilization(%%): before %s   after %s\n' "$b_cpu" "$a_cpu"
}

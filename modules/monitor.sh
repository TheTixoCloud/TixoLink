#!/usr/bin/env bash
# TixoLink NEXUS - live tunnel monitor
#
# Rate calculation is a pure function over two counter snapshots and the
# ACTUAL measured elapsed time between them (never an assumed refresh
# interval), handling a counter reset or interface recreation safely
# (reports "reset" rather than a nonsensical negative/huge rate). The
# display loop itself is a thin wrapper that samples, sleeps, samples
# again, and renders via lib/ui.sh - no heavy TUI framework.

if [[ -n "${TIXOLINK_MODULE_MONITOR_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_MODULE_MONITOR_SH_LOADED=1

# monitor::rate <before-counters-json> <after-counters-json> <elapsed-seconds>
# Prints {rx_bps, tx_bps, rx_pps, tx_pps, rx_drop_delta, tx_drop_delta,
# valid}. valid=false (all rates null) on a detected counter reset
# (any counter went backwards) or non-positive elapsed time - never a
# fabricated rate in either case.
monitor::rate() {
    local before="$1" after="$2" elapsed="$3"
    jq -nc --argjson b "$before" --argjson a "$after" --argjson e "$elapsed" '
        def d(k): ($a[k] - $b[k]);
        if $e <= 0 then
            {valid: false, rx_bps: null, tx_bps: null, rx_pps: null, tx_pps: null, rx_drop_delta: null, tx_drop_delta: null}
        elif (d("rx_bytes") < 0 or d("tx_bytes") < 0 or d("rx_packets") < 0 or d("tx_packets") < 0) then
            {valid: false, rx_bps: null, tx_bps: null, rx_pps: null, tx_pps: null, rx_drop_delta: null, tx_drop_delta: null}
        else
            {
                valid: true,
                rx_bps: ((d("rx_bytes") * 8 / $e) | round),
                tx_bps: ((d("tx_bytes") * 8 / $e) | round),
                rx_pps: ((d("rx_packets") / $e) | round),
                tx_pps: ((d("tx_packets") / $e) | round),
                rx_drop_delta: d("rx_drop"),
                tx_drop_delta: d("tx_drop")
            }
        end'
}

# monitor::_now_epoch_ms - monotonic-enough wall clock for elapsed-time math.
monitor::_now_epoch_ms() { date +%s%3N; }

# monitor::run <tunnel-id-or-name> [interval_s]
# The live loop. Ctrl+C exits cleanly (relies on lib/common.sh's existing
# EXIT/INT/TERM trap infrastructure); leaves no background process behind
# since everything here runs in the foreground of the current process.
monitor::run() {
    local ref="$1" interval="${2:-2}"
    [[ "$interval" =~ ^[0-9]+$ && "$interval" -ge 1 && "$interval" -le 60 ]] || interval=2

    local id; id="$(tunnel::resolve "$ref")" || return $?
    local tunnel_json engine iface
    tunnel_json="$(config::tunnel_read "$id")" || return "$EXIT_NOT_FOUND"
    engine="$(tunnel::_engine_of "$id")"
    iface="$(jq -r '.engine_config.interface' <<<"$tunnel_json")"

    local running=1
    trap 'running=0' INT TERM

    local before after before_ms after_ms rate
    before="$(sysinfo::iface_counters "$iface" 2>/dev/null)"
    before_ms="$(monitor::_now_epoch_ms)"

    while [[ "$running" == "1" ]]; do
        sleep "$interval"
        [[ "$running" == "1" ]] || break

        after="$(sysinfo::iface_counters "$iface" 2>/dev/null)"
        after_ms="$(monitor::_now_epoch_ms)"

        if [[ -z "$before" || -z "$after" ]]; then
            ui::warning "Interface $iface is not available; retrying..."
        else
            local elapsed; elapsed="$(awk -v a="$after_ms" -v b="$before_ms" 'BEGIN{printf "%.3f", (a-b)/1000}')"
            rate="$(monitor::rate "$before" "$after" "$elapsed")"

            local gre_state fwd_engine
            gre_state="$(engine::dispatch "$engine" status "$id" 2>/dev/null | awk -F= '/^STATE=/{print substr($0,7)}')"
            fwd_engine="$(jq -r '.forwarding.engine // "none"' <<<"$tunnel_json")"

            ui::header
            printf 'Tunnel: %s (%s)   State: %s   Forwarding: %s\n\n' "$(jq -r '.name' <<<"$tunnel_json")" "$id" "$gre_state" "$fwd_engine"
            if [[ "$(jq -r '.valid' <<<"$rate")" == "true" ]]; then
                printf 'RX: %8s bps  %6s pps  (drops this interval: %s)\n' \
                    "$(jq -r '.rx_bps' <<<"$rate")" "$(jq -r '.rx_pps' <<<"$rate")" "$(jq -r '.rx_drop_delta' <<<"$rate")"
                printf 'TX: %8s bps  %6s pps  (drops this interval: %s)\n' \
                    "$(jq -r '.tx_bps' <<<"$rate")" "$(jq -r '.tx_pps' <<<"$rate")" "$(jq -r '.tx_drop_delta' <<<"$rate")"
            else
                printf 'Rate unavailable this interval (counter reset or interface recreated).\n'
            fi
            printf '\n(Ctrl+C to exit)\n'

            before="$after"
            before_ms="$after_ms"
        fi
    done

    trap - INT TERM
    printf '\n'
    ui::info "Monitor stopped."
    return 0
}

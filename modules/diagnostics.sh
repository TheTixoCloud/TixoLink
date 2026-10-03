#!/usr/bin/env bash
# TixoLink NEXUS - diagnostics orchestration
#
# Read-only by construction: every function here either inspects the
# host (via lib/sysinfo.sh, lib/platform.sh) or inspects a tunnel's
# config/runtime (via engines/gre.sh, forwarders/*.sh status verbs).
# Nothing here mutates anything. Health classification is deterministic
# and documented inline at each classify_* function - there is no single
# "health score"; every individual observation is reported alongside the
# aggregate.
#
# Health states: PASS, WARN, FAIL, UNKNOWN (measurement could not safely
# be performed, e.g. optional tool missing or value unavailable).

if [[ -n "${TIXOLINK_MODULE_DIAGNOSTICS_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_MODULE_DIAGNOSTICS_SH_LOADED=1

# GRE over IPv4 overhead: 20-byte outer IPv4 header + 4-byte base GRE
# header (no key/seq options are used by engines/gre.sh). Used only to
# turn a measured underlay path MTU into a GRE MTU recommendation -
# never to silently change anything.
readonly TIXOLINK_GRE_OVERHEAD_BYTES=24

# Documented thresholds for health classification (see docs/troubleshooting.md).
readonly TIXOLINK_HEALTH_CPU_WARN_PCT=90
readonly TIXOLINK_HEALTH_MEM_WARN_PCT=90
readonly TIXOLINK_HEALTH_LOADAVG_WARN_RATIO=2

# --- Status envelope helpers --------------------------------------------------

# diagnostics::_wrap <status> [data-json]
diagnostics::_wrap() {
    local status="$1" data="${2:-null}"
    jq -nc --arg status "$status" --argjson data "$data" '{status: $status, data: $data}'
}

diagnostics::_wrap_unavailable() {
    jq -nc --arg status "UNAVAILABLE" --arg reason "$1" '{status: $status, data: null, reason: $reason}'
}

# --- System diagnostics -------------------------------------------------------

# diagnostics::system
# One JSON report covering CPU, memory, network, sockets, kernel stack.
# Each section is independently AVAILABLE/UNAVAILABLE - a missing
# optional tool never fails the whole report.
diagnostics::system() {
    local cpu_before cpu_after cpu_util loadavg meminfo ss_sum snmp_tcp conntrack sockbuf

    loadavg="$(sysinfo::loadavg 2>/dev/null)" || loadavg=""
    meminfo="$(sysinfo::meminfo 2>/dev/null)" || meminfo=""
    cpu_before="$(sysinfo::cpu_stat 2>/dev/null)" || cpu_before=""
    if [[ -n "$cpu_before" ]]; then
        sleep 0.3
        cpu_after="$(sysinfo::cpu_stat 2>/dev/null)" || cpu_after=""
        [[ -n "$cpu_after" ]] && cpu_util="$(sysinfo::cpu_util_from_samples "$cpu_before" "$cpu_after")"
    fi
    ss_sum="$(sysinfo::ss_summary 2>/dev/null)" || ss_sum=""
    snmp_tcp="$(sysinfo::snmp_tcp 2>/dev/null)" || snmp_tcp=""
    conntrack="$(sysinfo::conntrack 2>/dev/null)" || conntrack=""
    sockbuf="$(sysinfo::sockbuf 2>/dev/null)" || sockbuf=""

    local close_wait
    close_wait="$(sysinfo::tcp_state_count close-wait 2>/dev/null)" || close_wait=""

    jq -nc \
        --argjson cpu_count "$(sysinfo::cpu_count)" \
        --argjson loadavg "${loadavg:-null}" \
        --argjson cpu_util "${cpu_util:-null}" \
        --argjson meminfo "${meminfo:-null}" \
        --argjson ss_summary "${ss_sum:-null}" \
        --argjson tcp_close_wait "${close_wait:-null}" \
        --argjson snmp_tcp "${snmp_tcp:-null}" \
        --argjson conntrack "${conntrack:-null}" \
        --argjson sockbuf "${sockbuf:-null}" \
        --arg congestion_control "$(platform::congestion_control 2>/dev/null)" \
        --arg available_congestion_control "$(platform::available_congestion_control 2>/dev/null)" \
        --arg default_qdisc "$(platform::default_qdisc 2>/dev/null)" \
        '{
            cpu_count: $cpu_count,
            loadavg: $loadavg,
            cpu_util: $cpu_util,
            meminfo: $meminfo,
            ss_summary: $ss_summary,
            tcp_close_wait: $tcp_close_wait,
            snmp_tcp: $snmp_tcp,
            conntrack: $conntrack,
            sockbuf: $sockbuf,
            congestion_control: $congestion_control,
            available_congestion_control: $available_congestion_control,
            default_qdisc: $default_qdisc
        }'
}

# --- Ping (latency/loss) -----------------------------------------------------

# diagnostics::parse_ping <ping-output-text>
# Pure parser. Prints {transmitted, received, loss_pct, min_ms, avg_ms,
# max_ms, mdev_ms} - any field ping didn't report is null, never guessed.
diagnostics::parse_ping() {
    local text="$1" transmitted received loss min avg max mdev
    transmitted="$(grep -oP '\K[0-9]+(?= packets transmitted)' <<<"$text" | head -n1)"
    received="$(grep -oP '\K[0-9]+(?= (packets )?received)' <<<"$text" | head -n1)"
    loss="$(grep -oP '\K[0-9.]+(?=% packet loss)' <<<"$text" | head -n1)"
    local rtt_line; rtt_line="$(grep -oP 'rtt min/avg/max/mdev = \K[0-9.]+/[0-9.]+/[0-9.]+/[0-9.]+' <<<"$text")"
    if [[ -n "$rtt_line" ]]; then
        IFS='/' read -r min avg max mdev <<<"$rtt_line"
    fi
    jq -nc \
        --arg transmitted "${transmitted:-}" --arg received "${received:-}" --arg loss "${loss:-}" \
        --arg min "${min:-}" --arg avg "${avg:-}" --arg max "${max:-}" --arg mdev "${mdev:-}" \
        '{
            transmitted: (if $transmitted=="" then null else ($transmitted|tonumber) end),
            received: (if $received=="" then null else ($received|tonumber) end),
            loss_pct: (if $loss=="" then null else ($loss|tonumber) end),
            min_ms: (if $min=="" then null else ($min|tonumber) end),
            avg_ms: (if $avg=="" then null else ($avg|tonumber) end),
            max_ms: (if $max=="" then null else ($max|tonumber) end),
            mdev_ms: (if $mdev=="" then null else ($mdev|tonumber) end)
        }'
}

# diagnostics::ping <target> [count] [timeout_s]
# count is bounded to [1,20], timeout to [1,10] - safe bounds, never
# unbounded, never a flood. Automatically runs inside $TIXOLINK_NETNS
# when that's set, exactly like engines/gre.sh:gre::_ip and
# forwarders/netfilter.sh:netfilter::_ipt - this is what lets the same
# diagnostics code be exercised against a real namespace topology in
# integration tests without ever touching the host's default namespace.
diagnostics::ping() {
    local target="$1" count="${2:-3}" timeout="${3:-2}"
    validate::ipv4 "$target" || return "$EXIT_VALIDATION"
    [[ "$count" -ge 1 && "$count" -le 20 ]] 2>/dev/null || count=3
    [[ "$timeout" -ge 1 && "$timeout" -le 10 ]] 2>/dev/null || timeout=2
    local -a cmd=(ping -n -c "$count" -W "$timeout" "$target")
    local out
    if [[ -n "${TIXOLINK_NETNS:-}" ]]; then
        out="$(ip netns exec "$TIXOLINK_NETNS" "${cmd[@]}" 2>&1)" || true
    else
        out="$("${cmd[@]}" 2>&1)" || true
    fi
    diagnostics::parse_ping "$out"
}

# --- MTU / PMTU -----------------------------------------------------------------

# diagnostics::probe_df_ping <target> <icmp-payload-size> [netns-override]
# One DF ("don't fragment") ping at a specific ICMP payload size. Prints
# "ok" or "too-big" or "unknown". Never changes MTU; purely observational.
# Defaults to $TIXOLINK_NETNS like diagnostics::ping; an explicit
# [netns-override] argument (used by diagnostics::find_path_mtu's tests)
# takes precedence when given.
diagnostics::probe_df_ping() {
    local target="$1" size="$2" ns="${3:-${TIXOLINK_NETNS:-}}"
    # shellcheck disable=SC1010  # "-M do" is ping's don't-fragment flag value, not loop syntax
    local -a cmd=(ping -n -c 1 -W 1 -M do -s "$size" "$target")
    local out status=0
    if [[ -n "$ns" ]]; then
        out="$(ip netns exec "$ns" "${cmd[@]}" 2>&1)" || status=$?
    else
        out="$("${cmd[@]}" 2>&1)" || status=$?
    fi
    if [[ "$status" -eq 0 ]]; then
        printf 'ok'
    elif grep -qiE 'frag|too long|message too long' <<<"$out"; then
        printf 'too-big'
    else
        printf 'unknown'
    fi
}

# diagnostics::find_path_mtu <target> [netns]
# Bounded binary search (<=10 probes) for the largest ICMP payload that
# gets through without fragmentation, between 500 and 1472 (the usable
# range for a standard 1500-byte-MTU underlay). Prints the discovered
# total IPv4 path MTU (payload + 28 bytes of IPv4+ICMP header), or
# "unknown" if probing was inconclusive (e.g. all probes ambiguous).
diagnostics::find_path_mtu() {
    local target="$1" ns="${2:-}"
    local lo=500 hi=1472 best=0 iterations=0 mid result

    # Sanity-check the lower bound first; if even the smallest probe is
    # ambiguous, probing this path is not reliable.
    result="$(diagnostics::probe_df_ping "$target" "$lo" "$ns")"
    [[ "$result" == "ok" ]] || { printf 'unknown'; return 0; }
    best="$lo"

    while [[ "$lo" -lt "$hi" && "$iterations" -lt 10 ]]; do
        mid=$(( (lo + hi + 1) / 2 ))
        result="$(diagnostics::probe_df_ping "$target" "$mid" "$ns")"
        case "$result" in
            ok) lo="$mid"; best="$mid" ;;
            too-big) hi=$((mid - 1)) ;;
            *) break ;;  # unknown/ambiguous - stop, report best confirmed so far
        esac
        iterations=$((iterations + 1))
    done

    printf '%d' "$((best + 28))"
}

# diagnostics::mtu_recommendation <measured-path-mtu>
# GRE MTU = underlay path MTU - GRE/outer-IPv4 overhead. Never applied
# automatically - callers only ever display this.
diagnostics::mtu_recommendation() {
    local path_mtu="$1"
    [[ "$path_mtu" =~ ^[0-9]+$ ]] || { echo "unknown"; return 1; }
    echo "$((path_mtu - TIXOLINK_GRE_OVERHEAD_BYTES))"
}

# --- Health classification ----------------------------------------------------

# diagnostics::_fcmp <a> <op> <b>
# Floating-point comparison via awk (bc is not a TixoLink dependency;
# awk is always present). <op> is one of: ge gt.
diagnostics::_fcmp() {
    local a="$1" op="$2" b="$3"
    awk -v a="$a" -v b="$b" -v op="$op" 'BEGIN {
        if (op == "ge") { exit !(a >= b) }
        if (op == "gt") { exit !(a > b) }
        exit 1
    }'
}

# diagnostics::classify_loss <loss_pct>
# PASS: 0%. WARN: >0% and <100%. FAIL: 100% (completely unreachable).
# UNKNOWN: measurement unavailable.
diagnostics::classify_loss() {
    local loss="$1"
    [[ -z "$loss" || "$loss" == "null" ]] && { echo "UNKNOWN"; return 0; }
    if diagnostics::_fcmp "$loss" ge 100; then
        echo "FAIL"
    elif diagnostics::_fcmp "$loss" gt 0; then
        echo "WARN"
    else
        echo "PASS"
    fi
}

# diagnostics::classify_resource_pressure <cpu_total_pct|null> <mem_used_pct|null> <load1> <cpu_count>
# WARN if CPU >= 90%, memory >= 90%, or load1/cpu_count >= 2 (documented
# constants above). PASS otherwise. UNKNOWN if nothing could be measured.
diagnostics::classify_resource_pressure() {
    local cpu="$1" mem="$2" load1="$3" cpu_count="$4"
    local warned=0 measured=0
    if [[ -n "$cpu" && "$cpu" != "null" ]]; then
        measured=1
        diagnostics::_fcmp "$cpu" ge "$TIXOLINK_HEALTH_CPU_WARN_PCT" && warned=1
    fi
    if [[ -n "$mem" && "$mem" != "null" ]]; then
        measured=1
        diagnostics::_fcmp "$mem" ge "$TIXOLINK_HEALTH_MEM_WARN_PCT" && warned=1
    fi
    if [[ -n "$load1" && "$load1" != "null" && "$cpu_count" -gt 0 ]]; then
        measured=1
        local ratio; ratio="$(awk -v l="$load1" -v c="$cpu_count" 'BEGIN{printf "%.4f", l/c}')"
        diagnostics::_fcmp "$ratio" ge "$TIXOLINK_HEALTH_LOADAVG_WARN_RATIO" && warned=1
    fi
    if [[ "$measured" -eq 0 ]]; then
        echo "UNKNOWN"
    elif [[ "$warned" -eq 1 ]]; then
        echo "WARN"
    else
        echo "PASS"
    fi
}

# diagnostics::classify_iface_drops <drop_delta>
# WARN if drops increased during the (short, bounded) observation
# window; PASS if zero; UNKNOWN if not measured.
diagnostics::classify_iface_drops() {
    local delta="$1"
    [[ -z "$delta" || "$delta" == "null" ]] && { echo "UNKNOWN"; return 0; }
    if [[ "$delta" -gt 0 ]]; then echo "WARN"; else echo "PASS"; fi
}

# diagnostics::classify_forwarding_state <state>
# ACTIVE -> PASS. PARTIAL/DRIFTED -> WARN (recoverable via repair).
# CONFLICT/MISSING (when mappings exist) -> FAIL. NONE -> PASS (nothing
# expected). Anything else -> UNKNOWN.
diagnostics::classify_forwarding_state() {
    case "$1" in
        ACTIVE|NONE) echo "PASS" ;;
        PARTIAL|DRIFTED) echo "WARN" ;;
        CONFLICT|MISSING) echo "FAIL" ;;
        *) echo "UNKNOWN" ;;
    esac
}

# diagnostics::classify_gre_state <state>
# Mirrors engines/gre.sh's own STATE values onto health, but keeps
# runtime-vs-config DRIFT (WARN, recoverable) distinct from a genuine
# interface-missing-while-expected-active or ownership CONFLICT (FAIL).
diagnostics::classify_gre_state() {
    case "$1" in
        UP) echo "PASS" ;;
        DOWN|CONFIGURED) echo "WARN" ;;
        DRIFTED) echo "WARN" ;;
        MISSING|CONFLICT) echo "FAIL" ;;
        *) echo "UNKNOWN" ;;
    esac
}

# diagnostics::worst_of <state...>
# Aggregates without hiding individual observations: FAIL > WARN >
# UNKNOWN > PASS. Callers must still print every individual state -
# this is only ever an additional summary line, never a replacement.
diagnostics::worst_of() {
    local s rank best=0 best_name="PASS"
    declare -A ranks=([PASS]=0 [UNKNOWN]=1 [WARN]=2 [FAIL]=3)
    for s in "$@"; do
        rank="${ranks[$s]:-1}"
        if [[ "$rank" -gt "$best" ]]; then
            best="$rank"
            best_name="$s"
        fi
    done
    printf '%s' "$best_name"
}

# --- Tunnel diagnostics --------------------------------------------------------

# diagnostics::tunnel <id-or-name>
# Prints a structured report (KEY=VALUE lines, one block per section,
# blank-line separated) distinguishing configuration, runtime, and
# reachability as genuinely separate observations - interface UP is
# never treated as "tunnel healthy".
diagnostics::tunnel() {
    local ref="$1"
    local id; id="$(tunnel::resolve "$ref")" || return $?
    local tunnel_json; tunnel_json="$(config::tunnel_read "$id")" || return "$EXIT_NOT_FOUND"
    local engine; engine="$(tunnel::_engine_of "$id")"

    local gre_status; gre_status="$(engine::dispatch "$engine" status "$id")"
    local gre_state; gre_state="$(awk -F= '/^STATE=/{print substr($0,7)}' <<<"$gre_status")"
    local iface; iface="$(awk -F= '/^INTERFACE=/{print substr($0,11)}' <<<"$gre_status")"
    local local_public remote_public inner_local inner_remote desired_mtu
    local_public="$(awk -F= '/^LOCAL_PUBLIC=/{print substr($0,14)}' <<<"$gre_status")"
    remote_public="$(awk -F= '/^REMOTE_PUBLIC=/{print substr($0,15)}' <<<"$gre_status")"
    inner_local="$(awk -F= '/^INNER_LOCAL=/{print substr($0,13)}' <<<"$gre_status")"
    inner_remote="$(awk -F= '/^INNER_REMOTE=/{print substr($0,14)}' <<<"$gre_status")"
    desired_mtu="$(awk -F= '/^MTU=/{print substr($0,5)}' <<<"$gre_status")"

    printf 'TUNNEL_ID=%s\n' "$id"
    printf 'NAME=%s\n' "$(jq -r '.name' <<<"$tunnel_json")"
    printf 'TRANSPORT=%s\n' "$engine"
    printf 'GRE_STATE=%s\n' "$gre_state"
    printf 'GRE_HEALTH=%s\n' "$(diagnostics::classify_gre_state "$gre_state")"
    printf 'INTERFACE=%s\n' "$iface"
    printf 'DESIRED_LOCAL_PUBLIC=%s\n' "$local_public"
    printf 'DESIRED_REMOTE_PUBLIC=%s\n' "$remote_public"
    printf 'DESIRED_INNER_LOCAL=%s\n' "$inner_local"
    printf 'DESIRED_INNER_REMOTE=%s\n' "$inner_remote"
    printf 'DESIRED_MTU=%s\n' "$desired_mtu"

    # Runtime counters (two samples, briefly apart, for a drop-delta
    # observation) - distinct from the config/state comparison above.
    local before after rx_drop_before rx_drop_after tx_drop_before tx_drop_after
    before="$(sysinfo::iface_counters "$iface" 2>/dev/null)"
    sleep 0.3
    after="$(sysinfo::iface_counters "$iface" 2>/dev/null)"
    if [[ -n "$before" && -n "$after" ]]; then
        rx_drop_before="$(jq -r '.rx_drop' <<<"$before")"; rx_drop_after="$(jq -r '.rx_drop' <<<"$after")"
        tx_drop_before="$(jq -r '.tx_drop' <<<"$before")"; tx_drop_after="$(jq -r '.tx_drop' <<<"$after")"
        printf 'RX_BYTES=%s\n' "$(jq -r '.rx_bytes' <<<"$after")"
        printf 'TX_BYTES=%s\n' "$(jq -r '.tx_bytes' <<<"$after")"
        printf 'RX_PACKETS=%s\n' "$(jq -r '.rx_packets' <<<"$after")"
        printf 'TX_PACKETS=%s\n' "$(jq -r '.tx_packets' <<<"$after")"
        printf 'RX_ERRORS=%s\n' "$(jq -r '.rx_errs' <<<"$after")"
        printf 'TX_ERRORS=%s\n' "$(jq -r '.tx_errs' <<<"$after")"
        printf 'RX_DROPS=%s\n' "$(jq -r '.rx_drop' <<<"$after")"
        printf 'TX_DROPS=%s\n' "$(jq -r '.tx_drop' <<<"$after")"
        printf 'DROP_HEALTH=%s\n' "$(diagnostics::classify_iface_drops "$(( (rx_drop_after - rx_drop_before) + (tx_drop_after - tx_drop_before) ))")"
    else
        printf 'COUNTERS=UNAVAILABLE\n'
        printf 'DROP_HEALTH=UNKNOWN\n'
    fi

    # Reachability is tested, never assumed, and reported SEPARATELY for
    # public vs. inner peer - a working public peer does not imply a
    # working inner peer, and vice versa.
    local pub_ping inner_ping pub_loss inner_loss
    if validate::ipv4 "$remote_public" 2>/dev/null; then
        pub_ping="$(diagnostics::ping "$remote_public" 3 2)"
        pub_loss="$(jq -r '.loss_pct' <<<"$pub_ping")"
        printf 'PUBLIC_PEER_LOSS_PCT=%s\n' "$pub_loss"
        printf 'PUBLIC_PEER_AVG_MS=%s\n' "$(jq -r '.avg_ms' <<<"$pub_ping")"
        printf 'PUBLIC_PEER_HEALTH=%s\n' "$(diagnostics::classify_loss "$pub_loss")"
    else
        printf 'PUBLIC_PEER_HEALTH=UNKNOWN\n'
    fi
    if validate::ipv4 "$inner_remote" 2>/dev/null; then
        inner_ping="$(diagnostics::ping "$inner_remote" 3 2)"
        inner_loss="$(jq -r '.loss_pct' <<<"$inner_ping")"
        printf 'INNER_PEER_LOSS_PCT=%s\n' "$inner_loss"
        printf 'INNER_PEER_AVG_MS=%s\n' "$(jq -r '.avg_ms' <<<"$inner_ping")"
        printf 'INNER_PEER_HEALTH=%s\n' "$(diagnostics::classify_loss "$inner_loss")"
    else
        printf 'INNER_PEER_HEALTH=UNKNOWN\n'
    fi

    # Forwarding - config-valid/listener/backend-reachable are kept as
    # separate claims by the forwarder's own status verb; diagnostics
    # only classifies the aggregate STATE, never collapses it further.
    local fwd_engine; fwd_engine="$(jq -r '.forwarding.engine // "none"' <<<"$tunnel_json")"
    printf 'FORWARDING_ENGINE=%s\n' "$fwd_engine"
    if [[ "$fwd_engine" != "none" ]]; then
        local m mid mstate
        while IFS= read -r m; do
            [[ -z "$m" || "$m" == "null" ]] && continue
            mid="$(jq -r '.id' <<<"$m")"
            mstate="$(forwarder::dispatch "$fwd_engine" status "$tunnel_json" "$m" | awk -F= '/^STATE=/{print substr($0,7)}')"
            printf 'FORWARDING_MAPPING=%s STATE=%s HEALTH=%s\n' "$mid" "$mstate" "$(diagnostics::classify_forwarding_state "$mstate")"
        done < <(jq -c '.forwarding.mappings[]?' <<<"$tunnel_json")
    fi

    printf 'PERSISTENCE=%s\n' "not-installed (systemd persistence is configured by the installer phase)"

    return 0
}

# --- Support report -----------------------------------------------------------

# diagnostics::_redact_ips <text> <ip...>
# Replaces every occurrence of each given IPv4 address with a stable,
# order-based token (REDACTED-IP-1, REDACTED-IP-2, ...) so the same
# address always maps to the same token within one report, without ever
# revealing the real address.
diagnostics::_redact_ips() {
    local text="$1"
    shift
    local ip i=0
    for ip in "$@"; do
        [[ -z "$ip" ]] && continue
        i=$((i + 1))
        text="${text//${ip}/REDACTED-IP-${i}}"
    done
    printf '%s' "$text"
}

# diagnostics::report_manifest_line <description>
# Used to build an explicit, human-readable list of exactly what a
# support report collected - never a blind directory/env dump.
TIXOLINK_DIAG_MANIFEST=()
diagnostics::_manifest_add() { TIXOLINK_DIAG_MANIFEST+=("$1"); }

# diagnostics::generate_report [--privacy]
# Produces a single tar.gz under /tmp containing ONLY explicitly
# collected diagnostic output (system diagnostics, platform info, and
# each configured tunnel's diagnostics) plus a manifest describing
# exactly what was collected. Never archives /etc wholesale, never dumps
# process environment variables, and (with --privacy) redacts every
# public/inner IPv4 address referenced by any tunnel config.
diagnostics::generate_report() {
    local privacy=0
    [[ "${1:-}" == "--privacy" ]] && privacy=1

    TIXOLINK_DIAG_MANIFEST=()
    local workdir; workdir="$(mktemp -d /tmp/tixolink-report.XXXXXXXX)"
    chmod 0700 "$workdir"
    mkdir -p "$workdir/tunnels"

    local -a redact_ips=()
    if [[ "$privacy" == "1" ]]; then
        local id ip
        while IFS= read -r id; do
            [[ -z "$id" ]] && continue
            while IFS= read -r ip; do
                [[ -n "$ip" ]] && redact_ips+=("$ip")
            done < <(config::tunnel_read "$id" 2>/dev/null | jq -r '
                .engine_config.local_public_ip, .engine_config.remote_public_ip,
                .engine_config.inner_local_ip, .engine_config.inner_remote_ip' 2>/dev/null)
        done < <(config::tunnel_list)
    fi

    local sys_json
    sys_json="$(diagnostics::system 2>/dev/null)" || sys_json='{}'
    if [[ "$privacy" == "1" ]]; then
        sys_json="$(diagnostics::_redact_ips "$sys_json" "${redact_ips[@]}")"
    fi
    printf '%s\n' "$sys_json" >"$workdir/system.json"
    diagnostics::_manifest_add "system.json - CPU/memory/network/socket/kernel-stack snapshot (diagnostics::system)"

    jq -nc \
        --arg os_id "$(platform::os_id)" --arg os_version "$(platform::os_version)" \
        --arg kernel "$(platform::kernel)" --arg arch "$(platform::arch)" \
        --arg virt "$(platform::virt)" --arg version "$(common::version)" \
        '{os_id:$os_id, os_version:$os_version, kernel:$kernel, arch:$arch, virt:$virt, tixolink_version:$version}' \
        >"$workdir/platform.json"
    diagnostics::_manifest_add "platform.json - OS/kernel/arch/virtualization/TixoLink version"

    local id tunnel_text
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        tunnel_text="$(diagnostics::tunnel "$id" 2>/dev/null)" || continue
        if [[ "$privacy" == "1" ]]; then
            tunnel_text="$(diagnostics::_redact_ips "$tunnel_text" "${redact_ips[@]}")"
        fi
        printf '%s\n' "$tunnel_text" >"$workdir/tunnels/${id}.txt"
        diagnostics::_manifest_add "tunnels/${id}.txt - tunnel diagnostics (config/runtime/reachability/forwarding), per diagnostics::tunnel"
    done < <(config::tunnel_list)

    {
        printf 'TixoLink NEXUS support report\n'
        printf 'Generated: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf 'Privacy mode: %s\n\n' "$([[ "$privacy" == "1" ]] && echo "enabled (IP addresses redacted)" || echo "disabled")"
        printf 'This report contains ONLY the following, explicitly collected:\n'
        local line
        for line in "${TIXOLINK_DIAG_MANIFEST[@]}"; do
            printf '  - %s\n' "$line"
        done
        printf '\nIt does NOT contain: /etc, process environment variables, credentials,\n'
        printf 'SSH keys, API keys, or any configuration outside what is listed above.\n'
    } >"$workdir/manifest.txt"

    local out_file
    out_file="/tmp/tixolink-support-report-$(date -u '+%Y%m%dT%H%M%SZ').tar.gz"
    tar -czf "$out_file" -C "$(dirname "$workdir")" "$(basename "$workdir")" 2>/dev/null
    chmod 0600 "$out_file"
    rm -rf -- "$workdir"
    printf '%s' "$out_file"
}

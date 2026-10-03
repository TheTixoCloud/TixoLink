#!/usr/bin/env bash
# TixoLink NEXUS - read-only system inspection primitives
#
# Every function here is either a pure parser (takes raw text as input,
# returns parsed JSON, never touches the filesystem - fully unit
# testable with canned fixtures) or a thin read-only wrapper that reads
# a /proc file or runs a REQUIRED/OPTIONAL diagnostic tool and feeds its
# output to the matching parser. Nothing in this file writes anything,
# anywhere, ever - it is the read-only half of the diagnostics
# subsystem described in docs/architecture.md.

if [[ -n "${TIXOLINK_SYSINFO_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_SYSINFO_SH_LOADED=1

# --- CPU ----------------------------------------------------------------------

# sysinfo::parse_loadavg <text-of-/proc/loadavg>
# "0.12 0.34 0.56 2/512 12345" -> {load1,load5,load15,running,total_tasks,last_pid}
sysinfo::parse_loadavg() {
    local text="$1" l1 l5 l15 running total last_pid
    read -r l1 l5 l15 running_total last_pid <<<"$text"
    running="${running_total%/*}"
    total="${running_total#*/}"
    jq -nc --arg l1 "$l1" --arg l5 "$l5" --arg l15 "$l15" \
        --argjson running "${running:-0}" --argjson total "${total:-0}" \
        --argjson last_pid "${last_pid:-0}" \
        '{load1: ($l1|tonumber), load5: ($l5|tonumber), load15: ($l15|tonumber),
          running: $running, total_tasks: $total, last_pid: $last_pid}'
}

sysinfo::loadavg() {
    [[ -r /proc/loadavg ]] || return 1
    sysinfo::parse_loadavg "$(cat /proc/loadavg)"
}

# sysinfo::cpu_count
sysinfo::cpu_count() {
    nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1
}

# sysinfo::parse_cpu_stat <text-of-/proc/stat>
# Prints the aggregate "cpu " line as JSON counters (jiffies, not percentages -
# percentages require two samples, see cpu_util_from_samples).
sysinfo::parse_cpu_stat() {
    local line
    line="$(grep '^cpu ' <<<"$1")"
    # cpu  user nice system idle iowait irq softirq steal guest guest_nice
    read -r _ user nice system idle iowait irq softirq steal _ _ <<<"$line"
    jq -nc --argjson user "${user:-0}" --argjson nice "${nice:-0}" \
        --argjson system "${system:-0}" --argjson idle "${idle:-0}" \
        --argjson iowait "${iowait:-0}" --argjson irq "${irq:-0}" \
        --argjson softirq "${softirq:-0}" --argjson steal "${steal:-0}" \
        '{user:$user, nice:$nice, system:$system, idle:$idle, iowait:$iowait,
          irq:$irq, softirq:$softirq, steal:$steal}'
}

# sysinfo::parse_cpu_stat_percpu <text-of-/proc/stat>
# Prints one object per "cpuN " line (same fields, plus "core").
sysinfo::parse_cpu_stat_percpu() {
    local line core user nice system idle iowait irq softirq steal
    while IFS= read -r line; do
        [[ "$line" =~ ^cpu([0-9]+)\  ]] || continue
        core="${BASH_REMATCH[1]}"
        read -r _ user nice system idle iowait irq softirq steal _ _ <<<"$line"
        jq -nc --argjson core "$core" --argjson user "${user:-0}" --argjson nice "${nice:-0}" \
            --argjson system "${system:-0}" --argjson idle "${idle:-0}" \
            --argjson iowait "${iowait:-0}" --argjson irq "${irq:-0}" \
            --argjson softirq "${softirq:-0}" --argjson steal "${steal:-0}" \
            '{core:$core, user:$user, nice:$nice, system:$system, idle:$idle,
              iowait:$iowait, irq:$irq, softirq:$softirq, steal:$steal}'
    done <<<"$1"
}

sysinfo::cpu_stat() {
    [[ -r /proc/stat ]] || return 1
    sysinfo::parse_cpu_stat "$(cat /proc/stat)"
}

sysinfo::cpu_stat_percpu() {
    [[ -r /proc/stat ]] || return 1
    sysinfo::parse_cpu_stat_percpu "$(cat /proc/stat)"
}

# sysinfo::cpu_util_from_samples <before-json> <after-json>
# Pure delta math: given two sysinfo::parse_cpu_stat snapshots, returns
# percentage utilization for each category plus total (100-idle). Safe
# against a counter reset (if any delta is negative, returns null
# fields rather than a nonsensical negative/huge percentage).
sysinfo::cpu_util_from_samples() {
    local before="$1" after="$2"
    jq -nc --argjson b "$before" --argjson a "$after" '
        def d(k): ($a[k] - $b[k]);
        (["user","nice","system","idle","iowait","irq","softirq","steal"] | map(d(.))) as $deltas |
        ($deltas | add) as $total |
        if $total <= 0 or ($deltas | map(select(. < 0)) | length) > 0 then
            {valid: false}
        else
            {
                valid: true,
                total_pct: ((100 * (1 - (d("idle") / $total))) * 100 | round / 100),
                user_pct: ((100 * d("user") / $total) * 100 | round / 100),
                system_pct: ((100 * d("system") / $total) * 100 | round / 100),
                iowait_pct: ((100 * d("iowait") / $total) * 100 | round / 100),
                irq_pct: ((100 * d("irq") / $total) * 100 | round / 100),
                softirq_pct: ((100 * d("softirq") / $total) * 100 | round / 100),
                steal_pct: ((100 * d("steal") / $total) * 100 | round / 100),
                idle_pct: ((100 * d("idle") / $total) * 100 | round / 100)
            }
        end'
}

# --- Memory ---------------------------------------------------------------------

# sysinfo::parse_meminfo <text-of-/proc/meminfo>
sysinfo::parse_meminfo() {
    local text="$1"
    local total free avail buffers cached swap_total swap_free
    total="$(awk '/^MemTotal:/{print $2}' <<<"$text")"
    free="$(awk '/^MemFree:/{print $2}' <<<"$text")"
    avail="$(awk '/^MemAvailable:/{print $2}' <<<"$text")"
    buffers="$(awk '/^Buffers:/{print $2}' <<<"$text")"
    cached="$(awk '/^Cached:/{print $2}' <<<"$text")"
    swap_total="$(awk '/^SwapTotal:/{print $2}' <<<"$text")"
    swap_free="$(awk '/^SwapFree:/{print $2}' <<<"$text")"
    jq -nc \
        --argjson total "${total:-0}" --argjson free "${free:-0}" \
        --argjson avail "${avail:-0}" --argjson buffers "${buffers:-0}" \
        --argjson cached "${cached:-0}" --argjson swap_total "${swap_total:-0}" \
        --argjson swap_free "${swap_free:-0}" \
        '{
            total_kb: $total, free_kb: $free, available_kb: $avail,
            buffers_kb: $buffers, cached_kb: $cached,
            used_kb: ($total - $avail),
            swap_total_kb: $swap_total, swap_free_kb: $swap_free,
            swap_used_kb: ($swap_total - $swap_free)
        }'
}

sysinfo::meminfo() {
    [[ -r /proc/meminfo ]] || return 1
    sysinfo::parse_meminfo "$(cat /proc/meminfo)"
}

# --- Network interfaces -----------------------------------------------------

# sysinfo::parse_net_dev <text-of-/proc/net/dev>
# One JSON object per interface (excluding the two header lines).
sysinfo::parse_net_dev() {
    awk '
        NR <= 2 { next }
        {
            split($0, a, ":")
            iface = a[1]
            gsub(/^[ \t]+/, "", iface)
            n = split(a[2], f, /[ \t]+/)
            # f[1] may be empty due to leading whitespace in a[2]
            o = (f[1] == "") ? 1 : 0
            printf "{\"iface\":\"%s\",\"rx_bytes\":%s,\"rx_packets\":%s,\"rx_errs\":%s,\"rx_drop\":%s,\"tx_bytes\":%s,\"tx_packets\":%s,\"tx_errs\":%s,\"tx_drop\":%s}\n", \
                iface, f[o+1], f[o+2], f[o+3], f[o+4], f[o+9], f[o+10], f[o+11], f[o+12]
        }
    ' <<<"$1"
}

sysinfo::net_dev() {
    local text
    if [[ -n "${TIXOLINK_NETNS:-}" ]]; then
        # Per-namespace virtual interfaces (e.g. a GRE tunnel's own
        # interface) only exist in that namespace's /proc/net/dev - this
        # must be read inside it, exactly like gre::_ip/netfilter::_ipt
        # run their commands inside it. Host-level resources (CPU,
        # memory) are deliberately NOT namespace-scoped this way, since
        # there is only one real CPU/memory regardless of namespace.
        text="$(ip netns exec "$TIXOLINK_NETNS" cat /proc/net/dev 2>/dev/null)" || return 1
    else
        [[ -r /proc/net/dev ]] || return 1
        text="$(cat /proc/net/dev)"
    fi
    sysinfo::parse_net_dev "$text"
}

# sysinfo::iface_counters <iface>
sysinfo::iface_counters() {
    local iface="$1"
    sysinfo::net_dev | jq -c --arg i "$iface" 'select(.iface == $i)'
}

# sysinfo::iface_link_info <iface>
# Operational state, MTU, addresses - via `ip`, always required/present.
sysinfo::iface_link_info() {
    local iface="$1" link_json addr_json
    if [[ -n "${TIXOLINK_NETNS:-}" ]]; then
        link_json="$(ip -n "$TIXOLINK_NETNS" -j link show dev "$iface" 2>/dev/null)" || return 1
    else
        link_json="$(ip -j link show dev "$iface" 2>/dev/null)" || return 1
    fi
    [[ -z "$link_json" || "$link_json" == "[]" ]] && return 1
    if [[ -n "${TIXOLINK_NETNS:-}" ]]; then
        addr_json="$(ip -n "$TIXOLINK_NETNS" -j addr show dev "$iface" 2>/dev/null)"
    else
        addr_json="$(ip -j addr show dev "$iface" 2>/dev/null)"
    fi
    [[ -z "$addr_json" ]] && addr_json="[]"
    jq -nc --argjson link "$link_json" --argjson addr "$addr_json" '{
        iface: $link[0].ifname,
        mtu: $link[0].mtu,
        up: ((($link[0].flags // []) | index("UP")) != null),
        lower_up: ((($link[0].flags // []) | index("LOWER_UP")) != null),
        operstate: ($link[0].operstate // "UNKNOWN"),
        addresses: [$addr[0].addr_info[]?.local]
    }'
}

# --- Sockets --------------------------------------------------------------------

# sysinfo::parse_ss_summary <text-of-"ss -s">
# Tolerates format variation across iproute2 versions: any field it
# can't find is simply omitted rather than causing a parse failure.
sysinfo::parse_ss_summary() {
    local text="$1" total tcp_total estab closed orphaned timewait udp_total
    total="$(grep -oP '^Total:\s*\K[0-9]+' <<<"$text")"
    tcp_total="$(grep -oP '^TCP:\s*\K[0-9]+' <<<"$text")"
    estab="$(grep -oP 'estab \K[0-9]+' <<<"$text")"
    closed="$(grep -oP 'closed \K[0-9]+' <<<"$text")"
    orphaned="$(grep -oP 'orphaned \K[0-9]+' <<<"$text")"
    timewait="$(grep -oP 'timewait \K[0-9]+' <<<"$text")"
    udp_total="$(grep -oP '^UDP\s+\K[0-9]+' <<<"$text")"
    jq -nc \
        --arg total "${total:-}" --arg tcp_total "${tcp_total:-}" \
        --arg estab "${estab:-}" --arg closed "${closed:-}" \
        --arg orphaned "${orphaned:-}" --arg timewait "${timewait:-}" \
        --arg udp_total "${udp_total:-}" \
        '{
            total: (if $total == "" then null else ($total|tonumber) end),
            tcp_total: (if $tcp_total == "" then null else ($tcp_total|tonumber) end),
            tcp_established: (if $estab == "" then null else ($estab|tonumber) end),
            tcp_closed: (if $closed == "" then null else ($closed|tonumber) end),
            tcp_orphaned: (if $orphaned == "" then null else ($orphaned|tonumber) end),
            tcp_timewait: (if $timewait == "" then null else ($timewait|tonumber) end),
            udp_total: (if $udp_total == "" then null else ($udp_total|tonumber) end)
        }'
}

sysinfo::ss_summary() {
    command -v ss >/dev/null 2>&1 || return 1
    sysinfo::parse_ss_summary "$(ss -s 2>/dev/null)"
}

# sysinfo::tcp_state_count <state>
# Counts sockets in a specific TCP state (e.g. "close-wait") via `ss`.
# Separate from ss -s because close-wait is not in its summary.
sysinfo::tcp_state_count() {
    local state="$1"
    command -v ss >/dev/null 2>&1 || return 1
    ss -tan state "$state" 2>/dev/null | tail -n +2 | wc -l
}

# --- Kernel network stack ----------------------------------------------------

# sysinfo::parse_snmp_proto <text-of-/proc/net/snmp> <proto-prefix>
# /proc/net/snmp pairs a header line and a value line per protocol, e.g.:
#   Tcp: RtoAlgorithm RtoMin ... RetransSegs ...
#   Tcp: 1 200 ... 42 ...
sysinfo::parse_snmp_proto() {
    local text="$1" proto="$2" header_line value_line
    header_line="$(grep "^${proto}:" <<<"$text" | head -n1)"
    value_line="$(grep "^${proto}:" <<<"$text" | tail -n1)"
    [[ -n "$header_line" ]] || return 1
    local -a names values
    read -r -a names <<<"${header_line#*: }"
    read -r -a values <<<"${value_line#*: }"
    local i out="{}"
    for (( i=0; i<${#names[@]}; i++ )); do
        out="$(jq -c --arg k "${names[$i]}" --argjson v "${values[$i]:-0}" '. + {($k): $v}' <<<"$out")"
    done
    printf '%s' "$out"
}

sysinfo::snmp_tcp() {
    [[ -r /proc/net/snmp ]] || return 1
    sysinfo::parse_snmp_proto "$(cat /proc/net/snmp)" "Tcp"
}

sysinfo::snmp_udp() {
    [[ -r /proc/net/snmp ]] || return 1
    sysinfo::parse_snmp_proto "$(cat /proc/net/snmp)" "Udp"
}

# sysinfo::netstat_counter <counter-name>
# Pulls a single named counter (e.g. "TCPLoss", "ListenDrops") out of
# /proc/net/netstat's TcpExt section.
sysinfo::netstat_counter() {
    local name="$1" text header_line value_line
    [[ -r /proc/net/netstat ]] || return 1
    text="$(cat /proc/net/netstat)"
    header_line="$(grep '^TcpExt:' <<<"$text" | head -n1)"
    value_line="$(grep '^TcpExt:' <<<"$text" | tail -n1)"
    [[ -n "$header_line" ]] || return 1
    local -a names values
    read -r -a names <<<"${header_line#*: }"
    read -r -a values <<<"${value_line#*: }"
    local i
    for (( i=0; i<${#names[@]}; i++ )); do
        if [[ "${names[$i]}" == "$name" ]]; then
            printf '%s' "${values[$i]:-0}"
            return 0
        fi
    done
    return 1
}

# sysinfo::conntrack
sysinfo::conntrack() {
    local count_file="/proc/sys/net/netfilter/nf_conntrack_count"
    local max_file="/proc/sys/net/netfilter/nf_conntrack_max"
    [[ -r "$count_file" && -r "$max_file" ]] || return 1
    jq -nc --argjson count "$(cat "$count_file")" --argjson max "$(cat "$max_file")" \
        '{count: $count, max: $max}'
}

# sysinfo::qdisc <iface>
sysinfo::qdisc() {
    local iface="$1"
    command -v tc >/dev/null 2>&1 || return 1
    tc qdisc show dev "$iface" 2>/dev/null | head -n1
}

# sysinfo::sockbuf
# A handful of relevant socket-buffer-related tunables, read directly
# from /proc/sys (no subprocess needed).
sysinfo::sockbuf() {
    local f
    local -A vals=()
    for f in net/core/rmem_max net/core/wmem_max net/core/somaxconn \
             net/ipv4/tcp_rmem net/ipv4/tcp_wmem net/ipv4/tcp_max_syn_backlog; do
        local path="/proc/sys/${f}"
        [[ -r "$path" ]] && vals["$f"]="$(tr '\t' ' ' <"$path")"
    done
    jq -nc \
        --arg rmem_max "${vals[net/core/rmem_max]:-}" \
        --arg wmem_max "${vals[net/core/wmem_max]:-}" \
        --arg somaxconn "${vals[net/core/somaxconn]:-}" \
        --arg tcp_rmem "${vals[net/ipv4/tcp_rmem]:-}" \
        --arg tcp_wmem "${vals[net/ipv4/tcp_wmem]:-}" \
        --arg tcp_max_syn_backlog "${vals[net/ipv4/tcp_max_syn_backlog]:-}" \
        '{rmem_max: $rmem_max, wmem_max: $wmem_max, somaxconn: $somaxconn,
          tcp_rmem: $tcp_rmem, tcp_wmem: $tcp_wmem, tcp_max_syn_backlog: $tcp_max_syn_backlog}'
}

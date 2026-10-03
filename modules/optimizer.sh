#!/usr/bin/env bash
# TixoLink NEXUS - network optimizer
#
# Architecture: INSPECT -> SELECT PROFILE -> SHOW RATIONALE -> SHOW
# CURRENT->PROPOSED -> CONFIRM (caller's responsibility, e.g. lib/menu.sh)
# -> BACKUP BASELINE -> APPLY -> VERIFY -> COMMIT OR RESTORE.
#
# Opening/inspecting the optimizer (status, recommend) performs ZERO
# mutation. Only optimizer::apply_profile, when actually invoked, writes
# anything, and only after its caller has already confirmed.
#
# Ownership: TixoLink manages exactly one file,
# /etc/sysctl.d/99-tixolink.conf (overridable via TIXOLINK_SYSCTL_D_FILE
# for testing). It never edits /etc/sysctl.conf or any other
# sysctl.d file. Reading/writing individual tunables goes through
# optimizer::_read_current / optimizer::_write_value, which default to
# real /proc/sys access but are overridable (same test seam pattern as
# forwarders/haproxy.sh's _reload) so tests never touch this
# development host's real kernel tunables.
#
# Baseline: the ORIGINAL host value of a tunable is recorded the first
# time TixoLink ever changes it, and is never overwritten by a later
# optimization run - see optimizer::_baseline_record_if_absent. A
# separate "applied" record tracks the current TixoLink-desired value,
# which DOES change on every apply.

if [[ -n "${TIXOLINK_MODULE_OPTIMIZER_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_MODULE_OPTIMIZER_SH_LOADED=1

readonly TIXOLINK_OPTIMIZER_MANAGED_HEADER="# Managed by TixoLink NEXUS - do not edit by hand."

# --- File locations (overridable for tests) ----------------------------------

optimizer::_baseline_file() { printf '%s/optimizer/baseline.json' "$TIXOLINK_VAR_DIR"; }
optimizer::_applied_file()  { printf '%s/optimizer/applied.json' "$TIXOLINK_VAR_DIR"; }
optimizer::_managed_file()  { printf '%s' "${TIXOLINK_SYSCTL_D_FILE:-/etc/sysctl.d/99-tixolink.conf}"; }

# --- Tunable I/O (overridable for tests) --------------------------------------

optimizer::_sysctl_proc_path() { printf '/proc/sys/%s' "${1//.//}"; }

# optimizer::_read_current <key>
# Reads the tunable's live current value. Overridden by tests.
optimizer::_read_current() {
    local path; path="$(optimizer::_sysctl_proc_path "$1")"
    [[ -r "$path" ]] || return 1
    tr -s ' \t' ' ' <"$path" | sed 's/[[:space:]]*$//'
}

# optimizer::_write_value <key> <value>
# Applies a tunable immediately via sysctl -w (process-visible right
# away; persistence across reboot comes from the managed sysctl.d file,
# written separately). Overridden by tests.
optimizer::_write_value() {
    local key="$1" value="$2"
    sysctl -w "${key}=${value}" >/dev/null 2>&1
}

# --- Baseline / applied state --------------------------------------------------

optimizer::_baseline_init() {
    [[ -f "$(optimizer::_baseline_file)" ]] && return 0
    config::ensure_dir "$(dirname "$(optimizer::_baseline_file)")" 0750
    config::write_json_atomic "$(optimizer::_baseline_file)" '{}' 0600
}

optimizer::_applied_init() {
    [[ -f "$(optimizer::_applied_file)" ]] && return 0
    config::ensure_dir "$(dirname "$(optimizer::_applied_file)")" 0750
    config::write_json_atomic "$(optimizer::_applied_file)" '{}' 0600
}

# optimizer::_baseline_get <key>
optimizer::_baseline_get() {
    optimizer::_baseline_init
    jq -er --arg k "$1" '.[$k]' "$(optimizer::_baseline_file)" 2>/dev/null
}

# optimizer::_baseline_record_if_absent <key> <current-value>
# THE critical invariant: never overwrites an existing baseline entry.
optimizer::_baseline_record_if_absent() {
    local key="$1" value="$2"
    optimizer::_baseline_init
    if jq -e --arg k "$key" 'has($k)' "$(optimizer::_baseline_file)" >/dev/null 2>&1; then
        return 0
    fi
    local updated
    updated="$(jq -c --arg k "$key" --arg v "$value" '. + {($k): $v}' "$(optimizer::_baseline_file)")"
    config::write_json_atomic "$(optimizer::_baseline_file)" "$updated" 0600
}

optimizer::_applied_get() {
    optimizer::_applied_init
    jq -er --arg k "$1" '.[$k]' "$(optimizer::_applied_file)" 2>/dev/null
}

optimizer::_applied_set() {
    local key="$1" value="$2"
    optimizer::_applied_init
    local updated
    updated="$(jq -c --arg k "$key" --arg v "$value" '. + {($k): $v}' "$(optimizer::_applied_file)")"
    config::write_json_atomic "$(optimizer::_applied_file)" "$updated" 0600
}

optimizer::_applied_unset() {
    local key="$1"
    optimizer::_applied_init
    local updated
    updated="$(jq -c --arg k "$key" 'del(.[$k])' "$(optimizer::_applied_file)")"
    config::write_json_atomic "$(optimizer::_applied_file)" "$updated" 0600
}

# optimizer::_regenerate_managed_file
# Rewrites /etc/sysctl.d/99-tixolink.conf from applied.json. If nothing
# is currently applied, removes the file entirely rather than leaving an
# empty TixoLink-owned file behind.
optimizer::_regenerate_managed_file() {
    optimizer::_applied_init
    local applied; applied="$(cat "$(optimizer::_applied_file)")"
    if [[ "$(jq -c 'keys' <<<"$applied")" == "[]" ]]; then
        rm -f -- "$(optimizer::_managed_file)"
        return 0
    fi
    local content="$TIXOLINK_OPTIMIZER_MANAGED_HEADER"
    local key value
    while IFS= read -r key; do
        value="$(jq -r --arg k "$key" '.[$k]' <<<"$applied")"
        content="${content}
${key} = ${value}"
    done < <(jq -r 'keys[]' <<<"$applied")
    local dir; dir="$(dirname "$(optimizer::_managed_file)")"
    [[ -d "$dir" ]] || config::ensure_dir "$dir" 0755
    local tmp; tmp="$(mktemp "${dir}/.tixolink-sysctl.XXXXXXXX")"
    chmod 0644 "$tmp"
    printf '%s\n' "$content" >"$tmp"
    mv -T "$tmp" "$(optimizer::_managed_file)"
}

# --- Tunable registry -----------------------------------------------------------

# optimizer::registry
# The complete, deliberately small set of managed tunables. Each entry
# documents: key, description, rationale, downside, reboot_required,
# applies_immediately, and which profiles propose it. If a tunable
# cannot be justified this plainly, it does not belong here.
optimizer::registry() {
    cat <<'EOF'
{"key":"net.ipv4.tcp_fin_timeout","description":"How long a socket stays in FIN-WAIT-2 after the local side closes it.","rationale":"A tunnel server handling many short-lived forwarded connections accumulates FIN-WAIT-2 sockets; the 60s kernel default is conservative for a general-purpose host, not a dedicated forwarder.","downside":"Slightly less tolerant of a legitimately very slow remote close; 30s remains well within normal TCP behavior.","reboot_required":false,"applies_immediately":true,"profiles":["balanced","high_connection_count"]}
{"key":"net.ipv4.tcp_slow_start_after_idle","description":"Whether TCP resets the congestion window after a connection is briefly idle.","rationale":"GRE-forwarded long-lived connections (e.g. persistent backend links) are penalized by slow-start resets during normal idle gaps; disabling this is a well-documented, widely-used adjustment for exactly this case.","downside":"Slightly more aggressive sending immediately after an idle period, which matters mainly on severely congested paths.","reboot_required":false,"applies_immediately":true,"profiles":["balanced","high_throughput"]}
{"key":"net.core.somaxconn","description":"Maximum length of the queue of pending (not yet accepted) connections.","rationale":"A host forwarding to many short-lived backend connections can see the accept queue fill under burst load, causing new connections to be refused.","downside":"A larger backlog can briefly hold more half-open connections in memory under a connection burst.","reboot_required":false,"applies_immediately":true,"profiles":["high_connection_count"]}
{"key":"net.ipv4.tcp_max_syn_backlog","description":"Maximum number of queued, not-yet-established (SYN_RECV) TCP connections.","rationale":"Pairs with somaxconn for hosts expecting many concurrent new connections through forwarding mappings.","downside":"Higher memory use for pending half-open connections under a SYN burst; bounded, not unlimited.","reboot_required":false,"applies_immediately":true,"profiles":["high_connection_count"]}
{"key":"net.core.netdev_max_backlog","description":"Per-CPU queue length for packets waiting to be processed by the kernel networking stack.","rationale":"Under high packet-per-second forwarding load, the default queue can be too shallow, causing drops before packets are even handed to netfilter/GRE processing.","downside":"A deeper queue trades a small amount of added worst-case latency for fewer drops under burst.","reboot_required":false,"applies_immediately":true,"profiles":["high_throughput"]}
{"key":"net.ipv4.tcp_congestion_control","description":"The active TCP congestion control algorithm.","rationale":"BBR generally improves throughput on paths with loss/variable latency compared to the traditional loss-based CUBIC default, which matters for internet-facing tunnel traffic. Only ever proposed when the kernel actually exposes bbr in tcp_available_congestion_control - never assumed from kernel version alone. Managed via modules/bbr.sh, using this same baseline/apply/verify/restore machinery.","downside":"Behavior differs from CUBIC under certain loss patterns; on a path administrators have already tuned for CUBIC, switching may change observed behavior in ways that need re-validation.","reboot_required":false,"applies_immediately":true,"profiles":["bbr_enable"]}
EOF
}

optimizer::_registry_entry() {
    optimizer::registry | jq -c --arg k "$1" 'select(.key == $k)'
}

optimizer::_registry_for_profile() {
    local profile="$1"
    optimizer::registry | jq -c --arg p "$profile" 'select(.profiles | index($p))'
}

# --- Resource-aware bounding ---------------------------------------------------

# optimizer::_ram_tier <ram_kb>
# Simple, documented, bounded tiers - deliberately not a sliding
# formula: low (<1GiB), mid (1GiB-8GiB), high (>=8GiB).
optimizer::_ram_tier() {
    local ram_kb="$1"
    if [[ "$ram_kb" -lt 1048576 ]]; then
        echo "low"
    elif [[ "$ram_kb" -lt 8388608 ]]; then
        echo "mid"
    else
        echo "high"
    fi
}

# optimizer::proposed_value <key> <current-value> <ram_kb>
# Pure function: given a tunable, its live current value, and host RAM,
# returns the proposed value. Never proposes the same large value to a
# 1GiB host and a 64GiB host.
optimizer::proposed_value() {
    local key="$1" current="$2" ram_kb="${3:-0}"
    local tier; tier="$(optimizer::_ram_tier "$ram_kb")"
    local cur_num="${current//[!0-9]/}"
    [[ -z "$cur_num" ]] && cur_num=0

    case "$key" in
        net.ipv4.tcp_fin_timeout)
            [[ "$cur_num" -gt 30 ]] && echo 30 || echo "$cur_num"
            ;;
        net.ipv4.tcp_slow_start_after_idle)
            echo 0
            ;;
        net.core.somaxconn)
            local cap=4096
            [[ "$tier" == "low" ]] && cap=2048
            [[ "$tier" == "high" ]] && cap=8192
            [[ "$cur_num" -gt "$cap" ]] && echo "$cur_num" || echo "$cap"
            ;;
        net.ipv4.tcp_max_syn_backlog)
            local cap=2048
            [[ "$tier" == "low" ]] && cap=1024
            [[ "$tier" == "high" ]] && cap=4096
            [[ "$cur_num" -gt "$cap" ]] && echo "$cur_num" || echo "$cap"
            ;;
        net.core.netdev_max_backlog)
            local cap=5000
            [[ "$tier" == "low" ]] && cap=3000
            [[ "$tier" == "high" ]] && cap=10000
            [[ "$cur_num" -gt "$cap" ]] && echo "$cur_num" || echo "$cap"
            ;;
        net.ipv4.tcp_congestion_control)
            # Only ever reached via the "bbr_enable" profile, which
            # modules/bbr.sh refuses to invoke unless it has already
            # confirmed the kernel exposes "bbr" in
            # tcp_available_congestion_control (see bbr::_bbr_available).
            echo "bbr"
            ;;
        *)
            echo "$current"
            ;;
    esac
}

# --- Plan / inspect (read-only) ------------------------------------------------

# optimizer::plan <profile>
# Prints one JSON object per tunable in the profile: key, description,
# rationale, downside, reboot_required, current, proposed, changed.
# Purely read-only - never writes anything.
optimizer::plan() {
    local profile="$1" ram_kb entry key current proposed
    ram_kb="$(jq -r '.total_kb' <<<"$(sysinfo::meminfo 2>/dev/null)" 2>/dev/null)"
    [[ "$ram_kb" =~ ^[0-9]+$ ]] || ram_kb=0

    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        key="$(jq -r '.key' <<<"$entry")"
        current="$(optimizer::_read_current "$key" 2>/dev/null)" || current="unknown"
        proposed="$(optimizer::proposed_value "$key" "$current" "$ram_kb")"
        jq -c --arg current "$current" --arg proposed "$proposed" \
            --argjson changed "$([[ "$current" != "$proposed" ]] && echo true || echo false)" \
            '. + {current: $current, proposed: $proposed, changed: $changed}' <<<"$entry"
    done < <(optimizer::_registry_for_profile "$profile")
}

# optimizer::status
# Read-only: for every tunable TixoLink currently manages (per
# applied.json), shows baseline/applied/live-current and whether live
# matches what TixoLink last applied.
optimizer::status() {
    optimizer::_applied_init
    optimizer::_baseline_init
    local applied; applied="$(cat "$(optimizer::_applied_file)")"
    local key baseline_val applied_val live_val
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        baseline_val="$(optimizer::_baseline_get "$key" 2>/dev/null)" || baseline_val="unknown"
        applied_val="$(jq -r --arg k "$key" '.[$k]' <<<"$applied")"
        live_val="$(optimizer::_read_current "$key" 2>/dev/null)" || live_val="unknown"
        printf 'KEY=%s BASELINE=%s APPLIED=%s LIVE=%s MATCH=%s\n' \
            "$key" "$baseline_val" "$applied_val" "$live_val" "$([[ "$applied_val" == "$live_val" ]] && echo yes || echo no)"
    done < <(jq -r 'keys[]' <<<"$applied")
    [[ "$(jq -c 'keys' <<<"$applied")" == "[]" ]] && printf 'No TixoLink-managed tunables are currently applied.\n'
    return 0
}

# --- Apply / verify / rollback -------------------------------------------------

# optimizer::apply_profile <profile> [dry_run]
# BACKUP (baseline, first-write-only) -> APPLY -> VERIFY -> COMMIT, or
# ROLLBACK the tunables touched in THIS run back to their pre-this-run
# values on any apply/verify failure. Caller is responsible for having
# already confirmed (this function performs no additional prompting).
optimizer::apply_profile() {
    local profile="$1" dry_run="${2:-0}"
    local plan; plan="$(optimizer::plan "$profile")"

    if [[ "$dry_run" == "1" ]]; then
        local p
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            if [[ "$(jq -r '.changed' <<<"$p")" == "true" ]]; then
                printf '[DRY-RUN] SET %s: %s -> %s\n' "$(jq -r '.key' <<<"$p")" "$(jq -r '.current' <<<"$p")" "$(jq -r '.proposed' <<<"$p")"
            fi
        done <<<"$plan"
        return 0
    fi

    local -a touched_keys=() pre_values=() proposed_values=()
    local entry key current proposed
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        [[ "$(jq -r '.changed' <<<"$entry")" == "true" ]] || continue
        key="$(jq -r '.key' <<<"$entry")"
        current="$(jq -r '.current' <<<"$entry")"
        proposed="$(jq -r '.proposed' <<<"$entry")"

        # BACKUP: record the ORIGINAL host value, once, before any write.
        optimizer::_baseline_record_if_absent "$key" "$current" || return "$EXIT_GENERIC"

        if ! optimizer::_write_value "$key" "$proposed"; then
            log::error "failed to apply $key=$proposed; rolling back this run's changes"
            optimizer::_rollback_run "${touched_keys[@]:-}" "${pre_values[@]:-}"
            return "$EXIT_ROLLED_BACK"
        fi
        touched_keys+=("$key")
        pre_values+=("$current")
        proposed_values+=("$proposed")
    done <<<"$plan"

    if [[ ${#touched_keys[@]} -eq 0 ]]; then
        log::info "profile '$profile' proposes no changes to the current configuration"
        return 0
    fi

    # VERIFY: read back every touched key and compare to what THIS run
    # actually proposed and wrote (never recomputed from a fresh plan -
    # the system has already changed, so re-planning here would compare
    # against the wrong baseline).
    local i
    for i in "${!touched_keys[@]}"; do
        key="${touched_keys[$i]}"
        proposed="${proposed_values[$i]}"
        local live; live="$(optimizer::_read_current "$key" 2>/dev/null)"
        if [[ "$live" != "$proposed" ]]; then
            log::error "verification failed for $key (expected $proposed, got $live); rolling back this run's changes"
            optimizer::_rollback_run "${touched_keys[@]}" "${pre_values[@]}"
            return "$EXIT_ROLLED_BACK"
        fi
        optimizer::_applied_set "$key" "$proposed"
    done

    optimizer::_regenerate_managed_file
    log::history "optimize-apply" "$profile" "success"
    return 0
}

# optimizer::_rollback_run <touched-keys...> -- <pre-values...>
# Internal: restores exactly the tunables touched in a just-failed apply
# run back to their pre-this-run values (passed in, same order).
optimizer::_rollback_run() {
    local n=$(( $# / 2 ))
    local i
    for (( i=0; i<n; i++ )); do
        optimizer::_write_value "${@:$((i+1)):1}" "${@:$((n+i+1)):1}" 2>/dev/null || true
    done
}

# optimizer::restore [key]
# Restores TixoLink-managed tunables to their ORIGINAL baseline values
# (never to an intermediate applied value). With no key, restores every
# currently-applied tunable and removes the managed file entirely once
# nothing remains. Never touches a tunable TixoLink has not recorded a
# baseline for (i.e. never touches administrator-owned state).
optimizer::restore() {
    local only_key="${1:-}"
    optimizer::_applied_init
    local applied; applied="$(cat "$(optimizer::_applied_file)")"

    local -a keys=()
    if [[ -n "$only_key" ]]; then
        jq -e --arg k "$only_key" 'has($k)' <<<"$applied" >/dev/null 2>&1 || {
            log::error "tunable $only_key is not currently TixoLink-managed"
            return "$EXIT_NOT_FOUND"
        }
        keys=("$only_key")
    else
        while IFS= read -r only_key; do
            [[ -n "$only_key" ]] && keys+=("$only_key")
        done < <(jq -r 'keys[]' <<<"$applied")
    fi

    local key baseline_val
    for key in "${keys[@]:-}"; do
        [[ -z "$key" ]] && continue
        baseline_val="$(optimizer::_baseline_get "$key" 2>/dev/null)" || {
            log::warn "no baseline recorded for $key; leaving it as-is"
            continue
        }
        if ! optimizer::_write_value "$key" "$baseline_val"; then
            log::error "failed to restore $key to baseline value $baseline_val"
            return "$EXIT_GENERIC"
        fi
        local live; live="$(optimizer::_read_current "$key" 2>/dev/null)"
        if [[ "$live" != "$baseline_val" ]]; then
            log::error "restore verification failed for $key (expected $baseline_val, got $live)"
            return "$EXIT_ROLLED_BACK"
        fi
        optimizer::_applied_unset "$key"
    done

    optimizer::_regenerate_managed_file
    log::history "optimize-restore" "${only_key:-all}" "success"
    return 0
}

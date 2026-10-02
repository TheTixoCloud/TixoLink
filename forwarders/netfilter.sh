#!/usr/bin/env bash
# TixoLink NEXUS - netfilter (iptables) forwarding engine
#
# Backend decision: uses the `iptables`/`iptables -t nat` COMMAND
# INTERFACE, not raw `nft` syntax. On this development host (and on the
# supported Ubuntu 22.04/24.04 and Debian 12 targets) `iptables --version`
# reports "nf_tables" - the binary is iptables-nft, translating to nft
# rulesets under the hood - but the command-line semantics we rely on
# (-N/-A/-I/-D/-C, -m comment, DNAT/MASQUERADE targets) are identical to
# legacy iptables and portable across whichever backend `update-alternatives`
# has selected. This is verified read-only at module load via
# netfilter::backend, never assumed.
#
# Ownership model: all TixoLink rules live in three dedicated chains -
# TIXOLINK-DNAT (jumped from nat PREROUTING), TIXOLINK-FWD (jumped from
# filter FORWARD), TIXOLINK-SNAT (jumped from nat POSTROUTING, only
# created when a mapping actually uses NAT mode). Each hook jump and each
# mapping's rules are inserted idempotently (checked with `-C` before
# `-A`/`-I`) and tagged with an `-m comment --comment "tixolink:<tunnel-
# id>:<mapping-id>"`. TixoLink NEVER runs `-F`/`flush ruleset` and never
# deletes a rule it cannot prove it owns via that exact tag plus a
# corresponding entry in state.json (the same ownership-ledger pattern as
# engines/gre.sh).

if [[ -n "${TIXOLINK_FORWARDER_NETFILTER_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_FORWARDER_NETFILTER_SH_LOADED=1

readonly NF_CHAIN_DNAT="TIXOLINK-DNAT"
readonly NF_CHAIN_FWD="TIXOLINK-FWD"
readonly NF_CHAIN_SNAT="TIXOLINK-SNAT"

NF_DRY_RUN=0

# netfilter::_ipt <args...>
netfilter::_ipt() {
    if [[ -n "${TIXOLINK_NETNS:-}" ]]; then
        ip netns exec "$TIXOLINK_NETNS" iptables "$@"
    else
        iptables "$@"
    fi
}

# netfilter::backend
# Read-only detection of the active iptables backend. Documented, never
# assumed: callers may log/report this but command construction here does
# not branch on the result (iptables-nft and iptables-legacy accept the
# same syntax we use).
netfilter::backend() {
    local v
    v="$(iptables --version 2>/dev/null || true)"
    case "$v" in
        *nf_tables*) printf 'nf_tables' ;;
        *legacy*) printf 'legacy' ;;
        *) printf 'unknown' ;;
    esac
}

# nf::_do <label> <command...>
nf::_do() {
    local label="$1"
    shift
    if [[ "$NF_DRY_RUN" == "1" ]]; then
        printf '[DRY-RUN] %s: %s\n' "$label" "$(common::join ' ' "$@")"
        return 0
    fi
    "$@"
}

# --- Chain / hook management --------------------------------------------------

netfilter::_chain_exists() {
    local table="$1" chain="$2"
    netfilter::_ipt -t "$table" -nL "$chain" >/dev/null 2>&1
}

netfilter::_jump_exists() {
    local table="$1" parent="$2" target="$3"
    netfilter::_ipt -t "$table" -C "$parent" -j "$target" >/dev/null 2>&1
}

# netfilter::_ensure_chain_and_hook <table> <chain> <parent-chain>
netfilter::_ensure_chain_and_hook() {
    local table="$1" chain="$2" parent="$3"
    if ! netfilter::_chain_exists "$table" "$chain"; then
        nf::_do "CREATE CHAIN" netfilter::_ipt -t "$table" -N "$chain" || return "$EXIT_GENERIC"
        if [[ "$NF_DRY_RUN" != "1" ]]; then
            state::set ".netfilter.hooks[\"${table}:${chain}\"] = true" || return "$EXIT_GENERIC"
        fi
    fi
    if ! netfilter::_jump_exists "$table" "$parent" "$chain"; then
        nf::_do "ADD HOOK" netfilter::_ipt -t "$table" -I "$parent" 1 \
            -m comment --comment "tixolink:hook:${chain}" -j "$chain" || return "$EXIT_GENERIC"
    fi
    return 0
}

# netfilter::_hook_owned <table> <chain>
netfilter::_hook_owned() {
    local table="$1" chain="$2" recorded
    recorded="$(state::get ".netfilter.hooks[\"${table}:${chain}\"]" 2>/dev/null)" || return 1
    [[ "$recorded" == "true" ]]
}

# netfilter::_chain_rule_count <table> <chain>
netfilter::_chain_rule_count() {
    local table="$1" chain="$2"
    netfilter::_ipt -t "$table" -S "$chain" 2>/dev/null | grep -c '^-A '
}

# netfilter::_wipe_mapping_rules <table> <chain> <tag>
# Removes every rule in <chain> tagged with <tag>, regardless of its
# content. This is what makes forwarder_netfilter_apply a true per-mapping
# reconcile (like engines/gre.sh's create/reconcile): rather than only
# ever adding rules and separately content-matching a specific old rule
# for removal (fragile, and wrong when a mapping's own content changes
# across protocol/nat_mode/ports), apply() always wipes exactly this
# mapping's own previously-applied rules first, then re-adds the current
# expected set. Deletes by line number, in descending order, computed
# from `-S` output filtered to `-A` lines only (iptables' rule numbering
# for -D excludes the leading `-N <chain>` declaration line that -S also
# prints - confirmed empirically before relying on it here).
netfilter::_wipe_mapping_rules() {
    local table="$1" chain="$2" tag="$3"
    netfilter::_chain_exists "$table" "$chain" || return 0
    local -a line_numbers=()
    local n
    while IFS= read -r n; do
        [[ -n "$n" ]] && line_numbers+=("$n")
    done < <(netfilter::_ipt -t "$table" -S "$chain" 2>/dev/null \
        | grep '^-A ' | grep -n -F -- "$tag" | cut -d: -f1 | sort -rn)
    for n in "${line_numbers[@]:-}"; do
        [[ -z "$n" ]] && continue
        nf::_do "DELETE RULE" netfilter::_ipt -t "$table" -D "$chain" "$n" || return "$EXIT_GENERIC"
    done
    return 0
}

# netfilter::_maybe_remove_hook <table> <chain> <parent>
# Removes the jump and the now-empty TixoLink-owned chain, but only if it
# is both empty and proven TixoLink-owned.
netfilter::_maybe_remove_hook() {
    local table="$1" chain="$2" parent="$3"
    netfilter::_chain_exists "$table" "$chain" || return 0
    netfilter::_hook_owned "$table" "$chain" || return 0
    [[ "$(netfilter::_chain_rule_count "$table" "$chain")" == "0" ]] || return 0

    if netfilter::_jump_exists "$table" "$parent" "$chain"; then
        nf::_do "REMOVE HOOK" netfilter::_ipt -t "$table" -D "$parent" \
            -m comment --comment "tixolink:hook:${chain}" -j "$chain" || return "$EXIT_GENERIC"
    fi

    # Deleting the now-unreferenced, empty chain is best-effort: the
    # kernel can keep a NAT chain "busy" for a short time after its last
    # rule is removed, while existing conntrack entries still reference
    # rules that used to live in it. An empty, unreferenced TixoLink chain
    # left behind is harmless (no jump points to it anymore) and will be
    # removed the next time this runs once conntrack entries expire.
    if ! nf::_do "DELETE CHAIN" netfilter::_ipt -t "$table" -X "$chain"; then
        log::warn "could not delete empty chain ${table}:${chain} yet (likely still referenced by conntrack); will retry later"
        return 0
    fi
    if [[ "$NF_DRY_RUN" != "1" ]]; then
        state::set "del(.netfilter.hooks[\"${table}:${chain}\"])" || return "$EXIT_GENERIC"
    fi
    return 0
}

# --- Rule construction ---------------------------------------------------------

# netfilter::_tag <tunnel-id> <mapping-id>
netfilter::_tag() { printf 'tixolink:%s:%s' "$1" "$2"; }

# netfilter::_resolve_remote_address <tunnel-json> <mapping-json>
netfilter::_resolve_remote_address() {
    local tunnel_json="$1" mapping="$2" override
    override="$(jq -r '.remote_address // empty' <<<"$mapping")"
    if [[ -n "$override" ]]; then
        printf '%s' "$override"
    else
        jq -r '.engine_config.inner_remote_ip' <<<"$tunnel_json"
    fi
}

# netfilter::_port_arg <port-or-range>
# iptables wants "80" or "8000:9000" (colon, not hyphen) for ranges.
netfilter::_port_arg() {
    printf '%s' "${1/-/:}"
}

# netfilter::_dnat_args <proto> <listen_addr> <local_port> <remote_addr> <remote_port> <tag>
netfilter::_dnat_args() {
    local proto="$1" listen_addr="$2" local_port="$3" remote_addr="$4" remote_port="$5" tag="$6"
    local -a args=(-p "$proto")
    [[ "$listen_addr" != "0.0.0.0" ]] && args+=(-d "$listen_addr")
    args+=(--dport "$(netfilter::_port_arg "$local_port")" \
        -m comment --comment "$tag" \
        -j DNAT --to-destination "${remote_addr}:$(netfilter::_port_arg "$remote_port")")
    printf '%s\n' "${args[@]}"
}

# netfilter::_fwd_args <proto> <remote_addr> <remote_port> <tag>
netfilter::_fwd_args() {
    local proto="$1" remote_addr="$2" remote_port="$3" tag="$4"
    printf '%s\n' -p "$proto" -d "$remote_addr" --dport "$(netfilter::_port_arg "$remote_port")" \
        -m comment --comment "$tag" -j ACCEPT
}

# netfilter::_snat_args <proto> <remote_addr> <remote_port> <out_iface> <tag>
netfilter::_snat_args() {
    local proto="$1" remote_addr="$2" remote_port="$3" out_iface="$4" tag="$5"
    printf '%s\n' -o "$out_iface" -p "$proto" -d "$remote_addr" \
        --dport "$(netfilter::_port_arg "$remote_port")" -m comment --comment "$tag" -j MASQUERADE
}

# netfilter::_protocols <mapping-json>
# Expands "tcp+udp" into two separate protocol passes - iptables rules are
# always single-protocol.
netfilter::_protocols() {
    local proto; proto="$(jq -r '.protocol' <<<"$1")"
    case "$proto" in
        tcp+udp) printf 'tcp\nudp\n' ;;
        *) printf '%s\n' "$proto" ;;
    esac
}

# --- Engine contract implementation ------------------------------------------

# forwarder_netfilter_validate <tunnel-json> <mapping-json>
forwarder_netfilter_validate() {
    local mapping="$2"
    local proto listen_addr local_port remote_port remote_addr nat_mode
    proto="$(jq -r '.protocol' <<<"$mapping")"
    listen_addr="$(jq -r '.listen_address' <<<"$mapping")"
    local_port="$(jq -r '.local_port' <<<"$mapping")"
    remote_port="$(jq -r '.remote_port' <<<"$mapping")"
    remote_addr="$(jq -r '.remote_address // empty' <<<"$mapping")"
    nat_mode="$(jq -r '.nat_mode' <<<"$mapping")"

    validate::protocol "$proto" || { log::error "invalid protocol: $proto"; return "$EXIT_VALIDATION"; }
    validate::ipv4 "$listen_addr" || { log::error "invalid listen_address: $listen_addr"; return "$EXIT_VALIDATION"; }
    [[ -n "$remote_addr" ]] && { validate::ipv4 "$remote_addr" || { log::error "invalid remote_address: $remote_addr"; return "$EXIT_VALIDATION"; }; }

    local parsed
    parsed="$(ports::parse_token "${local_port}:${remote_port}")" || {
        log::error "invalid local/remote port spec: ${local_port}:${remote_port}"
        return "$EXIT_VALIDATION"
    }
    [[ "${parsed%%|*}" == "$local_port" && "${parsed#*|}" == "$remote_port" ]] || {
        log::error "local/remote port normalization mismatch"
        return "$EXIT_VALIDATION"
    }

    case "$nat_mode" in
        nat|source-preserving) : ;;
        *) log::error "invalid nat_mode: $nat_mode"; return "$EXIT_VALIDATION" ;;
    esac

    return 0
}

# forwarder_netfilter_check_conflicts <tunnel-id> <mapping-json> [exclude-mapping-id]
# Rejects a mapping whose listen_address+protocol+local_port overlaps any
# other mapping (on any tunnel, any forwarding engine) already configured.
forwarder_netfilter_check_conflicts() {
    local self_tunnel_id="$1" mapping="$2" exclude_mapping_id="${3:-}"
    local listen_addr proto local_port
    listen_addr="$(jq -r '.listen_address' <<<"$mapping")"
    proto="$(jq -r '.protocol' <<<"$mapping")"
    local_port="$(jq -r '.local_port' <<<"$mapping")"

    local other_id other_cfg
    while IFS= read -r other_id; do
        [[ -z "$other_id" ]] && continue
        other_cfg="$(config::tunnel_read "$other_id" 2>/dev/null)" || continue
        local m other_mid other_listen other_proto other_port
        while IFS= read -r m; do
            [[ -z "$m" || "$m" == "null" ]] && continue
            other_mid="$(jq -r '.id' <<<"$m")"
            [[ "$other_id" == "$self_tunnel_id" && "$other_mid" == "$exclude_mapping_id" ]] && continue
            other_listen="$(jq -r '.listen_address' <<<"$m")"
            [[ "$other_listen" != "$listen_addr" && "$other_listen" != "0.0.0.0" && "$listen_addr" != "0.0.0.0" ]] && continue
            other_proto="$(jq -r '.protocol' <<<"$m")"
            other_port="$(jq -r '.local_port' <<<"$m")"
            if ports::mapping_conflicts_with "$local_port" "$proto" "$other_port" "$other_proto"; then
                log::error "mapping conflicts with tunnel $other_id mapping $other_mid (port $other_port/$other_proto)"
                return "$EXIT_CONFLICT"
            fi
        done < <(jq -c '.forwarding.mappings[]?' <<<"$other_cfg")
    done < <(config::tunnel_list)

    return 0
}

# forwarder_netfilter_apply <tunnel-json> <mapping-json> [dry-run]
forwarder_netfilter_apply() {
    local tunnel_json="$1" mapping="$2"
    NF_DRY_RUN="${3:-0}"

    local tunnel_id iface tag remote_addr remote_port local_port listen_addr nat_mode
    tunnel_id="$(jq -r '.id' <<<"$tunnel_json")"
    iface="$(jq -r '.engine_config.interface' <<<"$tunnel_json")"
    tag="$(netfilter::_tag "$tunnel_id" "$(jq -r '.id' <<<"$mapping")")"
    remote_addr="$(netfilter::_resolve_remote_address "$tunnel_json" "$mapping")"
    remote_port="$(jq -r '.remote_port' <<<"$mapping")"
    local_port="$(jq -r '.local_port' <<<"$mapping")"
    listen_addr="$(jq -r '.listen_address' <<<"$mapping")"
    nat_mode="$(jq -r '.nat_mode' <<<"$mapping")"

    netfilter::_ensure_chain_and_hook nat "$NF_CHAIN_DNAT" PREROUTING || { NF_DRY_RUN=0; return "$EXIT_GENERIC"; }
    netfilter::_ensure_chain_and_hook filter "$NF_CHAIN_FWD" FORWARD || { NF_DRY_RUN=0; return "$EXIT_GENERIC"; }
    if [[ "$nat_mode" == "nat" ]]; then
        netfilter::_ensure_chain_and_hook nat "$NF_CHAIN_SNAT" POSTROUTING || { NF_DRY_RUN=0; return "$EXIT_GENERIC"; }
    fi

    # Reconcile, not just add: wipe whatever this exact mapping id
    # previously applied (possibly a different protocol/port/nat_mode)
    # before re-adding its current expected set. This makes apply() a
    # true idempotent "ensure mapping <id> looks like this" operation -
    # the same standard engines/gre.sh already holds itself to - so
    # modules/forwarding.sh's edit flow can call apply() alone for every
    # engine, never a separate "remove the old one" step that would be
    # wrong for identity-addressed engines (see forwarding::edit).
    netfilter::_wipe_mapping_rules nat "$NF_CHAIN_DNAT" "$tag" || { NF_DRY_RUN=0; return "$EXIT_GENERIC"; }
    netfilter::_wipe_mapping_rules filter "$NF_CHAIN_FWD" "$tag" || { NF_DRY_RUN=0; return "$EXIT_GENERIC"; }
    netfilter::_wipe_mapping_rules nat "$NF_CHAIN_SNAT" "$tag" || { NF_DRY_RUN=0; return "$EXIT_GENERIC"; }

    local proto
    while IFS= read -r proto; do
        [[ -z "$proto" ]] && continue

        local -a dnat_args fwd_args
        mapfile -t dnat_args < <(netfilter::_dnat_args "$proto" "$listen_addr" "$local_port" "$remote_addr" "$remote_port" "$tag")
        if ! netfilter::_ipt -t nat -C "$NF_CHAIN_DNAT" "${dnat_args[@]}" >/dev/null 2>&1; then
            nf::_do "ADD DNAT" netfilter::_ipt -t nat -A "$NF_CHAIN_DNAT" "${dnat_args[@]}" || { NF_DRY_RUN=0; return "$EXIT_GENERIC"; }
        fi

        mapfile -t fwd_args < <(netfilter::_fwd_args "$proto" "$remote_addr" "$remote_port" "$tag")
        if ! netfilter::_ipt -t filter -C "$NF_CHAIN_FWD" "${fwd_args[@]}" >/dev/null 2>&1; then
            nf::_do "ADD FORWARD" netfilter::_ipt -t filter -A "$NF_CHAIN_FWD" "${fwd_args[@]}" || { NF_DRY_RUN=0; return "$EXIT_GENERIC"; }
        fi

        if [[ "$nat_mode" == "nat" ]]; then
            local -a snat_args
            mapfile -t snat_args < <(netfilter::_snat_args "$proto" "$remote_addr" "$remote_port" "$iface" "$tag")
            if ! netfilter::_ipt -t nat -C "$NF_CHAIN_SNAT" "${snat_args[@]}" >/dev/null 2>&1; then
                nf::_do "ADD MASQUERADE" netfilter::_ipt -t nat -A "$NF_CHAIN_SNAT" "${snat_args[@]}" || { NF_DRY_RUN=0; return "$EXIT_GENERIC"; }
            fi
        fi
    done < <(netfilter::_protocols "$mapping")

    NF_DRY_RUN=0
    return 0
}

# forwarder_netfilter_remove <tunnel-json> <mapping-json> [dry-run]
# Removes every rule tagged with this mapping's id, in any chain,
# regardless of its current content - the same wipe primitive apply()
# uses for reconcile, so remove and apply can never disagree about what
# "this mapping's rules" means.
forwarder_netfilter_remove() {
    local tunnel_json="$1" mapping="$2"
    NF_DRY_RUN="${3:-0}"

    local tunnel_id tag
    tunnel_id="$(jq -r '.id' <<<"$tunnel_json")"
    tag="$(netfilter::_tag "$tunnel_id" "$(jq -r '.id' <<<"$mapping")")"

    netfilter::_wipe_mapping_rules nat "$NF_CHAIN_DNAT" "$tag" || { NF_DRY_RUN=0; return "$EXIT_GENERIC"; }
    netfilter::_wipe_mapping_rules filter "$NF_CHAIN_FWD" "$tag" || { NF_DRY_RUN=0; return "$EXIT_GENERIC"; }
    netfilter::_wipe_mapping_rules nat "$NF_CHAIN_SNAT" "$tag" || { NF_DRY_RUN=0; return "$EXIT_GENERIC"; }

    netfilter::_maybe_remove_hook nat "$NF_CHAIN_SNAT" POSTROUTING
    netfilter::_maybe_remove_hook filter "$NF_CHAIN_FWD" FORWARD
    netfilter::_maybe_remove_hook nat "$NF_CHAIN_DNAT" PREROUTING

    NF_DRY_RUN=0
    return 0
}

# forwarder_netfilter_repair <tunnel-json> <mapping-json>
# Removes any drifted (mismatched) rules for this mapping, then re-applies
# cleanly from the mapping's current desired state.
forwarder_netfilter_repair() {
    forwarder_netfilter_remove "$1" "$2" 0
    forwarder_netfilter_apply "$1" "$2" 0
}

# forwarder_netfilter_status <tunnel-json> <mapping-json>
# Prints STATE=ACTIVE|MISSING|PARTIAL|DRIFTED|CONFLICT
forwarder_netfilter_status() {
    local tunnel_json="$1" mapping="$2"
    local tunnel_id iface tag remote_addr remote_port local_port listen_addr nat_mode
    tunnel_id="$(jq -r '.id' <<<"$tunnel_json")"
    iface="$(jq -r '.engine_config.interface' <<<"$tunnel_json")"
    tag="$(netfilter::_tag "$tunnel_id" "$(jq -r '.id' <<<"$mapping")")"
    remote_addr="$(netfilter::_resolve_remote_address "$tunnel_json" "$mapping")"
    remote_port="$(jq -r '.remote_port' <<<"$mapping")"
    local_port="$(jq -r '.local_port' <<<"$mapping")"
    listen_addr="$(jq -r '.listen_address' <<<"$mapping")"
    nat_mode="$(jq -r '.nat_mode' <<<"$mapping")"

    if netfilter::_chain_exists nat "$NF_CHAIN_DNAT" && ! netfilter::_hook_owned nat "$NF_CHAIN_DNAT"; then
        printf 'STATE=CONFLICT\n'
        return 0
    fi

    local active=0 missing=0 drifted=0 expected=0
    local proto
    while IFS= read -r proto; do
        [[ -z "$proto" ]] && continue

        local -a dnat_args fwd_args
        mapfile -t dnat_args < <(netfilter::_dnat_args "$proto" "$listen_addr" "$local_port" "$remote_addr" "$remote_port" "$tag")
        expected=$((expected + 1))
        if netfilter::_ipt -t nat -C "$NF_CHAIN_DNAT" "${dnat_args[@]}" >/dev/null 2>&1; then
            active=$((active + 1))
        elif netfilter::_ipt -t nat -S "$NF_CHAIN_DNAT" 2>/dev/null | grep -qF "$tag"; then
            drifted=$((drifted + 1))
        else
            missing=$((missing + 1))
        fi

        mapfile -t fwd_args < <(netfilter::_fwd_args "$proto" "$remote_addr" "$remote_port" "$tag")
        expected=$((expected + 1))
        if netfilter::_ipt -t filter -C "$NF_CHAIN_FWD" "${fwd_args[@]}" >/dev/null 2>&1; then
            active=$((active + 1))
        elif netfilter::_ipt -t filter -S "$NF_CHAIN_FWD" 2>/dev/null | grep -qF "$tag"; then
            drifted=$((drifted + 1))
        else
            missing=$((missing + 1))
        fi

        if [[ "$nat_mode" == "nat" ]]; then
            local -a snat_args
            mapfile -t snat_args < <(netfilter::_snat_args "$proto" "$remote_addr" "$remote_port" "$iface" "$tag")
            expected=$((expected + 1))
            if netfilter::_ipt -t nat -C "$NF_CHAIN_SNAT" "${snat_args[@]}" >/dev/null 2>&1; then
                active=$((active + 1))
            elif netfilter::_ipt -t nat -S "$NF_CHAIN_SNAT" 2>/dev/null | grep -qF "$tag"; then
                drifted=$((drifted + 1))
            else
                missing=$((missing + 1))
            fi
        fi
    done < <(netfilter::_protocols "$mapping")

    if [[ "$drifted" -gt 0 ]]; then
        printf 'STATE=DRIFTED\n'
    elif [[ "$active" -eq "$expected" ]]; then
        printf 'STATE=ACTIVE\n'
    elif [[ "$missing" -eq "$expected" ]]; then
        printf 'STATE=MISSING\n'
    else
        printf 'STATE=PARTIAL\n'
    fi
    return 0
}

forwarder::register "netfilter"

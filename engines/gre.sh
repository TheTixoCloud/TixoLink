#!/usr/bin/env bash
# TixoLink NEXUS - GRE over IPv4 transport engine
#
# Implements the engines/engine_api.sh contract for "gre". Every runtime
# operation (ip link/addr) is derived from the tunnel's validated JSON
# configuration at call time - nothing about a peer IP, interface name, or
# address is ever baked into a separate generated script. Interface
# identity is always the deterministic `tixo-<id>` name derived from the
# tunnel's immutable ID, never from its mutable display name.
#
# Test seam: if TIXOLINK_NETNS is set, every `ip` invocation runs inside
# that network namespace via `ip -n`, instead of the real host namespace.
# This lets the exact same engine code be exercised against the real Linux
# GRE kernel implementation inside isolated namespaces (see
# tests/integration/) without ever touching host networking. Production
# use (TIXOLINK_NETNS unset) targets the host namespace normally.

if [[ -n "${TIXOLINK_ENGINE_GRE_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_ENGINE_GRE_SH_LOADED=1

GRE_DRY_RUN=0

# --- ip(8) wrapper / dry-run step runner -------------------------------------

# gre::_ip <ip-subcommand...>
gre::_ip() {
    if [[ -n "${TIXOLINK_NETNS:-}" ]]; then
        ip -n "$TIXOLINK_NETNS" "$@"
    else
        ip "$@"
    fi
}

# gre::_do <label> <command...>
# In dry-run mode, prints the action and the exact command that would run,
# without executing it. Otherwise executes it. Every state-changing `ip`
# call in this file goes through this function.
gre::_do() {
    local label="$1"
    shift
    if [[ "$GRE_DRY_RUN" == "1" ]]; then
        printf '[DRY-RUN] %s: %s\n' "$label" "$(common::join ' ' "$@")"
        return 0
    fi
    "$@"
}

# --- Runtime inspection -------------------------------------------------------

# gre::_iface_exists <iface>
gre::_iface_exists() {
    gre::_ip -j link show dev "$1" >/dev/null 2>&1
}

# gre::_iface_owned_by <id> <iface>
# TixoLink's own ownership ledger is the only proof of ownership: an
# interface that happens to share a name is never assumed to be ours.
gre::_iface_owned_by() {
    local id="$1" iface="$2" recorded
    validate::tunnel_id "$id" || return 1
    recorded="$(state::get ".tunnels[\"$id\"].interface" 2>/dev/null)" || return 1
    [[ "$recorded" == "$iface" ]]
}

# gre::_read_runtime <iface>
# Prints a JSON object describing the interface's current GRE attributes,
# or fails if the interface does not exist.
gre::_read_runtime() {
    local iface="$1" link_json addr_json
    link_json="$(gre::_ip -d -j link show dev "$iface" 2>/dev/null)" || return 1
    [[ -z "$link_json" || "$link_json" == "[]" ]] && return 1
    addr_json="$(gre::_ip -j addr show dev "$iface" 2>/dev/null)"
    [[ -z "$addr_json" ]] && addr_json="[]"
    jq -n --argjson link "$link_json" --argjson addr "$addr_json" '
        {
            local:        ($link[0].linkinfo.info_data.local // ""),
            remote:       ($link[0].linkinfo.info_data.remote // ""),
            ttl:          ($link[0].linkinfo.info_data.ttl // 0),
            mtu:          ($link[0].mtu // 0),
            up:           ((($link[0].flags // []) | index("UP")) != null),
            inner_ip:     ($addr[0].addr_info[0].local // ""),
            inner_prefix: ($addr[0].addr_info[0].prefixlen // 0)
        }'
}

# --- Config field access -----------------------------------------------------

gre::_field() { jq -r "$2" <<<"$1"; }

# --- Validation (pure, no I/O) ------------------------------------------------

# engine_gre_validate <tunnel-config-json>
# Semantic validation only - never touches the host or other tunnels.
engine_gre_validate() {
    local cfg="$1" v
    v="$(jq -r '.engine // empty' <<<"$cfg")"
    if [[ "$v" != "gre" ]]; then
        log::error "not a gre tunnel config (engine=$v)"
        return "$EXIT_VALIDATION"
    fi

    local name; name="$(jq -r '.name // empty' <<<"$cfg")"
    validate::tunnel_name "$name" || { log::error "invalid tunnel name: $name"; return "$EXIT_VALIDATION"; }

    local id; id="$(jq -r '.id // empty' <<<"$cfg")"
    if [[ -n "$id" ]]; then
        validate::tunnel_id "$id" || { log::error "invalid tunnel id: $id"; return "$EXIT_VALIDATION"; }
    fi

    local ec; ec="$(jq -c '.engine_config' <<<"$cfg")"
    local iface local_ip remote_ip inner_subnet inner_local inner_remote mtu ttl
    iface="$(gre::_field "$ec" '.interface // empty')"
    local_ip="$(gre::_field "$ec" '.local_public_ip // empty')"
    remote_ip="$(gre::_field "$ec" '.remote_public_ip // empty')"
    inner_subnet="$(gre::_field "$ec" '.inner_subnet // empty')"
    inner_local="$(gre::_field "$ec" '.inner_local_ip // empty')"
    inner_remote="$(gre::_field "$ec" '.inner_remote_ip // empty')"
    mtu="$(gre::_field "$ec" '.mtu // empty')"
    ttl="$(gre::_field "$ec" '.ttl // empty')"

    validate::iface_name "$iface" || { log::error "invalid interface name: $iface"; return "$EXIT_VALIDATION"; }
    validate::ipv4 "$local_ip" || { log::error "invalid local_public_ip: $local_ip"; return "$EXIT_VALIDATION"; }
    validate::ipv4 "$remote_ip" || { log::error "invalid remote_public_ip: $remote_ip"; return "$EXIT_VALIDATION"; }
    if [[ "$local_ip" == "$remote_ip" ]]; then
        log::error "local_public_ip and remote_public_ip must differ"
        return "$EXIT_VALIDATION"
    fi

    validate::cidr "$inner_subnet" || { log::error "invalid inner_subnet: $inner_subnet"; return "$EXIT_VALIDATION"; }
    if [[ "${inner_subnet#*/}" != "30" ]]; then
        log::error "inner_subnet must be a /30 (point-to-point GRE link): $inner_subnet"
        return "$EXIT_VALIDATION"
    fi
    validate::ipv4 "$inner_local" || { log::error "invalid inner_local_ip: $inner_local"; return "$EXIT_VALIDATION"; }
    validate::ipv4 "$inner_remote" || { log::error "invalid inner_remote_ip: $inner_remote"; return "$EXIT_VALIDATION"; }
    if [[ "$inner_local" == "$inner_remote" ]]; then
        log::error "inner_local_ip and inner_remote_ip must differ"
        return "$EXIT_VALIDATION"
    fi
    if ! subnet::_overlaps "${inner_local}/32" "$inner_subnet"; then
        log::error "inner_local_ip $inner_local is not within $inner_subnet"
        return "$EXIT_VALIDATION"
    fi
    if ! subnet::_overlaps "${inner_remote}/32" "$inner_subnet"; then
        log::error "inner_remote_ip $inner_remote is not within $inner_subnet"
        return "$EXIT_VALIDATION"
    fi

    validate::mtu "$mtu" || { log::error "invalid mtu: $mtu"; return "$EXIT_VALIDATION"; }
    validate::ttl "$ttl" || { log::error "invalid ttl: $ttl"; return "$EXIT_VALIDATION"; }

    return 0
}

# --- Host-dependent prechecks -------------------------------------------------

# engine_gre_precheck <tunnel-config-json>
# Confirms local_public_ip is actually present on this host/namespace.
# Separate from engine_gre_validate because validation of an imported peer
# document (which describes a tunnel to be created on a *different* host)
# must not require the address to exist here.
engine_gre_precheck() {
    local cfg="$1" ec local_ip
    ec="$(jq -c '.engine_config' <<<"$cfg")"
    local_ip="$(gre::_field "$ec" '.local_public_ip')"

    local -a live=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && live+=("$line")
    done < <(gre::_ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1)

    local addr
    for addr in "${live[@]}"; do
        [[ "$addr" == "$local_ip" ]] && return 0
    done

    log::error "local_public_ip $local_ip is not configured on this host"
    return "$EXIT_VALIDATION"
}

# engine_gre_check_conflicts <id> <tunnel-config-json>
# Host/state-dependent conflict detection: interface name collisions,
# inner-subnet overlap with other tunnels, and an unowned runtime
# interface already occupying the target name.
engine_gre_check_conflicts() {
    local id="$1" cfg="$2" ec
    # $id is interpolated into jq filter strings below (state::get/set use
    # it directly rather than --arg); validating the charset here, rather
    # than trusting every caller to have done so already, is defense in
    # depth against configuration injection via a malformed ID.
    validate::tunnel_id "$id" || { log::error "invalid tunnel id: $id"; return "$EXIT_VALIDATION"; }
    ec="$(jq -c '.engine_config' <<<"$cfg")"
    local iface inner_subnet
    iface="$(gre::_field "$ec" '.interface')"
    inner_subnet="$(gre::_field "$ec" '.inner_subnet')"

    local other_id other_cfg other_ec other_iface other_subnet
    while IFS= read -r other_id; do
        [[ -z "$other_id" || "$other_id" == "$id" ]] && continue
        other_cfg="$(config::tunnel_read "$other_id" 2>/dev/null)" || continue
        other_ec="$(jq -c '.engine_config' <<<"$other_cfg")"
        other_iface="$(gre::_field "$other_ec" '.interface // empty')"
        other_subnet="$(gre::_field "$other_ec" '.inner_subnet // empty')"

        if [[ -n "$other_iface" && "$other_iface" == "$iface" ]]; then
            log::error "interface $iface is already used by tunnel $other_id"
            return "$EXIT_CONFLICT"
        fi
        if [[ -n "$other_subnet" ]] && subnet::_overlaps "$inner_subnet" "$other_subnet"; then
            log::error "inner_subnet $inner_subnet overlaps tunnel $other_id ($other_subnet)"
            return "$EXIT_CONFLICT"
        fi
    done < <(config::tunnel_list)

    if gre::_iface_exists "$iface" && ! gre::_iface_owned_by "$id" "$iface"; then
        log::error "interface $iface already exists and is not TixoLink-owned by tunnel $id"
        return "$EXIT_CONFLICT"
    fi

    return 0
}

# --- Idempotent apply / reconcile --------------------------------------------

# gre::_apply_fresh <id> <engine-config-json>
# Creates the interface from scratch. Caller has already confirmed it
# does not exist (or does not matter because this is a drift repair that
# deleted it first).
gre::_apply_fresh() {
    local id="$1" ec="$2"
    local iface local_ip remote_ip mtu ttl inner_local inner_subnet prefix
    iface="$(gre::_field "$ec" '.interface')"
    local_ip="$(gre::_field "$ec" '.local_public_ip')"
    remote_ip="$(gre::_field "$ec" '.remote_public_ip')"
    mtu="$(gre::_field "$ec" '.mtu')"
    ttl="$(gre::_field "$ec" '.ttl')"
    inner_local="$(gre::_field "$ec" '.inner_local_ip')"
    inner_subnet="$(gre::_field "$ec" '.inner_subnet')"
    prefix="${inner_subnet#*/}"

    gre::_do "CREATE INTERFACE" \
        gre::_ip link add "$iface" type gre local "$local_ip" remote "$remote_ip" ttl "$ttl" \
        || return "$EXIT_GENERIC"
    gre::_do "SET MTU" gre::_ip link set "$iface" mtu "$mtu" || return "$EXIT_GENERIC"
    gre::_do "SET ADDRESS" gre::_ip addr add "${inner_local}/${prefix}" dev "$iface" || return "$EXIT_GENERIC"
    gre::_do "SET LINK UP" gre::_ip link set "$iface" up || return "$EXIT_GENERIC"

    if [[ "$GRE_DRY_RUN" != "1" ]]; then
        state::set ".tunnels[\"$id\"] = {\"interface\": \"$iface\"}" || return "$EXIT_GENERIC"
    fi
    return 0
}

# gre::_ensure_iface <id> <engine-config-json>
# Idempotent create-or-reconcile: if the interface already exists and is
# owned by this tunnel, repairs only what has drifted rather than
# unconditionally destroying and recreating it.
gre::_ensure_iface() {
    local id="$1" ec="$2"
    local iface; iface="$(gre::_field "$ec" '.interface')"

    if ! gre::_iface_exists "$iface"; then
        gre::_apply_fresh "$id" "$ec" || return $?
        return 0
    fi

    if ! gre::_iface_owned_by "$id" "$iface"; then
        log::error "interface $iface already exists and is not TixoLink-owned by tunnel $id"
        return "$EXIT_CONFLICT"
    fi

    local local_ip remote_ip mtu ttl inner_local inner_subnet prefix
    local_ip="$(gre::_field "$ec" '.local_public_ip')"
    remote_ip="$(gre::_field "$ec" '.remote_public_ip')"
    mtu="$(gre::_field "$ec" '.mtu')"
    ttl="$(gre::_field "$ec" '.ttl')"
    inner_local="$(gre::_field "$ec" '.inner_local_ip')"
    inner_subnet="$(gre::_field "$ec" '.inner_subnet')"
    prefix="${inner_subnet#*/}"

    local runtime
    runtime="$(gre::_read_runtime "$iface")" || {
        log::error "interface $iface is reported to exist but could not be read"
        return "$EXIT_GENERIC"
    }

    local rt_local rt_remote rt_ttl
    rt_local="$(jq -r '.local' <<<"$runtime")"
    rt_remote="$(jq -r '.remote' <<<"$runtime")"
    rt_ttl="$(jq -r '.ttl' <<<"$runtime")"

    if [[ "$rt_local" != "$local_ip" || "$rt_remote" != "$remote_ip" || "$rt_ttl" != "$ttl" ]]; then
        # Endpoint/TTL are creation-time parameters of the GRE device itself
        # and cannot be changed in place; repair by recreating only this
        # tunnel's own interface.
        log::warn "tunnel $id endpoint/ttl drifted from runtime; recreating interface $iface"
        gre::_do "DELETE INTERFACE" gre::_ip link del "$iface" || return "$EXIT_GENERIC"
        gre::_apply_fresh "$id" "$ec" || return $?
        return 0
    fi

    local rt_mtu; rt_mtu="$(jq -r '.mtu' <<<"$runtime")"
    if [[ "$rt_mtu" != "$mtu" ]]; then
        gre::_do "SET MTU" gre::_ip link set "$iface" mtu "$mtu" || return "$EXIT_GENERIC"
    fi

    local rt_inner_ip rt_inner_prefix
    rt_inner_ip="$(jq -r '.inner_ip' <<<"$runtime")"
    rt_inner_prefix="$(jq -r '.inner_prefix' <<<"$runtime")"
    if [[ "$rt_inner_ip" != "$inner_local" || "$rt_inner_prefix" != "$prefix" ]]; then
        if [[ -n "$rt_inner_ip" ]]; then
            gre::_do "DELETE ADDRESS" gre::_ip addr del "${rt_inner_ip}/${rt_inner_prefix}" dev "$iface" || true
        fi
        gre::_do "SET ADDRESS" gre::_ip addr add "${inner_local}/${prefix}" dev "$iface" || return "$EXIT_GENERIC"
    fi

    local rt_up; rt_up="$(jq -r '.up' <<<"$runtime")"
    if [[ "$rt_up" != "true" ]]; then
        gre::_do "SET LINK UP" gre::_ip link set "$iface" up || return "$EXIT_GENERIC"
    fi

    return 0
}

# --- Engine contract implementation ------------------------------------------

# engine_gre_create <id> [dry-run]
engine_gre_create() {
    local id="$1" dry_run="${2:-0}"
    GRE_DRY_RUN="$dry_run"
    local cfg
    cfg="$(config::tunnel_read "$id")" || { GRE_DRY_RUN=0; return "$EXIT_NOT_FOUND"; }

    engine_gre_validate "$cfg" || { GRE_DRY_RUN=0; return "$EXIT_VALIDATION"; }
    engine_gre_check_conflicts "$id" "$cfg" || { local s=$?; GRE_DRY_RUN=0; return "$s"; }

    local ec; ec="$(jq -c '.engine_config' <<<"$cfg")"
    local status=0
    gre::_ensure_iface "$id" "$ec" || status=$?
    GRE_DRY_RUN=0
    return "$status"
}

# engine_gre_start <id> [dry-run]
# Starting is the same idempotent ensure-correct-and-up operation as create.
engine_gre_start() {
    engine_gre_create "$1" "${2:-0}"
}

# engine_gre_stop <id> [dry-run]
# Stopping sets the link administratively down but preserves it (and its
# addresses) so the tunnel is cheap to bring back up. Succeeds even if the
# interface is already down or missing.
engine_gre_stop() {
    local id="$1" dry_run="${2:-0}"
    GRE_DRY_RUN="$dry_run"
    local cfg; cfg="$(config::tunnel_read "$id")" || { GRE_DRY_RUN=0; return "$EXIT_NOT_FOUND"; }
    local iface; iface="$(jq -r '.engine_config.interface' <<<"$cfg")"

    if ! gre::_iface_exists "$iface"; then
        GRE_DRY_RUN=0
        return 0
    fi
    if ! gre::_iface_owned_by "$id" "$iface"; then
        log::error "interface $iface is not TixoLink-owned by tunnel $id"
        GRE_DRY_RUN=0
        return "$EXIT_CONFLICT"
    fi

    local status=0
    gre::_do "SET LINK DOWN" gre::_ip link set "$iface" down || status=$?
    GRE_DRY_RUN=0
    return "$status"
}

# engine_gre_restart <id> [dry-run]
engine_gre_restart() {
    local id="$1" dry_run="${2:-0}"
    engine_gre_stop "$id" "$dry_run" || return $?
    engine_gre_start "$id" "$dry_run"
}

# engine_gre_reload <id> [dry-run]
# Reconcile: re-derives desired state from current config and repairs any
# drift. Identical machinery to create/start (which are already
# idempotent reconcile-or-create operations).
engine_gre_reload() {
    engine_gre_create "$1" "${2:-0}"
}

# engine_gre_delete <id> [dry-run]
# Removes only this tunnel's own interface. A missing interface is treated
# as already-deleted (idempotent), not an error.
engine_gre_delete() {
    local id="$1" dry_run="${2:-0}"
    GRE_DRY_RUN="$dry_run"
    local cfg; cfg="$(config::tunnel_read "$id")" || { GRE_DRY_RUN=0; return "$EXIT_NOT_FOUND"; }
    local iface; iface="$(jq -r '.engine_config.interface' <<<"$cfg")"

    if gre::_iface_exists "$iface"; then
        if ! gre::_iface_owned_by "$id" "$iface"; then
            log::error "interface $iface is not TixoLink-owned by tunnel $id; refusing to delete"
            GRE_DRY_RUN=0
            return "$EXIT_CONFLICT"
        fi
        gre::_do "DELETE INTERFACE" gre::_ip link del "$iface" || { GRE_DRY_RUN=0; return "$EXIT_GENERIC"; }
    fi

    if [[ "$GRE_DRY_RUN" != "1" ]]; then
        state::set "del(.tunnels[\"$id\"])" || { GRE_DRY_RUN=0; return "$EXIT_GENERIC"; }
    fi
    GRE_DRY_RUN=0
    return 0
}

# engine_gre_status <id>
# Prints KEY=VALUE lines. STATE is one of:
#   CONFIGURED - tunnel has a config but has never been created/started
#   UP         - interface exists, owned, matches config, link up
#   DOWN       - interface exists, owned, matches config, link down
#   DRIFTED    - interface exists, owned, but runtime differs from config
#   MISSING    - TixoLink's own ledger shows this tunnel was created before,
#                but the interface is gone now (e.g. removed outside
#                TixoLink, or lost across a reboot without persistence)
#   CONFLICT   - interface exists but is not TixoLink-owned by this tunnel
engine_gre_status() {
    local id="$1" cfg ec iface
    cfg="$(config::tunnel_read "$id")" || return "$EXIT_NOT_FOUND"
    ec="$(jq -c '.engine_config' <<<"$cfg")"
    iface="$(gre::_field "$ec" '.interface')"

    local state_val="CONFIGURED"
    if state::get ".tunnels[\"$id\"]" >/dev/null 2>&1; then
        state_val="MISSING"
    fi
    if gre::_iface_exists "$iface"; then
        if ! gre::_iface_owned_by "$id" "$iface"; then
            state_val="CONFLICT"
        else
            local runtime local_ip remote_ip mtu ttl inner_local
            runtime="$(gre::_read_runtime "$iface")"
            local_ip="$(gre::_field "$ec" '.local_public_ip')"
            remote_ip="$(gre::_field "$ec" '.remote_public_ip')"
            mtu="$(gre::_field "$ec" '.mtu')"
            ttl="$(gre::_field "$ec" '.ttl')"
            inner_local="$(gre::_field "$ec" '.inner_local_ip')"

            local rt_local rt_remote rt_ttl rt_mtu rt_inner rt_up
            rt_local="$(jq -r '.local' <<<"$runtime")"
            rt_remote="$(jq -r '.remote' <<<"$runtime")"
            rt_ttl="$(jq -r '.ttl' <<<"$runtime")"
            rt_mtu="$(jq -r '.mtu' <<<"$runtime")"
            rt_inner="$(jq -r '.inner_ip' <<<"$runtime")"
            rt_up="$(jq -r '.up' <<<"$runtime")"

            if [[ "$rt_local" != "$local_ip" || "$rt_remote" != "$remote_ip" || \
                  "$rt_ttl" != "$ttl" || "$rt_mtu" != "$mtu" || "$rt_inner" != "$inner_local" ]]; then
                state_val="DRIFTED"
            elif [[ "$rt_up" == "true" ]]; then
                state_val="UP"
            else
                state_val="DOWN"
            fi
        fi
    fi

    printf 'ID=%s\n' "$id"
    printf 'NAME=%s\n' "$(jq -r '.name' <<<"$cfg")"
    printf 'STATE=%s\n' "$state_val"
    printf 'INTERFACE=%s\n' "$iface"
    printf 'LOCAL_PUBLIC=%s\n' "$(gre::_field "$ec" '.local_public_ip')"
    printf 'REMOTE_PUBLIC=%s\n' "$(gre::_field "$ec" '.remote_public_ip')"
    printf 'INNER_LOCAL=%s\n' "$(gre::_field "$ec" '.inner_local_ip')"
    printf 'INNER_REMOTE=%s\n' "$(gre::_field "$ec" '.inner_remote_ip')"
    printf 'MTU=%s\n' "$(gre::_field "$ec" '.mtu')"
    printf 'TTL=%s\n' "$(gre::_field "$ec" '.ttl')"
    return 0
}

# engine_gre_export_peer <id>
# Prints the engine_config fragment for this tunnel's peer-facing document,
# with roles inverted (local<->remote). Subnet/MTU/TTL are unchanged.
engine_gre_export_peer() {
    local id="$1" cfg ec
    cfg="$(config::tunnel_read "$id")" || return "$EXIT_NOT_FOUND"
    ec="$(jq -c '.engine_config' <<<"$cfg")"
    jq -c '{
        local_public_ip:  .remote_public_ip,
        remote_public_ip: .local_public_ip,
        inner_subnet:     .inner_subnet,
        inner_local_ip:   .inner_remote_ip,
        inner_remote_ip:  .inner_local_ip,
        mtu:              .mtu,
        ttl:              .ttl
    }' <<<"$ec"
}

engine::register "gre"

#!/usr/bin/env bash
# TixoLink NEXUS - tunnel lifecycle orchestration
#
# This is the only layer allowed to call both an engine (via
# engine::dispatch) and the UI layer. It resolves id-or-name references,
# owns the transaction sequencing for create/edit/delete, and never
# duplicates engine-specific logic - everything GRE-specific lives in
# engines/gre.sh.

if [[ -n "${TIXOLINK_MODULE_TUNNEL_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_MODULE_TUNNEL_SH_LOADED=1

# TIXOLINK_TUNNEL_SCHEMA_VERSION is defined in lib/config.sh (the tunnel
# config store owns the schema version constant).

# tunnel::resolve <id-or-name>
# Prints the resolved immutable ID, or fails with EXIT_NOT_FOUND/EXIT_CONFLICT.
tunnel::resolve() {
    config::tunnel_resolve "$1"
}

# tunnel::_engine_of <id>
# Prints the transport engine name recorded in a tunnel's own config, so
# every lifecycle operation dispatches through engine::dispatch rather
# than hardcoding "gre" - the plugin boundary approved in Phase 1.
tunnel::_engine_of() {
    jq -r '.engine' <<<"$(config::tunnel_read "$1")"
}

# tunnel::_timestamp
tunnel::_timestamp() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# tunnel::_assemble <id> <name> <engine-config-json> [created_at] [forwarding-json]
# Builds the full tunnel document. <forwarding-json> defaults to "no
# forwarding configured yet" (used by create); callers editing an
# existing tunnel must pass its current .forwarding object through
# unchanged, or its mappings would be silently discarded on every edit.
tunnel::_assemble() {
    local id="$1" name="$2" engine_config="$3" created_at="${4:-}" forwarding="${5:-}"
    local now; now="$(tunnel::_timestamp)"
    [[ -z "$created_at" ]] && created_at="$now"
    [[ -z "$forwarding" ]] && forwarding='{"engine":"none","mappings":[]}'

    jq -nc \
        --argjson schema_version "$TIXOLINK_TUNNEL_SCHEMA_VERSION" \
        --arg id "$id" \
        --arg name "$name" \
        --argjson engine_config "$engine_config" \
        --argjson forwarding "$forwarding" \
        --arg created_at "$created_at" \
        --arg updated_at "$now" \
        '{
            schema_version: $schema_version,
            id: $id,
            name: $name,
            engine: "gre",
            engine_config: $engine_config,
            forwarding: $forwarding,
            persistence: {enabled: false, boot_enabled: false},
            status: {operational: "unknown"},
            created_at: $created_at,
            updated_at: $updated_at
        }'
}

# tunnel::_resolve_inner_addressing <mode> <manual-subnet> <manual-local> <manual-remote>
# mode is "auto" or "manual". On auto, allocates a fresh /30 and assigns
# .1/.2 as local/remote by convention. Prints "subnet local remote".
tunnel::_resolve_inner_addressing() {
    local mode="$1" manual_subnet="$2" manual_local="$3" manual_remote="$4"
    if [[ "$mode" == "auto" ]]; then
        local subnet
        subnet="$(subnet::allocate)" || return $?
        local base="${subnet%.*}"
        local last_octet="${subnet##*.}"
        last_octet="${last_octet%/*}"
        printf '%s %s.%s %s.%s' "$subnet" "$base" "$((last_octet + 1))" "$base" "$((last_octet + 2))"
        return 0
    fi
    printf '%s %s %s' "$manual_subnet" "$manual_local" "$manual_remote"
}

# tunnel::create_from_fields <name> <local_ip> <remote_ip> <addressing-mode> \
#     <manual_subnet> <manual_local> <manual_remote> <mtu> <ttl> [dry_run]
#
# addressing-mode is "auto" or "manual". Returns the new tunnel ID on
# stdout upon success (even in dry-run mode, so callers can refer to the
# planned ID in the review screen - nothing is written to disk until the
# transaction's APPLY stage, and dry-run skips APPLY entirely).
tunnel::create_from_fields() {
    local name="$1" local_ip="$2" remote_ip="$3" addr_mode="$4"
    local manual_subnet="$5" manual_local="$6" manual_remote="$7"
    local mtu="$8" ttl="$9" dry_run="${10:-0}"
    local engine="gre"  # the only engine the wizard can currently produce

    if config::tunnel_find_by_name "$name" >/dev/null 2>&1; then
        log::error "a tunnel named '$name' already exists"
        return "$EXIT_CONFLICT"
    fi

    local id; id="$(config::tunnel_new_id)" || return "$EXIT_GENERIC"
    local iface="tixo-${id}"

    local addressing subnet inner_local inner_remote
    addressing="$(tunnel::_resolve_inner_addressing "$addr_mode" "$manual_subnet" "$manual_local" "$manual_remote")" || return $?
    read -r subnet inner_local inner_remote <<<"$addressing"

    local engine_config
    engine_config="$(jq -nc \
        --arg interface "$iface" \
        --arg local_public_ip "$local_ip" \
        --arg remote_public_ip "$remote_ip" \
        --arg inner_subnet "$subnet" \
        --arg inner_local_ip "$inner_local" \
        --arg inner_remote_ip "$inner_remote" \
        --argjson mtu "$mtu" \
        --argjson ttl "$ttl" \
        '{interface: $interface, local_public_ip: $local_public_ip,
          remote_public_ip: $remote_public_ip, inner_subnet: $inner_subnet,
          inner_local_ip: $inner_local_ip, inner_remote_ip: $inner_remote_ip,
          mtu: $mtu, ttl: $ttl}')"

    local tunnel_json
    tunnel_json="$(tunnel::_assemble "$id" "$name" "$engine_config")"

    engine::dispatch "$engine" validate "$tunnel_json" || return "$EXIT_VALIDATION"

    tx::begin "tunnel-${id}" 10 || return $?
    tx::set_dry_run "$dry_run"

    tx::precheck engine::dispatch "$engine" precheck "$tunnel_json" || { tx::rollback; return "$EXIT_VALIDATION"; }
    tx::precheck engine::dispatch "$engine" check_conflicts "$id" "$tunnel_json" || { local s=$?; tx::rollback; return "$s"; }

    if [[ "$dry_run" == "1" ]]; then
        printf 'PLAN: write tunnel config %s\n' "$(config::tunnel_path "$id")"
        # GRE_DRY_RUN is engines/gre.sh's global; read there on the next
        # gre::_do call, not in this file - SC2034 is a false positive.
        # shellcheck disable=SC2034
        GRE_DRY_RUN=1
        gre::_ensure_iface "$id" "$engine_config" || true
        # shellcheck disable=SC2034  # engines/gre.sh reads this on its next invocation
        GRE_DRY_RUN=0
        tx::rollback
        printf '%s' "$id"
        return 0
    fi

    tx::apply config::tunnel_write "$id" "$tunnel_json" || { tx::rollback; return "$EXIT_GENERIC"; }
    local apply_status=0
    tx::apply engine::dispatch "$engine" create "$id" 0 || apply_status=$?
    if [[ "$apply_status" -ne 0 ]]; then
        tx::rollback tunnel::_rollback_create "$id"
        return "$EXIT_ROLLED_BACK"
    fi

    tx::verify engine::dispatch "$engine" status "$id" >/dev/null || { tx::rollback tunnel::_rollback_create "$id"; return "$EXIT_ROLLED_BACK"; }

    tx::commit
    log::history "create" "$id" "success"
    printf '%s' "$id"
    return 0
}

# tunnel::_rollback_create <id>
tunnel::_rollback_create() {
    local id="$1"
    engine::dispatch "$(tunnel::_engine_of "$id")" delete "$id" 0 2>/dev/null || true
    config::tunnel_delete "$id"
}

# tunnel::start / stop / restart <id-or-name> [dry_run]
tunnel::start() {
    local id; id="$(tunnel::resolve "$1")" || return $?
    engine::dispatch "$(tunnel::_engine_of "$id")" start "$id" "${2:-0}" && log::history "start" "$id" "success"
}
tunnel::stop() {
    local id; id="$(tunnel::resolve "$1")" || return $?
    engine::dispatch "$(tunnel::_engine_of "$id")" stop "$id" "${2:-0}" && log::history "stop" "$id" "success"
}
tunnel::restart() {
    local id; id="$(tunnel::resolve "$1")" || return $?
    engine::dispatch "$(tunnel::_engine_of "$id")" restart "$id" "${2:-0}" && log::history "restart" "$id" "success"
}
tunnel::reload() {
    local id; id="$(tunnel::resolve "$1")" || return $?
    engine::dispatch "$(tunnel::_engine_of "$id")" reload "$id" "${2:-0}" && log::history "reload" "$id" "success"
}

# tunnel::status <id-or-name>
tunnel::status() {
    local id; id="$(tunnel::resolve "$1")" || return $?
    engine::dispatch "$(tunnel::_engine_of "$id")" status "$id"
}

# tunnel::list
# Prints id/name/engine/local/remote/state, one tunnel per line, pipe-separated.
tunnel::list() {
    local id fields name state local_ip remote_ip engine
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        engine="$(tunnel::_engine_of "$id")"
        fields="$(engine::dispatch "$engine" status "$id" 2>/dev/null)" || continue
        name="$(awk -F= '/^NAME=/{print substr($0,6)}' <<<"$fields")"
        state="$(awk -F= '/^STATE=/{print substr($0,7)}' <<<"$fields")"
        local_ip="$(awk -F= '/^LOCAL_PUBLIC=/{print substr($0,14)}' <<<"$fields")"
        remote_ip="$(awk -F= '/^REMOTE_PUBLIC=/{print substr($0,15)}' <<<"$fields")"
        printf '%s|%s|%s|%s|%s|%s\n' "$id" "$name" "$engine" "$local_ip" "$remote_ip" "$state"
    done < <(config::tunnel_list)
}

# tunnel::delete <id-or-name> [dry_run] [force]
tunnel::delete() {
    local ref="$1" dry_run="${2:-0}" force="${3:-0}"
    local id; id="$(tunnel::resolve "$ref")" || return $?
    local engine; engine="$(tunnel::_engine_of "$id")"

    if [[ "$dry_run" == "1" ]]; then
        printf 'PLAN: delete tunnel %s (%s)\n' "$id" "$ref"
        engine::dispatch "$engine" delete "$id" 1 || true
        printf 'PLAN: remove config %s\n' "$(config::tunnel_path "$id")"
        return 0
    fi

    if [[ "$force" != "1" ]] && ! ui::confirm "Delete tunnel '$ref' ($id)? This removes its GRE interface and configuration." "n"; then
        ui::info "Deletion cancelled."
        return "$EXIT_GENERIC"
    fi

    tx::begin "tunnel-${id}" 10 || return $?
    local status=0
    tx::apply engine::dispatch "$engine" delete "$id" 0 || status=$?
    if [[ "$status" -ne 0 ]]; then
        tx::rollback
        return "$status"
    fi
    config::tunnel_delete "$id"
    tx::commit
    log::history "delete" "$id" "success"
    return 0
}

# tunnel::edit_from_fields <id-or-name> <local_ip> <remote_ip> <mtu> <ttl> [dry_run]
# Only endpoint/MTU/TTL editing is implemented in Phase 3 (inner addressing
# and forwarding edits are out of scope for the transport-only phase).
tunnel::edit_from_fields() {
    local ref="$1" local_ip="$2" remote_ip="$3" mtu="$4" ttl="$5" dry_run="${6:-0}"
    local id; id="$(tunnel::resolve "$ref")" || return $?
    local engine; engine="$(tunnel::_engine_of "$id")"

    local old_json; old_json="$(config::tunnel_read "$id")" || return "$EXIT_NOT_FOUND"
    local old_ec; old_ec="$(jq -c '.engine_config' <<<"$old_json")"
    local new_ec
    new_ec="$(jq -c \
        --arg local_public_ip "$local_ip" \
        --arg remote_public_ip "$remote_ip" \
        --argjson mtu "$mtu" \
        --argjson ttl "$ttl" \
        '.local_public_ip = $local_public_ip | .remote_public_ip = $remote_public_ip |
         .mtu = $mtu | .ttl = $ttl' <<<"$old_ec")"

    local created_at; created_at="$(jq -r '.created_at' <<<"$old_json")"
    local name; name="$(jq -r '.name' <<<"$old_json")"
    local old_forwarding; old_forwarding="$(jq -c '.forwarding' <<<"$old_json")"
    local candidate; candidate="$(tunnel::_assemble "$id" "$name" "$new_ec" "$created_at" "$old_forwarding")"

    engine::dispatch "$engine" validate "$candidate" || return "$EXIT_VALIDATION"

    if [[ "$dry_run" == "1" ]]; then
        ui::section "Planned changes for $id"
        diff <(jq -S . <<<"$old_json") <(jq -S . <<<"$candidate") || true
        # shellcheck disable=SC2034  # read by engines/gre.sh, see comment above
        GRE_DRY_RUN=1
        gre::_ensure_iface "$id" "$new_ec" || true
        # shellcheck disable=SC2034  # engines/gre.sh reads this on its next invocation
        GRE_DRY_RUN=0
        return 0
    fi

    tx::begin "tunnel-${id}" 10 || return $?
    tx::precheck engine::dispatch "$engine" precheck "$candidate" || { tx::rollback; return "$EXIT_VALIDATION"; }
    tx::precheck engine::dispatch "$engine" check_conflicts "$id" "$candidate" || { local s=$?; tx::rollback; return "$s"; }

    local backup_file
    backup_file="$(tx::workdir)/old_config.json"
    tx::backup tunnel::_write_backup "$old_json" "$backup_file" || { tx::rollback; return "$EXIT_GENERIC"; }

    tx::apply config::tunnel_write "$id" "$candidate" || { tx::rollback; return "$EXIT_GENERIC"; }
    local status=0
    tx::apply engine::dispatch "$engine" reload "$id" 0 || status=$?
    if [[ "$status" -ne 0 ]]; then
        tx::rollback tunnel::_rollback_edit "$id" "$backup_file"
        return "$EXIT_ROLLED_BACK"
    fi

    tx::verify engine::dispatch "$engine" status "$id" >/dev/null || { tx::rollback tunnel::_rollback_edit "$id" "$backup_file"; return "$EXIT_ROLLED_BACK"; }

    tx::commit
    log::history "edit" "$id" "success"
    return 0
}

# tunnel::_write_backup <json> <file>
tunnel::_write_backup() {
    printf '%s' "$1" >"$2"
}

# tunnel::_rollback_edit <id> <backup-file>
tunnel::_rollback_edit() {
    local id="$1" backup_file="$2"
    if [[ -f "$backup_file" ]]; then
        config::tunnel_write "$id" "$(cat "$backup_file")" || return "$EXIT_GENERIC"
        engine::dispatch "$(tunnel::_engine_of "$id")" reload "$id" 0 2>/dev/null || true
    fi
}

#!/usr/bin/env bash
# TixoLink NEXUS - port forwarding orchestration
#
# Mirrors modules/tunnel.sh's role for forwarding: resolves tunnels/
# mappings, owns transaction sequencing for add/edit/remove/migrate, and
# never duplicates forwarder-specific logic (that lives in forwarders/*.sh).

if [[ -n "${TIXOLINK_MODULE_FORWARDING_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_MODULE_FORWARDING_SH_LOADED=1

readonly TIXOLINK_DEFAULT_NAT_MODE="nat"

# forwarding::_new_mapping_id <tunnel-json>
forwarding::_new_mapping_id() {
    local tunnel_json="$1" id attempt
    for (( attempt=0; attempt<100; attempt++ )); do
        id="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n' | cut -c1-8)"
        validate::tunnel_id "$id" || continue
        if ! jq -e --arg id "$id" '.forwarding.mappings[]? | select(.id == $id)' <<<"$tunnel_json" >/dev/null 2>&1; then
            printf '%s' "$id"
            return 0
        fi
    done
    log::error "failed to generate a unique mapping ID"
    return "$EXIT_GENERIC"
}

# forwarding::_find_mapping <tunnel-json> <mapping-id>
forwarding::_find_mapping() {
    jq -e --arg id "$2" '.forwarding.mappings[]? | select(.id == $id)' <<<"$1"
}

# forwarding::_engine_of <tunnel-json>
forwarding::_engine_of() { jq -r '.forwarding.engine // "none"' <<<"$1"; }

# forwarding::add <tunnel-ref> <protocol> <port-token> <listen-address> \
#     <remote-address-override|""> <nat-mode> [dry-run]
# <port-token> is a single ports::parse_token token (e.g. "443" or "8443:443").
forwarding::add() {
    local ref="$1" protocol="$2" port_token="$3" listen_addr="${4:-0.0.0.0}"
    local remote_override="${5:-}" nat_mode="${6:-$TIXOLINK_DEFAULT_NAT_MODE}" dry_run="${7:-0}"

    local id; id="$(tunnel::resolve "$ref")" || return $?
    local tunnel_json; tunnel_json="$(config::tunnel_read "$id")" || return "$EXIT_NOT_FOUND"
    local engine; engine="$(forwarding::_engine_of "$tunnel_json")"

    if [[ "$engine" == "none" ]]; then
        log::error "tunnel $id has no forwarding engine selected; choose one first"
        return "$EXIT_USAGE"
    fi

    validate::protocol "$protocol" || { log::error "invalid protocol: $protocol"; return "$EXIT_VALIDATION"; }
    if [[ "$engine" == "haproxy" && "$protocol" != "tcp" ]]; then
        log::error "HAProxy forwarding only supports TCP in this build; use netfilter for UDP"
        return "$EXIT_VALIDATION"
    fi

    local parsed local_port remote_port
    parsed="$(ports::parse_token "$port_token")" || { log::error "invalid port spec: $port_token"; return "$EXIT_VALIDATION"; }
    local_port="${parsed%%|*}"
    remote_port="${parsed#*|}"

    [[ -n "$remote_override" ]] && { validate::ipv4 "$remote_override" || { log::error "invalid remote address override: $remote_override"; return "$EXIT_VALIDATION"; }; }
    validate::ipv4 "$listen_addr" || { log::error "invalid listen address: $listen_addr"; return "$EXIT_VALIDATION"; }

    local mapping_id; mapping_id="$(forwarding::_new_mapping_id "$tunnel_json")" || return "$EXIT_GENERIC"
    local now; now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    local mapping
    mapping="$(jq -nc \
        --arg id "$mapping_id" --arg protocol "$protocol" \
        --arg listen_address "$listen_addr" --arg local_port "$local_port" \
        --arg remote_address "$remote_override" --arg remote_port "$remote_port" \
        --arg nat_mode "$nat_mode" --arg now "$now" \
        '{id: $id, protocol: $protocol, listen_address: $listen_address,
          local_port: $local_port,
          remote_address: (if $remote_address == "" then null else $remote_address end),
          remote_port: $remote_port, nat_mode: $nat_mode,
          created_at: $now, updated_at: $now}')"

    forwarder::dispatch "$engine" validate "$tunnel_json" "$mapping" || return "$EXIT_VALIDATION"
    forwarder::dispatch "$engine" check_conflicts "$id" "$mapping" || return $?

    if [[ "$dry_run" == "1" ]]; then
        forwarder::dispatch "$engine" apply "$tunnel_json" "$mapping" 1
        return 0
    fi

    tx::begin "forwarding-${id}" 10 || return $?
    local status=0
    tx::apply forwarder::dispatch "$engine" apply "$tunnel_json" "$mapping" 0 || status=$?
    if [[ "$status" -ne 0 ]]; then
        tx::rollback forwarder::dispatch "$engine" remove "$tunnel_json" "$mapping" 0
        return "$EXIT_ROLLED_BACK"
    fi

    local new_tunnel_json
    new_tunnel_json="$(jq -c --argjson m "$mapping" '.forwarding.mappings += [$m]' <<<"$tunnel_json")"
    tx::apply config::tunnel_write "$id" "$new_tunnel_json" || {
        tx::rollback forwarder::dispatch "$engine" remove "$tunnel_json" "$mapping" 0
        return "$EXIT_ROLLED_BACK"
    }

    tx::commit
    log::history "forward-add" "$id" "success"
    printf '%s' "$mapping_id"
    return 0
}

# forwarding::remove <tunnel-ref> <mapping-id> [dry-run]
forwarding::remove() {
    local ref="$1" mapping_id="$2" dry_run="${3:-0}"
    local id; id="$(tunnel::resolve "$ref")" || return $?
    local tunnel_json; tunnel_json="$(config::tunnel_read "$id")" || return "$EXIT_NOT_FOUND"
    local engine; engine="$(forwarding::_engine_of "$tunnel_json")"

    local mapping
    mapping="$(forwarding::_find_mapping "$tunnel_json" "$mapping_id")" || { log::error "mapping not found: $mapping_id"; return "$EXIT_NOT_FOUND"; }

    if [[ "$dry_run" == "1" ]]; then
        forwarder::dispatch "$engine" remove "$tunnel_json" "$mapping" 1
        return 0
    fi

    tx::begin "forwarding-${id}" 10 || return $?
    tx::apply forwarder::dispatch "$engine" remove "$tunnel_json" "$mapping" 0 || {
        tx::rollback
        return "$EXIT_ROLLED_BACK"
    }

    local new_tunnel_json
    new_tunnel_json="$(jq -c --arg mid "$mapping_id" '.forwarding.mappings |= map(select(.id != $mid))' <<<"$tunnel_json")"
    tx::apply config::tunnel_write "$id" "$new_tunnel_json" || { tx::rollback; return "$EXIT_ROLLED_BACK"; }

    tx::commit
    log::history "forward-remove" "$id" "success"
    return 0
}

# forwarding::edit <tunnel-ref> <mapping-id> <new-port-token> [dry-run]
# Only the local/remote port of a mapping is editable in this build;
# protocol/engine changes go through remove+add or migrate respectively.
forwarding::edit() {
    local ref="$1" mapping_id="$2" new_port_token="$3" dry_run="${4:-0}"
    local id; id="$(tunnel::resolve "$ref")" || return $?
    local tunnel_json; tunnel_json="$(config::tunnel_read "$id")" || return "$EXIT_NOT_FOUND"
    local engine; engine="$(forwarding::_engine_of "$tunnel_json")"

    local old_mapping
    old_mapping="$(forwarding::_find_mapping "$tunnel_json" "$mapping_id")" || { log::error "mapping not found: $mapping_id"; return "$EXIT_NOT_FOUND"; }

    local parsed local_port remote_port
    parsed="$(ports::parse_token "$new_port_token")" || { log::error "invalid port spec: $new_port_token"; return "$EXIT_VALIDATION"; }
    local_port="${parsed%%|*}"
    remote_port="${parsed#*|}"

    local now; now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    local new_mapping
    new_mapping="$(jq -c --arg local_port "$local_port" --arg remote_port "$remote_port" --arg now "$now" \
        '.local_port = $local_port | .remote_port = $remote_port | .updated_at = $now' <<<"$old_mapping")"

    forwarder::dispatch "$engine" validate "$tunnel_json" "$new_mapping" || return "$EXIT_VALIDATION"
    forwarder::dispatch "$engine" check_conflicts "$id" "$new_mapping" "$mapping_id" || return $?

    if [[ "$dry_run" == "1" ]]; then
        ui::info "Planned: mapping $mapping_id local/remote port -> ${local_port}/${remote_port}"
        forwarder::dispatch "$engine" apply "$tunnel_json" "$new_mapping" 1
        return 0
    fi

    # New-before-old: apply the new mapping's rules first; only remove the
    # old mapping's rules once the new ones are confirmed active, so a
    # failed apply leaves the original mapping fully operational.
    tx::begin "forwarding-${id}" 10 || return $?
    local status=0
    tx::apply forwarder::dispatch "$engine" apply "$tunnel_json" "$new_mapping" 0 || status=$?
    if [[ "$status" -ne 0 ]]; then
        tx::rollback forwarder::dispatch "$engine" remove "$tunnel_json" "$new_mapping" 0
        return "$EXIT_ROLLED_BACK"
    fi

    tx::apply forwarder::dispatch "$engine" remove "$tunnel_json" "$old_mapping" 0 || true

    local new_tunnel_json
    new_tunnel_json="$(jq -c --arg mid "$mapping_id" --argjson m "$new_mapping" \
        '.forwarding.mappings |= map(if .id == $mid then $m else . end)' <<<"$tunnel_json")"
    tx::apply config::tunnel_write "$id" "$new_tunnel_json" || { tx::rollback; return "$EXIT_ROLLED_BACK"; }

    tx::commit
    log::history "forward-edit" "$id" "success"
    return 0
}

# forwarding::status <tunnel-ref>
forwarding::status() {
    local id; id="$(tunnel::resolve "$1")" || return $?
    local tunnel_json; tunnel_json="$(config::tunnel_read "$id")" || return "$EXIT_NOT_FOUND"
    local engine; engine="$(forwarding::_engine_of "$tunnel_json")"

    if [[ "$engine" == "none" ]]; then
        printf 'ENGINE=none\n'
        return 0
    fi

    printf 'ENGINE=%s\n' "$engine"
    local mapping mid state
    while IFS= read -r mapping; do
        [[ -z "$mapping" || "$mapping" == "null" ]] && continue
        mid="$(jq -r '.id' <<<"$mapping")"
        state="$(forwarder::dispatch "$engine" status "$tunnel_json" "$mapping" | awk -F= '/^STATE=/{print substr($0,7)}')"
        printf 'MAPPING=%s PROTO=%s LOCAL=%s REMOTE=%s STATE=%s\n' \
            "$mid" "$(jq -r '.protocol' <<<"$mapping")" "$(jq -r '.local_port' <<<"$mapping")" \
            "$(jq -r '.remote_port' <<<"$mapping")" "$state"
    done < <(jq -c '.forwarding.mappings[]?' <<<"$tunnel_json")
    return 0
}

# forwarding::migrate <tunnel-ref> <new-engine> [dry-run]
forwarding::migrate() {
    local ref="$1" new_engine="$2" dry_run="${3:-0}"
    local id; id="$(tunnel::resolve "$ref")" || return $?
    local tunnel_json; tunnel_json="$(config::tunnel_read "$id")" || return "$EXIT_NOT_FOUND"
    local old_engine; old_engine="$(forwarding::_engine_of "$tunnel_json")"

    forwarder::is_registered "$new_engine" || { log::error "unknown forwarding engine: $new_engine"; return "$EXIT_USAGE"; }
    if [[ "$old_engine" == "$new_engine" ]]; then
        log::info "tunnel $id already uses forwarding engine $new_engine"
        return 0
    fi

    local -a mappings=()
    local m
    while IFS= read -r m; do
        [[ -z "$m" || "$m" == "null" ]] && continue
        mappings+=("$m")
        if [[ "$new_engine" == "haproxy" && "$(jq -r '.protocol' <<<"$m")" != "tcp" ]]; then
            log::error "cannot migrate to haproxy: mapping $(jq -r '.id' <<<"$m") uses a non-TCP protocol"
            return "$EXIT_VALIDATION"
        fi
        forwarder::dispatch "$new_engine" validate "$tunnel_json" "$m" || return "$EXIT_VALIDATION"
    done < <(jq -c '.forwarding.mappings[]?' <<<"$tunnel_json")

    if [[ "$dry_run" == "1" ]]; then
        ui::info "Planned: migrate tunnel $id forwarding $old_engine -> $new_engine (${#mappings[@]} mapping(s))"
        for m in "${mappings[@]}"; do
            forwarder::dispatch "$new_engine" apply "$tunnel_json" "$m" 1
        done
        return 0
    fi

    tx::begin "forwarding-${id}" 15 || return $?

    local applied=()
    local status=0 m2
    for m2 in "${mappings[@]}"; do
        if ! tx::apply forwarder::dispatch "$new_engine" apply "$tunnel_json" "$m2" 0; then
            status=1
            break
        fi
        applied+=("$m2")
    done

    if [[ "$status" -ne 0 ]]; then
        local a
        for a in "${applied[@]:-}"; do
            [[ -z "$a" ]] && continue
            forwarder::dispatch "$new_engine" remove "$tunnel_json" "$a" 0 2>/dev/null || true
        done
        tx::rollback
        log::error "migration to $new_engine failed; old forwarding engine ($old_engine) remains active"
        return "$EXIT_ROLLED_BACK"
    fi

    # VERIFY TARGET before touching the old engine at all.
    local verify_ok=1
    for m2 in "${mappings[@]}"; do
        local st
        st="$(forwarder::dispatch "$new_engine" status "$tunnel_json" "$m2" | awk -F= '/^STATE=/{print substr($0,7)}')"
        [[ "$st" == "ACTIVE" ]] || { verify_ok=0; break; }
    done
    if [[ "$verify_ok" -ne 1 ]]; then
        for a in "${applied[@]}"; do
            forwarder::dispatch "$new_engine" remove "$tunnel_json" "$a" 0 2>/dev/null || true
        done
        tx::rollback
        log::error "migration to $new_engine did not verify active; old forwarding engine ($old_engine) remains active"
        return "$EXIT_ROLLED_BACK"
    fi

    # Only now remove the old engine's rules.
    for m2 in "${mappings[@]}"; do
        forwarder::dispatch "$old_engine" remove "$tunnel_json" "$m2" 0 2>/dev/null || true
    done

    local new_tunnel_json
    new_tunnel_json="$(jq -c --arg e "$new_engine" '.forwarding.engine = $e' <<<"$tunnel_json")"
    tx::apply config::tunnel_write "$id" "$new_tunnel_json" || { tx::rollback; return "$EXIT_ROLLED_BACK"; }

    tx::commit
    log::history "forward-migrate" "$id" "success"
    return 0
}

# forwarding::set_engine <tunnel-ref> <engine> [dry-run]
# For a tunnel currently at "none", selects its forwarding engine without
# needing to migrate anything (no mappings exist yet).
forwarding::set_engine() {
    local ref="$1" engine="$2" dry_run="${3:-0}"
    local id; id="$(tunnel::resolve "$ref")" || return $?
    local tunnel_json; tunnel_json="$(config::tunnel_read "$id")" || return "$EXIT_NOT_FOUND"
    local old_engine; old_engine="$(forwarding::_engine_of "$tunnel_json")"

    if [[ "$old_engine" != "none" ]]; then
        forwarding::migrate "$ref" "$engine" "$dry_run"
        return $?
    fi

    forwarder::is_registered "$engine" || { log::error "unknown forwarding engine: $engine"; return "$EXIT_USAGE"; }
    if [[ "$dry_run" == "1" ]]; then
        ui::info "Planned: set tunnel $id forwarding engine to $engine"
        return 0
    fi
    local new_tunnel_json
    new_tunnel_json="$(jq -c --arg e "$engine" '.forwarding.engine = $e' <<<"$tunnel_json")"
    config::tunnel_write "$id" "$new_tunnel_json"
}

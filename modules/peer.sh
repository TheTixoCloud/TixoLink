#!/usr/bin/env bash
# TixoLink NEXUS - peer export/import
#
# A peer document describes the *other side* of a tunnel: it inverts
# local/remote roles and contains only the fields needed to configure that
# side. It is configuration data, never authentication - no credentials,
# SSH data, API keys, private keys, or host runtime state are ever
# included. Importing a peer document always assigns a brand-new local
# immutable tunnel ID; an imported ID is never trusted as local identity.

if [[ -n "${TIXOLINK_MODULE_PEER_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_MODULE_PEER_SH_LOADED=1

readonly TIXOLINK_PEER_SCHEMA_VERSION=1
readonly TIXOLINK_PEER_DOCUMENT_TYPE="tixolink-peer-config"

# peer::_build <id-or-name>
# Prints the peer document JSON for the given tunnel.
peer::_build() {
    local ref="$1" id name peer_ec suggested_name
    id="$(tunnel::resolve "$ref")" || return $?
    name="$(jq -r '.name' <<<"$(config::tunnel_read "$id")")"
    peer_ec="$(engine::dispatch "gre" "export_peer" "$id")" || return "$EXIT_GENERIC"
    suggested_name="${name}-peer"

    jq -nc \
        --argjson schema_version "$TIXOLINK_PEER_SCHEMA_VERSION" \
        --arg document_type "$TIXOLINK_PEER_DOCUMENT_TYPE" \
        --arg name "$suggested_name" \
        --argjson engine_config "$peer_ec" \
        '{
            tixolink_peer_schema_version: $schema_version,
            document_type: $document_type,
            engine: "gre",
            name: $name,
            engine_config: $engine_config
        }'
}

# peer::export <id-or-name> [--output <file>] [--force]
peer::export() {
    local ref="$1"
    shift
    local output="" force=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output) output="$2"; shift 2 ;;
            --force) force=1; shift ;;
            *) log::error "peer export: unknown option $1"; return "$EXIT_USAGE" ;;
        esac
    done

    local doc
    doc="$(peer::_build "$ref")" || return $?

    if [[ -z "$output" ]]; then
        printf '%s\n' "$doc"
        return 0
    fi

    if [[ -e "$output" && "$force" != "1" ]]; then
        log::error "refusing to overwrite existing file: $output (use --force)"
        return "$EXIT_CONFLICT"
    fi

    local tmp dir
    dir="$(dirname "$output")"
    [[ -d "$dir" ]] || { log::error "output directory does not exist: $dir"; return "$EXIT_NOT_FOUND"; }
    tmp="$(mktemp "${dir}/.tixolink-peer.XXXXXXXX")"
    chmod 0640 "$tmp"
    printf '%s\n' "$doc" >"$tmp"
    mv -T "$tmp" "$output"
    return 0
}

# peer::_validate_document <json>
peer::_validate_document() {
    local doc="$1" schema_version doctype engine

    if ! jq -e . <<<"$doc" >/dev/null 2>&1; then
        log::error "peer document is not valid JSON"
        return "$EXIT_VALIDATION"
    fi

    schema_version="$(jq -r '.tixolink_peer_schema_version // empty' <<<"$doc")"
    doctype="$(jq -r '.document_type // empty' <<<"$doc")"
    engine="$(jq -r '.engine // empty' <<<"$doc")"

    if [[ "$doctype" != "$TIXOLINK_PEER_DOCUMENT_TYPE" ]]; then
        log::error "not a TixoLink peer configuration document (document_type=$doctype)"
        return "$EXIT_VALIDATION"
    fi
    if [[ "$schema_version" != "$TIXOLINK_PEER_SCHEMA_VERSION" ]]; then
        log::error "unsupported peer document schema version: $schema_version"
        return "$EXIT_VALIDATION"
    fi
    if [[ "$engine" != "gre" ]]; then
        log::error "unsupported peer document engine: $engine"
        return "$EXIT_VALIDATION"
    fi

    local name; name="$(jq -r '.name // empty' <<<"$doc")"
    validate::tunnel_name "$name" || { log::error "invalid peer document name: $name"; return "$EXIT_VALIDATION"; }

    return 0
}

# peer::import <file> [--force] [--start] [--dry-run]
# --force skips the interactive confirmation (for non-interactive/scripted use).
# --start applies and starts the tunnel immediately after import; without
# it, the tunnel is written but never started (per Phase 3 requirements).
peer::import() {
    local file="$1"
    shift
    local force=0 start=0 dry_run=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=1; shift ;;
            --start) start=1; shift ;;
            --dry-run) dry_run=1; shift ;;
            *) log::error "peer import: unknown option $1"; return "$EXIT_USAGE" ;;
        esac
    done

    [[ -f "$file" ]] || { log::error "peer file not found: $file"; return "$EXIT_NOT_FOUND"; }

    local doc
    doc="$(jq -e . "$file" 2>/dev/null)" || { log::error "peer file is not valid JSON: $file"; return "$EXIT_VALIDATION"; }

    peer::_validate_document "$doc" || return $?

    local ec; ec="$(jq -c '.engine_config' <<<"$doc")"
    local name; name="$(jq -r '.name' <<<"$doc")"

    # Imported tunnel ID identity is never trusted: a brand-new local ID
    # and interface name are always generated here.
    local id; id="$(config::tunnel_new_id)" || return "$EXIT_GENERIC"
    local iface="tixo-${id}"
    ec="$(jq -c --arg interface "$iface" '.interface = $interface' <<<"$ec")"

    if config::tunnel_find_by_name "$name" >/dev/null 2>&1; then
        name="${name}-$(printf '%s' "$id" | cut -c1-4)"
    fi

    local candidate; candidate="$(tunnel::_assemble "$id" "$name" "$ec")"

    engine::dispatch "gre" validate "$candidate" || return "$EXIT_VALIDATION"
    engine::dispatch "gre" check_conflicts "$id" "$candidate" || return $?

    # Review output goes to stderr, not stdout: on success this function's
    # only stdout output is the new tunnel ID, so callers can safely do
    # `id=$(peer::import file --force)` without the human-readable review
    # text ending up inside $id.
    {
        ui::section "Imported peer configuration (review before accepting)"
        printf 'Proposed name:    %s\n' "$name"
        printf 'Local public IP:  %s\n' "$(jq -r '.local_public_ip' <<<"$ec")"
        printf 'Remote public IP: %s\n' "$(jq -r '.remote_public_ip' <<<"$ec")"
        printf 'Inner subnet:     %s\n' "$(jq -r '.inner_subnet' <<<"$ec")"
        printf 'Inner local IP:   %s\n' "$(jq -r '.inner_local_ip' <<<"$ec")"
        printf 'Inner remote IP:  %s\n' "$(jq -r '.inner_remote_ip' <<<"$ec")"
        printf 'MTU:              %s\n' "$(jq -r '.mtu' <<<"$ec")"
        printf 'TTL:              %s\n' "$(jq -r '.ttl' <<<"$ec")"
    } >&2

    if [[ "$dry_run" == "1" ]]; then
        printf 'PLAN: write tunnel config %s (not written - dry run)\n' "$(config::tunnel_path "$id")" >&2
        return 0
    fi

    if [[ "$force" != "1" ]] && ! ui::confirm "Import this tunnel configuration?" "n"; then
        ui::info "Import cancelled."
        return "$EXIT_GENERIC"
    fi

    config::tunnel_write "$id" "$candidate" || return "$EXIT_GENERIC"
    log::history "peer-import" "$id" "success"

    if [[ "$start" == "1" ]]; then
        engine::dispatch "gre" create "$id" 0 || { log::warn "tunnel $id imported but failed to start"; printf '%s' "$id"; return "$EXIT_GENERIC"; }
        log::history "start" "$id" "success"
    fi

    printf '%s' "$id"
    return 0
}

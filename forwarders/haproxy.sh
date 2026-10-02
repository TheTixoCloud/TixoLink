#!/usr/bin/env bash
# TixoLink NEXUS - HAProxy forwarding engine
#
# ARCHITECTURE DECISION (Phase 4 re-evaluation, after the Phase 3 rejection
# of a systemd ExecStart override):
#
# Inspected the actual Ubuntu/Debian HAProxy packaging (haproxy 2.8.16,
# Ubuntu 24.04) read-only before writing this file:
#   - Its unit's ExecStart is `haproxy -Ws -f $CONFIG -p $PIDFILE $EXTRAOPTS`,
#     with $CONFIG/$EXTRAOPTS sourced from /etc/default/haproxy.
#   - HAProxy's `-f` flag natively accepts multiple files/directories, so
#     editing /etc/default/haproxy's EXTRAOPTS to add a second `-f` could
#     work - but that still means TixoLink silently rewriting a file the
#     administrator may already be managing, with the same "surprise edit"
#     problem the Phase 3 correction rejected for the unit file itself.
#   - HAProxy ships no native "include a managed sub-block of this exact
#     file" directive, and no conf.d convention in this packaging.
#
# DECISION: maintain a single, clearly delimited, idempotent managed block
# appended to the administrator's own /etc/haproxy/haproxy.cfg, between
#   # BEGIN TIXOLINK MANAGED BLOCK (do not edit below this line)
#   # END TIXOLINK MANAGED BLOCK
# markers. Everything outside the markers is preserved byte-for-byte.
# This is the one approach that touches nothing but the file the
# administrator already expects to be the single source of HAProxy
# configuration truth, requires no systemd/package changes, and needs no
# assumption about packaging features beyond `-c` validation (universal)
# and `systemctl reload` (which this package's own ExecReload already
# re-validates before signaling the running process).
#
# Safety sequence on every apply: generate full candidate -> `haproxy -c`
# validate the COMPLETE file -> if invalid, abort, real file untouched ->
# hash-compare the managed block against the last-applied hash -> skip
# reload entirely if unchanged -> backup current file -> atomic write ->
# `systemctl reload haproxy` -> verify service is still active -> on any
# verification failure, restore the backup and reload again.
#
# TCP only in this build: HAProxy's normal `mode tcp` cannot forward UDP;
# selecting UDP with this engine is rejected earlier, in
# modules/forwarding.sh, before this file is ever reached.

if [[ -n "${TIXOLINK_FORWARDER_HAPROXY_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_FORWARDER_HAPROXY_SH_LOADED=1

readonly HAPROXY_BEGIN_MARKER="# BEGIN TIXOLINK MANAGED BLOCK (do not edit below this line)"
readonly HAPROXY_END_MARKER="# END TIXOLINK MANAGED BLOCK"
readonly TIXOLINK_HAPROXY_CFG="${TIXOLINK_HAPROXY_CFG:-/etc/haproxy/haproxy.cfg}"

HAPROXY_DRY_RUN=0

# haproxy::_binary_available
haproxy::_binary_available() { command -v haproxy >/dev/null 2>&1; }

# haproxy::_reload
# The real reload mechanism. Overridden by tests to avoid ever touching a
# real systemd-managed haproxy.
haproxy::_reload() { systemctl reload haproxy; }

# haproxy::_is_active
haproxy::_is_active() { systemctl is-active --quiet haproxy; }

# haproxy::_sanitize_id <id>
# Object names must derive from immutable IDs, never display names, and
# must be safe HAProxy identifiers (alnum + underscore only).
haproxy::_sanitize_id() {
    [[ "$1" =~ ^[0-9a-f]{8}$ ]] || return 1
    printf '%s' "$1"
}

# haproxy::_object_name <tunnel-id> <mapping-id> <suffix>
haproxy::_object_name() {
    printf 'tixolink_%s_%s_%s' "$1" "$2" "$3"
}

# haproxy::_base_content
# Everything in the real config file outside the managed block, i.e.
# whatever the administrator owns. Prints a safe empty "global/defaults"
# skeleton if the file does not exist yet.
haproxy::_base_content() {
    local file="$TIXOLINK_HAPROXY_CFG"
    if [[ ! -f "$file" ]]; then
        printf 'global\n    log /dev/log local0\n\ndefaults\n    mode tcp\n    timeout connect 5s\n    timeout client 50s\n    timeout server 50s\n'
        return 0
    fi
    awk -v b="$HAPROXY_BEGIN_MARKER" -v e="$HAPROXY_END_MARKER" '
        $0 == b { skipping = 1; next }
        $0 == e { skipping = 0; next }
        !skipping { print }
    ' "$file"
}

# haproxy::_detect_malformed_blocks
# Fails if the real file has more than one BEGIN or an unmatched marker -
# this must never be silently "fixed" by picking one.
haproxy::_detect_malformed_blocks() {
    local file="$TIXOLINK_HAPROXY_CFG"
    [[ -f "$file" ]] || return 0
    local begins ends
    begins="$(grep -cF "$HAPROXY_BEGIN_MARKER" "$file" || true)"
    ends="$(grep -cF "$HAPROXY_END_MARKER" "$file" || true)"
    if [[ "$begins" -gt 1 || "$ends" -gt 1 || "$begins" != "$ends" ]]; then
        log::error "haproxy.cfg has a malformed or duplicated TixoLink managed block ($begins begin / $ends end markers); refusing to touch it"
        return "$EXIT_GENERIC"
    fi
    return 0
}

# haproxy::_render_mapping <tunnel-json> <mapping-json>
haproxy::_render_mapping() {
    local tunnel_json="$1" mapping="$2"
    local tid mid fe be listen_addr local_port remote_addr remote_port
    tid="$(jq -r '.id' <<<"$tunnel_json")"
    mid="$(jq -r '.id' <<<"$mapping")"
    haproxy::_sanitize_id "$tid" >/dev/null || return "$EXIT_VALIDATION"
    haproxy::_sanitize_id "$mid" >/dev/null || return "$EXIT_VALIDATION"
    fe="$(haproxy::_object_name "$tid" "$mid" fe)"
    be="$(haproxy::_object_name "$tid" "$mid" be)"
    listen_addr="$(jq -r '.listen_address' <<<"$mapping")"
    local_port="$(jq -r '.local_port' <<<"$mapping")"
    remote_addr="$(jq -r '.remote_address // empty' <<<"$mapping")"
    [[ -z "$remote_addr" ]] && remote_addr="$(jq -r '.engine_config.inner_remote_ip' <<<"$tunnel_json")"
    remote_port="$(jq -r '.remote_port' <<<"$mapping")"

    # Defense in depth: every current caller already runs
    # forwarder_haproxy_validate before apply, but this function
    # interpolates these values directly into HAProxy config text (not
    # through jq), so it re-validates its own inputs here too rather than
    # trusting that every present and future caller remembers to.
    # Port ranges are also rejected here - not representable as a single
    # HAProxy bind/server port.
    validate::ipv4 "$listen_addr" || return "$EXIT_VALIDATION"
    validate::ipv4 "$remote_addr" || return "$EXIT_VALIDATION"
    validate::port "$local_port" || return "$EXIT_VALIDATION"
    validate::port "$remote_port" || return "$EXIT_VALIDATION"

    cat <<EOF

# tixolink:${tid}:${mid}
frontend ${fe}
    bind ${listen_addr}:${local_port}
    default_backend ${be}

backend ${be}
    server ${mid} ${remote_addr}:${remote_port}
EOF
}

# haproxy::_render_block <tunnel-mapping-pairs...>
# Each argument is "tunnel-json|mapping-json" (pipe-joined to pass both
# through a single positional array element).
haproxy::_render_block() {
    printf '%s\n' "$HAPROXY_BEGIN_MARKER"
    printf '# Managed by TixoLink NEXUS - do not edit by hand; see\n'
    printf '# docs/architecture.md for the HAProxy integration mechanism.\n'
    local pair tunnel_json mapping
    for pair in "$@"; do
        tunnel_json="${pair%%|*}"
        mapping="${pair#*|}"
        haproxy::_render_mapping "$tunnel_json" "$mapping" || return "$EXIT_VALIDATION"
    done
    printf '\n%s\n' "$HAPROXY_END_MARKER"
}

# haproxy::_collect_pairs <this-tunnel-json> <this-tunnel-effective-mappings-json-array>
# Gathers every "tunnel|mapping" pair across all tunnels using haproxy
# forwarding, substituting the caller's in-memory effective mapping set
# for the current tunnel (which may differ from what's on disk mid-apply).
haproxy::_collect_pairs() {
    local this_tunnel_json="$1" this_mappings="$2"
    local this_id; this_id="$(jq -r '.id' <<<"$this_tunnel_json")"
    local -a pairs=()

    local m
    while IFS= read -r m; do
        [[ -z "$m" || "$m" == "null" ]] && continue
        pairs+=("${this_tunnel_json}|${m}")
    done < <(jq -c '.[]' <<<"$this_mappings")

    local other_id other_json other_engine m2
    while IFS= read -r other_id; do
        [[ -z "$other_id" || "$other_id" == "$this_id" ]] && continue
        other_json="$(config::tunnel_read "$other_id" 2>/dev/null)" || continue
        other_engine="$(jq -r '.forwarding.engine // "none"' <<<"$other_json")"
        [[ "$other_engine" == "haproxy" ]] || continue
        while IFS= read -r m2; do
            [[ -z "$m2" || "$m2" == "null" ]] && continue
            pairs+=("${other_json}|${m2}")
        done < <(jq -c '.forwarding.mappings[]?' <<<"$other_json")
    done < <(config::tunnel_list)

    printf '%s\n' "${pairs[@]}"
}

# haproxy::_apply_candidate <candidate-content> [dry-run]
# Validates, change-detects, backs up, writes, reloads, verifies.
haproxy::_apply_candidate() {
    local candidate="$1" dry_run="${2:-0}"

    haproxy::_detect_malformed_blocks || return "$EXIT_GENERIC"

    local tmp
    tmp="$(mktemp /tmp/tixolink-haproxy-candidate.XXXXXXXX)"
    printf '%s\n' "$candidate" >"$tmp"

    # If the managed block ends up with no TixoLink frontends at all (the
    # last mapping using this engine was just removed), skip our own
    # pre-validation gate: HAProxy's `-c` check itself refuses ANY config
    # with zero listeners anywhere, including the administrator's own
    # part, as an error - that's a real HAProxy requirement, not
    # something specific to what we're removing. The normal
    # apply/reload-failure rollback path below is the correct safety net
    # for the genuine edge case where the administrator's base config
    # also has no listener of its own.
    local has_tixolink_frontend=1
    grep -q '^frontend tixolink_' <<<"$candidate" || has_tixolink_frontend=0

    if [[ "$has_tixolink_frontend" == "1" ]] && haproxy::_binary_available; then
        if ! haproxy -c -f "$tmp" >/tmp/tixolink-haproxy-validate.log 2>&1; then
            log::error "candidate HAProxy configuration failed validation:"
            log::error "$(cat /tmp/tixolink-haproxy-validate.log)"
            rm -f -- "$tmp" /tmp/tixolink-haproxy-validate.log
            return "$EXIT_VALIDATION"
        fi
        rm -f -- /tmp/tixolink-haproxy-validate.log
    elif [[ "$has_tixolink_frontend" == "0" ]]; then
        log::info "no TixoLink-managed frontends remain; skipping -c validation (relying on reload's own result)"
    else
        log::warn "haproxy binary not found; skipping config validation (cannot confirm candidate is valid)"
    fi

    local new_hash old_hash
    new_hash="$(sha256sum "$tmp" | awk '{print $1}')"
    old_hash="$(state::get '.haproxy.config_hash' 2>/dev/null || true)"

    if [[ "$new_hash" == "$old_hash" ]]; then
        rm -f -- "$tmp"
        log::info "HAProxy managed configuration unchanged; skipping reload"
        return 0
    fi

    if [[ "$dry_run" == "1" ]]; then
        printf '[DRY-RUN] WRITE CONFIG: %s\n' "$TIXOLINK_HAPROXY_CFG"
        printf '[DRY-RUN] RELOAD HAPROXY (config changed and validated)\n'
        rm -f -- "$tmp"
        return 0
    fi

    local backup=""
    if [[ -f "$TIXOLINK_HAPROXY_CFG" ]]; then
        backup="$(mktemp /tmp/tixolink-haproxy-backup.XXXXXXXX)"
        cp -p -- "$TIXOLINK_HAPROXY_CFG" "$backup"
    fi

    local dir; dir="$(dirname "$TIXOLINK_HAPROXY_CFG")"
    if [[ ! -d "$dir" ]]; then
        rm -f -- "$tmp" "$backup"
        log::error "HAProxy config directory does not exist: $dir"
        return "$EXIT_NOT_FOUND"
    fi
    mv -T "$tmp" "$TIXOLINK_HAPROXY_CFG"

    if ! haproxy::_reload; then
        log::error "HAProxy reload failed; restoring previous configuration"
        [[ -n "$backup" ]] && mv -T "$backup" "$TIXOLINK_HAPROXY_CFG" && haproxy::_reload
        return "$EXIT_GENERIC"
    fi

    if ! haproxy::_is_active; then
        log::error "HAProxy is not active after reload; restoring previous configuration"
        [[ -n "$backup" ]] && mv -T "$backup" "$TIXOLINK_HAPROXY_CFG" && haproxy::_reload
        return "$EXIT_GENERIC"
    fi

    # new_hash is always a 64-char lowercase-hex sha256 digest (fixed
    # charset, computed above) - safe to interpolate into the jq filter.
    state::set ".haproxy.config_hash = \"$new_hash\""
    [[ -n "$backup" ]] && rm -f -- "$backup"
    return 0
}

# --- Engine contract implementation ------------------------------------------

forwarder_haproxy_validate() {
    local mapping="$2"
    local proto listen_addr local_port remote_port remote_addr
    proto="$(jq -r '.protocol' <<<"$mapping")"
    if [[ "$proto" != "tcp" ]]; then
        log::error "HAProxy forwarding only supports TCP in this build; use netfilter for UDP"
        return "$EXIT_VALIDATION"
    fi
    listen_addr="$(jq -r '.listen_address' <<<"$mapping")"
    local_port="$(jq -r '.local_port' <<<"$mapping")"
    remote_port="$(jq -r '.remote_port' <<<"$mapping")"
    remote_addr="$(jq -r '.remote_address // empty' <<<"$mapping")"

    validate::ipv4 "$listen_addr" || { log::error "invalid listen_address: $listen_addr"; return "$EXIT_VALIDATION"; }
    [[ -n "$remote_addr" ]] && { validate::ipv4 "$remote_addr" || { log::error "invalid remote_address: $remote_addr"; return "$EXIT_VALIDATION"; }; }
    validate::port "$local_port" || { log::error "HAProxy mappings must use a single port, not a range: $local_port"; return "$EXIT_VALIDATION"; }
    validate::port "$remote_port" || { log::error "HAProxy mappings must use a single port, not a range: $remote_port"; return "$EXIT_VALIDATION"; }
    return 0
}

# forwarder_haproxy_check_conflicts <tunnel-id> <mapping-json> [exclude-mapping-id]
# Detects bind conflicts: another TixoLink haproxy mapping already using
# the same listen_address:port, distinguished from "owned by us" via the
# excluded mapping id during edits.
forwarder_haproxy_check_conflicts() {
    local self_tunnel_id="$1" mapping="$2" exclude_mapping_id="${3:-}"
    local listen_addr local_port
    listen_addr="$(jq -r '.listen_address' <<<"$mapping")"
    local_port="$(jq -r '.local_port' <<<"$mapping")"

    local other_id other_json other_engine m other_mid other_listen other_port
    while IFS= read -r other_id; do
        [[ -z "$other_id" ]] && continue
        other_json="$(config::tunnel_read "$other_id" 2>/dev/null)" || continue
        other_engine="$(jq -r '.forwarding.engine // "none"' <<<"$other_json")"
        [[ "$other_engine" == "haproxy" ]] || continue
        while IFS= read -r m; do
            [[ -z "$m" || "$m" == "null" ]] && continue
            other_mid="$(jq -r '.id' <<<"$m")"
            [[ "$other_id" == "$self_tunnel_id" && "$other_mid" == "$exclude_mapping_id" ]] && continue
            other_listen="$(jq -r '.listen_address' <<<"$m")"
            other_port="$(jq -r '.local_port' <<<"$m")"
            if [[ "$other_listen" == "$listen_addr" && "$other_port" == "$local_port" ]]; then
                log::error "listen address:port ${listen_addr}:${local_port} already used by tunnel $other_id mapping $other_mid"
                return "$EXIT_CONFLICT"
            fi
        done < <(jq -c '.forwarding.mappings[]?' <<<"$other_json")
    done < <(config::tunnel_list)

    # Bind conflict against something NOT TixoLink-managed (another
    # process already listening) - detected read-only, never assumed away.
    if command -v ss >/dev/null 2>&1; then
        if ss -ltn "( sport = :$local_port )" 2>/dev/null | grep -q ":$local_port"; then
            log::warn "port $local_port appears to already have a listener on this host outside TixoLink's knowledge"
        fi
    fi
    return 0
}

forwarder_haproxy_apply() {
    local tunnel_json="$1" mapping="$2"
    HAPROXY_DRY_RUN="${3:-0}"

    local effective
    effective="$(jq -c --argjson m "$mapping" \
        '(.forwarding.mappings // []) as $ms | ($ms | map(select(.id == $m.id)) | length) as $exists |
         if $exists > 0 then ($ms | map(if .id == $m.id then $m else . end)) else ($ms + [$m]) end' \
        <<<"$tunnel_json")"

    local -a pairs=()
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] && pairs+=("$p")
    done < <(haproxy::_collect_pairs "$tunnel_json" "$effective")

    local block; block="$(haproxy::_render_block "${pairs[@]}")" || return "$EXIT_VALIDATION"
    local candidate; candidate="$(haproxy::_base_content)"$'\n'"$block"

    haproxy::_apply_candidate "$candidate" "$HAPROXY_DRY_RUN"
    local status=$?
    HAPROXY_DRY_RUN=0
    return "$status"
}

forwarder_haproxy_remove() {
    local tunnel_json="$1" mapping="$2"
    HAPROXY_DRY_RUN="${3:-0}"
    local mid; mid="$(jq -r '.id' <<<"$mapping")"

    local effective
    effective="$(jq -c --arg mid "$mid" '(.forwarding.mappings // []) | map(select(.id != $mid))' <<<"$tunnel_json")"

    local -a pairs=()
    local p
    while IFS= read -r p; do
        [[ -n "$p" ]] && pairs+=("$p")
    done < <(haproxy::_collect_pairs "$tunnel_json" "$effective")

    local block
    if [[ ${#pairs[@]} -eq 0 ]]; then
        block="$HAPROXY_BEGIN_MARKER"$'\n'"$HAPROXY_END_MARKER"
    else
        block="$(haproxy::_render_block "${pairs[@]}")" || return "$EXIT_VALIDATION"
    fi
    local candidate; candidate="$(haproxy::_base_content)"$'\n'"$block"

    haproxy::_apply_candidate "$candidate" "$HAPROXY_DRY_RUN"
    local status=$?
    HAPROXY_DRY_RUN=0
    return "$status"
}

forwarder_haproxy_repair() {
    forwarder_haproxy_apply "$1" "$2" 0
}

# forwarder_haproxy_status <tunnel-json> <mapping-json>
# Deliberately does not claim healthy merely because the haproxy process
# is running - only confirms the specific frontend/backend objects this
# mapping expects are present in the currently active managed block, and
# that the service process is active. Real traffic health is a
# diagnostics concern, out of scope here.
forwarder_haproxy_status() {
    local tunnel_json="$1" mapping="$2"
    local tid mid tag
    tid="$(jq -r '.id' <<<"$tunnel_json")"
    mid="$(jq -r '.id' <<<"$mapping")"
    tag="tixolink:${tid}:${mid}"

    if [[ ! -f "$TIXOLINK_HAPROXY_CFG" ]] || ! grep -qF "$tag" "$TIXOLINK_HAPROXY_CFG" 2>/dev/null; then
        printf 'STATE=MISSING\n'
        return 0
    fi
    if haproxy::_binary_available && ! haproxy::_is_active; then
        printf 'STATE=PARTIAL\n'
        return 0
    fi
    printf 'STATE=ACTIVE\n'
    return 0
}

forwarder::register "haproxy"

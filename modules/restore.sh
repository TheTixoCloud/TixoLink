#!/usr/bin/env bash
# TixoLink NEXUS - restore
#
# INSPECT -> VERIFY FORMAT -> VERIFY CHECKSUMS -> CHECK SCHEMA COMPATIBILITY
# -> PREVIEW -> (confirm) -> BACKUP CURRENT STATE -> APPLY -> MIGRATE ->
# VALIDATE -> VERIFY -> COMMIT, with ROLLBACK to the automatic pre-restore
# backup on any failure from APPLY onward.
#
# An untrusted archive is never extracted over "/" and never trusted before
# its members are individually checked: no absolute paths, no ".." path
# segments, no symlink/hardlink/device entries, no duplicate checksum
# manifest entries. Extraction always lands in a private 0700 staging
# directory first; only after every check passes does anything get copied
# into /etc/tixolink or /var/lib/tixolink.

if [[ -n "${TIXOLINK_MODULE_RESTORE_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_MODULE_RESTORE_SH_LOADED=1

# restore::_new_stage
restore::_new_stage() {
    local stage; stage="$(mktemp -d "${TIXOLINK_TMP_DIR:-${TMPDIR:-/tmp}}/tixolink-restore.XXXXXXXX")"
    chmod 0700 "$stage"
    printf '%s' "$stage"
}

# restore::_validate_and_extract <archive> <out-stage-var-name>
# On success, sets the named variable to the staging directory containing
# an already-validated backup/ tree and returns 0. On failure, cleans up
# any staging directory it created and returns a non-zero EXIT_* code.
restore::_validate_and_extract() {
    local archive="$1"
    local -n _out_stage="$2"

    [[ -f "$archive" ]] || { log::error "restore: archive not found: $archive"; return "$EXIT_NOT_FOUND"; }

    local _stage; _stage="$(restore::_new_stage)"
    if ! common::tar_extract_safely "$archive" "$_stage" "backup"; then
        rm -rf -- "$_stage"
        return "$EXIT_VALIDATION"
    fi

    local root="${_stage}/backup"
    if [[ ! -d "$root" || ! -f "${root}/manifest.json" || ! -f "${root}/checksums.sha256" ]]; then
        rm -rf -- "$_stage"
        log::error "restore: archive is missing required manifest/checksums"
        return "$EXIT_VALIDATION"
    fi

    local manifest
    manifest="$(jq -e . "${root}/manifest.json" 2>/dev/null)" || { rm -rf -- "$_stage"; log::error "restore: malformed manifest.json in archive"; return "$EXIT_VALIDATION"; }

    local backup_schema; backup_schema="$(jq -r '.schema_version // 0' <<<"$manifest")"
    if (( backup_schema > TIXOLINK_BACKUP_SCHEMA_VERSION )); then
        rm -rf -- "$_stage"
        log::error "restore: backup format schema_version $backup_schema is newer than this TixoLink build supports ($TIXOLINK_BACKUP_SCHEMA_VERSION); install a newer TixoLink release"
        return "$EXIT_VALIDATION"
    fi

    # Reject duplicate manifest/checksum entries for the same path - a sign
    # of a tampered or malformed archive, never a legitimate backup.
    local dupes
    dupes="$(awk '{print $2}' "${root}/checksums.sha256" | sort | uniq -d)"
    if [[ -n "$dupes" ]]; then
        rm -rf -- "$_stage"
        log::error "restore: archive checksum manifest has duplicate entries: $dupes"
        return "$EXIT_VALIDATION"
    fi

    # Every file actually present under payload/ must be listed in
    # checksums.sha256 - an unexpected extra file is treated the same as a
    # checksum mismatch, since it was never accounted for by the backup.
    local on_disk listed
    on_disk="$(cd "$root" && find payload -type f 2>/dev/null | sort)"
    listed="$(awk '{print $2}' "${root}/checksums.sha256" | sort)"
    if [[ "$on_disk" != "$listed" ]]; then
        rm -rf -- "$_stage"
        log::error "restore: archive payload does not match its checksum manifest (unexpected or missing files)"
        return "$EXIT_VALIDATION"
    fi

    if ! ( cd "$root" && sha256sum -c checksums.sha256 --status 2>/dev/null ); then
        rm -rf -- "$_stage"
        log::error "restore: checksum verification failed; archive is corrupt or has been tampered with"
        return "$EXIT_VALIDATION"
    fi

    _out_stage="$_stage"
    return 0
}

# restore::_print_preview <root>
restore::_print_preview() {
    local root="$1" manifest
    manifest="$(jq -e . "${root}/manifest.json")"
    ui::section "Backup contents"
    printf 'Created:            %s\n' "$(jq -r '.created_at' <<<"$manifest")"
    printf 'TixoLink version:   %s\n' "$(jq -r '.tixolink_version' <<<"$manifest")"
    printf 'Config schema:      %s\n' "$(jq -r '.component_schema_versions.config' <<<"$manifest")"
    printf 'Tunnel schema:      %s\n' "$(jq -r '.component_schema_versions.tunnel' <<<"$manifest")"
    printf 'State schema:       %s\n' "$(jq -r '.component_schema_versions.state' <<<"$manifest")"
    printf 'Included:\n'
    jq -r '.included[]' <<<"$manifest" | sed 's/^/  - /'
    local n; n="$(find "${root}/payload/tunnels" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l)"
    printf 'Tunnel configs in backup: %s\n' "$n"
}

# restore::_apply_payload <root>
# Copies payload/* from a validated staging root into the real
# /etc/tixolink and /var/lib/tixolink locations, replacing the tunnels
# directory wholesale (restore is exact: a tunnel not in the backup is
# removed), then runs the migration framework over every restored
# document. Used both for the user-requested restore and internally to
# roll back to the automatic pre-restore backup on failure.
restore::_apply_payload() {
    local root="$1"
    local payload="${root}/payload"

    if [[ -f "${payload}/config.json" ]]; then
        config::write_json_atomic "$TIXOLINK_APP_CONFIG_FILE" "$(cat "${payload}/config.json")" 0640 || return "$EXIT_GENERIC"
    fi

    config::ensure_dir "$TIXOLINK_TUNNELS_DIR" 0750
    local existing
    existing="$(config::tunnel_list)"
    local f id
    for f in "${payload}/tunnels"/*.json; do
        [[ -e "$f" ]] || continue
        id="$(basename "$f" .json)"
        validate::tunnel_id "$id" || continue
        config::write_json_atomic "$(config::tunnel_path "$id")" "$(cat "$f")" 0640 || return "$EXIT_GENERIC"
    done
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        [[ -f "${payload}/tunnels/${id}.json" ]] || rm -f -- "$(config::tunnel_path "$id")"
    done <<<"$existing"

    if [[ -f "${payload}/state.json" ]]; then
        config::write_json_atomic "$TIXOLINK_STATE_FILE" "$(cat "${payload}/state.json")" 0600 || return "$EXIT_GENERIC"
    fi

    if [[ -f "${payload}/optimizer/baseline.json" || -f "${payload}/optimizer/applied.json" ]]; then
        config::ensure_dir "${TIXOLINK_VAR_DIR}/optimizer" 0750
        [[ -f "${payload}/optimizer/baseline.json" ]] && config::write_json_atomic "${TIXOLINK_VAR_DIR}/optimizer/baseline.json" "$(cat "${payload}/optimizer/baseline.json")" 0600
        [[ -f "${payload}/optimizer/applied.json" ]] && config::write_json_atomic "${TIXOLINK_VAR_DIR}/optimizer/applied.json" "$(cat "${payload}/optimizer/applied.json")" 0600
    fi

    # MIGRATE IF REQUIRED - idempotent no-op when already current.
    [[ -f "$TIXOLINK_APP_CONFIG_FILE" ]] && { migration::migrate_file config "$TIXOLINK_APP_CONFIG_FILE" 0 0640 || return $?; }
    [[ -f "$TIXOLINK_STATE_FILE" ]] && { migration::migrate_file state "$TIXOLINK_STATE_FILE" 0 0600 || return $?; }
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        migration::migrate_file tunnel "$(config::tunnel_path "$id")" 0 0640 || return $?
    done < <(config::tunnel_list)

    return 0
}

# restore::_validate_applied
# VALIDATE + VERIFY: every restored JSON document parses and is at the
# component's current schema version.
restore::_validate_applied() {
    [[ -f "$TIXOLINK_APP_CONFIG_FILE" ]] && { config::read_json "$TIXOLINK_APP_CONFIG_FILE" >/dev/null || return "$EXIT_GENERIC"; }
    [[ -f "$TIXOLINK_STATE_FILE" ]] && { config::read_json "$TIXOLINK_STATE_FILE" >/dev/null || return "$EXIT_GENERIC"; }
    local id
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        config::tunnel_read "$id" >/dev/null || return "$EXIT_GENERIC"
    done < <(config::tunnel_list)
    return 0
}

# restore::run <archive> [--force] [--dry-run]
restore::run() {
    local archive="$1"
    shift
    local force=0 dry_run=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=1; shift ;;
            --dry-run) dry_run=1; shift ;;
            *) log::error "restore: unknown option $1"; return "$EXIT_USAGE" ;;
        esac
    done

    local stage
    restore::_validate_and_extract "$archive" stage || return $?
    local root="${stage}/backup"
    # Deliberately double-quoted: $stage must expand NOW (it is a local
    # variable in this stack frame that will be gone by the time RETURN
    # fires), not re-evaluated at trap time.
    # shellcheck disable=SC2064
    trap "rm -rf -- '$stage'" RETURN

    restore::_print_preview "$root"

    if [[ "$dry_run" == "1" ]]; then
        ui::info "Dry run: no changes applied."
        return 0
    fi

    if [[ "$force" != "1" ]] && ! ui::confirm "Restore this backup now? This replaces current TixoLink configuration/state on disk only - no tunnel/forwarding is started, stopped, or reloaded by this command." "n"; then
        ui::info "Restore cancelled."
        return "$EXIT_GENERIC"
    fi

    # BACKUP CURRENT STATE before touching anything, so a failure below can
    # be rolled back to exactly this point.
    local pre_restore
    pre_restore="$(backup::create --output "${TIXOLINK_VAR_DIR}/backups/pre-restore-$(date -u '+%Y%m%dT%H%M%SZ').tar.gz")" || {
        log::error "restore: failed to snapshot current state before restoring; aborting without changes"
        return "$EXIT_GENERIC"
    }

    local status=0
    restore::_apply_payload "$root" || status=$?
    if [[ "$status" -eq 0 ]]; then
        restore::_validate_applied || status=$?
    fi

    if [[ "$status" -ne 0 ]]; then
        log::error "restore failed (exit $status); rolling back to the pre-restore snapshot"
        local rb_stage
        if restore::_validate_and_extract "$pre_restore" rb_stage; then
            restore::_apply_payload "${rb_stage}/backup" >/dev/null 2>&1
            rm -rf -- "$rb_stage"
            log::error "rollback complete: previous TixoLink state restored from $pre_restore"
        else
            log::error "rollback FAILED to re-validate the pre-restore snapshot; manual recovery needed from $pre_restore"
        fi
        return "$EXIT_ROLLED_BACK"
    fi

    log::history "restore" "-" "success"
    ui::success "Restore complete. Pre-restore snapshot kept at: $pre_restore"
    ui::info "No tunnels were started/reloaded automatically; use 'tixolink reload <id>' per tunnel as needed."
    return 0
}

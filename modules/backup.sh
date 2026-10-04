#!/usr/bin/env bash
# TixoLink NEXUS - backup
#
# Archives exactly the TixoLink-owned persistent documents needed to
# restore this host's TixoLink configuration elsewhere or after data loss:
# app config, tunnel configs, the owned-resource state ledger, and the
# optimizer baseline/applied records. Deliberately excludes everything
# else on the host (no /etc, no /var, no HAProxy config, no firewall
# rules, no runtime-only /run state) - see docs/lifecycle.md.

if [[ -n "${TIXOLINK_MODULE_BACKUP_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_MODULE_BACKUP_SH_LOADED=1

readonly TIXOLINK_BACKUP_SCHEMA_VERSION=1
readonly TIXOLINK_BACKUP_ARCHIVE_ROOT="backup"

backup::_dir() { printf '%s/backups' "$TIXOLINK_VAR_DIR"; }

# backup::_stage <staging-dir>
# Populates <staging-dir>/backup/payload with everything backup::create
# archives, and writes manifest.json + checksums.sha256 alongside it.
# Internal helper, also used by restore.sh to build the automatic
# pre-restore safety backup.
backup::_stage() {
    local stage="$1"
    local root="${stage}/${TIXOLINK_BACKUP_ARCHIVE_ROOT}"
    local payload="${root}/payload"
    install -d -m 0700 "${payload}/tunnels" "${payload}/optimizer"

    local -a included=()

    if [[ -f "$TIXOLINK_APP_CONFIG_FILE" ]]; then
        cp -p -- "$TIXOLINK_APP_CONFIG_FILE" "${payload}/config.json"
        included+=("config.json")
    fi

    local id f
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        f="$(config::tunnel_path "$id")"
        [[ -f "$f" ]] || continue
        cp -p -- "$f" "${payload}/tunnels/${id}.json"
        included+=("tunnels/${id}.json")
    done < <(config::tunnel_list)

    if [[ -f "$TIXOLINK_STATE_FILE" ]]; then
        cp -p -- "$TIXOLINK_STATE_FILE" "${payload}/state.json"
        included+=("state.json")
    fi

    local opt_baseline="${TIXOLINK_VAR_DIR}/optimizer/baseline.json"
    local opt_applied="${TIXOLINK_VAR_DIR}/optimizer/applied.json"
    if [[ -f "$opt_baseline" ]]; then
        cp -p -- "$opt_baseline" "${payload}/optimizer/baseline.json"
        included+=("optimizer/baseline.json")
    fi
    if [[ -f "$opt_applied" ]]; then
        cp -p -- "$opt_applied" "${payload}/optimizer/applied.json"
        included+=("optimizer/applied.json")
    fi

    ( cd "$root" && find payload -type f -print0 | sort -z | xargs -0 -r sha256sum ) >"${root}/checksums.sha256"

    local ts; ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    jq -nc \
        --argjson schema_version "$TIXOLINK_BACKUP_SCHEMA_VERSION" \
        --arg tixolink_version "$(common::version)" \
        --arg ts "$ts" \
        --argjson included "$(printf '%s\n' "${included[@]:-}" | jq -R -s 'split("\n") | map(select(length > 0))')" \
        --argjson config_schema "$(migration::current_version config)" \
        --argjson tunnel_schema "$(migration::current_version tunnel)" \
        --argjson state_schema "$(migration::current_version state)" \
        '{
            schema_version: $schema_version,
            tixolink_version: $tixolink_version,
            created_at: $ts,
            included: $included,
            component_schema_versions: {
                config: $config_schema, tunnel: $tunnel_schema, state: $state_schema
            }
        }' >"${root}/manifest.json"

    chmod -R go-rwx "$root"
}

# backup::create [--output <file>] [--force]
# Prints the final archive path on success.
backup::create() {
    local output="" force=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output) output="$2"; shift 2 ;;
            --force) force=1; shift ;;
            *) log::error "backup: unknown option $1"; return "$EXIT_USAGE" ;;
        esac
    done

    local dir; dir="$(backup::_dir)"
    config::ensure_dir "$dir" 0700

    if [[ -z "$output" ]]; then
        output="${dir}/tixolink-backup-$(common::version)-$(date -u '+%Y%m%dT%H%M%SZ').tar.gz"
    fi
    if [[ -e "$output" && "$force" != "1" ]]; then
        log::error "refusing to overwrite existing backup: $output (use --force)"
        return "$EXIT_CONFLICT"
    fi

    local stage; stage="$(mktemp -d "${TIXOLINK_TMP_DIR:-${TMPDIR:-/tmp}}/tixolink-backup.XXXXXXXX")"
    chmod 0700 "$stage"
    # shellcheck disable=SC2064  # intentional: expand $stage's value now, not at trap time
    trap "rm -rf -- '$stage'" RETURN

    backup::_stage "$stage" || { log::error "backup staging failed"; return "$EXIT_GENERIC"; }

    local out_dir; out_dir="$(dirname "$output")"
    [[ -d "$out_dir" ]] || { log::error "backup output directory does not exist: $out_dir"; return "$EXIT_NOT_FOUND"; }
    local tmp_archive; tmp_archive="$(mktemp "${out_dir}/.tixolink-backup.XXXXXXXX")"
    chmod 0600 "$tmp_archive"

    if ! tar --numeric-owner --owner=0 --group=0 -czf "$tmp_archive" -C "$stage" "$TIXOLINK_BACKUP_ARCHIVE_ROOT"; then
        rm -f -- "$tmp_archive"
        log::error "failed to create backup archive"
        return "$EXIT_GENERIC"
    fi
    mv -T "$tmp_archive" "$output"
    rm -rf -- "$stage"

    log::history "backup-create" "-" "success"
    printf '%s' "$output"
    return 0
}

# backup::list
# Prints one backup archive path per line, newest last.
backup::list() {
    local dir; dir="$(backup::_dir)"
    [[ -d "$dir" ]] || return 0
    find "$dir" -maxdepth 1 -name 'tixolink-backup-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null \
        | sort -n | awk '{print $2}'
}

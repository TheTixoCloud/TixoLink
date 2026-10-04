#!/usr/bin/env bash
# TixoLink NEXUS - config/state schema migration framework
#
# Every persisted document (app config, tunnel config, state ledger) carries
# an explicit integer schema_version. This file provides the ordered,
# idempotent upgrade path between versions, used by the updater and by
# restore before any migrated document is trusted.
#
# Deliberate design choices:
#   - Migrations are registered as pure functions: <json-in> on stdin/arg,
#     <json-out> on stdout, always producing schema_version = from + 1.
#     Multi-version jumps are expressed as a chain of single-step
#     migrations, never a single function spanning several versions, so
#     the ordered chain is auditable one step at a time.
#   - A document whose schema_version is NEWER than this build's current
#     version for that component is never touched: migration::upgrade
#     fails safe (EXIT_VALIDATION) rather than guessing how to downgrade it.
#   - migration::migrate_file always backs up the original file before
#     writing, and restores that backup if the post-write read-back does
#     not show exactly the expected target version.
#
# As of this build, every component (config, tunnel, state) is still at
# schema_version 1 - there is nothing to migrate yet. The registry below is
# intentionally empty in production; tests populate it with fixture
# migrations to exercise the mechanism without inventing a fake real one.

if [[ -n "${TIXOLINK_MIGRATION_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_MIGRATION_SH_LOADED=1

declare -gA TIXOLINK_MIGRATIONS_REG=()

# migration::current_version <component>
# component is one of: config, tunnel, state. Mirrors the schema_version
# constants each component's own file (config.sh / state.sh) already
# defines; kept centralized here so the updater/restore workflow has one
# place to ask "what does THIS build support".
migration::current_version() {
    case "$1" in
        config) printf '%s' "${TIXOLINK_APP_CONFIG_SCHEMA_VERSION:-1}" ;;
        tunnel) printf '%s' "${TIXOLINK_TUNNEL_SCHEMA_VERSION:-1}" ;;
        state)  printf '%s' "${TIXOLINK_STATE_SCHEMA_VERSION:-1}" ;;
        *) return "$EXIT_USAGE" ;;
    esac
}

# migration::detect_version <json>
migration::detect_version() {
    jq -r '.schema_version // 0' <<<"$1" 2>/dev/null || printf '0'
}

# migration::register <component> <from-version> <function-name>
# <function-name> must accept one JSON string argument and print the
# migrated JSON (schema_version == from-version + 1) on stdout.
migration::register() {
    local component="$1" from="$2" fn="$3"
    TIXOLINK_MIGRATIONS_REG["${component}:${from}"]="$fn"
}

# migration::_lookup <component> <from-version>
migration::_lookup() {
    printf '%s' "${TIXOLINK_MIGRATIONS_REG[${1}:${2}]:-}"
}

# migration::plan <component> <json>
# Read-only: prints one "<from> -> <to>" line per planned step without
# applying anything. Prints nothing if already current.
migration::plan() {
    local component="$1" json="$2"
    local current target fn
    current="$(migration::detect_version "$json")"
    target="$(migration::current_version "$component")"
    while (( current < target )); do
        fn="$(migration::_lookup "$component" "$current")"
        [[ -n "$fn" ]] || { log::error "no migration registered for $component from schema_version $current"; return "$EXIT_GENERIC"; }
        printf '%s -> %s\n' "$current" "$((current + 1))"
        current=$((current + 1))
    done
    return 0
}

# migration::upgrade <component> <json>
# Applies every registered migration in order, in memory, and prints the
# final JSON. Fails safe (no mutation, no partial state) if the document is
# newer than this build understands, or if a step in the chain is missing.
migration::upgrade() {
    local component="$1" json="$2"
    local current target fn next
    current="$(migration::detect_version "$json")"
    target="$(migration::current_version "$component")"

    if (( current > target )); then
        log::error "$component schema_version $current is newer than this TixoLink build supports (max $target); a newer TixoLink version is required - refusing to modify it"
        return "$EXIT_VALIDATION"
    fi

    while (( current < target )); do
        fn="$(migration::_lookup "$component" "$current")"
        if [[ -z "$fn" ]]; then
            log::error "no migration path registered for $component from schema_version $current"
            return "$EXIT_GENERIC"
        fi
        json="$("$fn" "$json")" || { log::error "migration $fn failed for $component"; return "$EXIT_GENERIC"; }
        next="$(migration::detect_version "$json")"
        if (( next != current + 1 )); then
            log::error "migration $fn produced schema_version $next, expected $((current + 1)); aborting"
            return "$EXIT_GENERIC"
        fi
        current="$next"
    done
    printf '%s' "$json"
    return 0
}

# migration::migrate_file <component> <path> [dry_run:0|1] [mode]
# BACKUP -> APPLY -> VALIDATE -> COMMIT, with automatic restore-from-backup
# on any failure after the file has been overwritten. Idempotent: a file
# already at the current version is left untouched and reported as such.
migration::migrate_file() {
    local component="$1" path="$2" dry_run="${3:-0}" mode="${4:-0640}"

    [[ -f "$path" ]] || { log::error "migrate: file not found: $path"; return "$EXIT_NOT_FOUND"; }
    local json; json="$(config::read_json "$path")" || { log::error "migrate: not valid JSON: $path"; return "$EXIT_VALIDATION"; }

    local current target
    current="$(migration::detect_version "$json")"
    target="$(migration::current_version "$component")"

    if (( current == target )); then
        log::info "no migration needed for $path (schema_version $current)"
        return 0
    fi

    if (( current > target )); then
        log::error "$path has schema_version $current, newer than this build supports ($target); install a newer TixoLink release before touching it"
        return "$EXIT_VALIDATION"
    fi

    if [[ "$dry_run" == "1" ]]; then
        log::info "PLAN for $path:"
        migration::plan "$component" "$json" | while IFS= read -r line; do log::info "  $line"; done
        return 0
    fi

    local upgraded; upgraded="$(migration::upgrade "$component" "$json")" || return $?

    local backup
    backup="${path}.pre-migration.$(date -u '+%Y%m%dT%H%M%SZ')"
    cp -p -- "$path" "$backup" || { log::error "migrate: failed to back up $path before migrating"; return "$EXIT_GENERIC"; }

    if ! config::write_json_atomic "$path" "$upgraded" "$mode"; then
        log::error "migrate: failed to write migrated $path; original left untouched"
        rm -f -- "$backup"
        return "$EXIT_GENERIC"
    fi

    local verify_json verify_v
    verify_json="$(config::read_json "$path" 2>/dev/null)" || verify_json=""
    verify_v="$(migration::detect_version "${verify_json:-\{\}}")"
    if [[ -z "$verify_json" || "$verify_v" != "$target" ]]; then
        log::error "migrate: post-write verification failed for $path; restoring pre-migration backup"
        cp -p -- "$backup" "$path"
        return "$EXIT_ROLLED_BACK"
    fi

    rm -f -- "$backup"
    log::info "migrated $path: schema_version $current -> $target"
    return 0
}

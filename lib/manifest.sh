#!/usr/bin/env bash
# TixoLink NEXUS - install manifest (ownership ledger for lifecycle operations)
#
# install.sh/uninstall.sh/modules/update.sh never assume a path is
# TixoLink-owned merely because it looks familiar (e.g. "/usr/local/bin/
# tixolink"). Ownership is only ever established by recording the exact
# path (plus a content hash, for files) in this manifest at install/upgrade
# time, and every later destructive lifecycle step (uninstall, purge,
# factory-reset, rollback) consults it before touching anything.
#
# Deliberately separate from lib/state.sh: state.sh tracks tunnel runtime
# ownership; this tracks installed-program-file ownership. Different
# lifecycle, different consumers (installer/uninstaller vs. engines).

if [[ -n "${TIXOLINK_MANIFEST_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_MANIFEST_SH_LOADED=1

readonly TIXOLINK_MANIFEST_SCHEMA_VERSION=1

# manifest::file
manifest::file() {
    printf '%s/install-manifest.json' "$TIXOLINK_VAR_DIR"
}

# manifest::exists
manifest::exists() {
    [[ -f "$(manifest::file)" ]]
}

# manifest::read
# Prints the manifest JSON, or fails with EXIT_NOT_FOUND if none exists.
manifest::read() {
    config::read_json "$(manifest::file)"
}

# manifest::write <json>
manifest::write() {
    local json="$1"
    config::ensure_dir "$TIXOLINK_VAR_DIR" 0750
    config::write_json_atomic "$(manifest::file)" "$json" 0640
}

# manifest::sha256 <file>
manifest::sha256() {
    sha256sum -- "$1" | awk '{print $1}'
}

# manifest::new <version> <bin-path> <lib-dir> <etc-dir> <var-dir> <log-dir>
#               <run-dir> <systemd-unit-path>
# Prints a fresh manifest skeleton with no files/dirs recorded yet.
manifest::new() {
    local version="$1" bin_path="$2" lib_dir="$3" etc_dir="$4" var_dir="$5" \
        log_dir="$6" run_dir="$7" systemd_unit="$8"
    local ts; ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    jq -nc \
        --argjson schema_version "$TIXOLINK_MANIFEST_SCHEMA_VERSION" \
        --arg version "$version" \
        --arg ts "$ts" \
        --arg bin_path "$bin_path" \
        --arg lib_dir "$lib_dir" \
        --arg etc_dir "$etc_dir" \
        --arg var_dir "$var_dir" \
        --arg log_dir "$log_dir" \
        --arg run_dir "$run_dir" \
        --arg systemd_unit "$systemd_unit" \
        '{
            schema_version: $schema_version,
            tixolink_version: $version,
            previous_version: null,
            installed_at: $ts,
            updated_at: $ts,
            prefix: {
                bin_path: $bin_path, lib_dir: $lib_dir, etc_dir: $etc_dir,
                var_dir: $var_dir, log_dir: $log_dir, run_dir: $run_dir,
                systemd_unit: $systemd_unit
            },
            files: [],
            dirs: []
        }'
}

# manifest::add_file <manifest-json> <path> <sha256> <mode>
manifest::add_file() {
    local json="$1" path="$2" sha256="$3" mode="$4"
    jq -c --arg path "$path" --arg sha256 "$sha256" --arg mode "$mode" \
        '.files += [{path: $path, sha256: $sha256, mode: $mode}]' <<<"$json"
}

# manifest::add_dir <manifest-json> <path>
manifest::add_dir() {
    local json="$1" path="$2"
    jq -c --arg path "$path" '.dirs = (.dirs + [$path] | unique)' <<<"$json"
}

# manifest::set_previous_version <manifest-json> <version-or-null>
manifest::set_previous_version() {
    local json="$1" version="$2"
    jq -c --arg v "$version" '.previous_version = (if $v == "" then null else $v end)' <<<"$json"
}

# manifest::bump <manifest-json> <new-version>
# Used by the updater: keeps files/dirs cleared (caller re-populates) but
# records the version transition and refreshes updated_at.
manifest::bump() {
    local json="$1" new_version="$2"
    local old_version; old_version="$(jq -r '.tixolink_version' <<<"$json")"
    local ts; ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    jq -c --arg nv "$new_version" --arg ov "$old_version" --arg ts "$ts" \
        '.previous_version = $ov | .tixolink_version = $nv | .updated_at = $ts | .files = [] | .dirs = []' \
        <<<"$json"
}

# manifest::owns_file <path>
manifest::owns_file() {
    local path="$1"
    manifest::exists || return 1
    jq -e --arg p "$path" '.files[] | select(.path == $p)' "$(manifest::file)" >/dev/null 2>&1
}

# manifest::owns_dir <path>
manifest::owns_dir() {
    local path="$1"
    manifest::exists || return 1
    jq -e --arg p "$path" '.dirs[] | select(. == $p)' "$(manifest::file)" >/dev/null 2>&1
}

# manifest::files
# Prints one recorded file path per line.
manifest::files() {
    manifest::exists || return 0
    jq -r '.files[].path' "$(manifest::file)"
}

# manifest::dirs
# Prints one recorded directory path per line, deepest first (safe removal
# order: a directory's own entry never needs its children removed first
# since files are removed independently, but nested TixoLink dirs should
# still be removed inside-out).
manifest::dirs() {
    manifest::exists || return 0
    jq -r '.dirs | sort | reverse | .[]' "$(manifest::file)"
}

# manifest::verify
# Re-hashes every recorded file and compares against the manifest. Prints
# one "OK|MISSING|MODIFIED <path>" line per file; returns non-zero if any
# file is missing or modified.
manifest::verify() {
    manifest::exists || { log::error "no install manifest found at $(manifest::file)"; return "$EXIT_NOT_FOUND"; }
    local json; json="$(manifest::read)"
    local bad=0
    local path sha256
    while IFS=$'\t' read -r path sha256; do
        [[ -z "$path" ]] && continue
        if [[ ! -f "$path" ]]; then
            printf 'MISSING\t%s\n' "$path"
            bad=1
            continue
        fi
        local actual; actual="$(manifest::sha256 "$path")"
        if [[ "$actual" != "$sha256" ]]; then
            printf 'MODIFIED\t%s\n' "$path"
            bad=1
        else
            printf 'OK\t%s\n' "$path"
        fi
    done < <(jq -r '.files[] | [.path, .sha256] | @tsv' <<<"$json")
    return "$bad"
}

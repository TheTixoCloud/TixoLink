#!/usr/bin/env bash
# TixoLink NEXUS - configuration layer (desired state)
#
# Configuration is always structured JSON, validated with jq, and written
# atomically (tmp file + rename). Never sourced, never eval'd.

if [[ -n "${TIXOLINK_CONFIG_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_CONFIG_SH_LOADED=1

readonly TIXOLINK_ETC_DIR="${TIXOLINK_ETC_DIR:-/etc/tixolink}"
readonly TIXOLINK_APP_CONFIG_FILE="${TIXOLINK_ETC_DIR}/config.json"
readonly TIXOLINK_APP_CONFIG_SCHEMA_VERSION=1
readonly TIXOLINK_DEFAULT_SUBNET_POOL="10.200.0.0/16"

# config::ensure_dir <path> <mode>
# Creates a directory (and parents) with the given mode if it does not
# already exist. Refuses to proceed through a symlink it does not expect.
config::ensure_dir() {
    local path="$1" mode="$2"
    if [[ -L "$path" ]]; then
        log::error "refusing to use symlinked path: $path"
        return "$EXIT_GENERIC"
    fi
    install -d -m "$mode" "$path"
}

# config::read_json <file>
# Prints the file's contents, compacted to a single line, if it is
# syntactically valid JSON; returns non-zero and prints nothing otherwise.
# Compact (not pretty-printed) output is required: callers pass this
# through line-oriented loops (`read -r line`) in several places, and a
# multi-line value would silently be split across multiple iterations.
config::read_json() {
    local file="$1"
    [[ -r "$file" ]] || return "$EXIT_NOT_FOUND"
    jq -ce . "$file" 2>/dev/null
}

# config::write_json_atomic <file> <json-string> [mode]
# Validates <json-string> with jq, writes it to a temp file in the same
# directory as <file>, then atomically renames it into place.
config::write_json_atomic() {
    local file="$1" json="$2" mode="${3:-0640}"
    local dir
    dir="$(dirname "$file")"
    [[ -d "$dir" ]] || config::ensure_dir "$dir" 0750

    if ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
        log::error "refusing to write invalid JSON to $file"
        return "$EXIT_VALIDATION"
    fi

    local tmp
    tmp="$(mktemp "${dir}/.tixolink.XXXXXXXX")"
    chmod "$mode" "$tmp"
    printf '%s\n' "$json" | jq -ce . >"$tmp"
    mv -T "$tmp" "$file"

    # Best-effort fsync of the directory so the rename survives a crash
    # immediately after this call; not fatal if unsupported (e.g. tmpfs).
    sync -- "$dir" 2>/dev/null || true
}

# config::app_defaults
# Prints the default application configuration as JSON.
config::app_defaults() {
    jq -nc \
        --argjson schema_version "$TIXOLINK_APP_CONFIG_SCHEMA_VERSION" \
        --arg subnet_pool "$TIXOLINK_DEFAULT_SUBNET_POOL" \
        '{schema_version: $schema_version, subnet_pool: $subnet_pool}'
}

# config::init_app_config
# Creates /etc/tixolink/config.json with defaults if it does not exist yet.
# Idempotent: does nothing if the file is already present.
config::init_app_config() {
    if [[ -f "$TIXOLINK_APP_CONFIG_FILE" ]]; then
        return 0
    fi
    config::ensure_dir "$TIXOLINK_ETC_DIR" 0750
    config::write_json_atomic "$TIXOLINK_APP_CONFIG_FILE" "$(config::app_defaults)" 0640
}

# config::get <jq-filter>
# Reads a value out of the app config via a jq filter, e.g. ".subnet_pool".
config::get() {
    local filter="$1"
    [[ -f "$TIXOLINK_APP_CONFIG_FILE" ]] || return "$EXIT_NOT_FOUND"
    jq -er "$filter" "$TIXOLINK_APP_CONFIG_FILE"
}

# --- Tunnel configuration store ---------------------------------------------
# Each tunnel's desired-state configuration lives in its own file, keyed by
# its immutable tunnel ID (never its display name).

readonly TIXOLINK_TUNNELS_DIR="${TIXOLINK_ETC_DIR}/tunnels"
# Consumed by modules/tunnel.sh (tunnel::_assemble), a different sourced
# file - SC2034 here is a false positive by design.
# shellcheck disable=SC2034
readonly TIXOLINK_TUNNEL_SCHEMA_VERSION=1

# config::tunnel_path <id>
config::tunnel_path() {
    printf '%s/%s.json' "$TIXOLINK_TUNNELS_DIR" "$1"
}

# config::tunnel_exists <id>
config::tunnel_exists() {
    [[ -f "$(config::tunnel_path "$1")" ]]
}

# config::tunnel_read <id>
# Prints the tunnel's JSON config, or fails with EXIT_NOT_FOUND.
config::tunnel_read() {
    local id="$1"
    validate::tunnel_id "$id" || return "$EXIT_VALIDATION"
    config::tunnel_exists "$id" || return "$EXIT_NOT_FOUND"
    config::read_json "$(config::tunnel_path "$id")"
}

# config::tunnel_write <id> <json>
# Atomically writes a tunnel's config. Caller is responsible for validation
# before calling this (this function only guarantees atomic, well-formed-JSON
# writes, not semantic correctness).
config::tunnel_write() {
    local id="$1" json="$2"
    validate::tunnel_id "$id" || return "$EXIT_VALIDATION"
    config::ensure_dir "$TIXOLINK_TUNNELS_DIR" 0750
    config::write_json_atomic "$(config::tunnel_path "$id")" "$json" 0640
}

# config::tunnel_delete <id>
config::tunnel_delete() {
    local id="$1"
    validate::tunnel_id "$id" || return "$EXIT_VALIDATION"
    rm -f -- "$(config::tunnel_path "$id")"
}

# config::tunnel_list
# Prints one tunnel ID per line, sorted, for every tunnel currently
# configured. Prints nothing (not an error) if the directory doesn't exist.
config::tunnel_list() {
    [[ -d "$TIXOLINK_TUNNELS_DIR" ]] || return 0
    local f base
    for f in "$TIXOLINK_TUNNELS_DIR"/*.json; do
        [[ -e "$f" ]] || continue
        base="$(basename "$f" .json)"
        validate::tunnel_id "$base" && printf '%s\n' "$base"
    done | sort
}

# config::tunnel_new_id
# Generates a random 8-hex-character ID guaranteed not to collide with any
# existing tunnel configuration.
config::tunnel_new_id() {
    local id
    local attempt
    for (( attempt=0; attempt<100; attempt++ )); do
        id="$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n' | cut -c1-8)"
        validate::tunnel_id "$id" || continue
        config::tunnel_exists "$id" || { printf '%s' "$id"; return 0; }
    done
    log::error "failed to generate a unique tunnel ID after 100 attempts"
    return "$EXIT_GENERIC"
}

# config::tunnel_find_by_name <name>
# Prints the ID of the tunnel with the given display name. Fails with
# EXIT_NOT_FOUND if none matches, EXIT_CONFLICT if more than one does
# (display names are expected to be unique but are not the identity key).
config::tunnel_find_by_name() {
    local name="$1" id found="" count=0
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        if [[ "$(config::tunnel_read "$id" | jq -r '.name')" == "$name" ]]; then
            found="$id"
            count=$((count + 1))
        fi
    done < <(config::tunnel_list)
    if [[ "$count" -eq 0 ]]; then
        return "$EXIT_NOT_FOUND"
    elif [[ "$count" -gt 1 ]]; then
        log::error "multiple tunnels share the display name '$name'; use the tunnel ID"
        return "$EXIT_CONFLICT"
    fi
    printf '%s' "$found"
}

# config::tunnel_resolve <id-or-name>
# Accepts either an immutable tunnel ID or a display name and prints the
# resolved tunnel ID.
config::tunnel_resolve() {
    local ref="$1"
    if validate::tunnel_id "$ref" && config::tunnel_exists "$ref"; then
        printf '%s' "$ref"
        return 0
    fi
    config::tunnel_find_by_name "$ref"
}

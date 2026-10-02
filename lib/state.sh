#!/usr/bin/env bash
# TixoLink NEXUS - state layer (owned-resource ledger, runtime facts)
#
# Deliberately separate from lib/config.sh: config.sh holds user-editable
# intent (what a tunnel should be), state.sh holds TixoLink-managed fact
# (what currently exists and is owned by whom). Conflating the two makes
# ownership tracking and rollback much harder to reason about.

if [[ -n "${TIXOLINK_STATE_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_STATE_SH_LOADED=1

readonly TIXOLINK_VAR_DIR="${TIXOLINK_VAR_DIR:-/var/lib/tixolink}"
readonly TIXOLINK_STATE_FILE="${TIXOLINK_VAR_DIR}/state.json"
readonly TIXOLINK_STATE_SCHEMA_VERSION=1

# state::defaults
state::defaults() {
    local ts
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    jq -nc \
        --argjson schema_version "$TIXOLINK_STATE_SCHEMA_VERSION" \
        --arg initialized_at "$ts" \
        --arg version "$(common::version)" \
        '{schema_version: $schema_version, initialized_at: $initialized_at,
          tixolink_version: $version, tunnels: {}}'
}

# state::init
# Creates /var/lib/tixolink/state.json with defaults if it does not exist.
state::init() {
    if [[ -f "$TIXOLINK_STATE_FILE" ]]; then
        return 0
    fi
    config::ensure_dir "$TIXOLINK_VAR_DIR" 0750
    config::write_json_atomic "$TIXOLINK_STATE_FILE" "$(state::defaults)" 0600
}

# state::get <jq-filter>
state::get() {
    local filter="$1"
    [[ -f "$TIXOLINK_STATE_FILE" ]] || return "$EXIT_NOT_FOUND"
    jq -er "$filter" "$TIXOLINK_STATE_FILE"
}

# state::set <jq-filter-expression>
# Applies a jq transform to the state file and writes the result back
# atomically, e.g. state::set '.tunnels["abc123"] = {"owns": []}'.
state::set() {
    local expr="$1"
    [[ -f "$TIXOLINK_STATE_FILE" ]] || state::init
    local updated
    updated="$(jq -c "$expr" "$TIXOLINK_STATE_FILE")" || return "$EXIT_GENERIC"
    config::write_json_atomic "$TIXOLINK_STATE_FILE" "$updated" 0600
}

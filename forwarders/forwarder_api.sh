#!/usr/bin/env bash
# TixoLink NEXUS - forwarding engine contract and dispatcher
#
# Mirrors engines/engine_api.sh. Contract (prefix forwarder_<name>_):
#   validate   <tunnel-json> <mapping-json>        -> pure semantic validation
#   check_conflicts <tunnel-id> <mapping-json> [exclude-mapping-id]
#   apply      <tunnel-json> <mapping-json> [dry-run:0|1]   -> idempotent
#   remove     <tunnel-json> <mapping-id> [dry-run:0|1]
#   status     <tunnel-json> <mapping-json>         -> KEY=VALUE lines
#   repair     <tunnel-json> <mapping-json>         -> re-assert drifted rules

if [[ -n "${TIXOLINK_FORWARDER_API_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_FORWARDER_API_SH_LOADED=1

declare -gA TIXOLINK_FORWARDERS=()

forwarder::register() { TIXOLINK_FORWARDERS["$1"]=1; }
forwarder::is_registered() { [[ -n "${TIXOLINK_FORWARDERS[$1]:-}" ]]; }

# forwarder::dispatch <name> <verb> [args...]
forwarder::dispatch() {
    local name="$1" verb="$2"
    shift 2
    if ! forwarder::is_registered "$name"; then
        log::error "unknown forwarding engine: $name"
        return "$EXIT_GENERIC"
    fi
    local fn="forwarder_${name}_${verb}"
    if ! declare -F "$fn" >/dev/null 2>&1; then
        log::error "forwarder '$name' does not implement verb '$verb'"
        return "$EXIT_GENERIC"
    fi
    "$fn" "$@"
}

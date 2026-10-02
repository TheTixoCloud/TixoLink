#!/usr/bin/env bash
# TixoLink NEXUS - transport engine contract and dispatcher
#
# Every engine implementation sources this file first, then registers
# itself. The dispatcher resolves `engine_<name>_<verb>` and calls it;
# modules/*.sh never call an engine's functions directly by name, only
# through engine::dispatch, so a future engine (IP6GRE, IPIP, ...) plugs in
# without any change to calling code.
#
# Contract (prefix engine_<name>_):
#   validate   <tunnel-config-json>              -> pure semantic validation
#   precheck   <tunnel-config-json>               -> host-dependent checks (e.g. local IP exists)
#   check_conflicts <id> <tunnel-config-json>     -> conflict detection against other tunnels/runtime
#   create     <id> [dry-run:0|1]                 -> idempotent
#   start|stop|restart <id> [dry-run:0|1]
#   reload     <id> [dry-run:0|1]                 -> reconcile runtime to match desired config
#   status     <id>                               -> structured KEY=VALUE lines on stdout
#   delete     <id> [dry-run:0|1]
#   export_peer <id>                              -> peer-facing engine_config fragment
#
# Not every engine must implement every optional verb; engine::dispatch
# fails clearly (EXIT_GENERIC) rather than silently if a verb is missing.

if [[ -n "${TIXOLINK_ENGINE_API_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_ENGINE_API_SH_LOADED=1

declare -gA TIXOLINK_ENGINES=()

# engine::register <name>
# Marks <name> as a known transport engine. Call once from the bottom of
# each engine file.
engine::register() {
    TIXOLINK_ENGINES["$1"]=1
}

# engine::is_registered <name>
engine::is_registered() {
    [[ -n "${TIXOLINK_ENGINES[$1]:-}" ]]
}

# engine::dispatch <name> <verb> [args...]
engine::dispatch() {
    local name="$1" verb="$2"
    shift 2
    if ! engine::is_registered "$name"; then
        log::error "unknown transport engine: $name"
        return "$EXIT_GENERIC"
    fi
    local fn="engine_${name}_${verb}"
    if ! declare -F "$fn" >/dev/null 2>&1; then
        log::error "engine '$name' does not implement verb '$verb'"
        return "$EXIT_GENERIC"
    fi
    "$fn" "$@"
}

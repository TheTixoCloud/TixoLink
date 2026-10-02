#!/usr/bin/env bash
# TixoLink NEXUS - logging (levels, terminal output, persistent log file)
#
# Must be sourced after lib/common.sh.

if [[ -n "${TIXOLINK_LOGGING_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_LOGGING_SH_LOADED=1

readonly LOG_LEVEL_ERROR=0
readonly LOG_LEVEL_WARN=1
readonly LOG_LEVEL_INFO=2
readonly LOG_LEVEL_DEBUG=3

# Terminal verbosity threshold: WARN by default, raised by --verbose/--debug.
TIXOLINK_LOG_TERMINAL_LEVEL=${TIXOLINK_LOG_TERMINAL_LEVEL:-$LOG_LEVEL_WARN}
# Persistent log file threshold: INFO+ always recorded, per architecture.
TIXOLINK_LOG_FILE_LEVEL=${TIXOLINK_LOG_FILE_LEVEL:-$LOG_LEVEL_INFO}
# Log file path; override with TIXOLINK_LOG_FILE (used by tests to avoid
# touching /var/log/tixolink).
TIXOLINK_LOG_FILE=${TIXOLINK_LOG_FILE:-/var/log/tixolink/tixolink.log}

# log::set_verbose - raise terminal threshold to INFO.
log::set_verbose() { TIXOLINK_LOG_TERMINAL_LEVEL=$LOG_LEVEL_INFO; }
# log::set_debug - raise terminal threshold to DEBUG.
log::set_debug() { TIXOLINK_LOG_TERMINAL_LEVEL=$LOG_LEVEL_DEBUG; }

# log::_emit <level-num> <level-name> <message>
log::_emit() {
    local level_num="$1" level_name="$2"
    shift 2
    local message="$*"
    local ts
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    if (( level_num <= TIXOLINK_LOG_TERMINAL_LEVEL )); then
        if [[ "$level_name" == "ERROR" || "$level_name" == "WARN" ]]; then
            printf '[%s] %s\n' "$level_name" "$message" >&2
        else
            printf '[%s] %s\n' "$level_name" "$message"
        fi
    fi

    if (( level_num <= TIXOLINK_LOG_FILE_LEVEL )); then
        local log_dir
        log_dir="$(dirname "$TIXOLINK_LOG_FILE")"
        if [[ -d "$log_dir" && -w "$log_dir" ]] || mkdir -p "$log_dir" 2>/dev/null; then
            printf '%s %s %s\n' "$ts" "$level_name" "$message" >>"$TIXOLINK_LOG_FILE" 2>/dev/null || true
        fi
    fi
}

log::error() { log::_emit "$LOG_LEVEL_ERROR" "ERROR" "$*"; }
log::warn()  { log::_emit "$LOG_LEVEL_WARN"  "WARN"  "$*"; }
log::info()  { log::_emit "$LOG_LEVEL_INFO"  "INFO"  "$*"; }
log::debug() { log::_emit "$LOG_LEVEL_DEBUG" "DEBUG" "$*"; }

# log::history <operation> <tunnel-id> <result>
# Appends a single JSON line to the operation history audit trail. This is a
# distinct stream from the free-text debug log (see docs/architecture.md).
log::history() {
    local operation="$1" tunnel_id="$2" result="$3"
    # Deliberately resolved at call time, not at source time: lib/logging.sh
    # is sourced before lib/state.sh sets TIXOLINK_VAR_DIR, and defaulting
    # to a hardcoded /var/lib/tixolink path here (ignoring a sandboxed
    # TIXOLINK_VAR_DIR override used by tests) would leak test data onto
    # the real host, as happened before this fix.
    local history_file="${TIXOLINK_HISTORY_FILE:-${TIXOLINK_VAR_DIR:-/var/lib/tixolink}/history.jsonl}"
    local history_dir
    history_dir="$(dirname "$history_file")"
    [[ -d "$history_dir" ]] || mkdir -p "$history_dir" 2>/dev/null || return 0
    local ts
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    jq -nc \
        --arg ts "$ts" \
        --arg operation "$operation" \
        --arg tunnel_id "$tunnel_id" \
        --arg result "$result" \
        '{timestamp: $ts, operation: $operation, tunnel_id: $tunnel_id, result: $result}' \
        >>"$history_file" 2>/dev/null || true
}

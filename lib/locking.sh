#!/usr/bin/env bash
# TixoLink NEXUS - locking (flock-based mutual exclusion for state changes)

if [[ -n "${TIXOLINK_LOCKING_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_LOCKING_SH_LOADED=1

readonly TIXOLINK_RUN_DIR="${TIXOLINK_RUN_DIR:-/run/tixolink}"
readonly TIXOLINK_LOCK_DIR="${TIXOLINK_RUN_DIR}/locks"
readonly TIXOLINK_DEFAULT_LOCK_TIMEOUT=10

declare -gA TIXOLINK_LOCK_FDS=()

# locking::_path <name>
locking::_path() {
    printf '%s/%s.lock' "$TIXOLINK_LOCK_DIR" "$1"
}

# locking::acquire <name> [timeout-seconds]
# Acquires an exclusive lock named <name>. Returns EXIT_LOCK_TIMEOUT if it
# cannot be obtained within the timeout. Safe to call once per <name> per
# process; a second call for the same name while held will deadlock the
# caller against itself by design (locks are not re-entrant).
locking::acquire() {
    local name="$1" timeout="${2:-$TIXOLINK_DEFAULT_LOCK_TIMEOUT}"
    config::ensure_dir "$TIXOLINK_LOCK_DIR" 0750
    local lock_path
    lock_path="$(locking::_path "$name")"

    local fd
    exec {fd}>"$lock_path"
    if ! flock -w "$timeout" -x "$fd"; then
        exec {fd}>&-
        log::error "timed out waiting for lock: $name"
        return "$EXIT_LOCK_TIMEOUT"
    fi
    TIXOLINK_LOCK_FDS["$name"]="$fd"
    return 0
}

# locking::release <name>
locking::release() {
    local name="$1"
    local fd="${TIXOLINK_LOCK_FDS[$name]:-}"
    [[ -n "$fd" ]] || return 0
    flock -u "$fd" 2>/dev/null || true
    # `exec {fd}<&-` closes whatever descriptor number the "fd" variable
    # currently holds - no eval needed, and nothing here is user-controlled
    # input in any case (fd is always a small integer bash itself assigned).
    exec {fd}<&- 2>/dev/null || true
    unset 'TIXOLINK_LOCK_FDS[$name]'
}

# locking::with_lock <name> <timeout> <command...>
# Acquires the named lock, runs the command, always releases the lock
# afterwards (even if the command fails), and propagates its exit status.
locking::with_lock() {
    local name="$1" timeout="$2"
    shift 2
    locking::acquire "$name" "$timeout" || return $?
    local status=0
    "$@" || status=$?
    locking::release "$name"
    return "$status"
}

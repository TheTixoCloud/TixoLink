#!/usr/bin/env bash
# TixoLink NEXUS - transaction framework
#
# PRECHECK -> BACKUP -> PLAN -> APPLY -> VERIFY -> COMMIT, with ROLLBACK on
# any failure after APPLY has started. Callers supply small functions for
# each stage; this file owns sequencing, the lock, the transaction workdir,
# and rollback-on-failure.

if [[ -n "${TIXOLINK_TRANSACTION_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_TRANSACTION_SH_LOADED=1

TIXOLINK_TX_DIR=""
TIXOLINK_TX_LOCK_NAME=""
TIXOLINK_TX_DRY_RUN=0

# tx::begin <lock-name> [timeout]
# Acquires the named lock and creates a fresh transaction workdir. Must be
# paired with tx::commit or tx::rollback.
tx::begin() {
    local lock_name="$1" timeout="${2:-$TIXOLINK_DEFAULT_LOCK_TIMEOUT}"
    locking::acquire "$lock_name" "$timeout" || return $?
    TIXOLINK_TX_LOCK_NAME="$lock_name"

    local tx_root="${TIXOLINK_RUN_DIR}/tx"
    config::ensure_dir "$tx_root" 0750
    TIXOLINK_TX_DIR="$(mktemp -d "${tx_root}/tx.XXXXXXXX")"
    chmod 0700 "$TIXOLINK_TX_DIR"
    return 0
}

# tx::set_dry_run <0|1>
tx::set_dry_run() {
    TIXOLINK_TX_DRY_RUN="$1"
}

# tx::is_dry_run
tx::is_dry_run() {
    [[ "$TIXOLINK_TX_DRY_RUN" == "1" ]]
}

# tx::workdir
tx::workdir() {
    printf '%s' "$TIXOLINK_TX_DIR"
}

# tx::precheck <fn> [args...]
# <fn> must return 0 to proceed; any non-zero aborts the transaction (no
# rollback needed yet, since nothing has been changed).
tx::precheck() {
    "$@"
}

# tx::backup <fn> [args...]
# <fn> should copy whatever state tx::rollback will need into tx::workdir.
tx::backup() {
    "$@"
}

# tx::plan <fn> [args...]
# <fn> computes/prints the intended operations. Used for --dry-run display.
tx::plan() {
    "$@"
}

# tx::apply <fn> [args...]
# Performs the actual mutation. Skipped entirely when tx::is_dry_run.
tx::apply() {
    if tx::is_dry_run; then
        return 0
    fi
    "$@"
}

# tx::verify <fn> [args...]
# Skipped when tx::is_dry_run (nothing was applied to verify).
tx::verify() {
    if tx::is_dry_run; then
        return 0
    fi
    "$@"
}

# tx::commit
# Discards the transaction workdir and releases the lock. Call only after
# verify has succeeded.
tx::commit() {
    [[ -n "$TIXOLINK_TX_DIR" ]] && rm -rf -- "$TIXOLINK_TX_DIR"
    [[ -n "$TIXOLINK_TX_LOCK_NAME" ]] && locking::release "$TIXOLINK_TX_LOCK_NAME"
    TIXOLINK_TX_DIR=""
    TIXOLINK_TX_LOCK_NAME=""
}

# tx::rollback <fn> [args...]
# Runs the caller's rollback function (restoring from tx::workdir), then
# releases resources the same way tx::commit does.
tx::rollback() {
    local status=0
    if [[ $# -gt 0 ]]; then
        "$@" || status=$?
    fi
    [[ -n "$TIXOLINK_TX_DIR" ]] && rm -rf -- "$TIXOLINK_TX_DIR"
    [[ -n "$TIXOLINK_TX_LOCK_NAME" ]] && locking::release "$TIXOLINK_TX_LOCK_NAME"
    TIXOLINK_TX_DIR=""
    TIXOLINK_TX_LOCK_NAME=""
    return "$status"
}

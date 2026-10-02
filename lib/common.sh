#!/usr/bin/env bash
# TixoLink NEXUS - common utilities (strict-mode helpers, exit codes, cleanup traps)
#
# This file must be sourced, never executed directly.

if [[ -n "${TIXOLINK_COMMON_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_COMMON_SH_LOADED=1

set -Eeuo pipefail

# --- Exit code contract -----------------------------------------------------
# These are the only exit codes TixoLink's CLI dispatcher emits. Module
# functions return one of these values; only lib/cli.sh calls `exit`.
# Consumed across every other sourced file, so ShellCheck's single-file
# analysis can't see the uses - SC2034 below is a false positive by design.
# shellcheck disable=SC2034
readonly EXIT_OK=0 EXIT_GENERIC=1 EXIT_USAGE=2 EXIT_VALIDATION=3 \
    EXIT_CONFLICT=4 EXIT_NOT_FOUND=5 EXIT_PERMISSION=6 EXIT_DEPENDENCY=7 \
    EXIT_LOCK_TIMEOUT=8 EXIT_ROLLED_BACK=9

# --- Version -----------------------------------------------------------------
# common::version prints the installed TixoLink version. The VERSION file is
# looked up both as a sibling of lib/ (installed layout, where packaging
# copies VERSION alongside the library files) and one directory above lib/
# (development checkout layout, where VERSION lives at the repo root).
common::version() {
    local candidate
    for candidate in "$TIXOLINK_LIB_DIR/VERSION" "$TIXOLINK_LIB_DIR/../VERSION"; do
        if [[ -r "$candidate" ]]; then
            head -n1 "$candidate"
            return 0
        fi
    done
    echo "unknown"
    return 1
}

# --- Error reporting ----------------------------------------------------------
# common::die <exit-code> <message...>
# Logs the message as ERROR (if logging.sh is loaded) and exits with the
# given code. Falls back to plain stderr if logging.sh has not been sourced.
common::die() {
    local code="$1"
    shift
    if declare -F log::error >/dev/null 2>&1; then
        log::error "$*"
    else
        printf 'ERROR: %s\n' "$*" >&2
    fi
    exit "$code"
}

# --- Cleanup / signal handling ------------------------------------------------
declare -ga TIXOLINK_CLEANUP_FNS=()

# common::register_cleanup <function-name>
# Registers a function to run on EXIT/INT/TERM, in reverse order of
# registration (LIFO), so cleanup mirrors acquisition order.
common::register_cleanup() {
    TIXOLINK_CLEANUP_FNS+=("$1")
}

common::_run_cleanup() {
    local i
    for (( i=${#TIXOLINK_CLEANUP_FNS[@]}-1; i>=0; i-- )); do
        "${TIXOLINK_CLEANUP_FNS[$i]}" || true
    done
}

trap 'common::_run_cleanup' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Safe temp files -----------------------------------------------------------
# common::mktemp_file [template]
# Creates a private temp file under a TixoLink-owned directory and registers
# it for cleanup. Never relies on predictable names.
common::mktemp_file() {
    local base="${TIXOLINK_TMP_DIR:-${TMPDIR:-/tmp}}"
    local file
    file="$(mktemp "${base}/tixolink.XXXXXXXX")"
    chmod 0600 "$file"
    TIXOLINK_TMP_FILES+=("$file")
    printf '%s' "$file"
}
declare -ga TIXOLINK_TMP_FILES=()
common::_cleanup_tmp_files() {
    local f
    for f in "${TIXOLINK_TMP_FILES[@]:-}"; do
        [[ -n "$f" && -e "$f" ]] && rm -f -- "$f"
    done
}
common::register_cleanup common::_cleanup_tmp_files

# --- Misc helpers --------------------------------------------------------------
# common::require_root
# Returns EXIT_PERMISSION (non-fatal, caller decides what to do) when not
# running as root.
common::require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        return "$EXIT_PERMISSION"
    fi
    return 0
}

# common::trim <string>
# Prints the string with leading/trailing whitespace removed.
common::trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# common::lower <string>
common::lower() {
    printf '%s' "${1,,}"
}

# common::join <sep> <args...>
common::join() {
    local sep="$1"
    shift
    local out=""
    local item
    local first=1
    for item in "$@"; do
        if [[ $first -eq 1 ]]; then
            out="$item"
            first=0
        else
            out="${out}${sep}${item}"
        fi
    done
    printf '%s' "$out"
}

# common::is_integer <string>
common::is_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

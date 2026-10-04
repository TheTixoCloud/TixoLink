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

# --- Safe archive extraction ---------------------------------------------------
# Resource limits for any archive this process did not create itself
# (a backup handed to `restore`, a release artifact downloaded by
# `update`). Centralized here, not duplicated per call site, and
# deliberately overridable (same test-seam pattern as
# TIXOLINK_SYSCTL_D_FILE) so tests can exercise rejection with tiny
# archives instead of needing to actually build multi-megabyte fixtures.
#
# Chosen against what TixoLink itself ever legitimately produces: a
# backup is a handful of small JSON documents (realistically under 1 MiB
# even with hundreds of tunnels); a release artifact is this project's own
# source tree (a few hundred '*.sh'/doc files, a few MiB at most). Each
# limit below is roughly two orders of magnitude above that reality -
# generous enough to never bite a legitimate archive, nowhere near large
# enough to let a hostile one turn "verify a backup" into "fill the disk"
# or "peg a CPU for an hour."
TIXOLINK_ARCHIVE_MAX_COMPRESSED_BYTES="${TIXOLINK_ARCHIVE_MAX_COMPRESSED_BYTES:-67108864}"   # 64 MiB, checked before tar ever runs
TIXOLINK_ARCHIVE_MAX_ENTRIES="${TIXOLINK_ARCHIVE_MAX_ENTRIES:-5000}"
TIXOLINK_ARCHIVE_MAX_FILE_BYTES="${TIXOLINK_ARCHIVE_MAX_FILE_BYTES:-52428800}"                # 50 MiB per regular file
TIXOLINK_ARCHIVE_MAX_TOTAL_BYTES="${TIXOLINK_ARCHIVE_MAX_TOTAL_BYTES:-209715200}"             # 200 MiB declared uncompressed total

# common::tar_extract_safely <archive> <dest-dir> <expected-root>
# Shared by modules/restore.sh and modules/update.sh, the two places that
# ever extract an archive that did not originate from this process.
# Everything is checked BEFORE a single byte is extracted:
#   - the compressed file itself is bounded (cheap stat(), checked first,
#     before tar ever touches the file);
#   - the member listing is bounded (entry count) and every path is
#     checked for duplicates, absolute paths, ".." traversal, and
#     containment under <expected-root> ("*" accepts any top-level name,
#     for release artifacts whose directory name varies by version);
#   - the verbose listing's declared per-entry type and size are used to
#     reject symlink/hardlink/device/fifo/socket entries and to bound
#     both the largest single regular file and the declared total
#     uncompressed size - all computed from tar's own metadata, never by
#     writing anything to disk first. A size field that isn't a plain
#     non-negative integer is treated as a rejection, not as zero: this
#     function fails closed on anything it cannot confidently parse.
# <dest-dir> must already exist and be empty; on any failure it is left
# untouched (caller owns removing it) and EXIT_VALIDATION is returned.
common::tar_extract_safely() {
    local archive="$1" dest="$2" expected_root="$3"

    local compressed_bytes
    compressed_bytes="$(stat -c '%s' "$archive" 2>/dev/null)" || { log::error "cannot stat archive: $archive"; return "$EXIT_VALIDATION"; }
    if [[ ! "$compressed_bytes" =~ ^[0-9]+$ ]]; then
        log::error "archive size could not be determined; refusing to process: $archive"
        return "$EXIT_VALIDATION"
    fi
    if (( compressed_bytes > TIXOLINK_ARCHIVE_MAX_COMPRESSED_BYTES )); then
        log::error "archive exceeds maximum compressed size ($compressed_bytes > $TIXOLINK_ARCHIVE_MAX_COMPRESSED_BYTES bytes): $archive"
        return "$EXIT_VALIDATION"
    fi

    local listing
    listing="$(tar -tzf "$archive" 2>/dev/null)" || { log::error "not a valid gzip tar archive: $archive"; return "$EXIT_VALIDATION"; }
    [[ -n "$listing" ]] || { log::error "archive is empty: $archive"; return "$EXIT_VALIDATION"; }

    local entry_count
    entry_count="$(wc -l <<<"$listing")"
    if (( entry_count > TIXOLINK_ARCHIVE_MAX_ENTRIES )); then
        log::error "archive exceeds maximum entry count ($entry_count > $TIXOLINK_ARCHIVE_MAX_ENTRIES): $archive"
        return "$EXIT_VALIDATION"
    fi

    local dupes
    dupes="$(sort <<<"$listing" | uniq -d)"
    if [[ -n "$dupes" ]]; then
        log::error "archive contains duplicate member paths (possible extraction-order smuggling): $dupes"
        return "$EXIT_VALIDATION"
    fi

    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ "$line" == /* ]]; then
            log::error "archive contains an absolute path: $line"
            return "$EXIT_VALIDATION"
        fi
        if [[ "$line" == *".."* ]]; then
            log::error "archive contains a path-traversal entry: $line"
            return "$EXIT_VALIDATION"
        fi
        if [[ "$expected_root" != "*" && "$line" != "$expected_root" && "$line" != "${expected_root}/"* ]]; then
            log::error "archive contains an entry outside the expected ${expected_root}/ root: $line"
            return "$EXIT_VALIDATION"
        fi
    done <<<"$listing"

    local vline vtype vsize total_bytes=0
    while IFS= read -r vline; do
        [[ -z "$vline" ]] && continue
        vtype="${vline:0:1}"
        case "$vtype" in
            -|d) ;; # regular file or directory: fine
            *)
                log::error "archive contains a non-regular entry (symlink/hardlink/device/fifo/socket): $vline"
                return "$EXIT_VALIDATION"
                ;;
        esac

        if [[ "$vtype" == "-" ]]; then
            vsize="$(awk '{print $3}' <<<"$vline")"
            if [[ ! "$vsize" =~ ^[0-9]+$ ]]; then
                log::error "archive entry has an unparseable declared size; refusing to trust it: $vline"
                return "$EXIT_VALIDATION"
            fi
            if (( vsize > TIXOLINK_ARCHIVE_MAX_FILE_BYTES )); then
                log::error "archive entry exceeds maximum single-file size ($vsize > $TIXOLINK_ARCHIVE_MAX_FILE_BYTES bytes): $vline"
                return "$EXIT_VALIDATION"
            fi
            total_bytes=$(( total_bytes + vsize ))
            if (( total_bytes > TIXOLINK_ARCHIVE_MAX_TOTAL_BYTES )); then
                log::error "archive exceeds maximum total declared uncompressed size ($total_bytes > $TIXOLINK_ARCHIVE_MAX_TOTAL_BYTES bytes)"
                return "$EXIT_VALIDATION"
            fi
        fi
    done < <(tar -tvzf "$archive" 2>/dev/null)

    if ! tar -xzf "$archive" -C "$dest" --no-same-owner --no-same-permissions 2>/dev/null; then
        log::error "failed to extract archive: $archive"
        return "$EXIT_VALIDATION"
    fi
    return 0
}

# --- Destructive-path safety --------------------------------------------------
# common::assert_safe_delete_path <path>
# The one gate every `rm -rf` of a directory variable in install.sh,
# uninstall.sh, and lifecycle::factory_reset must pass first. Refuses any
# path that isn't resolvable, any path on a short denylist of real
# filesystem roots (so a blank/misconfigured TIXOLINK_ROOT or env override
# can never turn into "rm -rf /etc"), and any path whose final component
# is not literally "tixolink" (every directory TixoLink ever recursively
# removes is named .../tixolink or is itself that directory).
common::assert_safe_delete_path() {
    local path="$1"
    [[ -n "$path" ]] || { log::error "refusing to delete: empty path"; return "$EXIT_GENERIC"; }

    local resolved; resolved="$(realpath -m "$path" 2>/dev/null)" || { log::error "refusing to delete: unresolvable path $path"; return "$EXIT_GENERIC"; }

    case "$resolved" in
        /|/etc|/var|/var/lib|/var/log|/usr|/usr/local|/usr/local/bin|/usr/local/lib|/run|/home|/root|/bin|/sbin|/lib|/opt|/srv|/tmp)
            log::error "refusing to delete a protected system path: $resolved"
            return "$EXIT_GENERIC"
            ;;
    esac

    local depth; depth="$(tr -cd '/' <<<"$resolved" | wc -c)"
    if (( depth < 3 )); then
        log::error "refusing to delete a path this close to the filesystem root: $resolved"
        return "$EXIT_GENERIC"
    fi

    if [[ "$(basename "$resolved")" != "tixolink" ]]; then
        log::error "refusing to delete a path not owned by name: $resolved"
        return "$EXIT_GENERIC"
    fi

    return 0
}

# common::safe_rm_rf <path>
# common::assert_safe_delete_path, then rm -rf. The only sanctioned way to
# recursively remove a TixoLink-owned directory anywhere in this codebase.
common::safe_rm_rf() {
    local path="$1"
    common::assert_safe_delete_path "$path" || return $?
    [[ -e "$path" ]] || return 0
    rm -rf -- "$path"
}

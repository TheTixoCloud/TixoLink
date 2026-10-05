#!/usr/bin/env bash
# TixoLink NEXUS - public one-command bootstrap installer.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/TheTixoCloud/TixoLink/master/TixoLink.sh)
#
# This script is deliberately small and does NOT reimplement the
# application installer. It only: checks the host is supported, resolves
# which published GitHub Release to install (see "Release selection"
# below), downloads that release's tixolink-<version>.tar.gz + SHA256SUMS,
# verifies the archive's checksum and internal structure BEFORE extracting
# anything, then delegates the actual install/upgrade/downgrade-refusal
# transaction to the verified package's own install.sh --force - the same
# authoritative lifecycle used by `tixolink update apply` (modules/update.sh).
# It never runs a second unverified "curl | bash", never clones the repo,
# and never installs from a working tree.
#
# Trust model: SHA256 verifies the downloaded bytes match what the release
# published. It does NOT authenticate that the release channel itself is
# uncompromised - see docs/lifecycle.md's updater trust-model section,
# which applies identically here.
#
# Release selection:
#   TIXOLINK_CHANNEL=stable   (default) latest non-prerelease GitHub Release.
#                             Refuses to fall back to a prerelease - if no
#                             stable release is published yet, this fails
#                             with an explicit message rather than silently
#                             installing a release candidate.
#   TIXOLINK_CHANNEL=rc       latest published prerelease (release candidate).
#   TIXOLINK_VERSION=X.Y.Z[-rcN]  install exactly this version, bypassing
#                             channel resolution and the GitHub API entirely
#                             (deterministic release-asset URL).
#
# Every value taken from the network or the environment is treated as
# untrusted: version strings are matched against a strict allowlist regex
# before ever being used in a path, filename, or URL, and nothing
# downloaded is ever eval'd, sourced, or used to build a command line.

set -Eeuo pipefail

readonly TIXOLINK_REPO="TheTixoCloud/TixoLink"
readonly TIXOLINK_VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9]+)?$'

# Resource limits mirrored from lib/common.sh:common::tar_extract_safely -
# this script cannot source that file (it does not exist on the target yet),
# so the same bounds are reimplemented standalone rather than relaxed.
readonly TIXOLINK_BOOT_MAX_COMPRESSED_BYTES=67108864   # 64 MiB
readonly TIXOLINK_BOOT_MAX_ENTRIES=5000
readonly TIXOLINK_BOOT_MAX_FILE_BYTES=52428800         # 50 MiB
readonly TIXOLINK_BOOT_MAX_TOTAL_BYTES=209715200       # 200 MiB

bootstrap::die() {
    printf 'TixoLink.sh: ERROR: %s\n' "$1" >&2
    return 1
}

bootstrap::info() {
    printf 'TixoLink.sh: %s\n' "$1"
}

# --- Test seams --------------------------------------------------------------
# Every seam below has a safe, real-host default and is only ever
# overridden by redefining the function after `source`-ing this script
# (the same pattern modules/update.sh uses for update::_http_get). None of
# these are configurable via the public environment-variable UX.
bootstrap::_current_uid() { id -u; }
bootstrap::_os_release_file() { printf '/etc/os-release'; }
bootstrap::_arch() { uname -m; }
bootstrap::_has_curl() { command -v curl >/dev/null 2>&1; }
bootstrap::_curl_supports_https() { curl --version 2>/dev/null | head -n1 | grep -qi https; }
bootstrap::_apt_install() { DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$1" >/dev/null 2>&1; }
bootstrap::_apt_update() { apt-get update -qq >/dev/null 2>&1; }
# Extra args appended to the verified package's install.sh invocation.
# Production default: none. Tests override this to inject --root <sandbox>
# so no sandbox test ever touches the real host filesystem.
bootstrap::_install_extra_args() { :; }
bootstrap::http_get() { curl -fL --proto '=https' --tlsv1.2 --max-time 15 "$1" 2>/dev/null; }
bootstrap::http_get_file() { curl -fL --proto '=https' --tlsv1.2 --max-time 120 -o "$2" "$1" 2>/dev/null; }

# --- Preflight checks ---------------------------------------------------------

bootstrap::require_root() {
    [[ "$(bootstrap::_current_uid)" == "0" ]] || { bootstrap::die "must be run as root"; return 1; }
}

bootstrap::check_os() {
    local os_release_path id="unknown" version="unknown"
    os_release_path="$(bootstrap::_os_release_file)"
    if [[ -r "$os_release_path" ]]; then
        # shellcheck disable=SC1090,SC1091
        id="$(. "$os_release_path" 2>/dev/null; printf '%s' "${ID:-unknown}")"
        # shellcheck disable=SC1090,SC1091
        version="$(. "$os_release_path" 2>/dev/null; printf '%s' "${VERSION_ID:-unknown}")"
    fi
    case "$id" in
        ubuntu) [[ "$version" == "22.04" || "$version" == "24.04" ]] && return 0 ;;
        debian) [[ "$version" == "12" ]] && return 0 ;;
    esac
    bootstrap::die "unsupported OS: $id $version (supported: Ubuntu 22.04/24.04, Debian 12)"
    return 1
}

bootstrap::check_arch() {
    local arch; arch="$(bootstrap::_arch)"
    case "$arch" in
        x86_64|amd64) return 0 ;;
    esac
    bootstrap::die "unsupported architecture: $arch (supported: amd64/x86_64)"
    return 1
}

bootstrap::check_curl() {
    bootstrap::_has_curl || { bootstrap::die "curl is required and was not found"; return 1; }
    bootstrap::_curl_supports_https || { bootstrap::die "installed curl has no HTTPS support"; return 1; }
    return 0
}

# bootstrap::ensure_command <command> <apt-package>
bootstrap::ensure_command() {
    local cmd="$1" pkg="$2"
    command -v "$cmd" >/dev/null 2>&1 && return 0
    bootstrap::_apt_update
    bootstrap::_apt_install "$pkg"
    command -v "$cmd" >/dev/null 2>&1 || { bootstrap::die "required command '$cmd' is missing and could not be installed (package: $pkg)"; return 1; }
}

bootstrap::valid_version() {
    [[ "$1" =~ $TIXOLINK_VERSION_RE ]]
}

# --- Release selection ---------------------------------------------------------

bootstrap::resolve_stable() {
    bootstrap::ensure_command jq jq || return 1
    local json; json="$(bootstrap::http_get "https://api.github.com/repos/${TIXOLINK_REPO}/releases/latest")"
    if [[ -z "$json" ]]; then
        bootstrap::die "no stable TixoLink release is published yet. Use TIXOLINK_CHANNEL=rc or TIXOLINK_VERSION=<version> to install a release candidate."
        return 1
    fi
    jq -e . >/dev/null 2>&1 <<<"$json" || { bootstrap::die "malformed response from GitHub while resolving the stable release"; return 1; }
    local apierr; apierr="$(jq -r '.message // empty' <<<"$json")"
    if [[ -n "$apierr" ]]; then
        bootstrap::die "GitHub API error resolving stable release: $apierr"
        return 1
    fi
    local prerelease; prerelease="$(jq -r '.prerelease // false' <<<"$json")"
    if [[ "$prerelease" == "true" ]]; then
        bootstrap::die "the latest GitHub release is marked prerelease; refusing to install it on the stable channel"
        return 1
    fi
    local tag; tag="$(jq -r '.tag_name // empty' <<<"$json")"
    [[ -n "$tag" ]] || { bootstrap::die "GitHub response is missing tag_name"; return 1; }
    local version="${tag#v}"
    bootstrap::valid_version "$version" || { bootstrap::die "unexpected version string from GitHub: $version"; return 1; }
    printf '%s' "$version"
}

bootstrap::resolve_rc() {
    bootstrap::ensure_command jq jq || return 1
    local json; json="$(bootstrap::http_get "https://api.github.com/repos/${TIXOLINK_REPO}/releases?per_page=10")"
    [[ -n "$json" ]] || { bootstrap::die "could not reach GitHub to resolve the rc channel"; return 1; }
    jq -e . >/dev/null 2>&1 <<<"$json" || { bootstrap::die "malformed response from GitHub while resolving the rc channel"; return 1; }
    local tag; tag="$(jq -r '[.[] | select(.prerelease==true and .draft==false)][0].tag_name // empty' <<<"$json")"
    [[ -n "$tag" ]] || { bootstrap::die "no release-candidate build is currently published"; return 1; }
    local version="${tag#v}"
    bootstrap::valid_version "$version" || { bootstrap::die "unexpected version string from GitHub: $version"; return 1; }
    printf '%s' "$version"
}

bootstrap::resolve_version() {
    if [[ -n "${TIXOLINK_VERSION:-}" ]]; then
        bootstrap::valid_version "$TIXOLINK_VERSION" || { bootstrap::die "invalid TIXOLINK_VERSION: $TIXOLINK_VERSION"; return 1; }
        printf '%s' "$TIXOLINK_VERSION"
        return 0
    fi
    case "${TIXOLINK_CHANNEL:-stable}" in
        stable) bootstrap::resolve_stable ;;
        rc) bootstrap::resolve_rc ;;
        *) bootstrap::die "invalid TIXOLINK_CHANNEL: ${TIXOLINK_CHANNEL} (must be 'stable' or 'rc')"; return 1 ;;
    esac
}

# --- Checksum verification ----------------------------------------------------

# bootstrap::verify_checksum <archive-file> <sums-file> <expected-name>
bootstrap::verify_checksum() {
    local archive="$1" sums="$2" name="$3"
    local escaped; escaped="$(printf '%s' "$name" | sed 's/[.[\*^$]/\\&/g')"
    local matches; matches="$(grep -E "^[0-9a-f]{64}[[:space:]]+\*?${escaped}\$" "$sums" || true)"
    [[ -n "$matches" ]] || { bootstrap::die "SHA256SUMS has no entry for $name"; return 1; }
    local count; count="$(wc -l <<<"$matches")"
    if (( count > 1 )); then
        bootstrap::die "SHA256SUMS has multiple/conflicting entries for $name"
        return 1
    fi
    local expected; expected="$(awk '{print $1}' <<<"$matches")"
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || { bootstrap::die "malformed hash in SHA256SUMS for $name"; return 1; }
    local actual; actual="$(sha256sum "$archive" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        bootstrap::die "checksum mismatch for $name (expected $expected, got $actual)"
        return 1
    fi
    return 0
}

# --- Safe archive extraction ---------------------------------------------------
# Standalone equivalent of lib/common.sh:common::tar_extract_safely (not
# available pre-install). Everything is checked before a single byte is
# extracted. <expected_root> must match exactly (no "*" wildcard here - the
# version, and therefore the expected top-level directory name, is already
# known and validated by this point).
bootstrap::extract_safely() {
    local archive="$1" dest="$2" expected_root="$3"

    local compressed_bytes
    compressed_bytes="$(stat -c '%s' "$archive" 2>/dev/null)" || { bootstrap::die "cannot stat archive: $archive"; return 1; }
    [[ "$compressed_bytes" =~ ^[0-9]+$ ]] || { bootstrap::die "archive size could not be determined"; return 1; }
    if (( compressed_bytes > TIXOLINK_BOOT_MAX_COMPRESSED_BYTES )); then
        bootstrap::die "archive exceeds maximum compressed size ($compressed_bytes > $TIXOLINK_BOOT_MAX_COMPRESSED_BYTES bytes)"
        return 1
    fi

    local listing
    listing="$(tar -tzf "$archive" 2>/dev/null)" || { bootstrap::die "not a valid gzip tar archive"; return 1; }
    [[ -n "$listing" ]] || { bootstrap::die "archive is empty"; return 1; }

    local entry_count; entry_count="$(wc -l <<<"$listing")"
    if (( entry_count > TIXOLINK_BOOT_MAX_ENTRIES )); then
        bootstrap::die "archive exceeds maximum entry count ($entry_count > $TIXOLINK_BOOT_MAX_ENTRIES)"
        return 1
    fi

    local dupes; dupes="$(sort <<<"$listing" | uniq -d)"
    if [[ -n "$dupes" ]]; then
        bootstrap::die "archive contains duplicate member paths: $dupes"
        return 1
    fi

    local line
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ "$line" == /* ]]; then
            bootstrap::die "archive contains an absolute path: $line"
            return 1
        fi
        if [[ "$line" == *".."* ]]; then
            bootstrap::die "archive contains a path-traversal entry: $line"
            return 1
        fi
        if [[ "$line" != "$expected_root" && "$line" != "${expected_root}/"* ]]; then
            bootstrap::die "archive contains an entry outside the expected ${expected_root}/ root: $line"
            return 1
        fi
    done <<<"$listing"

    local vline vtype vsize total_bytes=0
    while IFS= read -r vline; do
        [[ -z "$vline" ]] && continue
        vtype="${vline:0:1}"
        case "$vtype" in
            -|d) ;;
            *)
                bootstrap::die "archive contains a non-regular entry (symlink/hardlink/device/fifo/socket): $vline"
                return 1
                ;;
        esac
        if [[ "$vtype" == "-" ]]; then
            vsize="$(awk '{print $3}' <<<"$vline")"
            [[ "$vsize" =~ ^[0-9]+$ ]] || { bootstrap::die "archive entry has an unparseable declared size: $vline"; return 1; }
            if (( vsize > TIXOLINK_BOOT_MAX_FILE_BYTES )); then
                bootstrap::die "archive entry exceeds maximum single-file size ($vsize > $TIXOLINK_BOOT_MAX_FILE_BYTES bytes): $vline"
                return 1
            fi
            total_bytes=$(( total_bytes + vsize ))
            if (( total_bytes > TIXOLINK_BOOT_MAX_TOTAL_BYTES )); then
                bootstrap::die "archive exceeds maximum total declared uncompressed size ($total_bytes > $TIXOLINK_BOOT_MAX_TOTAL_BYTES bytes)"
                return 1
            fi
        fi
    done < <(tar -tvzf "$archive" 2>/dev/null)

    if ! tar -xzf "$archive" -C "$dest" --no-same-owner --no-same-permissions 2>/dev/null; then
        bootstrap::die "failed to extract archive"
        return 1
    fi
    return 0
}

# --- Main ----------------------------------------------------------------------

bootstrap::main() {
    bootstrap::require_root || return 1
    bootstrap::check_os || return 1
    bootstrap::check_arch || return 1
    bootstrap::check_curl || return 1
    bootstrap::ensure_command tar tar || return 1
    bootstrap::ensure_command sha256sum coreutils || return 1

    local version
    version="$(bootstrap::resolve_version)" || return 1
    local tag="v${version}"
    local archive_name="tixolink-${version}.tar.gz"
    local pkg_root_name="tixolink-${version}"

    bootstrap::info "Installing TixoLink NEXUS ${version} from ${TIXOLINK_REPO}@${tag}..."

    local tmp
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/tixolink-bootstrap.XXXXXXXX")" || { bootstrap::die "failed to create a temporary directory"; return 1; }
    chmod 0700 "$tmp"
    # shellcheck disable=SC2064  # $tmp must expand now, not at trap time
    trap "rm -rf -- '$tmp'" RETURN

    local archive_url="https://github.com/${TIXOLINK_REPO}/releases/download/${tag}/${archive_name}"
    local sums_url="https://github.com/${TIXOLINK_REPO}/releases/download/${tag}/SHA256SUMS"
    local archive_tmp="$tmp/$archive_name" sums_tmp="$tmp/SHA256SUMS"

    if ! bootstrap::http_get_file "$archive_url" "$archive_tmp" || [[ ! -s "$archive_tmp" ]]; then
        bootstrap::die "failed to download release artifact: $archive_name (release $tag may not exist or be reachable)"
        return 1
    fi
    if ! bootstrap::http_get_file "$sums_url" "$sums_tmp" || [[ ! -s "$sums_tmp" ]]; then
        bootstrap::die "failed to download SHA256SUMS for $tag"
        return 1
    fi

    bootstrap::verify_checksum "$archive_tmp" "$sums_tmp" "$archive_name" || return 1
    bootstrap::info "Checksum verified."

    local extract="$tmp/extract"
    install -d -m 0700 "$extract"
    bootstrap::extract_safely "$archive_tmp" "$extract" "$pkg_root_name" || return 1

    local pkg_root="$extract/$pkg_root_name"
    if [[ ! -d "$pkg_root" || -L "$pkg_root" ]]; then
        bootstrap::die "release package is missing its expected ${pkg_root_name}/ directory"
        return 1
    fi
    if [[ ! -f "$pkg_root/install.sh" || -L "$pkg_root/install.sh" ]]; then
        bootstrap::die "release package is missing install.sh"
        return 1
    fi
    if [[ ! -f "$pkg_root/VERSION" || -L "$pkg_root/VERSION" ]]; then
        bootstrap::die "release package is missing VERSION"
        return 1
    fi
    local pkg_version; pkg_version="$(head -n1 "$pkg_root/VERSION")"
    if [[ "$pkg_version" != "$version" ]]; then
        bootstrap::die "release package reports version $pkg_version, expected $version"
        return 1
    fi
    chmod 0755 "$pkg_root/install.sh"

    local -a extra_args=()
    local extra_line
    while IFS= read -r extra_line; do
        [[ -n "$extra_line" ]] && extra_args+=("$extra_line")
    done < <(bootstrap::_install_extra_args)

    bootstrap::info "Verified. Running the release installer..."
    if ! "$pkg_root/install.sh" --force "${extra_args[@]}"; then
        bootstrap::die "installer failed; see output above (TixoLink was not left half-installed - install.sh rolls back program files on its own failure path)"
        return 1
    fi

    if ! command -v tixolink >/dev/null 2>&1; then
        bootstrap::die "install.sh reported success but 'tixolink' is not on PATH; installation cannot be considered complete"
        return 1
    fi

    local installed_version
    if ! installed_version="$(tixolink version 2>/dev/null)"; then
        bootstrap::die "install.sh reported success but 'tixolink version' failed to run"
        return 1
    fi
    if [[ "$installed_version" != "$version" ]]; then
        bootstrap::die "install.sh reported success but 'tixolink version' reports $installed_version, expected $version"
        return 1
    fi

    bootstrap::info "Installation complete."
    printf 'Run:\n  tixolink\n'
    return 0
}

if [[ "${BASH_SOURCE[0]:-}" == "${0}" ]]; then
    bootstrap::main "$@"
    exit $?
fi

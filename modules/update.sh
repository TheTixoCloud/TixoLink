#!/usr/bin/env bash
# TixoLink NEXUS - updater (GitHub Releases)
#
# Updates are explicit, versioned GitHub Releases only - never
# `git pull origin main`, never an arbitrary branch HEAD. A release
# publishes exactly one <name>.tar.gz source-tree artifact plus a
# "checksums.sha256" asset; update::apply verifies the downloaded archive's
# SHA256 against that manifest before anything is extracted, then delegates
# the actual filesystem change to the extracted package's own install.sh,
# reusing its PRECHECK/BACKUP/STAGE/VALIDATE/ACTIVATE/VERIFY/COMMIT
# transaction and rollback instead of duplicating it here.
#
# Trust model: SHA256 verifies the download matches what the release
# published - it does NOT authenticate that the release channel itself is
# uncompromised (an attacker who can edit the GitHub release can republish
# a matching checksum for a malicious archive). There is no artifact
# signing in this build; see docs/lifecycle.md for how that could be added
# later without changing this command surface.
#
# All network access goes through update::_http_get, the single seam
# tests override to serve local fixtures instead of reaching GitHub.

if [[ -n "${TIXOLINK_MODULE_UPDATE_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_MODULE_UPDATE_SH_LOADED=1

readonly TIXOLINK_UPDATE_REPO="${TIXOLINK_UPDATE_REPO:-TheTixoCloud/TixoLink}"

# update::_http_get <url>
# Prints the response body on stdout; returns non-zero on any transport
# failure (no network, DNS failure, timeout, GitHub unavailable). Tests
# override this function to serve fixture content for known URLs.
update::_http_get() {
    command -v curl >/dev/null 2>&1 || { log::error "update: curl is required and not installed"; return "$EXIT_DEPENDENCY"; }
    curl -fsSL --max-time 15 "$1" 2>/dev/null
}

# update::_http_get_file <url> <dest-file>
update::_http_get_file() {
    local url="$1" dest="$2"
    update::_http_get "$url" >"$dest"
}

# update::_version_compare <a> <b>
# Prints -1, 0, or 1. Numeric dotted components compare numerically; a
# "-suffix" (e.g. "-dev", "-rc1") sorts BEFORE the same bare numeric
# version, since it denotes a pre-release of that version. Two different
# suffixes on the same numeric version compare lexically - a deliberately
# simple rule, not a full SemVer precedence implementation.
update::_version_compare() {
    local a="${1#v}" b="${2#v}"
    local a_num="${a%%-*}" b_num="${b%%-*}"
    local a_suf="" b_suf=""
    [[ "$a" == *-* ]] && a_suf="${a#*-}"
    [[ "$b" == *-* ]] && b_suf="${b#*-}"

    local -a av bv
    IFS='.' read -r -a av <<<"$a_num"
    IFS='.' read -r -a bv <<<"$b_num"
    local i max=${#av[@]}
    (( ${#bv[@]} > max )) && max=${#bv[@]}
    for (( i=0; i<max; i++ )); do
        local x="${av[i]:-0}" y="${bv[i]:-0}"
        x="${x//[!0-9]/}"; y="${y//[!0-9]/}"
        x="${x:-0}"; y="${y:-0}"
        if (( 10#$x < 10#$y )); then printf -- '-1'; return 0; fi
        if (( 10#$x > 10#$y )); then printf '1'; return 0; fi
    done

    if [[ -z "$a_suf" && -n "$b_suf" ]]; then printf '1'; return 0; fi
    if [[ -n "$a_suf" && -z "$b_suf" ]]; then printf -- '-1'; return 0; fi
    if [[ "$a_suf" == "$b_suf" ]]; then printf '0'; return 0; fi
    [[ "$a_suf" < "$b_suf" ]] && { printf -- '-1'; return 0; }
    printf '1'
}

# update::check
# Prints a JSON object describing the current/latest/available state.
# Fails (non-zero) only on a transport/parse error - "no update available"
# is a successful, informative result, not an error.
update::check() {
    local current; current="$(common::version)"
    local json; json="$(update::_http_get "https://api.github.com/repos/${TIXOLINK_UPDATE_REPO}/releases/latest")"
    if [[ -z "$json" ]]; then
        log::error "update check: could not reach GitHub (network/DNS failure or timeout)"
        return "$EXIT_GENERIC"
    fi
    if ! jq -e . >/dev/null 2>&1 <<<"$json"; then
        log::error "update check: malformed response from GitHub"
        return "$EXIT_GENERIC"
    fi

    local tag; tag="$(jq -r '.tag_name // empty' <<<"$json")"
    if [[ -z "$tag" ]]; then
        local msg; msg="$(jq -r '.message // "unknown error"' <<<"$json")"
        log::error "update check: GitHub API error: $msg"
        return "$EXIT_GENERIC"
    fi

    local latest="${tag#v}"
    local cmp; cmp="$(update::_version_compare "$latest" "$current")"
    local available="false"
    [[ "$cmp" == "1" ]] && available="true"

    jq -nc \
        --arg current "$current" --arg latest "$latest" \
        --argjson available "$available" \
        --arg url "$(jq -r '.html_url // ""' <<<"$json")" \
        --arg notes "$(jq -r '.body // ""' <<<"$json")" \
        '{current_version: $current, latest_version: $latest, update_available: $available, release_url: $url, release_notes: $notes}'
}

# update::_select_asset <release-json> <name-suffix>
update::_select_asset() {
    jq -c --arg suf "$2" '[.assets[]? | select(.name | endswith($suf))][0] // empty' <<<"$1"
}

# update::apply [--force] [--dry-run]
update::apply() {
    local force=0 dry_run=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=1; shift ;;
            --dry-run) dry_run=1; shift ;;
            *) log::error "update: unknown option $1"; return "$EXIT_USAGE" ;;
        esac
    done

    local check; check="$(update::check)" || return $?
    local available; available="$(jq -r '.update_available' <<<"$check")"
    local current latest
    current="$(jq -r '.current_version' <<<"$check")"
    latest="$(jq -r '.latest_version' <<<"$check")"

    if [[ "$available" != "true" ]]; then
        ui::info "Already up to date (current: $current, latest published: $latest)."
        return 0
    fi

    local release_json; release_json="$(update::_http_get "https://api.github.com/repos/${TIXOLINK_UPDATE_REPO}/releases/latest")"

    local archive_asset checksum_asset
    archive_asset="$(update::_select_asset "$release_json" ".tar.gz")"
    checksum_asset="$(update::_select_asset "$release_json" "checksums.sha256")"

    if [[ -z "$archive_asset" ]]; then
        log::error "update: release $latest does not publish a .tar.gz artifact; refusing to update"
        return "$EXIT_GENERIC"
    fi
    if [[ -z "$checksum_asset" ]]; then
        log::error "update: release $latest does not publish a checksums.sha256 manifest; refusing to update"
        return "$EXIT_GENERIC"
    fi

    local archive_name archive_url checksum_url
    archive_name="$(jq -r '.name' <<<"$archive_asset")"
    archive_url="$(jq -r '.browser_download_url' <<<"$archive_asset")"
    checksum_url="$(jq -r '.browser_download_url' <<<"$checksum_asset")"

    if [[ "$dry_run" == "1" ]]; then
        ui::section "Update plan"
        printf 'Current:  %s\nTarget:   %s\nArtifact: %s\n' "$current" "$latest" "$archive_name"
        return 0
    fi

    if [[ "$force" != "1" ]] && ! ui::confirm "Update TixoLink $current -> $latest now?" "n"; then
        ui::info "Update cancelled."
        return "$EXIT_GENERIC"
    fi

    local work; work="$(mktemp -d "${TIXOLINK_TMP_DIR:-${TMPDIR:-/tmp}}/tixolink-update.XXXXXXXX")"
    chmod 0700 "$work"
    # shellcheck disable=SC2064  # $work must expand now, not at trap time
    trap "rm -rf -- '$work'" RETURN

    local archive_tmp="${work}/${archive_name}" checksum_tmp="${work}/checksums.sha256"
    if ! update::_http_get_file "$archive_url" "$archive_tmp" || [[ ! -s "$archive_tmp" ]]; then
        log::error "update: failed to download $archive_name"
        return "$EXIT_GENERIC"
    fi
    if ! update::_http_get_file "$checksum_url" "$checksum_tmp" || [[ ! -s "$checksum_tmp" ]]; then
        log::error "update: failed to download checksums.sha256"
        return "$EXIT_GENERIC"
    fi

    local expected; expected="$(awk -v n="$archive_name" '$2==n {print $1}' "$checksum_tmp" | head -n1)"
    if [[ -z "$expected" ]]; then
        log::error "update: checksums.sha256 does not list an entry for $archive_name"
        return "$EXIT_GENERIC"
    fi
    local actual; actual="$(sha256sum "$archive_tmp" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
        log::error "update: checksum mismatch for $archive_name (expected $expected, got $actual); refusing to install"
        return "$EXIT_VALIDATION"
    fi

    local extract="${work}/extract"
    install -d -m 0700 "$extract"
    if ! common::tar_extract_safely "$archive_tmp" "$extract" "*"; then
        return "$EXIT_VALIDATION"
    fi

    local pkg_root; pkg_root="$(find "$extract" -mindepth 1 -maxdepth 1 -type d | head -n1)"
    [[ -z "$pkg_root" ]] && pkg_root="$extract"

    if [[ ! -x "${pkg_root}/install.sh" || ! -f "${pkg_root}/VERSION" ]]; then
        log::error "update: downloaded package does not have the expected layout (missing install.sh/VERSION)"
        return "$EXIT_VALIDATION"
    fi
    local pkg_version; pkg_version="$(head -n1 "${pkg_root}/VERSION")"
    if [[ "$pkg_version" != "$latest" ]]; then
        log::error "update: downloaded package reports version $pkg_version, expected $latest; refusing to install"
        return "$EXIT_VALIDATION"
    fi

    ui::info "Verified and staged $archive_name; invoking package installer for the upgrade transaction..."
    if ! "${pkg_root}/install.sh" --force; then
        log::error "update: upgrade transaction failed; install.sh has already rolled back program files on its own failure path"
        return "$EXIT_GENERIC"
    fi

    local installed_version; installed_version="$(common::version)"
    if [[ "$installed_version" != "$latest" ]]; then
        log::error "update: post-install version check failed (expected $latest, got $installed_version)"
        return "$EXIT_GENERIC"
    fi

    log::history "update-apply" "-" "success"
    ui::success "Updated TixoLink $current -> $latest."
    return 0
}

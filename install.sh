#!/usr/bin/env bash
# TixoLink NEXUS installer.
#
# PRECHECK -> PLAN -> BACKUP EXISTING INSTALL IF PRESENT -> STAGE ->
# VALIDATE -> ACTIVATE -> VERIFY -> COMMIT, with ROLLBACK of program files
# to their pre-run state on any VERIFY failure. Never touches
# /etc/tixolink or /var/lib/tixolink contents except to create them with
# defaults if they do not already exist - existing configuration is never
# overwritten.
#
# This installs from THIS checkout/source tree, not from a remote URL.
# There is no "curl | bash" step anywhere in this script or in the
# updater (modules/update.sh) that calls it.
#
# For sandboxed testing, set TIXOLINK_ROOT (or pass --root) to install
# under a private prefix instead of the real host filesystem - see
# docs/lifecycle.md and tests/integration/test_lifecycle_sandbox.sh.

set -Eeuo pipefail

SELF_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

install::usage() {
    cat <<'EOF'
Usage: install.sh [options]

  --force, --yes       Skip the interactive confirmation.
  --dry-run            Show the installation plan and exit; change nothing.
  --allow-downgrade    Permit installing an older version than is currently
                        installed (still refuses if on-disk schema is newer
                        than the older version supports).
  --root <path>        Install under <path> instead of the real filesystem
                        root (equivalent to setting TIXOLINK_ROOT). Intended
                        for sandboxed testing only.
  -h, --help           Show this help text.
EOF
}

for c in jq tar sha256sum realpath cp mv; do
    command -v "$c" >/dev/null 2>&1 || { echo "ERROR: required command not found: $c" >&2; exit 7; }
done

FORCE=0
DRY_RUN=0
ALLOW_DOWNGRADE=0
ROOT_FLAG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force|--yes) FORCE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --allow-downgrade) ALLOW_DOWNGRADE=1; shift ;;
        --root) ROOT_FLAG="$2"; shift 2 ;;
        -h|--help) install::usage; exit 0 ;;
        *) echo "ERROR: unknown option: $1" >&2; install::usage; exit 2 ;;
    esac
done

TIXOLINK_ROOT="${ROOT_FLAG:-${TIXOLINK_ROOT:-}}"

export TIXOLINK_ETC_DIR="${TIXOLINK_ROOT}/etc/tixolink"
export TIXOLINK_VAR_DIR="${TIXOLINK_ROOT}/var/lib/tixolink"
export TIXOLINK_RUN_DIR="${TIXOLINK_ROOT}/run/tixolink"
LOG_DIR="${TIXOLINK_ROOT}/var/log/tixolink"
export TIXOLINK_LOG_FILE="${LOG_DIR}/tixolink.log"

INSTALL_BIN_PATH="${TIXOLINK_ROOT}/usr/local/bin/tixolink"
INSTALL_LIB_DIR="${TIXOLINK_ROOT}/usr/local/lib/tixolink"
SYSTEMD_UNIT_PATH="${TIXOLINK_ROOT}/etc/systemd/system/tixolink@.service"

export TIXOLINK_LIB_DIR="$SELF_DIR/lib"

# shellcheck source=lib/common.sh
source "$SELF_DIR/lib/common.sh"
# shellcheck source=lib/logging.sh
source "$SELF_DIR/lib/logging.sh"
# shellcheck source=lib/ui.sh
source "$SELF_DIR/lib/ui.sh"
# shellcheck source=lib/validation.sh
source "$SELF_DIR/lib/validation.sh"
# shellcheck source=lib/platform.sh
source "$SELF_DIR/lib/platform.sh"
# shellcheck source=lib/dependency.sh
source "$SELF_DIR/lib/dependency.sh"
# shellcheck source=lib/locking.sh
source "$SELF_DIR/lib/locking.sh"
# shellcheck source=lib/config.sh
source "$SELF_DIR/lib/config.sh"
# shellcheck source=lib/state.sh
source "$SELF_DIR/lib/state.sh"
# shellcheck source=lib/manifest.sh
source "$SELF_DIR/lib/manifest.sh"
# shellcheck source=lib/migration.sh
source "$SELF_DIR/lib/migration.sh"

SOURCE_VERSION="$(head -n1 "$SELF_DIR/VERSION")"

# install::_vcmp <a> <b> - prints -1/0/1. Deliberately duplicated (not
# sourced from modules/update.sh) so install.sh works standalone even
# before modules/ exists on a brand-new target.
install::_vcmp() {
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
        x="${x//[!0-9]/}"; y="${y//[!0-9]/}"; x="${x:-0}"; y="${y:-0}"
        if (( 10#$x < 10#$y )); then printf -- '-1'; return; fi
        if (( 10#$x > 10#$y )); then printf '1'; return; fi
    done
    if [[ -z "$a_suf" && -n "$b_suf" ]]; then printf '1'; return; fi
    if [[ -n "$a_suf" && -z "$b_suf" ]]; then printf -- '-1'; return; fi
    if [[ "$a_suf" == "$b_suf" ]]; then printf '0'; return; fi

    local a_pre="$a_suf" a_dig="" b_pre="$b_suf" b_dig=""
    [[ "$a_suf" =~ ^([a-zA-Z]*)([0-9]+)$ ]] && { a_pre="${BASH_REMATCH[1]}"; a_dig="${BASH_REMATCH[2]}"; }
    [[ "$b_suf" =~ ^([a-zA-Z]*)([0-9]+)$ ]] && { b_pre="${BASH_REMATCH[1]}"; b_dig="${BASH_REMATCH[2]}"; }
    if [[ -n "$a_dig" && -n "$b_dig" && "$a_pre" == "$b_pre" ]]; then
        if (( 10#$a_dig < 10#$b_dig )); then printf -- '-1'; return; fi
        if (( 10#$a_dig > 10#$b_dig )); then printf '1'; return; fi
        printf '0'; return
    fi

    [[ "$a_suf" < "$b_suf" ]] && { printf -- '-1'; return; }
    printf '1'
}

# --- PRECHECK ------------------------------------------------------------------
if [[ -z "$TIXOLINK_ROOT" ]]; then
    common::require_root || common::die "$EXIT_PERMISSION" "install.sh must be run as root (use --root/TIXOLINK_ROOT only for sandboxed testing)"
fi

if ! platform::is_supported_os && [[ "$FORCE" != "1" ]]; then
    ui::warning "Unsupported OS: $(platform::os_id) $(platform::os_version) (supported: Ubuntu 22.04/24.04, Debian 12). Re-run with --force to continue anyway."
    [[ "$DRY_RUN" != "1" ]] && exit "$EXIT_USAGE"
fi

MISSING_REQUIRED="$(dependency::missing required || true)"

MANIFEST_PRESENT=0
manifest::exists && MANIFEST_PRESENT=1
INSTALLED_VERSION=""
[[ "$MANIFEST_PRESENT" == "1" ]] && INSTALLED_VERSION="$(jq -r '.tixolink_version' "$(manifest::file)" 2>/dev/null || true)"

INSTALL_KIND="fresh"
if [[ -n "$INSTALLED_VERSION" ]]; then
    case "$(install::_vcmp "$SOURCE_VERSION" "$INSTALLED_VERSION")" in
        0)  INSTALL_KIND="reinstall" ;;
        1)  INSTALL_KIND="upgrade" ;;
        -1) INSTALL_KIND="downgrade" ;;
    esac
fi

if [[ "$INSTALL_KIND" == "downgrade" ]]; then
    [[ "$ALLOW_DOWNGRADE" == "1" ]] || common::die "$EXIT_USAGE" "refusing to downgrade installed TixoLink $INSTALLED_VERSION to $SOURCE_VERSION without --allow-downgrade"

    if [[ -f "$TIXOLINK_APP_CONFIG_FILE" ]]; then
        v="$(migration::detect_version "$(cat "$TIXOLINK_APP_CONFIG_FILE")")"
        s="$(migration::current_version config)"
        (( v > s )) && common::die "$EXIT_VALIDATION" "installed config schema_version $v is newer than $SOURCE_VERSION supports ($s); refusing downgrade"
    fi
    if [[ -f "$TIXOLINK_STATE_FILE" ]]; then
        v="$(migration::detect_version "$(cat "$TIXOLINK_STATE_FILE")")"
        s="$(migration::current_version state)"
        (( v > s )) && common::die "$EXIT_VALIDATION" "installed state schema_version $v is newer than $SOURCE_VERSION supports ($s); refusing downgrade"
    fi
    if [[ -d "$TIXOLINK_TUNNELS_DIR" ]]; then
        for tf in "$TIXOLINK_TUNNELS_DIR"/*.json; do
            [[ -e "$tf" ]] || continue
            v="$(migration::detect_version "$(cat "$tf")")"
            s="$(migration::current_version tunnel)"
            (( v > s )) && common::die "$EXIT_VALIDATION" "tunnel config $tf has schema_version $v newer than $SOURCE_VERSION supports ($s); refusing downgrade"
        done
    fi
fi

# --- PLAN ------------------------------------------------------------------
ui::section "TixoLink NEXUS install plan"
printf 'Kind:          %s\n' "$INSTALL_KIND"
printf 'Version:       %s' "$SOURCE_VERSION"
[[ -n "$INSTALLED_VERSION" ]] && printf ' (currently installed: %s)' "$INSTALLED_VERSION"
printf '\n'
printf 'Binary:        %s\n' "$INSTALL_BIN_PATH"
printf 'Library dir:   %s\n' "$INSTALL_LIB_DIR"
printf 'Config dir:    %s (preserved if already present)\n' "$TIXOLINK_ETC_DIR"
printf 'State dir:     %s (preserved if already present)\n' "$TIXOLINK_VAR_DIR"
printf 'Systemd unit:  %s\n' "$SYSTEMD_UNIT_PATH"
if [[ -n "$MISSING_REQUIRED" ]]; then
    printf 'Missing required dependencies (apt): %s\n' "$(tr '\n' ' ' <<<"$MISSING_REQUIRED")"
fi
printf 'No tunnels will be started automatically by this install.\n'

if [[ "$DRY_RUN" == "1" ]]; then
    ui::info "Dry run: no changes made."
    exit 0
fi

if [[ "$FORCE" != "1" ]]; then
    if [[ -t 0 && -t 1 ]]; then
        ui::confirm "Proceed with installation?" "n" || common::die "$EXIT_GENERIC" "Installation cancelled."
    else
        common::die "$EXIT_USAGE" "non-interactive install requires --force/--yes"
    fi
fi

if [[ -n "$MISSING_REQUIRED" ]]; then
    if [[ -n "$TIXOLINK_ROOT" ]]; then
        ui::warning "Sandboxed install: skipping apt-get install of: $(tr '\n' ' ' <<<"$MISSING_REQUIRED")"
    else
        dependency::ensure required || common::die "$EXIT_DEPENDENCY" "failed to install required dependencies"
    fi
fi

# --- STAGE -------------------------------------------------------------------
install -d -m 0755 "$(dirname "$INSTALL_LIB_DIR")"
STAGE_DIR="$(mktemp -d "$(dirname "$INSTALL_LIB_DIR")/.tixolink-lib.XXXXXXXX")"
cp -p "$SELF_DIR"/lib/*.sh "$STAGE_DIR"/
cp -a "$SELF_DIR/engines" "$STAGE_DIR/engines"
cp -a "$SELF_DIR/forwarders" "$STAGE_DIR/forwarders"
cp -a "$SELF_DIR/modules" "$STAGE_DIR/modules"
cp -p "$SELF_DIR/VERSION" "$STAGE_DIR/VERSION"

# --- VALIDATE ------------------------------------------------------------------
VALIDATE_FAILED=0
while IFS= read -r -d '' f; do
    bash -n "$f" || VALIDATE_FAILED=1
done < <(find "$STAGE_DIR" -name '*.sh' -print0)
if [[ "$VALIDATE_FAILED" == "1" ]]; then
    rm -rf -- "$STAGE_DIR"
    common::die "$EXIT_GENERIC" "staged package failed syntax validation; nothing was activated"
fi

if command -v systemd-analyze >/dev/null 2>&1; then
    # Informational only: systemd-analyze verify legitimately reports the
    # ExecStart binary as missing until this very install finishes, so a
    # non-zero exit here does not abort the install - it only surfaces a
    # genuine unit *syntax* problem to read in the output.
    systemd-analyze verify "$SELF_DIR/systemd/tixolink@.service" 2>&1 | sed 's/^/[systemd-analyze] /' || true
fi

# --- ACTIVATE ------------------------------------------------------------------
OLD_LIB_BACKUP=""
if [[ -d "$INSTALL_LIB_DIR" ]]; then
    OLD_LIB_BACKUP="${INSTALL_LIB_DIR}.old.$$"
    mv -T "$INSTALL_LIB_DIR" "$OLD_LIB_BACKUP"
fi
mv -T "$STAGE_DIR" "$INSTALL_LIB_DIR"

install -d -m 0755 "$(dirname "$INSTALL_BIN_PATH")"
OLD_BIN_BACKUP=""
if [[ -f "$INSTALL_BIN_PATH" ]]; then
    OLD_BIN_BACKUP="${INSTALL_BIN_PATH}.old.$$"
    mv -T "$INSTALL_BIN_PATH" "$OLD_BIN_BACKUP"
fi
NEW_BIN_TMP="$(mktemp "$(dirname "$INSTALL_BIN_PATH")/.tixolink-bin.XXXXXXXX")"
cp -p "$SELF_DIR/bin/tixolink" "$NEW_BIN_TMP"
chmod 0755 "$NEW_BIN_TMP"
mv -T "$NEW_BIN_TMP" "$INSTALL_BIN_PATH"

config::ensure_dir "$TIXOLINK_ETC_DIR" 0750
config::ensure_dir "$TIXOLINK_VAR_DIR" 0750
config::ensure_dir "${TIXOLINK_VAR_DIR}/backups" 0700
config::ensure_dir "${TIXOLINK_VAR_DIR}/optimizer" 0750
install -d -m 0750 "$LOG_DIR"
install -d -m 0750 "$TIXOLINK_RUN_DIR"
config::init_app_config
state::init

install -d -m 0755 "$(dirname "$SYSTEMD_UNIT_PATH")"
UNIT_CHANGED=0
if [[ ! -f "$SYSTEMD_UNIT_PATH" ]] || ! cmp -s "$SELF_DIR/systemd/tixolink@.service" "$SYSTEMD_UNIT_PATH"; then
    UNIT_TMP="$(mktemp "$(dirname "$SYSTEMD_UNIT_PATH")/.tixolink-unit.XXXXXXXX")"
    cp -p "$SELF_DIR/systemd/tixolink@.service" "$UNIT_TMP"
    chmod 0644 "$UNIT_TMP"
    mv -T "$UNIT_TMP" "$SYSTEMD_UNIT_PATH"
    UNIT_CHANGED=1
fi

install::rollback() {
    log::error "rolling back program files to their pre-install state"
    [[ -d "$INSTALL_LIB_DIR" ]] && common::safe_rm_rf "$INSTALL_LIB_DIR"
    if [[ -n "$OLD_LIB_BACKUP" ]]; then mv -T "$OLD_LIB_BACKUP" "$INSTALL_LIB_DIR"; fi
    rm -f -- "$INSTALL_BIN_PATH"
    if [[ -n "$OLD_BIN_BACKUP" ]]; then mv -T "$OLD_BIN_BACKUP" "$INSTALL_BIN_PATH"; fi
    log::error "rollback complete; program files restored to their pre-install state (config/state were never touched)"
}

# --- VERIFY --------------------------------------------------------------------
VERIFY_OK=1
INSTALLED_CLI_VERSION="$(
    TIXOLINK_LIB_DIR="$INSTALL_LIB_DIR" \
    TIXOLINK_ENGINES_DIR="$INSTALL_LIB_DIR/engines" \
    TIXOLINK_MODULES_DIR="$INSTALL_LIB_DIR/modules" \
    TIXOLINK_FORWARDERS_DIR="$INSTALL_LIB_DIR/forwarders" \
    "$INSTALL_BIN_PATH" version 2>/dev/null
)" || VERIFY_OK=0
[[ "$INSTALLED_CLI_VERSION" == "$SOURCE_VERSION" ]] || VERIFY_OK=0

if [[ "$VERIFY_OK" != "1" ]]; then
    install::rollback
    common::die "$EXIT_GENERIC" "post-install verification failed (installed CLI reported '$INSTALLED_CLI_VERSION', expected '$SOURCE_VERSION'); rolled back"
fi

# --- COMMIT --------------------------------------------------------------------
[[ -n "$OLD_LIB_BACKUP" ]] && rm -rf -- "$OLD_LIB_BACKUP"
[[ -n "$OLD_BIN_BACKUP" ]] && rm -f -- "$OLD_BIN_BACKUP"

if [[ "$UNIT_CHANGED" == "1" && -z "$TIXOLINK_ROOT" ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || ui::warning "systemctl daemon-reload failed; run it manually"
fi

MANIFEST_JSON="$(manifest::new "$SOURCE_VERSION" "$INSTALL_BIN_PATH" "$INSTALL_LIB_DIR" "$TIXOLINK_ETC_DIR" "$TIXOLINK_VAR_DIR" "$LOG_DIR" "$TIXOLINK_RUN_DIR" "$SYSTEMD_UNIT_PATH")"
[[ -n "$INSTALLED_VERSION" ]] && MANIFEST_JSON="$(manifest::set_previous_version "$MANIFEST_JSON" "$INSTALLED_VERSION")"
MANIFEST_JSON="$(manifest::add_file "$MANIFEST_JSON" "$INSTALL_BIN_PATH" "$(manifest::sha256 "$INSTALL_BIN_PATH")" "0755")"
while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    f="${INSTALL_LIB_DIR}/${rel}"
    MANIFEST_JSON="$(manifest::add_file "$MANIFEST_JSON" "$f" "$(manifest::sha256 "$f")" "0644")"
done < <(cd "$INSTALL_LIB_DIR" && find . -type f -printf '%P\n')
MANIFEST_JSON="$(manifest::add_file "$MANIFEST_JSON" "$SYSTEMD_UNIT_PATH" "$(manifest::sha256 "$SYSTEMD_UNIT_PATH")" "0644")"
MANIFEST_JSON="$(manifest::add_dir "$MANIFEST_JSON" "$INSTALL_LIB_DIR")"
manifest::write "$MANIFEST_JSON"

ui::success "TixoLink NEXUS $SOURCE_VERSION installed ($INSTALL_KIND)."
ui::info "No tunnels were started automatically. Run '$INSTALL_BIN_PATH help' to get started."
exit 0

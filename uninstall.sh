#!/usr/bin/env bash
# TixoLink NEXUS uninstaller.
#
# Default mode removes only installed PROGRAM files (binary, library tree,
# systemd unit) - it never touches /etc/tixolink or /var/lib/tixolink, so
# tunnel configs, backups, and the optimizer baseline survive a plain
# uninstall. Pass --purge for the separate, explicitly-confirmed
# destructive path that also tears down owned tunnels/forwarding, restores
# the optimizer/BBR baseline, and removes TixoLink's persistent data.
#
# Every recursive directory removal in this script goes through
# common::safe_rm_rf, which refuses to run unless the resolved path's
# final component is literally "tixolink" and it isn't one of a handful of
# real filesystem roots - see lib/common.sh.

set -Eeuo pipefail

SELF_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

uninstall::usage() {
    cat <<'EOF'
Usage: uninstall.sh [options]

  --force, --yes        Skip the interactive confirmation.
  --dry-run             Show the removal plan and exit; change nothing.
  --purge                Also remove /etc/tixolink and /var/lib/tixolink
                          (tunnels, backups, optimizer baseline, manifest)
                          after tearing down owned tunnels/forwarding and
                          restoring the optimizer/BBR baseline. Requires
                          --confirm-purge in non-interactive mode.
  --confirm-purge        Unmistakable explicit opt-in required alongside
                          --purge when not running interactively.
  --skip-backup          Do not take an automatic backup before --purge.
  --backup-output <file> Write the automatic pre-purge backup to <file>
                          instead of the current working directory.
  --root <path>          Operate under <path> instead of the real
                          filesystem root (sandboxed testing).
  -h, --help             Show this help text.
EOF
}

FORCE=0
DRY_RUN=0
PURGE=0
CONFIRM_PURGE=0
SKIP_BACKUP=0
BACKUP_OUTPUT=""
ROOT_FLAG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force|--yes) FORCE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --purge) PURGE=1; shift ;;
        --confirm-purge) CONFIRM_PURGE=1; shift ;;
        --skip-backup) SKIP_BACKUP=1; shift ;;
        --backup-output) BACKUP_OUTPUT="$2"; shift 2 ;;
        --root) ROOT_FLAG="$2"; shift 2 ;;
        -h|--help) uninstall::usage; exit 0 ;;
        *) echo "ERROR: unknown option: $1" >&2; uninstall::usage; exit 2 ;;
    esac
done

TIXOLINK_ROOT="${ROOT_FLAG:-${TIXOLINK_ROOT:-}}"

export TIXOLINK_ETC_DIR="${TIXOLINK_ROOT}/etc/tixolink"
export TIXOLINK_VAR_DIR="${TIXOLINK_ROOT}/var/lib/tixolink"
export TIXOLINK_RUN_DIR="${TIXOLINK_ROOT}/run/tixolink"
LOG_DIR="${TIXOLINK_ROOT}/var/log/tixolink"
export TIXOLINK_LOG_FILE="${LOG_DIR}/tixolink.log"

export TIXOLINK_LIB_DIR="$SELF_DIR/lib"
export TIXOLINK_ENGINES_DIR="$SELF_DIR/engines"
export TIXOLINK_MODULES_DIR="$SELF_DIR/modules"
export TIXOLINK_FORWARDERS_DIR="$SELF_DIR/forwarders"

# shellcheck source=lib/common.sh
source "$SELF_DIR/lib/common.sh"
source "$SELF_DIR/lib/logging.sh"
source "$SELF_DIR/lib/ui.sh"
source "$SELF_DIR/lib/validation.sh"
source "$SELF_DIR/lib/platform.sh"
source "$SELF_DIR/lib/locking.sh"
source "$SELF_DIR/lib/config.sh"
source "$SELF_DIR/lib/state.sh"
source "$SELF_DIR/lib/subnet.sh"
source "$SELF_DIR/lib/ports.sh"
source "$SELF_DIR/lib/dependency.sh"
source "$SELF_DIR/lib/transaction.sh"
source "$SELF_DIR/lib/sysinfo.sh"
source "$SELF_DIR/lib/manifest.sh"
source "$SELF_DIR/lib/migration.sh"
source "$SELF_DIR/engines/engine_api.sh"
source "$SELF_DIR/engines/gre.sh"
source "$SELF_DIR/forwarders/forwarder_api.sh"
source "$SELF_DIR/forwarders/none.sh"
source "$SELF_DIR/forwarders/netfilter.sh"
source "$SELF_DIR/forwarders/haproxy.sh"
source "$SELF_DIR/modules/tunnel.sh"
source "$SELF_DIR/modules/forwarding.sh"
source "$SELF_DIR/modules/optimizer.sh"
source "$SELF_DIR/modules/bbr.sh"
source "$SELF_DIR/modules/backup.sh"
source "$SELF_DIR/modules/lifecycle.sh"

if [[ -z "$TIXOLINK_ROOT" ]]; then
    common::require_root || common::die "$EXIT_PERMISSION" "uninstall.sh must be run as root (use --root/TIXOLINK_ROOT only for sandboxed testing)"
fi

if [[ "$PURGE" == "1" && "$FORCE" != "1" && -t 0 && -t 1 ]]; then
    : # interactive purge confirms below, after the plan is shown
elif [[ "$PURGE" == "1" && ( ! -t 0 || ! -t 1 ) && "$CONFIRM_PURGE" != "1" ]]; then
    common::die "$EXIT_USAGE" "non-interactive --purge requires --confirm-purge as well (unmistakable explicit opt-in)"
fi

MANIFEST_PRESENT=0
manifest::exists && MANIFEST_PRESENT=1

# --- PLAN ------------------------------------------------------------------
ui::section "TixoLink NEXUS uninstall plan"
if [[ "$MANIFEST_PRESENT" == "1" ]]; then
    printf 'Installed version: %s\n' "$(jq -r '.tixolink_version' "$(manifest::file)")"
    printf 'Program files to remove (%s):\n' "$(jq -r '.files | length' "$(manifest::file)")"
    jq -r '.files[].path' "$(manifest::file)" | sed 's/^/  - /'
else
    ui::warning "No install manifest found at $(manifest::file); program-file removal will be skipped (nothing to safely remove by ownership)."
fi

ACTIVE_UNITS=()
if command -v systemctl >/dev/null 2>&1 && [[ -z "$TIXOLINK_ROOT" ]]; then
    while IFS= read -r u; do
        [[ -n "$u" ]] && ACTIVE_UNITS+=("$u")
    done < <(systemctl list-units --type=service --state=active --no-legend 'tixolink@*.service' 2>/dev/null | awk '{print $1}')
fi
if [[ ${#ACTIVE_UNITS[@]} -gt 0 ]]; then
    printf 'Active systemd units that will be stopped: %s\n' "${ACTIVE_UNITS[*]}"
fi

if [[ "$PURGE" == "1" ]]; then
    ui::warning "PURGE requested: this will ALSO remove $TIXOLINK_ETC_DIR and $TIXOLINK_VAR_DIR (tunnels, backups, optimizer baseline, manifest) and $LOG_DIR, after tearing down owned tunnels/forwarding and restoring the optimizer/BBR baseline."
else
    printf 'Preserved (default uninstall): %s, %s, %s\n' "$TIXOLINK_ETC_DIR" "$TIXOLINK_VAR_DIR" "$LOG_DIR"
fi

if [[ "$DRY_RUN" == "1" ]]; then
    ui::info "Dry run: no changes made."
    exit 0
fi

if [[ "$FORCE" != "1" ]]; then
    if [[ -t 0 && -t 1 ]]; then
        ui::confirm "Proceed with uninstall?" "n" || common::die "$EXIT_GENERIC" "Uninstall cancelled."
        if [[ "$PURGE" == "1" ]]; then
            typed="$(ui::input "Type PURGE to confirm permanent removal of TixoLink data")"
            [[ "$typed" == "PURGE" ]] || common::die "$EXIT_GENERIC" "Purge not confirmed; aborting with nothing removed."
        fi
    else
        common::die "$EXIT_USAGE" "non-interactive uninstall requires --force/--yes"
    fi
fi

# --- STOP active units -------------------------------------------------------
for u in "${ACTIVE_UNITS[@]:-}"; do
    [[ -z "$u" ]] && continue
    systemctl stop "$u" || ui::warning "failed to stop $u; continuing"
done

# --- PURGE: tear down owned resources before removing any data ---------------
if [[ "$PURGE" == "1" ]]; then
    if [[ "$SKIP_BACKUP" != "1" ]]; then
        pre_purge_backup="${BACKUP_OUTPUT:-$(pwd)/tixolink-pre-purge-$(date -u '+%Y%m%dT%H%M%SZ').tar.gz}"
        if backup::create --output "$pre_purge_backup" >/dev/null 2>&1; then
            ui::info "Backup saved before purge: $pre_purge_backup"
        else
            ui::warning "Could not create pre-purge backup (continuing anyway; use --skip-backup to silence this)."
        fi
    fi

    FAILED_IDS=()
    lifecycle::teardown_owned_resources FAILED_IDS
    teardown_status=$?
    if [[ "$teardown_status" -ne 0 ]]; then
        common::die "$EXIT_ROLLED_BACK" "purge: optimizer/BBR baseline restoration did not verify clean; aborting before removing any TixoLink data"
    fi
    if [[ ${#FAILED_IDS[@]} -gt 0 ]]; then
        common::die "$EXIT_GENERIC" "purge: tunnel(s) ${FAILED_IDS[*]} could not be removed cleanly; aborting before removing any TixoLink data - resolve and re-run"
    fi
fi

# --- REMOVE program files ----------------------------------------------------
if [[ "$MANIFEST_PRESENT" == "1" ]]; then
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        rm -f -- "$f"
    done < <(jq -r '.files[].path' "$(manifest::file)")
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        common::safe_rm_rf "$d" || ui::warning "could not remove $d"
    done < <(manifest::dirs)

    UNIT_PATH="$(jq -r '.prefix.systemd_unit' "$(manifest::file)")"
    if [[ -f "$UNIT_PATH" ]] && command -v systemctl >/dev/null 2>&1 && [[ -z "$TIXOLINK_ROOT" ]]; then
        systemctl daemon-reload || ui::warning "systemctl daemon-reload failed; run it manually"
    fi
fi

# --- PURGE: remove data directories (manifest-independent, guarded) ----------
if [[ "$PURGE" == "1" ]]; then
    common::safe_rm_rf "$TIXOLINK_ETC_DIR" || ui::warning "could not remove $TIXOLINK_ETC_DIR"
    common::safe_rm_rf "$TIXOLINK_VAR_DIR" || ui::warning "could not remove $TIXOLINK_VAR_DIR"
    common::safe_rm_rf "$LOG_DIR" || ui::warning "could not remove $LOG_DIR"
    common::safe_rm_rf "$TIXOLINK_RUN_DIR" || ui::warning "could not remove $TIXOLINK_RUN_DIR"
    ui::success "TixoLink NEXUS purged: program files and all persistent data removed."
else
    ui::success "TixoLink NEXUS uninstalled. Preserved: $TIXOLINK_ETC_DIR, $TIXOLINK_VAR_DIR, $LOG_DIR"
fi
exit 0

#!/usr/bin/env bash
# TixoLink NEXUS - factory reset
#
# Factory reset differs from uninstall: the application stays installed,
# but every TixoLink-MANAGED thing it is responsible for is torn down and
# reset to a fresh state - tunnels, their forwarding, the optimizer/BBR
# host tunables (restored to the administrator's own pre-TixoLink
# baseline, never just deleted), and the app config/state ledger.
#
# Order matters, and is the reason this is its own module rather than a
# one-liner: the optimizer baseline is the ONLY record of what the host's
# sysctls were before TixoLink ever touched them, so it is restored to the
# live host and VERIFIED before its backing file is removed. If tunnel or
# forwarding removal fails partway through, config/state are deliberately
# left untouched (not reset) so the administrator has something to retry
# against instead of a wiped ledger with half-torn-down resources.

if [[ -n "${TIXOLINK_MODULE_LIFECYCLE_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_MODULE_LIFECYCLE_SH_LOADED=1

# lifecycle::teardown_owned_resources <failed-ids-array-name>
# Shared by factory_reset and `uninstall.sh --purge`: removes every owned
# forwarding mapping then every tunnel (best-effort - one tunnel's failure
# does not stop the rest), then restores the optimizer/BBR baseline to the
# live host and verifies nothing TixoLink-managed remains applied.
# Appends any tunnel IDs that failed to remove cleanly to the named array.
# Returns non-zero only if optimizer/BBR baseline restoration did not
# verify clean (the one failure mode callers must never paper over, since
# it means the host's own pre-TixoLink sysctls are not confirmed restored).
lifecycle::teardown_owned_resources() {
    local -n _failed_ids="$1"
    local id
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        local tunnel_json mid status
        tunnel_json="$(config::tunnel_read "$id" 2>/dev/null)" || continue
        while IFS= read -r mid; do
            [[ -z "$mid" ]] && continue
            status=0
            forwarding::remove "$id" "$mid" 0 || status=$?
            [[ "$status" -ne 0 ]] && log::warn "teardown: failed to remove mapping $mid on tunnel $id (exit $status), continuing"
        done < <(jq -r '.forwarding.mappings[]?.id // empty' <<<"$tunnel_json")

        status=0
        tunnel::delete "$id" 0 1 || status=$?
        if [[ "$status" -ne 0 ]]; then
            log::error "teardown: failed to remove tunnel $id (exit $status)"
            _failed_ids+=("$id")
        fi
    done < <(config::tunnel_list)

    optimizer::restore >/dev/null 2>&1
    optimizer::_applied_init
    local remaining; remaining="$(jq -c 'keys' <<<"$(cat "$(optimizer::_applied_file)")")"
    if [[ "$remaining" != "[]" ]]; then
        log::error "teardown: optimizer/BBR baseline restoration left tunables still applied: $remaining"
        return "$EXIT_ROLLED_BACK"
    fi
    return 0
}

# lifecycle::_plan
lifecycle::_plan() {
    ui::section "Factory reset plan"
    local -a ids=()
    local id
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        ids+=("$id")
    done < <(config::tunnel_list)

    if [[ ${#ids[@]} -eq 0 ]]; then
        printf 'No tunnels configured.\n'
    else
        printf 'Tunnels to be removed (%d):\n' "${#ids[@]}"
        for id in "${ids[@]}"; do
            printf '  - %s (%s)\n' "$id" "$(jq -r '.name' <<<"$(config::tunnel_read "$id")")"
        done
    fi

    optimizer::_applied_init
    local applied; applied="$(cat "$(optimizer::_applied_file)")"
    if [[ "$(jq -c 'keys' <<<"$applied")" == "[]" ]]; then
        printf 'No optimizer/BBR tunables are currently TixoLink-managed.\n'
    else
        printf 'Optimizer/BBR tunables to be restored to baseline: %s\n' "$(jq -r 'keys | join(", ")' <<<"$applied")"
    fi

    printf 'App config (%s) and state ledger (%s) will be reset to defaults once the above completes cleanly.\n' \
        "$TIXOLINK_APP_CONFIG_FILE" "$TIXOLINK_STATE_FILE"
}

# lifecycle::factory_reset [--force] [--dry-run] [--skip-backup]
lifecycle::factory_reset() {
    local force=0 dry_run=0 skip_backup=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force) force=1; shift ;;
            --dry-run) dry_run=1; shift ;;
            --skip-backup) skip_backup=1; shift ;;
            *) log::error "factory-reset: unknown option $1"; return "$EXIT_USAGE" ;;
        esac
    done

    common::require_root || { log::error "factory-reset requires root"; return "$EXIT_PERMISSION"; }

    lifecycle::_plan
    if [[ "$dry_run" == "1" ]]; then
        ui::info "Dry run: no changes made."
        return 0
    fi

    if [[ "$force" != "1" ]] && ! ui::confirm "Proceed with factory reset? This removes all tunnels/forwarding and resets TixoLink's own config/state." "n"; then
        ui::info "Factory reset cancelled."
        return "$EXIT_GENERIC"
    fi

    if [[ "$skip_backup" != "1" ]]; then
        local backup_file
        backup_file="$(backup::create --output "${TIXOLINK_VAR_DIR}/backups/pre-factory-reset-$(date -u '+%Y%m%dT%H%M%SZ').tar.gz" 2>/dev/null)" \
            && ui::info "Backup saved before reset: $backup_file"
    fi

    local -a failed_ids=()
    lifecycle::teardown_owned_resources failed_ids
    local teardown_status=$?

    if [[ "$teardown_status" -ne 0 ]]; then
        log::error "factory-reset: optimizer/BBR baseline restoration did not verify clean; aborting before touching config/state"
        return "$EXIT_ROLLED_BACK"
    fi

    if [[ ${#failed_ids[@]} -gt 0 ]]; then
        log::error "factory-reset: ${#failed_ids[@]} tunnel(s) could not be removed cleanly (${failed_ids[*]}); config/state left untouched - resolve and re-run factory-reset"
        return "$EXIT_GENERIC"
    fi

    config::write_json_atomic "$TIXOLINK_APP_CONFIG_FILE" "$(config::app_defaults)" 0640
    config::write_json_atomic "$TIXOLINK_STATE_FILE" "$(state::defaults)" 0600
    rm -f -- "${TIXOLINK_VAR_DIR}/optimizer/baseline.json" "${TIXOLINK_VAR_DIR}/optimizer/applied.json"

    log::history "factory-reset" "-" "success"
    ui::success "Factory reset complete. TixoLink remains installed; host tunables restored to their pre-TixoLink baseline."
    return 0
}

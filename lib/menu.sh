#!/usr/bin/env bash
# TixoLink NEXUS - interactive menu
#
# Data-driven menu table: each entry is "label|handler-function". Adding a
# menu item is a table row, not a new case branch. Wizard functions here
# are shared with lib/cli.sh so `tixolink create`/`tixolink edit` and the
# interactive menu present the exact same flow.

if [[ -n "${TIXOLINK_MENU_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_MENU_SH_LOADED=1

menu::_not_implemented() {
    ui::info "This feature is not implemented yet in this build (Phase 3: transport only)."
}

menu::_about() {
    ui::section "About"
    printf 'TixoLink NEXUS %s\n' "$(common::version)"
    printf 'TheTixoCloud - Linux Tunnel Management Suite\n\n'
    printf 'Host: %s %s (%s)\n' "$(platform::os_id)" "$(platform::os_version)" "$(platform::arch)"
    printf 'Kernel: %s\n' "$(platform::kernel)"
    printf 'Virtualization: %s\n' "$(platform::virt)"
}

# --- Create Tunnel wizard ----------------------------------------------------

# menu::wizard_create_tunnel
# Collects fields interactively, shows a review screen, then applies.
# Returns non-zero without applying anything if the user declines at review.
menu::wizard_create_tunnel() {
    ui::section "Create Tunnel"

    local name
    while true; do
        name="$(ui::input "Tunnel name (e.g. germany-1)")"
        validate::tunnel_name "$name" && break
        ui::error "Invalid name: use letters, digits, '.', '_', '-' only (max 64 chars)."
    done

    local local_ip
    while true; do
        local_ip="$(ui::input "Local public IPv4")"
        validate::ipv4 "$local_ip" && break
        ui::error "Invalid IPv4 address."
    done

    local remote_ip
    while true; do
        remote_ip="$(ui::input "Remote public IPv4")"
        if ! validate::ipv4 "$remote_ip"; then
            ui::error "Invalid IPv4 address."
        elif [[ "$remote_ip" == "$local_ip" ]]; then
            ui::error "Remote address must differ from the local address."
        else
            break
        fi
    done

    local addr_mode="auto" manual_subnet="" manual_local="" manual_remote=""
    if ui::confirm "Use automatic inner addressing (recommended)?" "y"; then
        addr_mode="auto"
    else
        addr_mode="manual"
        while true; do
            manual_subnet="$(ui::input "Inner subnet (must be a /30, e.g. 10.200.0.0/30)")"
            validate::cidr "$manual_subnet" && [[ "${manual_subnet#*/}" == "30" ]] && break
            ui::error "Must be a valid /30 CIDR."
        done
        while true; do
            manual_local="$(ui::input "Local inner IPv4")"
            validate::ipv4 "$manual_local" && break
            ui::error "Invalid IPv4 address."
        done
        while true; do
            manual_remote="$(ui::input "Remote inner IPv4")"
            if ! validate::ipv4 "$manual_remote"; then
                ui::error "Invalid IPv4 address."
            elif [[ "$manual_remote" == "$manual_local" ]]; then
                ui::error "Remote inner address must differ from the local inner address."
            else
                break
            fi
        done
    fi

    local mtu; mtu="$(ui::input "MTU" "1300")"
    validate::mtu "$mtu" || { ui::error "Invalid MTU; aborting."; return "$EXIT_VALIDATION"; }

    local ttl; ttl="$(ui::input "TTL" "255")"
    validate::ttl "$ttl" || { ui::error "Invalid TTL; aborting."; return "$EXIT_VALIDATION"; }

    ui::section "Review"
    printf -- '----------------------------------------\n'
    printf 'Tunnel:      %s\n' "$name"
    printf 'Transport:   GRE\n'
    printf 'Local:       %s\n' "$local_ip"
    printf 'Remote:      %s\n' "$remote_ip"
    if [[ "$addr_mode" == "auto" ]]; then
        printf 'Inner:       automatic /30 allocation\n'
    else
        printf 'Inner:       %s (%s <-> %s)\n' "$manual_subnet" "$manual_local" "$manual_remote"
    fi
    printf 'MTU:         %s\n' "$mtu"
    printf 'TTL:         %s\n' "$ttl"
    printf 'Forwarding:  Not configured yet (set up afterwards via Port Forwarding)\n'
    printf -- '----------------------------------------\n'

    ui::confirm "Proceed?" "n" || { ui::info "Cancelled."; return "$EXIT_GENERIC"; }

    local id status=0
    id="$(tunnel::create_from_fields "$name" "$local_ip" "$remote_ip" "$addr_mode" \
        "$manual_subnet" "$manual_local" "$manual_remote" "$mtu" "$ttl" 0)" || status=$?
    if [[ "$status" -ne 0 ]]; then
        ui::error "Tunnel creation failed (exit $status)."
        return "$status"
    fi
    ui::success "Tunnel '$name' created (id: $id)."
    tunnel::status "$id"
    return 0
}

# menu::wizard_edit_tunnel <id-or-name>
menu::wizard_edit_tunnel() {
    local ref="$1"
    local id; id="$(tunnel::resolve "$ref")" || { ui::error "Tunnel not found: $ref"; return "$EXIT_NOT_FOUND"; }
    local cfg; cfg="$(config::tunnel_read "$id")"
    local ec; ec="$(jq -c '.engine_config' <<<"$cfg")"

    ui::section "Edit Tunnel: $(jq -r '.name' <<<"$cfg") ($id)"

    local cur_local cur_remote cur_mtu cur_ttl
    cur_local="$(jq -r '.local_public_ip' <<<"$ec")"
    cur_remote="$(jq -r '.remote_public_ip' <<<"$ec")"
    cur_mtu="$(jq -r '.mtu' <<<"$ec")"
    cur_ttl="$(jq -r '.ttl' <<<"$ec")"

    local new_local new_remote new_mtu new_ttl
    new_local="$(ui::input "Local public IPv4" "$cur_local")"
    new_remote="$(ui::input "Remote public IPv4" "$cur_remote")"
    new_mtu="$(ui::input "MTU" "$cur_mtu")"
    new_ttl="$(ui::input "TTL" "$cur_ttl")"

    ui::confirm "Apply these changes?" "n" || { ui::info "Cancelled."; return "$EXIT_GENERIC"; }

    local status=0
    tunnel::edit_from_fields "$id" "$new_local" "$new_remote" "$new_mtu" "$new_ttl" 0 || status=$?
    if [[ "$status" -ne 0 ]]; then
        ui::error "Edit failed (exit $status)."
        return "$status"
    fi
    ui::success "Tunnel $id updated."
    return 0
}

# --- Port Forwarding ----------------------------------------------------------

menu::_print_mappings() {
    local id="$1"
    forwarding::status "$id" | while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ "$line" == ENGINE=* ]]; then
            printf 'Forwarding engine: %s\n' "${line#ENGINE=}"
            continue
        fi
        local mid proto local_p remote_p state
        mid="$(grep -o 'MAPPING=[^ ]*' <<<"$line" | cut -d= -f2)"
        proto="$(grep -o 'PROTO=[^ ]*' <<<"$line" | cut -d= -f2)"
        local_p="$(grep -o 'LOCAL=[^ ]*' <<<"$line" | cut -d= -f2)"
        remote_p="$(grep -o 'REMOTE=[^ ]*' <<<"$line" | cut -d= -f2)"
        state="$(grep -o 'STATE=[^ ]*' <<<"$line" | cut -d= -f2)"
        printf '  %-10s %-5s %-10s -> %-10s %s\n' "$mid" "$proto" "$local_p" "$remote_p" "$state"
    done
}

menu::_wizard_add_mapping() {
    local id="$1" engine="$2"

    local proto
    if [[ "$engine" == "haproxy" ]]; then
        proto="tcp"
        ui::info "HAProxy forwarding only supports TCP in this build."
    else
        while true; do
            proto="$(ui::input "Protocol (tcp / udp / tcp+udp)" "tcp")"
            validate::protocol "$proto" && break
            ui::error "Enter tcp, udp, or tcp+udp."
        done
    fi

    local port_token
    while true; do
        port_token="$(ui::input "Port (e.g. 443, 8443:443, 8000-9000)")"
        ports::parse_token "$port_token" >/dev/null 2>&1 && break
        ui::error "Invalid port/remap spec."
    done

    local listen_addr; listen_addr="$(ui::input "Listen address" "0.0.0.0")"
    local remote_override; remote_override="$(ui::input "Backend address override (blank = tunnel's remote inner address)" "")"
    local nat_mode="nat"
    if [[ "$engine" == "netfilter" ]]; then
        if ! ui::confirm "Use NAT/MASQUERADE mode (recommended; works without backend routing changes)?" "y"; then
            nat_mode="source-preserving"
            ui::warning "Source-preserving mode requires the backend to route the original client's subnet back through its own tunnel interface."
        fi
    fi

    ui::confirm "Add this mapping?" "y" || { ui::info "Cancelled."; return "$EXIT_GENERIC"; }

    local mapping_id status=0
    mapping_id="$(forwarding::add "$id" "$proto" "$port_token" "$listen_addr" "$remote_override" "$nat_mode" 0)" || status=$?
    if [[ "$status" -ne 0 ]]; then
        ui::error "Add mapping failed (exit $status)."
        return "$status"
    fi
    ui::success "Mapping added (id: $mapping_id)."
}

menu::_wizard_edit_mapping() {
    local id="$1" mapping_id="$2"
    local port_token; port_token="$(ui::input "New port (e.g. 443, 8443:443)")"
    ports::parse_token "$port_token" >/dev/null 2>&1 || { ui::error "Invalid port/remap spec."; return "$EXIT_VALIDATION"; }
    ui::confirm "Apply this change?" "n" || { ui::info "Cancelled."; return "$EXIT_GENERIC"; }
    local status=0
    forwarding::edit "$id" "$mapping_id" "$port_token" 0 || status=$?
    if [[ "$status" -ne 0 ]]; then
        ui::error "Edit mapping failed (exit $status)."
        return "$status"
    fi
    ui::success "Mapping updated."
}

menu::_port_forwarding() {
    local ref="$1"
    local id; id="$(tunnel::resolve "$ref")" || { ui::error "Tunnel not found: $ref"; return; }

    while true; do
        local cfg engine
        cfg="$(config::tunnel_read "$id")"
        engine="$(jq -r '.forwarding.engine // "none"' <<<"$cfg")"

        ui::section "Port Forwarding: $(jq -r '.name' <<<"$cfg") ($id) - engine: $engine"
        local -a labels=("View Mappings" "Add Mapping" "Edit Mapping" "Remove Mapping"
            "Change Forwarding Engine" "Forwarding Status" "Back")
        local choice
        choice="$(ui::select "Select an action" "${labels[@]}")" || return
        case "$choice" in
            1) menu::_print_mappings "$id" ;;
            2)
                if [[ "$engine" == "none" ]]; then
                    ui::error "Select a forwarding engine first."
                else
                    menu::_wizard_add_mapping "$id" "$engine"
                fi
                ;;
            3)
                local mid; mid="$(ui::input "Mapping ID to edit")"
                [[ -n "$mid" ]] && menu::_wizard_edit_mapping "$id" "$mid"
                ;;
            4)
                local mid; mid="$(ui::input "Mapping ID to remove")"
                if [[ -n "$mid" ]] && ui::confirm "Remove mapping $mid?" "n"; then
                    if forwarding::remove "$id" "$mid" 0; then ui::success "Removed."; else ui::error "Remove failed."; fi
                fi
                ;;
            5)
                local new_engine
                new_engine="$(ui::select "Select forwarding engine" "netfilter" "HAProxy (TCP only)" "None")"
                case "$new_engine" in
                    1) new_engine="netfilter" ;;
                    2) new_engine="haproxy" ;;
                    3) new_engine="none" ;;
                    *) continue ;;
                esac
                if ui::confirm "Switch forwarding engine to $new_engine?" "n"; then
                    if forwarding::set_engine "$id" "$new_engine" 0; then
                        ui::success "Forwarding engine set to $new_engine."
                    else
                        ui::error "Could not switch forwarding engine."
                    fi
                fi
                ;;
            6) menu::_print_mappings "$id" ;;
            7) return ;;
        esac
    done
}

menu::_port_forwarding_select_tunnel() {
    menu::_print_tunnel_list || return
    local ref; ref="$(ui::input "Enter tunnel ID or name (blank to go back)")"
    [[ -z "$ref" ]] && return
    menu::_port_forwarding "$ref"
}

# --- Manage Tunnels -----------------------------------------------------------

menu::_print_tunnel_list() {
    local -a rows=()
    local id name engine local_ip remote_ip state
    while IFS='|' read -r id name engine local_ip remote_ip state; do
        [[ -z "$id" ]] && continue
        rows+=("$id|$name|$engine|$local_ip -> $remote_ip|$state")
    done < <(tunnel::list)

    if [[ ${#rows[@]} -eq 0 ]]; then
        ui::info "No tunnels configured yet."
        return 1
    fi
    ui::table "ID|Name|Engine|Peer|State" "${rows[@]}"
    return 0
}

menu::_manage_one_tunnel() {
    local ref="$1"
    local id; id="$(tunnel::resolve "$ref")" || { ui::error "Tunnel not found: $ref"; return; }

    while true; do
        ui::section "Tunnel: $ref"
        local -a labels=("Status" "Start" "Stop" "Restart" "Edit" "Port Forwarding"
            "Export Peer Config" "Enable at Boot" "Disable at Boot" "Delete" "Back")
        local choice
        choice="$(ui::select "Select an action" "${labels[@]}")" || return
        case "$choice" in
            1) tunnel::status "$id" ;;
            2) if tunnel::start "$id"; then ui::success "Started."; else ui::error "Start failed."; fi ;;
            3) if tunnel::stop "$id"; then ui::success "Stopped."; else ui::error "Stop failed."; fi ;;
            4) if tunnel::restart "$id"; then ui::success "Restarted."; else ui::error "Restart failed."; fi ;;
            5) menu::wizard_edit_tunnel "$id" ;;
            6) menu::_port_forwarding "$id" ;;
            7) peer::export "$id" ;;
            8|9) ui::info "Boot persistence requires an installed systemd unit (available from the installer phase)." ;;
            10)
                if ui::confirm "Delete tunnel $ref ($id)?" "n"; then
                    if tunnel::delete "$id" 0 1; then ui::success "Deleted."; else ui::error "Delete failed."; fi
                    return
                fi
                ;;
            11) return ;;
        esac
    done
}

menu::_manage_tunnels() {
    while true; do
        ui::section "Manage Tunnels"
        menu::_print_tunnel_list || { return; }
        local ref
        ref="$(ui::input "Enter tunnel ID or name to manage (blank to go back)")"
        [[ -z "$ref" ]] && return
        menu::_manage_one_tunnel "$ref"
    done
}

menu::main() {
    local -a labels=(
        "Create Tunnel"
        "Manage Tunnels"
        "Port Forwarding"
        "Live Dashboard"
        "Diagnostics"
        "Benchmark"
        "Network Optimizer"
        "Backup / Restore"
        "Update"
        "Settings"
        "About"
        "Exit"
    )

    while true; do
        ui::header
        local choice
        choice="$(ui::select "Main Menu" "${labels[@]}")" || return "$EXIT_OK"

        case "$choice" in
            1) menu::wizard_create_tunnel ;;
            2) menu::_manage_tunnels ;;
            3) menu::_port_forwarding_select_tunnel ;;
            11) menu::_about ;;
            12) return "$EXIT_OK" ;;
            *) menu::_not_implemented ;;
        esac
    done
}

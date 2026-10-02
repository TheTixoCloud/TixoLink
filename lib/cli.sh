#!/usr/bin/env bash
# TixoLink NEXUS - non-interactive CLI dispatcher
#
# This is the only file permitted to call `exit`. Module/library functions
# return one of the EXIT_* codes from lib/common.sh; cli::main translates
# that into the process exit status. Business logic never lives here -
# every command dispatches into modules/tunnel.sh, modules/peer.sh, or the
# shared wizard functions in lib/menu.sh.

if [[ -n "${TIXOLINK_CLI_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_CLI_SH_LOADED=1

cli::usage() {
    cat <<'EOF'
TixoLink NEXUS - Linux Tunnel Management Suite (TheTixoCloud)

Usage: tixolink [--verbose|--debug] [--no-color] <command> [args]

Commands:
  version                      Print the installed version
  help                         Show this help text
  list                         List all configured tunnels
  status [id-or-name]          Show status (all tunnels, or one)
  create                       Interactive tunnel creation wizard
  start   <id-or-name>         Bring a tunnel up (idempotent)
  stop    <id-or-name>         Take a tunnel down (idempotent)
  restart <id-or-name>         Stop then start a tunnel
  reload  <id-or-name>         Reconcile runtime state to match config
  edit    <id-or-name>         Interactive edit wizard
  delete  <id-or-name>         Delete a tunnel (prompts unless --force)
  peer export <id-or-name>     Print (or --output <file>) a peer document
  peer import <file>           Import a peer document as a new tunnel
  ports [id-or-name]           List forwarding mappings (all tunnels, or one)
  forward add <tunnel> <proto> <port-token> [--listen addr] [--remote-addr addr] [--nat-mode nat|source-preserving]
  forward edit <tunnel> <mapping-id> <port-token>
  forward remove <tunnel> <mapping-id>
  forward status <tunnel>
  forward migrate <tunnel> <none|netfilter|haproxy>

Flags (where applicable):
  --dry-run                    Show planned actions without applying them
  --force                      Skip interactive confirmation
  --output <file>              peer export: write to file instead of stdout
  --start                      peer import: start the tunnel after import

<port-token> forms: "443", "8000-9000", "8443:443", "8000-8010:9000-9010"

Running "tixolink" with no command launches the interactive menu when
connected to a terminal.

Note: diagnostics, optimizer, and lifecycle (install/update/backup)
commands are not implemented yet (Phase 4: transport + forwarding).
EOF
}

cli::_print_status() {
    local fields="$1"
    local k v
    while IFS='=' read -r k v; do
        [[ -z "$k" ]] && continue
        printf '%-14s %s\n' "${k}:" "$v"
    done <<<"$fields"
}

cli::_print_list() {
    local rows=()
    while IFS='|' read -r id name engine local_ip remote_ip state; do
        [[ -z "$id" ]] && continue
        rows+=("$id|$name|$engine|$local_ip -> $remote_ip|$state")
    done < <(tunnel::list)

    if [[ ${#rows[@]} -eq 0 ]]; then
        ui::info "No tunnels configured."
        return 0
    fi
    ui::table "ID|Name|Engine|Peer|State" "${rows[@]}"
}

# cli::_extract_flags <flag-names...> -- parses TIXOLINK_CLI_ARGS (set by
# caller) splitting out the given boolean/value flags. Positional args are
# left in TIXOLINK_CLI_POSITIONAL.
cli::cmd_start()   { tunnel::start   "$1" "$2"; }
cli::cmd_stop()    { tunnel::stop    "$1" "$2"; }
cli::cmd_restart() { tunnel::restart "$1" "$2"; }
cli::cmd_reload()  { tunnel::reload  "$1" "$2"; }

cli::_print_forwarding_status() {
    local line engine mid proto local_p remote_p state
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if [[ "$line" == ENGINE=* ]]; then
            printf 'Forwarding engine: %s\n' "${line#ENGINE=}"
            continue
        fi
        mid="$(grep -o 'MAPPING=[^ ]*' <<<"$line" | cut -d= -f2)"
        proto="$(grep -o 'PROTO=[^ ]*' <<<"$line" | cut -d= -f2)"
        local_p="$(grep -o 'LOCAL=[^ ]*' <<<"$line" | cut -d= -f2)"
        remote_p="$(grep -o 'REMOTE=[^ ]*' <<<"$line" | cut -d= -f2)"
        state="$(grep -o 'STATE=[^ ]*' <<<"$line" | cut -d= -f2)"
        printf '  %-10s %-5s %-10s -> %-10s %s\n' "$mid" "$proto" "$local_p" "$remote_p" "$state"
    done
}

cli::_print_ports_all() {
    local id name engine
    while IFS='|' read -r id name engine _ _ _; do
        [[ -z "$id" ]] && continue
        printf '%s (%s):\n' "$name" "$id"
        forwarding::status "$id" | cli::_print_forwarding_status
    done < <(tunnel::list)
}

cli::cmd_ports() {
    if [[ -z "${1:-}" ]]; then
        cli::_print_ports_all
    else
        forwarding::status "$1" | cli::_print_forwarding_status
    fi
}

# cli::cmd_forward <dry_run> <sub> <tunnel> [args...]
cli::cmd_forward() {
    local dry_run="$1" sub="$2" tunnel="$3"
    shift 3

    case "$sub" in
        add)
            local proto="$1" port_token="$2"
            shift 2
            local listen="0.0.0.0" remote_addr="" nat_mode="nat"
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --listen) listen="$2"; shift 2 ;;
                    --remote-addr) remote_addr="$2"; shift 2 ;;
                    --nat-mode) nat_mode="$2"; shift 2 ;;
                    *) ui::error "forward add: unknown option $1"; return "$EXIT_USAGE" ;;
                esac
            done
            forwarding::add "$tunnel" "$proto" "$port_token" "$listen" "$remote_addr" "$nat_mode" "$dry_run"
            ;;
        edit)
            local mapping_id="$1" port_token="$2"
            forwarding::edit "$tunnel" "$mapping_id" "$port_token" "$dry_run"
            ;;
        remove)
            local mapping_id="$1"
            forwarding::remove "$tunnel" "$mapping_id" "$dry_run"
            ;;
        status)
            forwarding::status "$tunnel" | cli::_print_forwarding_status
            ;;
        migrate)
            local engine="$1"
            forwarding::migrate "$tunnel" "$engine" "$dry_run"
            ;;
        *)
            ui::error "unknown forward subcommand: $sub"
            return "$EXIT_USAGE"
            ;;
    esac
}

cli::cmd_peer() {
    local sub="$1"
    shift
    case "$sub" in
        export)
            local ref="$1"
            shift
            peer::export "$ref" "$@"
            ;;
        import)
            local file="$1"
            shift
            peer::import "$file" "$@"
            printf '\n'
            ;;
        *)
            ui::error "unknown peer subcommand: $sub"
            return "$EXIT_USAGE"
            ;;
    esac
}

# cli::main <args...>
cli::main() {
    local -a args=()
    local arg

    for arg in "$@"; do
        case "$arg" in
            --verbose) log::set_verbose ;;
            --debug) log::set_debug ;;
            --no-color) : ;; # color is resolved at ui.sh load time from NO_COLOR/TERM
            *) args+=("$arg") ;;
        esac
    done

    if [[ ${#args[@]} -eq 0 ]]; then
        if [[ -t 0 && -t 1 ]]; then
            menu::main
            exit $?
        fi
        cli::usage
        exit "$EXIT_USAGE"
    fi

    local command="${args[0]}"
    local -a rest=("${args[@]:1}")

    # Pull --dry-run/--force out of the remaining args wherever they appear;
    # everything else stays positional, in order.
    local dry_run=0 force=0
    local -a positional=()
    for arg in "${rest[@]}"; do
        case "$arg" in
            --dry-run) dry_run=1 ;;
            --force) force=1 ;;
            *) positional+=("$arg") ;;
        esac
    done

    local status=0
    case "$command" in
        version)
            common::version
            ;;
        help|-h|--help)
            cli::usage
            ;;
        list)
            cli::_print_list
            ;;
        status)
            if [[ ${#positional[@]} -eq 0 ]]; then
                cli::_print_list
            else
                local fields
                fields="$(tunnel::status "${positional[0]}")" || status=$?
                [[ "$status" -eq 0 ]] && cli::_print_status "$fields"
            fi
            ;;
        create)
            if [[ -t 0 && -t 1 ]]; then
                menu::wizard_create_tunnel || status=$?
            else
                ui::error "create requires an interactive terminal in this build"
                status="$EXIT_USAGE"
            fi
            ;;
        # Internal verbs used only by systemd/tixolink@.service (ExecStart/
        # Stop/Reload); intentionally omitted from cli::usage.
        tunnel-up)     tunnel::start  "${positional[0]:-}" 0 || status=$? ;;
        tunnel-down)   tunnel::stop   "${positional[0]:-}" 0 || status=$? ;;
        tunnel-reload) tunnel::reload "${positional[0]:-}" 0 || status=$? ;;
        start)   cli::cmd_start   "${positional[0]:-}" "$dry_run" || status=$? ;;
        stop)    cli::cmd_stop    "${positional[0]:-}" "$dry_run" || status=$? ;;
        restart) cli::cmd_restart "${positional[0]:-}" "$dry_run" || status=$? ;;
        reload)  cli::cmd_reload  "${positional[0]:-}" "$dry_run" || status=$? ;;
        edit)
            if [[ -t 0 && -t 1 ]]; then
                menu::wizard_edit_tunnel "${positional[0]:-}" || status=$?
            else
                ui::error "edit requires an interactive terminal in this build"
                status="$EXIT_USAGE"
            fi
            ;;
        delete)
            tunnel::delete "${positional[0]:-}" "$dry_run" "$force" || status=$?
            ;;
        peer)
            local -a peer_args=("${positional[@]}")
            [[ "$force" == "1" ]] && peer_args+=(--force)
            [[ "$dry_run" == "1" ]] && peer_args+=(--dry-run)
            cli::cmd_peer "${peer_args[@]}" || status=$?
            ;;
        ports)
            cli::cmd_ports "${positional[0]:-}" || status=$?
            ;;
        forward)
            cli::cmd_forward "$dry_run" "${positional[@]}" || status=$?
            ;;
        *)
            ui::error "unknown command: $command"
            cli::usage
            status="$EXIT_USAGE"
            ;;
    esac

    exit "$status"
}

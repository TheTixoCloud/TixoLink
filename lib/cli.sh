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
  create                       Interactive tunnel creation wizard (no flags, TTY)
  create --name N --local-ip IP --remote-ip IP [--mtu M] [--ttl T]
         [--inner-subnet CIDR --inner-local IP --inner-remote IP]
                                Non-interactive create (any flag given skips
                                the wizard; --inner-* must all be given
                                together for manual addressing, otherwise
                                an automatic /30 is allocated)
  start   <id-or-name>         Bring a tunnel up (idempotent)
  stop    <id-or-name>         Take a tunnel down (idempotent)
  restart <id-or-name>         Stop then start a tunnel
  reload  <id-or-name>         Reconcile runtime state to match config
  edit    <id-or-name>         Interactive edit wizard (no flags, TTY)
  edit    <id-or-name> [--local-ip IP] [--remote-ip IP] [--mtu M] [--ttl T] --force
                                Non-interactive edit (requires --force to
                                apply; --dry-run to preview). Any flag you
                                omit keeps that field's CURRENT value
                                unchanged - omitting a flag never resets it
                                to a default.
  delete  <id-or-name>         Delete a tunnel (prompts unless --force)
  peer export <id-or-name>     Print (or --output <file>) a peer document
  peer import <file>           Import a peer document as a new tunnel
  ports [id-or-name]           List forwarding mappings (all tunnels, or one)
  forward add <tunnel> <proto> <port-token> [--listen addr] [--remote-addr addr] [--nat-mode nat|source-preserving]
  forward edit <tunnel> <mapping-id> <port-token>
  forward remove <tunnel> <mapping-id>
  forward status <tunnel>
  forward migrate <tunnel> <none|netfilter|haproxy>
  diagnostics                  System diagnostics (read-only)
  diagnostics system            Same as above
  diagnostics tunnel <id>       Tunnel config/runtime/reachability/forwarding diagnostics
  diagnostics report [--privacy]  Generate a redacted support-report archive
  benchmark <id> [--count N] [--throughput server-ip]  Latency/loss, optional throughput
  monitor <id> [interval_s]    Live rate dashboard (Ctrl+C to exit)
  optimize status              Show currently-applied tunables (read-only)
  optimize recommend <profile>  Show current->proposed plan for a profile (read-only)
  optimize apply <profile>     Apply a profile (requires --force)
  optimize restore [key]       Restore TixoLink-managed tunable(s) to baseline
  bbr status                   Show congestion-control status (read-only)
  bbr enable                   Enable BBR (requires --force)
  bbr disable / bbr restore    Undo TixoLink's BBR change, back to baseline
  backup [--output <file>]     Archive config/tunnels/state/optimizer baseline
  restore <archive>            Restore a backup (requires --force to apply).
                                 Rewrites config/tunnels/state/optimizer
                                 baseline on disk only - does NOT start,
                                 stop, or reload any tunnel/forwarding;
                                 run 'tixolink reload <id>' afterwards for
                                 any tunnel you want reconciled to it.
  update check                 Check GitHub Releases for a newer version
  update apply                 Download, verify, and apply an update (requires --force)
  factory-reset                 Remove all tunnels/forwarding, restore optimizer/BBR
                                 baseline, reset config/state (requires --force)

Profiles: balanced, high_connection_count, high_throughput

Flags (where applicable):
  --dry-run                    Show planned actions without applying them
  --force                      Skip interactive confirmation
  --output <file>              peer export: write to file instead of stdout
  --start                      peer import: start the tunnel after import

<port-token> forms: "443", "8000-9000", "8443:443", "8000-8010:9000-9010"

Running "tixolink" with no command launches the interactive menu when
connected to a terminal.
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

# cli::cmd_create <dry_run> [--name N --local-ip IP --remote-ip IP ...]
# With zero create-specific flags on an interactive TTY, launches the same
# wizard `create` has always launched. With any flag given (or no TTY),
# takes the flag-driven path, which calls the exact same
# tunnel::create_from_fields validation/transaction path the wizard calls
# - no duplicated business logic.
cli::cmd_create() {
    local dry_run="$1"
    shift
    local name="" local_ip="" remote_ip="" mtu="" ttl="" inner_subnet="" inner_local="" inner_remote=""
    local have_flags=0
    while [[ $# -gt 0 ]]; do
        have_flags=1
        case "$1" in
            --name) name="$2"; shift 2 ;;
            --local-ip) local_ip="$2"; shift 2 ;;
            --remote-ip) remote_ip="$2"; shift 2 ;;
            --mtu) mtu="$2"; shift 2 ;;
            --ttl) ttl="$2"; shift 2 ;;
            --inner-subnet) inner_subnet="$2"; shift 2 ;;
            --inner-local) inner_local="$2"; shift 2 ;;
            --inner-remote) inner_remote="$2"; shift 2 ;;
            *) ui::error "create: unknown option $1"; return "$EXIT_USAGE" ;;
        esac
    done

    if [[ "$have_flags" == "0" ]]; then
        if [[ -t 0 && -t 1 ]]; then
            menu::wizard_create_tunnel
            return $?
        fi
        ui::error "create requires either an interactive terminal or --name/--local-ip/--remote-ip"
        return "$EXIT_USAGE"
    fi

    [[ -n "$name" ]]      || { ui::error "create: --name is required"; return "$EXIT_USAGE"; }
    [[ -n "$local_ip" ]]  || { ui::error "create: --local-ip is required"; return "$EXIT_USAGE"; }
    [[ -n "$remote_ip" ]] || { ui::error "create: --remote-ip is required"; return "$EXIT_USAGE"; }
    mtu="${mtu:-1300}"
    ttl="${ttl:-255}"

    validate::tunnel_name "$name" || { ui::error "create: invalid --name: $name"; return "$EXIT_VALIDATION"; }
    validate::ipv4 "$local_ip" || { ui::error "create: invalid --local-ip: $local_ip"; return "$EXIT_VALIDATION"; }
    validate::ipv4 "$remote_ip" || { ui::error "create: invalid --remote-ip: $remote_ip"; return "$EXIT_VALIDATION"; }
    validate::mtu "$mtu" || { ui::error "create: invalid --mtu: $mtu"; return "$EXIT_VALIDATION"; }
    validate::ttl "$ttl" || { ui::error "create: invalid --ttl: $ttl"; return "$EXIT_VALIDATION"; }

    local addr_mode="auto"
    if [[ -n "$inner_subnet" || -n "$inner_local" || -n "$inner_remote" ]]; then
        if [[ -z "$inner_subnet" || -z "$inner_local" || -z "$inner_remote" ]]; then
            ui::error "create: --inner-subnet/--inner-local/--inner-remote must all be given together for manual addressing"
            return "$EXIT_USAGE"
        fi
        if ! validate::cidr "$inner_subnet" || [[ "${inner_subnet#*/}" != "30" ]]; then
            ui::error "create: --inner-subnet must be a valid /30 CIDR: $inner_subnet"
            return "$EXIT_VALIDATION"
        fi
        validate::ipv4 "$inner_local" || { ui::error "create: invalid --inner-local: $inner_local"; return "$EXIT_VALIDATION"; }
        validate::ipv4 "$inner_remote" || { ui::error "create: invalid --inner-remote: $inner_remote"; return "$EXIT_VALIDATION"; }
        addr_mode="manual"
    fi

    local id status=0
    id="$(tunnel::create_from_fields "$name" "$local_ip" "$remote_ip" "$addr_mode" \
        "$inner_subnet" "$inner_local" "$inner_remote" "$mtu" "$ttl" "$dry_run")" || status=$?
    [[ "$status" -ne 0 ]] && return "$status"
    if [[ "$dry_run" == "1" ]]; then
        ui::info "PLAN: would create tunnel '$name' (id: $id)"
    else
        printf '%s\n' "$id"
    fi
    return 0
}

# cli::cmd_edit <dry_run> <force> <id-or-name> [--local-ip IP] [--remote-ip IP] [--mtu M] [--ttl T]
# A flag that is NOT given is resolved from the tunnel's CURRENT config
# before calling tunnel::edit_from_fields (which requires all four
# positionally) - omitting a flag always means "leave this field exactly
# as it is," never "reset it to a default." Mirrors exactly what the
# interactive wizard does via ui::input's own current-value default.
cli::cmd_edit() {
    local dry_run="$1" force="$2"
    shift 2
    local ref="${1:-}"
    [[ $# -gt 0 ]] && shift
    local local_ip="" remote_ip="" mtu="" ttl=""
    local have_flags=0
    while [[ $# -gt 0 ]]; do
        have_flags=1
        case "$1" in
            --local-ip) local_ip="$2"; shift 2 ;;
            --remote-ip) remote_ip="$2"; shift 2 ;;
            --mtu) mtu="$2"; shift 2 ;;
            --ttl) ttl="$2"; shift 2 ;;
            *) ui::error "edit: unknown option $1"; return "$EXIT_USAGE" ;;
        esac
    done

    [[ -n "$ref" ]] || { ui::error "edit requires a tunnel id or name"; return "$EXIT_USAGE"; }

    if [[ "$have_flags" == "0" ]]; then
        if [[ -t 0 && -t 1 ]]; then
            menu::wizard_edit_tunnel "$ref"
            return $?
        fi
        ui::error "edit requires either an interactive terminal or at least one of --local-ip/--remote-ip/--mtu/--ttl"
        return "$EXIT_USAGE"
    fi

    local id; id="$(tunnel::resolve "$ref")" || return $?
    local cfg; cfg="$(config::tunnel_read "$id")" || return "$EXIT_NOT_FOUND"
    local ec; ec="$(jq -c '.engine_config' <<<"$cfg")"

    [[ -z "$local_ip" ]]  && local_ip="$(jq -r '.local_public_ip' <<<"$ec")"
    [[ -z "$remote_ip" ]] && remote_ip="$(jq -r '.remote_public_ip' <<<"$ec")"
    [[ -z "$mtu" ]]       && mtu="$(jq -r '.mtu' <<<"$ec")"
    [[ -z "$ttl" ]]       && ttl="$(jq -r '.ttl' <<<"$ec")"

    validate::ipv4 "$local_ip" || { ui::error "edit: invalid --local-ip: $local_ip"; return "$EXIT_VALIDATION"; }
    validate::ipv4 "$remote_ip" || { ui::error "edit: invalid --remote-ip: $remote_ip"; return "$EXIT_VALIDATION"; }
    validate::mtu "$mtu" || { ui::error "edit: invalid --mtu: $mtu"; return "$EXIT_VALIDATION"; }
    validate::ttl "$ttl" || { ui::error "edit: invalid --ttl: $ttl"; return "$EXIT_VALIDATION"; }

    if [[ "$dry_run" != "1" && "$force" != "1" ]]; then
        ui::warning "This would mutate tunnel $id. Re-run with --dry-run to preview, or --force to apply."
        return "$EXIT_USAGE"
    fi

    tunnel::edit_from_fields "$id" "$local_ip" "$remote_ip" "$mtu" "$ttl" "$dry_run"
}

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

cli::cmd_diagnostics() {
    local sub="${1:-system}"
    case "$sub" in
        system)
            diagnostics::system | jq .
            ;;
        tunnel)
            local ref="${2:-}"
            [[ -z "$ref" ]] && { ui::error "diagnostics tunnel requires a tunnel id or name"; return "$EXIT_USAGE"; }
            diagnostics::tunnel "$ref"
            ;;
        report)
            local privacy=""
            [[ "${2:-}" == "--privacy" ]] && privacy="--privacy"
            local report; report="$(diagnostics::generate_report $privacy)"
            ui::success "Support report written to: $report"
            ui::info "Inspect it with: tar tzf '$report'"
            ;;
        *)
            ui::error "unknown diagnostics subcommand: $sub"
            return "$EXIT_USAGE"
            ;;
    esac
}

cli::cmd_benchmark() {
    local ref="$1" count="${2:-3}" throughput_server="${3:-}"
    local id; id="$(tunnel::resolve "$ref")" || return $?
    local cfg; cfg="$(config::tunnel_read "$id")" || return "$EXIT_NOT_FOUND"
    local remote_public inner_remote
    remote_public="$(jq -r '.engine_config.remote_public_ip' <<<"$cfg")"
    inner_remote="$(jq -r '.engine_config.inner_remote_ip' <<<"$cfg")"

    ui::section "Latency / loss benchmark: $ref"
    printf 'Public peer (%s):\n' "$remote_public"
    benchmark::latency "$remote_public" "$count" 2 | jq .
    printf 'Inner peer (%s):\n' "$inner_remote"
    benchmark::latency "$inner_remote" "$count" 2 | jq .

    if [[ -n "$throughput_server" ]]; then
        ui::section "Throughput benchmark (iperf3, explicit target: $throughput_server)"
        benchmark::throughput "$throughput_server" | jq .
    fi
    return 0
}

cli::cmd_optimize() {
    local sub="$1" force="$2" dry_run="$3"
    shift 3
    case "$sub" in
        status)
            optimizer::status
            ;;
        recommend)
            local profile="${1:-}"
            [[ -z "$profile" ]] && { ui::error "optimize recommend requires a profile"; return "$EXIT_USAGE"; }
            optimizer::plan "$profile" | jq .
            ;;
        apply)
            local profile="${1:-}"
            [[ -z "$profile" ]] && { ui::error "optimize apply requires a profile"; return "$EXIT_USAGE"; }
            if [[ "$dry_run" != "1" && "$force" != "1" ]]; then
                ui::warning "This would mutate host sysctls. Re-run with --dry-run to preview, or --force to apply."
                return "$EXIT_USAGE"
            fi
            optimizer::apply_profile "$profile" "$dry_run"
            ;;
        restore)
            optimizer::restore "${1:-}"
            ;;
        *)
            ui::error "unknown optimize subcommand: $sub"
            return "$EXIT_USAGE"
            ;;
    esac
}

cli::cmd_bbr() {
    local sub="$1" force="$2" dry_run="$3"
    case "$sub" in
        status)
            bbr::status
            ;;
        enable)
            if [[ "$dry_run" != "1" && "$force" != "1" ]]; then
                ui::warning "This would mutate the host's TCP congestion control. Re-run with --dry-run to preview, or --force to apply."
                return "$EXIT_USAGE"
            fi
            bbr::enable "$dry_run"
            ;;
        disable) bbr::disable ;;
        restore) bbr::restore ;;
        *)
            ui::error "unknown bbr subcommand: $sub"
            return "$EXIT_USAGE"
            ;;
    esac
}

cli::cmd_backup() {
    local output="" force=0 dry_run="$1"
    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output) output="$2"; shift 2 ;;
            --force) force=1; shift ;;
            *) ui::error "backup: unknown option $1"; return "$EXIT_USAGE" ;;
        esac
    done
    [[ "$dry_run" == "1" ]] && { ui::info "backup does not support --dry-run (it never mutates anything other than creating the archive)."; }
    local -a args=()
    [[ -n "$output" ]] && args+=(--output "$output")
    [[ "$force" == "1" ]] && args+=(--force)
    local archive; archive="$(backup::create "${args[@]}")" || return $?
    ui::success "Backup created: $archive"
}

cli::cmd_restore() {
    local archive="$1" force="$2" dry_run="$3"
    local -a args=()
    [[ "$force" == "1" ]] && args+=(--force)
    [[ "$dry_run" == "1" ]] && args+=(--dry-run)
    restore::run "$archive" "${args[@]}"
}

cli::cmd_update() {
    local sub="$1" force="$2" dry_run="$3"
    case "$sub" in
        check)
            update::check | jq .
            ;;
        apply)
            local -a args=()
            [[ "$force" == "1" ]] && args+=(--force)
            [[ "$dry_run" == "1" ]] && args+=(--dry-run)
            update::apply "${args[@]}"
            ;;
        *)
            ui::error "unknown update subcommand: $sub"
            return "$EXIT_USAGE"
            ;;
    esac
}

cli::cmd_factory_reset() {
    local force="$1" dry_run="$2"
    local -a args=()
    [[ "$force" == "1" ]] && args+=(--force)
    [[ "$dry_run" == "1" ]] && args+=(--dry-run)
    lifecycle::factory_reset "${args[@]}"
}

cli::cmd_monitor() {
    local ref="$1" interval="${2:-2}"
    if [[ ! -t 0 || ! -t 1 ]]; then
        ui::error "monitor requires an interactive terminal"
        return "$EXIT_USAGE"
    fi
    monitor::run "$ref" "$interval"
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
            cli::cmd_create "$dry_run" "${positional[@]}" || status=$?
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
            cli::cmd_edit "$dry_run" "$force" "${positional[@]}" || status=$?
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
        diagnostics)
            cli::cmd_diagnostics "${positional[@]}" || status=$?
            ;;
        benchmark)
            cli::cmd_benchmark "${positional[@]}" || status=$?
            ;;
        monitor)
            cli::cmd_monitor "${positional[@]}" || status=$?
            ;;
        optimize)
            cli::cmd_optimize "${positional[0]:-}" "$force" "$dry_run" "${positional[@]:1}" || status=$?
            ;;
        bbr)
            cli::cmd_bbr "${positional[0]:-}" "$force" "$dry_run" || status=$?
            ;;
        backup)
            local -a backup_args=("${positional[@]}")
            [[ "$force" == "1" ]] && backup_args+=(--force)
            cli::cmd_backup "$dry_run" "${backup_args[@]}" || status=$?
            ;;
        restore)
            cli::cmd_restore "${positional[0]:-}" "$force" "$dry_run" || status=$?
            ;;
        update)
            cli::cmd_update "${positional[0]:-}" "$force" "$dry_run" || status=$?
            ;;
        factory-reset)
            cli::cmd_factory_reset "$force" "$dry_run" || status=$?
            ;;
        *)
            ui::error "unknown command: $command"
            cli::usage
            status="$EXIT_USAGE"
            ;;
    esac

    exit "$status"
}

#!/usr/bin/env bash
# TixoLink NEXUS - input validation
#
# All functions are pure (no side effects, no I/O) and treat every argument
# as untrusted. They return 0 (valid) or 1 (invalid); nothing here ever
# calls eval or constructs a command string from the input.

if [[ -n "${TIXOLINK_VALIDATION_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_VALIDATION_SH_LOADED=1

# validate::ipv4 <string>
validate::ipv4() {
    local ip="$1"
    local -a octets
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    IFS='.' read -r -a octets <<<"$ip"
    local o
    for o in "${octets[@]}"; do
        [[ "$o" =~ ^[0-9]+$ ]] || return 1
        (( 10#$o <= 255 )) || return 1
        [[ "$o" == "0" || "$o" != 0* ]] || return 1
    done
    return 0
}

# validate::cidr <string>   (e.g. 10.200.0.0/16)
validate::cidr() {
    local cidr="$1"
    [[ "$cidr" == */* ]] || return 1
    local addr="${cidr%/*}" prefix="${cidr#*/}"
    validate::ipv4 "$addr" || return 1
    [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
    (( prefix >= 0 && prefix <= 32 )) || return 1
    return 0
}

# validate::port <number>
validate::port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] || return 1
    (( 10#$port >= 1 && 10#$port <= 65535 ))
}

# validate::port_range <low>-<high>
validate::port_range() {
    local range="$1"
    [[ "$range" == *-* ]] || return 1
    local low="${range%-*}" high="${range#*-}"
    validate::port "$low" || return 1
    validate::port "$high" || return 1
    (( 10#$low <= 10#$high ))
}

# validate::port_spec <spec>
# Accepts comma-separated ports and ranges, e.g. "80,443,8000-9000".
validate::port_spec() {
    local spec="$1"
    [[ -n "$spec" ]] || return 1
    # `read` stops at the first newline regardless of IFS, which would
    # silently validate only the part before an embedded newline and
    # discard the rest while still reporting success - reject outright
    # instead of ever risking that silent truncation.
    [[ "$spec" != *$'\n'* ]] || return 1
    local -a parts
    IFS=',' read -r -a parts <<<"$spec"
    local part
    for part in "${parts[@]}"; do
        part="$(common::trim "$part")"
        [[ -n "$part" ]] || return 1
        if [[ "$part" == *-* ]]; then
            validate::port_range "$part" || return 1
        else
            validate::port "$part" || return 1
        fi
    done
    return 0
}

# validate::protocol <proto>
validate::protocol() {
    case "$(common::lower "$1")" in
        tcp|udp|tcp+udp) return 0 ;;
        *) return 1 ;;
    esac
}

# validate::mtu <number>
# GRE over IPv4 practical range: 68 (minimum IPv4 MTU) to 65535 (kernel cap),
# though usable physical-network values realistically sit between 576-9000.
validate::mtu() {
    local mtu="$1"
    [[ "$mtu" =~ ^[0-9]+$ ]] || return 1
    (( 10#$mtu >= 68 && 10#$mtu <= 65535 ))
}

# validate::ttl <number>
validate::ttl() {
    local ttl="$1"
    [[ "$ttl" =~ ^[0-9]+$ ]] || return 1
    (( 10#$ttl >= 1 && 10#$ttl <= 255 ))
}

# validate::iface_name <name>
# Linux IFNAMSIZ is 16 bytes including the terminating NUL, so 15 usable
# characters. Restrict to a conservative safe charset.
validate::iface_name() {
    local name="$1"
    [[ ${#name} -ge 1 && ${#name} -le 15 ]] || return 1
    [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]
}

# validate::tunnel_name <name>
# Human-readable display name: conservative charset, reasonable length,
# disallows leading/trailing whitespace by construction (no spaces at all).
validate::tunnel_name() {
    local name="$1"
    [[ ${#name} -ge 1 && ${#name} -le 64 ]] || return 1
    [[ "$name" =~ ^[a-zA-Z0-9._-]+$ ]]
}

# validate::tunnel_id <id>
# Stable tunnel identity: exactly 8 lowercase hex characters.
validate::tunnel_id() {
    [[ "$1" =~ ^[0-9a-f]{8}$ ]]
}

# validate::path_within <path> <allowed-root>
# Resolves <path> and confirms it is actually inside <allowed-root>, to
# defend against symlink-based path escapes.
validate::path_within() {
    local path="$1" root="$2"
    local resolved_root resolved_path
    resolved_root="$(realpath -e "$root" 2>/dev/null)" || return 1
    resolved_path="$(realpath -m "$path" 2>/dev/null)" || return 1
    [[ "$resolved_path" == "$resolved_root" || "$resolved_path" == "$resolved_root"/* ]]
}

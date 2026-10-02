#!/usr/bin/env bash
# TixoLink NEXUS - automatic inner /30 subnet allocation
#
# Allocates /30 blocks out of a configurable pool (default
# 10.200.0.0/16, see lib/config.sh), checking for collisions against
# other TixoLink tunnels, live host addresses, and host routes. This file
# is split from lib/config.sh so the core allocation algorithm
# (subnet::allocate_from_pool) is a pure function that unit tests can
# exercise deterministically without touching real network state.

if [[ -n "${TIXOLINK_SUBNET_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_SUBNET_SH_LOADED=1

# --- IPv4 <-> integer helpers ------------------------------------------------
subnet::_ip_to_int() {
    local ip="$1" a b c d
    IFS='.' read -r a b c d <<<"$ip"
    printf '%d' "$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))"
}

subnet::_int_to_ip() {
    local n="$1"
    printf '%d.%d.%d.%d' "$(( (n >> 24) & 255 ))" "$(( (n >> 16) & 255 ))" \
        "$(( (n >> 8) & 255 ))" "$(( n & 255 ))"
}

# subnet::_network_int <cidr>
subnet::_network_int() {
    local cidr="$1"
    local ip="${cidr%/*}" prefix="${cidr#*/}"
    local ip_int mask
    ip_int="$(subnet::_ip_to_int "$ip")"
    if [[ "$prefix" -eq 0 ]]; then
        mask=0
    else
        mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    fi
    printf '%d' "$(( ip_int & mask ))"
}

# subnet::_broadcast_int <cidr>
subnet::_broadcast_int() {
    local cidr="$1"
    local prefix="${cidr#*/}"
    local net size
    net="$(subnet::_network_int "$cidr")"
    if [[ "$prefix" -eq 32 ]]; then
        size=0
    else
        size=$(( (1 << (32 - prefix)) - 1 ))
    fi
    printf '%d' "$(( net + size ))"
}

# subnet::_as_cidr <ip-or-cidr>
# Normalizes a bare IPv4 address to a /32 CIDR; passes an existing CIDR
# through unchanged.
subnet::_as_cidr() {
    local v="$1"
    [[ "$v" == */* ]] && printf '%s' "$v" || printf '%s/32' "$v"
}

# subnet::_overlaps <cidr-a> <cidr-b>
subnet::_overlaps() {
    local a_net a_bc b_net b_bc
    a_net="$(subnet::_network_int "$(subnet::_as_cidr "$1")")"
    a_bc="$(subnet::_broadcast_int "$(subnet::_as_cidr "$1")")"
    b_net="$(subnet::_network_int "$(subnet::_as_cidr "$2")")"
    b_bc="$(subnet::_broadcast_int "$(subnet::_as_cidr "$2")")"
    (( a_net <= b_bc && b_net <= a_bc ))
}

# subnet::_enumerate_blocks <pool-cidr>
# Prints every /30 block within the pool, in ascending network-address order.
subnet::_enumerate_blocks() {
    local pool="$1" net broadcast cur
    net="$(subnet::_network_int "$pool")"
    broadcast="$(subnet::_broadcast_int "$pool")"
    for (( cur = net; cur + 3 <= broadcast; cur += 4 )); do
        printf '%s/30\n' "$(subnet::_int_to_ip "$cur")"
    done
}

# --- Pure allocation algorithm -----------------------------------------------
# subnet::allocate_from_pool <pool-cidr> [exclusion-cidr ...]
# Returns the first /30 in the pool that does not overlap any exclusion.
# Deterministic: always scans the pool in the same ascending order, so the
# same pool/exclusion-set always yields the same result. Returns
# EXIT_CONFLICT if the pool is exhausted.
subnet::allocate_from_pool() {
    local pool="$1"
    shift
    local -a exclusions=("$@")
    local candidate ex collision

    while IFS= read -r candidate; do
        collision=0
        for ex in "${exclusions[@]:-}"; do
            [[ -z "$ex" ]] && continue
            if subnet::_overlaps "$candidate" "$ex"; then
                collision=1
                break
            fi
        done
        if [[ "$collision" -eq 0 ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done < <(subnet::_enumerate_blocks "$pool")

    log::error "subnet pool $pool is exhausted (no free /30 remaining)"
    return "$EXIT_CONFLICT"
}

# --- Real-world exclusion gathering ------------------------------------------
# Split into small overridable functions so tests can substitute fake
# "live address"/"route" data without touching the real host network stack.

# subnet::_live_addresses - current IPv4 addresses on this host/namespace.
subnet::_live_addresses() {
    ip -4 -j addr show 2>/dev/null \
        | jq -r '.[].addr_info[]? | "\(.local)/\(.prefixlen)"' 2>/dev/null
}

# subnet::_live_routes - current IPv4 route destinations (excluding default).
subnet::_live_routes() {
    ip -4 -j route show 2>/dev/null \
        | jq -r '.[].dst // empty' 2>/dev/null \
        | grep -v '^default$' || true
}

# subnet::_tunnel_subnets - inner_subnet of every existing TixoLink tunnel.
subnet::_tunnel_subnets() {
    local id
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        config::tunnel_read "$id" 2>/dev/null \
            | jq -r '.engine_config.inner_subnet // empty' 2>/dev/null
    done < <(config::tunnel_list)
}

# subnet::collect_exclusions
# Gathers every CIDR that a newly-allocated /30 must not overlap: existing
# TixoLink tunnel subnets, live addresses, and live routes.
subnet::collect_exclusions() {
    local line
    { subnet::_tunnel_subnets; subnet::_live_addresses; subnet::_live_routes; } \
        | while IFS= read -r line; do
            [[ -n "$line" ]] && printf '%s\n' "$(subnet::_as_cidr "$line")"
        done
}

# subnet::allocate
# Allocates a /30 from the configured pool (lib/config.sh:config::get
# '.subnet_pool', falling back to the documented default), checking real
# exclusions gathered from this host/namespace.
subnet::allocate() {
    local pool
    pool="$(config::get '.subnet_pool' 2>/dev/null)" || pool="$TIXOLINK_DEFAULT_SUBNET_POOL"
    local -a exclusions=()
    local ex
    while IFS= read -r ex; do
        exclusions+=("$ex")
    done < <(subnet::collect_exclusions)
    subnet::allocate_from_pool "$pool" "${exclusions[@]}"
}

#!/usr/bin/env bash
# TixoLink NEXUS - platform detection
#
# Every function here is strictly read-only: it inspects the host and
# reports, it never modifies networking, firewall, systemd, or sysctl state.

if [[ -n "${TIXOLINK_PLATFORM_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_PLATFORM_SH_LOADED=1

# platform::os_id - e.g. "ubuntu", "debian"
platform::os_id() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        ( . /etc/os-release && printf '%s' "${ID:-unknown}" )
    else
        printf 'unknown'
    fi
}

# platform::os_version - e.g. "24.04"
platform::os_version() {
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        ( . /etc/os-release && printf '%s' "${VERSION_ID:-unknown}" )
    else
        printf 'unknown'
    fi
}

# platform::kernel
platform::kernel() {
    uname -r
}

# platform::arch
platform::arch() {
    uname -m
}

# platform::virt - best effort; prints "unknown" if systemd-detect-virt is absent.
platform::virt() {
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        systemd-detect-virt 2>/dev/null || true
    else
        printf 'unknown'
    fi
}

# platform::is_supported_os
# TixoLink's initial supported matrix: Ubuntu 22.04/24.04, Debian 12.
platform::is_supported_os() {
    local id version
    id="$(platform::os_id)"
    version="$(platform::os_version)"
    case "$id" in
        ubuntu)
            [[ "$version" == "22.04" || "$version" == "24.04" ]] && return 0
            ;;
        debian)
            [[ "$version" == "12" ]] && return 0
            ;;
    esac
    return 1
}

# platform::gre_module_available
# Checks whether the running kernel has GRE support, either already loaded
# or available to load, without loading it.
platform::gre_module_available() {
    if lsmod 2>/dev/null | grep -q '^ip_gre'; then
        return 0
    fi
    if command -v modinfo >/dev/null 2>&1 && modinfo ip_gre >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# platform::ipv4_forwarding_enabled
platform::ipv4_forwarding_enabled() {
    local val
    val="$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)"
    [[ "$val" == "1" ]]
}

# platform::iptables_backend
# Prints "nf_tables", "legacy", or "unknown".
platform::iptables_backend() {
    if ! command -v iptables >/dev/null 2>&1; then
        printf 'absent'
        return 0
    fi
    local version_str
    version_str="$(iptables --version 2>/dev/null || true)"
    if [[ "$version_str" == *nf_tables* ]]; then
        printf 'nf_tables'
    elif [[ "$version_str" == *legacy* ]]; then
        printf 'legacy'
    else
        printf 'unknown'
    fi
}

# platform::has_nft
platform::has_nft() {
    command -v nft >/dev/null 2>&1
}

# platform::has_ufw
platform::has_ufw() {
    command -v ufw >/dev/null 2>&1
}

# platform::has_docker
platform::has_docker() {
    command -v docker >/dev/null 2>&1
}

# platform::has_podman
platform::has_podman() {
    command -v podman >/dev/null 2>&1
}

# platform::has_haproxy
platform::has_haproxy() {
    command -v haproxy >/dev/null 2>&1
}

# platform::congestion_control - currently active TCP congestion control algorithm.
platform::congestion_control() {
    cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || printf 'unknown'
}

# platform::available_congestion_control
platform::available_congestion_control() {
    cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || printf 'unknown'
}

# platform::default_qdisc
platform::default_qdisc() {
    cat /proc/sys/net/core/default_qdisc 2>/dev/null || printf 'unknown'
}

# platform::public_ipv4_addresses
# Lists non-loopback, non-link-local IPv4 addresses configured on the host.
# This is informational only (used by the wizard to offer a "local IP"
# choice); it does not attempt to determine which address is internet-routable.
platform::public_ipv4_addresses() {
    ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1
}

# platform::default_route_interface
platform::default_route_interface() {
    ip -4 route show default 2>/dev/null | awk '/^default/ {print $5; exit}'
}

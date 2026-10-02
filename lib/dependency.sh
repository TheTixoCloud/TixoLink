#!/usr/bin/env bash
# TixoLink NEXUS - dependency manager
#
# Centralizes the declarative package manifest and the single apt-get
# install code path. No other module is permitted to shell out to apt
# directly. Never runs `apt-get upgrade`/`dist-upgrade`.

if [[ -n "${TIXOLINK_DEPENDENCY_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_DEPENDENCY_SH_LOADED=1

# Package -> apt package name, and which feature tag requires it.
# REQUIRED tags are needed for the application to function at all.
# OPTIONAL tags enhance diagnostics/benchmarking but degrade gracefully.
# FEATURE:<name> tags are only needed when that forwarding/engine feature
# is actually selected by the user.
#
# Each array below is only read indirectly, through the `local -n _manifest`
# nameref assigned from a string in dependency::missing/dependency::ensure,
# so ShellCheck's static analysis cannot trace the reference - SC2034 here
# is a false positive by design.
# shellcheck disable=SC2034
declare -gA TIXOLINK_DEP_REQUIRED=(
    [iproute2]="iproute2"
    [ping]="iputils-ping"
    [jq]="jq"
)

# shellcheck disable=SC2034
declare -gA TIXOLINK_DEP_OPTIONAL=(
    [mtr]="mtr-tiny"
    [iperf3]="iperf3"
    [sysstat]="sysstat"
    [ethtool]="ethtool"
    [conntrack]="conntrack"
    [tracepath]="iputils-tracepath"
)

# shellcheck disable=SC2034
declare -gA TIXOLINK_DEP_FEATURE_NETFILTER=(
    [iptables]="iptables"
)

# shellcheck disable=SC2034
declare -gA TIXOLINK_DEP_FEATURE_HAPROXY=(
    [haproxy]="haproxy"
    [socat]="socat"
)

# dependency::command_for <package-key>
# Returns the command name used to check presence, when it differs from the
# apt package name (e.g. apt package "mtr-tiny" provides command "mtr").
dependency::command_for() {
    case "$1" in
        mtr) printf 'mtr' ;;
        tracepath) printf 'tracepath' ;;
        conntrack) printf 'conntrack' ;;
        *) printf '%s' "$1" ;;
    esac
}

# dependency::is_present <package-key>
dependency::is_present() {
    command -v "$(dependency::command_for "$1")" >/dev/null 2>&1
}

# dependency::missing <tag>
# tag is one of: required, optional, netfilter, haproxy
# Prints missing package keys (one per line) for the given tag's manifest.
dependency::missing() {
    local tag="$1"
    local -n _manifest
    case "$tag" in
        required)  _manifest=TIXOLINK_DEP_REQUIRED ;;
        optional)  _manifest=TIXOLINK_DEP_OPTIONAL ;;
        netfilter) _manifest=TIXOLINK_DEP_FEATURE_NETFILTER ;;
        haproxy)   _manifest=TIXOLINK_DEP_FEATURE_HAPROXY ;;
        *) return 1 ;;
    esac
    local key
    for key in "${!_manifest[@]}"; do
        dependency::is_present "$key" || printf '%s\n' "$key"
    done
    return 0
}

# dependency::ensure <tag>
# Installs any missing packages for the given tag. Must only be called
# after the caller has obtained explicit user confirmation.
dependency::ensure() {
    local tag="$1"
    local -n _manifest
    case "$tag" in
        required)  _manifest=TIXOLINK_DEP_REQUIRED ;;
        optional)  _manifest=TIXOLINK_DEP_OPTIONAL ;;
        netfilter) _manifest=TIXOLINK_DEP_FEATURE_NETFILTER ;;
        haproxy)   _manifest=TIXOLINK_DEP_FEATURE_HAPROXY ;;
        *) return "$EXIT_USAGE" ;;
    esac

    common::require_root || return "$EXIT_PERMISSION"

    local -a to_install=()
    local key
    for key in "${!_manifest[@]}"; do
        dependency::is_present "$key" || to_install+=("${_manifest[$key]}")
    done

    if [[ ${#to_install[@]} -eq 0 ]]; then
        return 0
    fi

    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${to_install[@]}"
}

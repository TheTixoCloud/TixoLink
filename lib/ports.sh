#!/usr/bin/env bash
# TixoLink NEXUS - port parsing and remapping for forwarding mappings.
#
# A forwarding "mapping" represents exactly one protocol + one local
# port-or-range + one remote port-or-range (see docs/architecture.md). The
# functions here parse and validate a single mapping token (optionally
# comma-separated for convenience when adding several mappings at once -
# see ports::expand_spec) and never pass raw user port expressions
# directly to a shell command.

if [[ -n "${TIXOLINK_PORTS_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_PORTS_SH_LOADED=1

# ports::_is_range <token>
ports::_is_range() { [[ "$1" == *-* ]]; }

# ports::_range_low <range>  / ports::_range_high <range>
ports::_range_low()  { printf '%s' "${1%-*}"; }
ports::_range_high() { printf '%s' "${1#*-}"; }

# ports::_cardinality <port-or-range>
# Prints how many ports a single port or range token represents.
ports::_cardinality() {
    local tok="$1"
    if ports::_is_range "$tok"; then
        printf '%d' "$(( $(ports::_range_high "$tok") - $(ports::_range_low "$tok") + 1 ))"
    else
        printf '1'
    fi
}

# ports::_validate_single <port-or-range>
# Validates syntax and bounds of one port or range (no remap colon).
ports::_validate_single() {
    local tok="$1"
    if ports::_is_range "$tok"; then
        validate::port_range "$tok"
    else
        validate::port "$tok"
    fi
}

# ports::parse_token <token>
# Parses exactly one mapping token:
#   "80"              -> local=80         remote=80
#   "80-90"           -> local=80-90      remote=80-90
#   "8443:443"        -> local=8443       remote=443
#   "8000-8010:9000-9010" -> local=8000-8010  remote=9000-9010 (cardinality must match)
# Prints "local|remote" on success. Returns EXIT_VALIDATION on anything
# malformed, out of range, reversed, or with mismatched range cardinality.
ports::parse_token() {
    local token="$1"
    [[ -n "$token" ]] || return "$EXIT_VALIDATION"

    local local_part remote_part
    case "$token" in
        *:*)
            [[ "$token" == *:*:* ]] && return "$EXIT_VALIDATION"  # more than one colon
            local_part="${token%%:*}"
            remote_part="${token#*:}"
            ;;
        *)
            local_part="$token"
            remote_part="$token"
            ;;
    esac

    ports::_validate_single "$local_part" || return "$EXIT_VALIDATION"
    ports::_validate_single "$remote_part" || return "$EXIT_VALIDATION"

    local local_is_range remote_is_range
    ports::_is_range "$local_part" && local_is_range=1 || local_is_range=0
    ports::_is_range "$remote_part" && remote_is_range=1 || remote_is_range=0

    # Range-to-single or single-to-range remapping is not a supported
    # semantic (ambiguous which single port every element in the range
    # would land on); only single->single or range->range (with matching
    # cardinality) are accepted.
    if [[ "$local_is_range" != "$remote_is_range" ]]; then
        return "$EXIT_VALIDATION"
    fi
    if [[ "$local_is_range" == "1" ]]; then
        [[ "$(ports::_cardinality "$local_part")" == "$(ports::_cardinality "$remote_part")" ]] || return "$EXIT_VALIDATION"
    fi

    printf '%s|%s' "$local_part" "$remote_part"
}

# ports::_overlaps <port-or-range-a> <port-or-range-b>
ports::_overlaps() {
    local a="$1" b="$2"
    local a_lo a_hi b_lo b_hi
    if ports::_is_range "$a"; then a_lo=$(ports::_range_low "$a"); a_hi=$(ports::_range_high "$a"); else a_lo="$a"; a_hi="$a"; fi
    if ports::_is_range "$b"; then b_lo=$(ports::_range_low "$b"); b_hi=$(ports::_range_high "$b"); else b_lo="$b"; b_hi="$b"; fi
    (( a_lo <= b_hi && b_lo <= a_hi ))
}

# ports::expand_spec <comma-separated-spec>
# Expands a convenience multi-token spec (e.g. "80,443,8000-9000" or
# "80,8443:443") into one normalized "local|remote" line per token.
# Rejects the whole spec if any token is malformed, or if any two tokens
# in the spec have overlapping local-port ranges (duplicate/overlapping
# mappings within a single add operation).
ports::expand_spec() {
    local spec="$1"
    [[ -n "$spec" ]] || return "$EXIT_VALIDATION"

    local -a tokens parsed_locals=() lines=()
    IFS=',' read -r -a tokens <<<"$spec"
    [[ ${#tokens[@]} -gt 0 ]] || return "$EXIT_VALIDATION"

    local tok line local_part i j
    for tok in "${tokens[@]}"; do
        tok="$(common::trim "$tok")"
        line="$(ports::parse_token "$tok")" || return "$EXIT_VALIDATION"
        lines+=("$line")
        parsed_locals+=("${line%%|*}")
    done

    for (( i=0; i<${#parsed_locals[@]}; i++ )); do
        for (( j=i+1; j<${#parsed_locals[@]}; j++ )); do
            if ports::_overlaps "${parsed_locals[$i]}" "${parsed_locals[$j]}"; then
                log::error "overlapping/duplicate local ports in spec: ${parsed_locals[$i]} and ${parsed_locals[$j]}"
                return "$EXIT_VALIDATION"
            fi
        done
    done

    local out
    for out in "${lines[@]}"; do
        printf '%s\n' "$out"
    done
}

# ports::mapping_conflicts_with <local-port-or-range> <protocol> <other-local-port-or-range> <other-protocol>
# Two mappings conflict only if they share a protocol (or either is
# "tcp+udp") and their local port ranges overlap - listen address
# scoping is handled by the caller (different listen addresses on the
# same port never conflict at the netfilter/haproxy level, but TixoLink's
# current model has one implicit listen scope per tunnel, so callers
# normally pass matching addresses already).
ports::mapping_conflicts_with() {
    local a_port="$1" a_proto="$2" b_port="$3" b_proto="$4"
    local protos_overlap=0
    case "$a_proto:$b_proto" in
        *tcp+udp*|tcp:tcp|udp:udp) protos_overlap=1 ;;
    esac
    [[ "$protos_overlap" == "1" ]] || return 1
    ports::_overlaps "$a_port" "$b_port"
}

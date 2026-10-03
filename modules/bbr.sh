#!/usr/bin/env bash
# TixoLink NEXUS - BBR congestion control manager
#
# Deliberately a thin layer over modules/optimizer.sh: BBR management
# uses the EXACT same baseline/applied/verify/rollback machinery as the
# general optimizer (one managed tunable, net.ipv4.tcp_congestion_control,
# under the "bbr_enable" profile in optimizer::registry) rather than a
# second, parallel implementation. This is what guarantees BBR shares
# the optimizer's ownership guarantees:
#   - if the host already uses BBR before TixoLink ever touches it,
#     enabling is recognized as a no-op and NO baseline is recorded (so
#     a later restore cannot possibly move the host away from an
#     administrator's own pre-existing BBR choice - ownership is only
#     ever claimed over a change TixoLink itself made);
#   - restore always returns to the ORIGINAL pre-TixoLink value, never
#     to some intermediate value, via optimizer's baseline semantics.
#
# default_qdisc is deliberately NOT managed here: BBR does not strictly
# require `fq` (it works, with reduced pacing benefit, on pfifo_fast
# too, since Linux 4.13+) - assuming every environment needs an fq
# qdisc change is exactly the kind of unverified folklore tunable this
# project avoids. qdisc is reported for information only.

if [[ -n "${TIXOLINK_MODULE_BBR_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_MODULE_BBR_SH_LOADED=1

readonly TIXOLINK_BBR_KEY="net.ipv4.tcp_congestion_control"
readonly TIXOLINK_BBR_PROFILE="bbr_enable"

# bbr::_bbr_available
# Verifies actual kernel support via the real available-algorithms list
# first; falls back to a read-only module-presence check (modinfo,
# never modprobe) as corroborating evidence only. Never infers support
# from kernel version alone.
bbr::_bbr_available() {
    local available; available="$(platform::available_congestion_control 2>/dev/null)"
    if grep -qw bbr <<<"$available"; then
        return 0
    fi
    if command -v modinfo >/dev/null 2>&1 && modinfo tcp_bbr >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# bbr::status
bbr::status() {
    local current available qdisc owns
    current="$(optimizer::_read_current "$TIXOLINK_BBR_KEY" 2>/dev/null)" || current="$(platform::congestion_control)"
    available="$(platform::available_congestion_control 2>/dev/null)"
    qdisc="$(platform::default_qdisc 2>/dev/null)"
    owns="no"
    optimizer::_applied_get "$TIXOLINK_BBR_KEY" >/dev/null 2>&1 && owns="yes"

    printf 'CURRENT=%s\n' "$current"
    printf 'AVAILABLE=%s\n' "$available"
    printf 'DEFAULT_QDISC=%s\n' "$qdisc"
    printf 'BBR_AVAILABLE=%s\n' "$(bbr::_bbr_available && echo yes || echo no)"
    printf 'TIXOLINK_OWNS_CHANGE=%s\n' "$owns"
    if [[ "$current" == "bbr" ]]; then
        printf 'NOTE=BBR is already the active congestion control.\n'
    fi
    return 0
}

# bbr::enable [dry_run]
bbr::enable() {
    local dry_run="${1:-0}"
    local current; current="$(optimizer::_read_current "$TIXOLINK_BBR_KEY" 2>/dev/null)" || current="$(platform::congestion_control)"

    if [[ "$current" == "bbr" ]]; then
        log::info "BBR is already active; no change needed (not claiming ownership of a pre-existing choice)."
        return 0
    fi

    bbr::_bbr_available || {
        log::error "this kernel does not expose bbr in tcp_available_congestion_control; refusing to enable it"
        return "$EXIT_VALIDATION"
    }

    optimizer::apply_profile "$TIXOLINK_BBR_PROFILE" "$dry_run"
}

# bbr::restore
# Returns net.ipv4.tcp_congestion_control to its pre-TixoLink baseline,
# if and only if TixoLink ever recorded one. Never touches an
# administrator's own BBR (or any other) choice that TixoLink did not
# itself change.
bbr::restore() {
    optimizer::restore "$TIXOLINK_BBR_KEY"
}

# bbr::disable
# Documented alias for bbr::restore: "turning BBR off" means undoing
# whatever TixoLink itself changed, back to the original value - never
# an independent second mutation path with its own notion of "off".
bbr::disable() {
    bbr::restore
}

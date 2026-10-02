#!/usr/bin/env bash
# TixoLink NEXUS - "none" forwarding engine: an explicit no-op.
#
# Keeping "no forwarding" as a real, total entry in the dispatch table
# (rather than special-casing an absent forwarder everywhere) means every
# migration is just forwarder-to-forwarder, including the "none" cases.

if [[ -n "${TIXOLINK_FORWARDER_NONE_SH_LOADED:-}" ]]; then
    return 0
fi
readonly TIXOLINK_FORWARDER_NONE_SH_LOADED=1

forwarder_none_validate() { return 0; }
forwarder_none_check_conflicts() { return 0; }
forwarder_none_apply() { return 0; }
forwarder_none_remove() { return 0; }
forwarder_none_repair() { return 0; }
forwarder_none_status() { printf 'STATE=NONE\n'; }

forwarder::register "none"

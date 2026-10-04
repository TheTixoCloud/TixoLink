#!/usr/bin/env bash
# TixoLink NEXUS - non-interactive CLI create/edit (Phase 7 CLI-completeness).
#
# Exercises `tixolink create`/`tixolink edit` as flag-driven, non-interactive
# commands (cli::cmd_create/cli::cmd_edit in lib/cli.sh) against the real
# Linux GRE implementation inside an isolated network namespace - never the
# host's default namespace. Proves: required-flag errors, validation
# errors, successful create, dry-run previews nothing applied, --force
# gating, and - the specific Phase 7 requirement - that a partial edit
# (one flag given) leaves every unspecified field exactly as it was,
# across repeated partial edits.
set -uo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "SKIP: this integration suite requires root (CAP_NET_ADMIN) for network namespaces."
    exit 0
fi
if ! command -v ip >/dev/null 2>&1 || ! ip netns list >/dev/null 2>&1; then
    echo "SKIP: iproute2 'ip netns' support is not available in this environment."
    exit 0
fi

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NS="tixo-cliflags-$$"
SANDBOX="$(mktemp -d /tmp/tixolink-cliflags.XXXXXXXX)"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }
check_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', expected '$3')"; fi; }

HOST_IFACES_BEFORE="$(ip -o link show 2>/dev/null | awk '{print $2}' | sort)"
HOST_NETNS_BEFORE="$(ip netns list 2>/dev/null | sort)"

cleanup() {
    ip netns exec "$NS" ip link show 2>/dev/null | grep -q tixo- && \
        ip netns exec "$NS" ip -o link show 2>/dev/null | awk -F': ' '/tixo-/{print $2}' | cut -d@ -f1 | \
        while read -r i; do ip netns exec "$NS" ip link del "$i" 2>/dev/null || true; done
    ip netns del "$NS" 2>/dev/null || true
    rm -rf -- "$SANDBOX"
}
trap cleanup EXIT

ip netns add "$NS"
ip netns exec "$NS" ip link set lo up
ip netns exec "$NS" ip addr add 10.90.0.1/32 dev lo

tlink() {
    TIXOLINK_ETC_DIR="$SANDBOX/etc" TIXOLINK_VAR_DIR="$SANDBOX/var" \
        TIXOLINK_RUN_DIR="$SANDBOX/run" TIXOLINK_LOG_FILE="$SANDBOX/log" \
        TIXOLINK_NETNS="$NS" "$REPO_ROOT/bin/tixolink" "$@" </dev/null
}

# --- required-flag / validation errors --------------------------------------

tlink create --name tun1 >/dev/null 2>&1; status=$?
check_eq "create: missing --local-ip/--remote-ip is a usage error" "$status" "2"

tlink create --name tun1 --local-ip not-an-ip --remote-ip 192.0.2.2 >/dev/null 2>&1; status=$?
check_eq "create: invalid --local-ip is a validation error" "$status" "3"

tlink create --name tun1 --local-ip 10.90.0.1 --remote-ip 192.0.2.2 --inner-subnet 10.200.0.0/30 >/dev/null 2>&1; status=$?
check_eq "create: partial --inner-* flags is a usage error" "$status" "2"

# --- successful create --------------------------------------------------------

TID="$(tlink create --name tun1 --local-ip 10.90.0.1 --remote-ip 192.0.2.2 2>/tmp/tixolink-cliflags-create.err)"
status=$?
check_eq "create: succeeds with required flags" "$status" "0"
check_eq "create: tunnel ID looks like a tunnel ID" "$(printf '%s' "$TID" | grep -cE '^[0-9a-f]{8}$')" "1"

list_out="$(tlink list)"
check_eq "create: tunnel appears in list" "$(grep -c "$TID" <<<"$list_out")" "1"

# GRE point-to-point links report operstate UNKNOWN even when
# administratively up (no link-detection mechanism exists for them); the
# IFF_UP flag, not operstate, is the real "up" signal - same check
# engines/gre.sh:gre::_read_runtime itself uses.
ifup="$(ip netns exec "$NS" ip -j link show "tixo-${TID}" 2>/dev/null | jq -r '(.[0].flags // []) | index("UP") != null')"
check_eq "create: real GRE interface is up inside the namespace" "$ifup" "true"

# --- edit: no flags, non-interactive --------------------------------------

tlink edit "$TID" >/dev/null 2>&1
check_eq "edit: no flags non-interactively is a usage error" "$?" "2"

# --- edit: dry-run changes nothing --------------------------------------------

mtu_before="$(jq -r '.engine_config.mtu' "$SANDBOX/etc/tunnels/${TID}.json")"
tlink edit "$TID" --mtu 1400 --dry-run >/dev/null 2>&1
mtu_after_dryrun="$(jq -r '.engine_config.mtu' "$SANDBOX/etc/tunnels/${TID}.json")"
check_eq "edit --dry-run: config on disk unchanged" "$mtu_after_dryrun" "$mtu_before"

# --- edit: without --force is refused -----------------------------------------

tlink edit "$TID" --mtu 1400 >/dev/null 2>&1
check_eq "edit without --force is a usage error" "$?" "2"
mtu_after_noforce="$(jq -r '.engine_config.mtu' "$SANDBOX/etc/tunnels/${TID}.json")"
check_eq "edit without --force: config on disk unchanged" "$mtu_after_noforce" "$mtu_before"

# --- edit: partial edit preserves every unspecified field ---------------------

local_before="$(jq -r '.engine_config.local_public_ip' "$SANDBOX/etc/tunnels/${TID}.json")"
remote_before="$(jq -r '.engine_config.remote_public_ip' "$SANDBOX/etc/tunnels/${TID}.json")"
ttl_before="$(jq -r '.engine_config.ttl' "$SANDBOX/etc/tunnels/${TID}.json")"

tlink edit "$TID" --mtu 1400 --force >/dev/null 2>&1
status=$?
check_eq "edit --force --mtu: succeeds" "$status" "0"

cfg="$(cat "$SANDBOX/etc/tunnels/${TID}.json")"
check_eq "partial edit (mtu): mtu actually changed" "$(jq -r '.engine_config.mtu' <<<"$cfg")" "1400"
check_eq "partial edit (mtu): local_public_ip preserved" "$(jq -r '.engine_config.local_public_ip' <<<"$cfg")" "$local_before"
check_eq "partial edit (mtu): remote_public_ip preserved" "$(jq -r '.engine_config.remote_public_ip' <<<"$cfg")" "$remote_before"
check_eq "partial edit (mtu): ttl preserved" "$(jq -r '.engine_config.ttl' <<<"$cfg")" "$ttl_before"

# A second, independent partial edit (a different single field) must not
# undo the first one - proves fields are read from CURRENT config at edit
# time, not from some stale baseline.
tlink edit "$TID" --ttl 200 --force >/dev/null 2>&1
status=$?
check_eq "edit --force --ttl: succeeds" "$status" "0"

cfg2="$(cat "$SANDBOX/etc/tunnels/${TID}.json")"
check_eq "second partial edit (ttl): ttl actually changed" "$(jq -r '.engine_config.ttl' <<<"$cfg2")" "200"
check_eq "second partial edit (ttl): mtu from FIRST edit still preserved" "$(jq -r '.engine_config.mtu' <<<"$cfg2")" "1400"
check_eq "second partial edit (ttl): local_public_ip still preserved" "$(jq -r '.engine_config.local_public_ip' <<<"$cfg2")" "$local_before"

# --- manual inner addressing, full flag set -----------------------------------

TID2="$(tlink create --name tun2 --local-ip 10.90.0.1 --remote-ip 192.0.2.3 \
    --inner-subnet 10.201.0.0/30 --inner-local 10.201.0.1 --inner-remote 10.201.0.2 2>/dev/null)"
status=$?
check_eq "create with manual inner addressing: succeeds" "$status" "0"
cfg3="$(cat "$SANDBOX/etc/tunnels/${TID2}.json")"
check_eq "manual addressing: inner_subnet matches request" "$(jq -r '.engine_config.inner_subnet' <<<"$cfg3")" "10.201.0.0/30"

# --- cleanup, verified ---------------------------------------------------------

tlink delete "$TID" --force >/dev/null 2>&1
check_eq "delete tun1: succeeds" "$?" "0"
tlink delete "$TID2" --force >/dev/null 2>&1
check_eq "delete tun2: succeeds" "$?" "0"

ns_ifaces_left="$(ip netns exec "$NS" ip -o link show 2>/dev/null | grep -c 'tixo-' || true)"
check_eq "no tixo- interfaces left in the namespace" "$ns_ifaces_left" "0"

HOST_IFACES_AFTER="$(ip -o link show 2>/dev/null | awk '{print $2}' | sort)"
check_eq "no leaked interfaces in the host default namespace" "$HOST_IFACES_AFTER" "$HOST_IFACES_BEFORE"

printf '%d checks passed, %d failed\n' "$PASS" "$FAIL"

trap - EXIT
cleanup
rm -f /tmp/tixolink-cliflags-create.err
HOST_NETNS_AFTER="$(ip netns list 2>/dev/null | sort)"
check_eq "no leaked network namespaces after cleanup" "$HOST_NETNS_AFTER" "$HOST_NETNS_BEFORE"
printf '%d checks passed, %d failed (final)\n' "$PASS" "$FAIL"

[[ "$FAIL" -eq 0 ]]

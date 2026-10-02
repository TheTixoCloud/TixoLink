#!/usr/bin/env bash
# TixoLink NEXUS - mandatory Phase 3 closure test: tunnel::edit_from_fields
# rollback when APPLY genuinely fails against the real kernel.
#
# Failure injection strategy: edits that change the GRE remote endpoint
# force engines/gre.sh to delete-then-recreate the interface (endpoint is a
# creation-time-only GRE parameter). We pre-create an unrelated real GRE
# device in the same namespace using the exact (local, remote) pair the
# edit is moving to - the Linux kernel rejects a second GRE device with an
# identical (local, remote) tuple ("File exists"), so the recreate's
# `ip link add` fails for real, with no mocking involved.
set -uo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "SKIP: this test requires root (CAP_NET_ADMIN) for network namespaces."
    exit 0
fi
if ! command -v ip >/dev/null 2>&1 || ! ip netns list >/dev/null 2>&1; then
    echo "SKIP: iproute2 'ip netns' support is not available in this environment."
    exit 0
fi

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="$TEST_DIR/_driver.sh"

readonly EXIT_ROLLED_BACK=9

SUFFIX="$$"
NS_ENTRY="tixo-rb-entry-${SUFFIX}"
NS_EXIT="tixo-rb-exit-${SUFFIX}"

SANDBOX_ROOT="$(mktemp -d /tmp/tixolink-rb.XXXXXXXX)"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }
check_eq() {
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', expected '$3')"; fi
}

HOST_IFACES_BEFORE="$(ip -o link show 2>/dev/null | awk '{print $2}' | sort)"
HOST_NETNS_BEFORE="$(ip netns list 2>/dev/null | sort)"

entry() {
    TIXOLINK_ETC_DIR="$SANDBOX_ROOT/etc" TIXOLINK_VAR_DIR="$SANDBOX_ROOT/var" \
        TIXOLINK_RUN_DIR="$SANDBOX_ROOT/run" TIXOLINK_LOG_FILE="$SANDBOX_ROOT/tixolink.log" \
        TIXOLINK_NETNS="$NS_ENTRY" bash "$DRIVER" "$@"
}
exitn() {
    TIXOLINK_ETC_DIR="$SANDBOX_ROOT/etc-exit" TIXOLINK_VAR_DIR="$SANDBOX_ROOT/var-exit" \
        TIXOLINK_RUN_DIR="$SANDBOX_ROOT/run-exit" TIXOLINK_LOG_FILE="$SANDBOX_ROOT/tixolink-exit.log" \
        TIXOLINK_NETNS="$NS_EXIT" bash "$DRIVER" "$@"
}
ns_link_exists() { ip -n "$1" link show "$2" >/dev/null 2>&1; }
ns_link_ttl() { ip -n "$1" -d -j link show "$2" 2>/dev/null | jq -r '.[0].linkinfo.info_data.ttl'; }
ns_link_remote() { ip -n "$1" -d -j link show "$2" 2>/dev/null | jq -r '.[0].linkinfo.info_data.remote'; }
ns_ping() { ip netns exec "$1" ping -c1 -W1 "$2" >/dev/null 2>&1; }

cleanup() {
    ip netns del "$NS_ENTRY" >/dev/null 2>&1 || true
    ip netns del "$NS_EXIT" >/dev/null 2>&1 || true
    rm -rf -- "$SANDBOX_ROOT"
}
trap cleanup EXIT INT TERM

echo "== Setup: isolated namespaces + a valid, running tunnel =="
ip netns add "$NS_ENTRY" || { echo "FAIL: could not create namespace"; exit 1; }
ip netns add "$NS_EXIT"
ip -n "$NS_ENTRY" link set lo up
ip -n "$NS_EXIT" link set lo up
ip link add veth-entry netns "$NS_ENTRY" type veth peer name veth-exit netns "$NS_EXIT"
ip -n "$NS_ENTRY" link set veth-entry up
ip -n "$NS_EXIT" link set veth-exit up
ip -n "$NS_ENTRY" addr add 192.0.2.1/30 dev veth-entry
ip -n "$NS_EXIT" addr add 192.0.2.2/30 dev veth-exit

TUN_ID="$(entry tunnel::create_from_fields "rb-tun" "192.0.2.1" "192.0.2.2" \
    "manual" "10.250.0.0/30" "10.250.0.1" "10.250.0.2" "1300" "255" "0")"
check_eq "(1) initial tunnel create succeeded" "$?" "0"
IFACE="tixo-${TUN_ID}"
check_eq "(2) runtime TTL matches config before edit" "$(ns_link_ttl "$NS_ENTRY" "$IFACE")" "255"
check_eq "(2) runtime remote matches config before edit" "$(ns_link_remote "$NS_ENTRY" "$IFACE")" "192.0.2.2"

EXIT_TUN_ID="$(exitn tunnel::create_from_fields "rb-tun-peer" "192.0.2.2" "192.0.2.1" \
    "manual" "10.250.0.0/30" "10.250.0.2" "10.250.0.1" "1300" "255" "0")"
check_eq "(2) exit-side peer tunnel created, inner ping works pre-edit" \
    "$(ns_ping "$NS_ENTRY" 10.250.0.2 && echo ok || echo fail)" "ok"

echo "== Sabotage: pre-occupy the (local,remote) pair the edit will move to =="
ip -n "$NS_ENTRY" link add tixo-sabotage type gre local 192.0.2.1 remote 192.0.2.9 ttl 1
pass "(3) sabotage device created (unrelated to TixoLink ownership)"

echo "== Attempt edit: change remote to 192.0.2.9 (forces recreate; will fail) =="
entry tunnel::edit_from_fields "$TUN_ID" "192.0.2.1" "192.0.2.9" "1300" "200" 0 >/dev/null 2>&1
EDIT_STATUS=$?
check_eq "(4+5) APPLY failed and transaction reported failure" "$EDIT_STATUS" "$EXIT_ROLLED_BACK"

echo "== Verify rollback =="
OLD_JSON="$(entry config::tunnel_read "$TUN_ID")"
check_eq "(6) old JSON config restored (remote)" "$(jq -r '.engine_config.remote_public_ip' <<<"$OLD_JSON")" "192.0.2.2"
check_eq "(6) old JSON config restored (ttl)" "$(jq -r '.engine_config.ttl' <<<"$OLD_JSON")" "255"

if ns_link_exists "$NS_ENTRY" "$IFACE"; then
    pass "(7) old GRE runtime interface exists again after rollback"
else
    fail "(7) old GRE runtime interface missing after rollback"
fi
check_eq "(7) restored runtime TTL matches old config" "$(ns_link_ttl "$NS_ENTRY" "$IFACE")" "255"
check_eq "(7) restored runtime remote matches old config" "$(ns_link_remote "$NS_ENTRY" "$IFACE")" "192.0.2.2"
check_eq "(8) no stale new-config runtime remains (ttl != 200)" \
    "$([[ "$(ns_link_ttl "$NS_ENTRY" "$IFACE")" == "200" ]] && echo stale || echo clean)" "clean"

RECORDED_IFACE="$(entry state::get ".tunnels[\"$TUN_ID\"].interface" 2>/dev/null)"
check_eq "(9) ownership ledger still points at the same interface" "$RECORDED_IFACE" "$IFACE"

echo "== Verify normal operation still works after rollback =="
check_eq "(10) real inner GRE ping end-to-end still works after rollback" \
    "$(ns_ping "$NS_ENTRY" 10.250.0.2 && echo ok || echo fail)" "ok"
entry tunnel::edit_from_fields "$TUN_ID" "192.0.2.1" "192.0.2.2" "1350" "255" 0 >/dev/null
check_eq "(10) a subsequent normal edit (mtu only, no recreate) succeeds" "$?" "0"
entry tunnel::status "$TUN_ID" >/dev/null
check_eq "(10) status still works after rollback+recovery" "$?" "0"
entry tunnel::delete "$TUN_ID" 0 1 >/dev/null
check_eq "(10) delete still works cleanly after rollback+recovery" "$?" "0"
exitn tunnel::delete "$EXIT_TUN_ID" 0 1 >/dev/null

ip -n "$NS_ENTRY" link del tixo-sabotage >/dev/null 2>&1 || true

echo
printf '%d checks passed, %d failed\n' "$PASS" "$FAIL"

HOST_IFACES_AFTER="$(ip -o link show 2>/dev/null | awk '{print $2}' | sort)"
check_eq "no leaked interfaces in host default namespace (pre-cleanup)" \
    "$([[ "$HOST_IFACES_AFTER" == "$HOST_IFACES_BEFORE" ]] && echo same || echo "$HOST_IFACES_AFTER")" "same"

trap - EXIT INT TERM
cleanup

HOST_NETNS_AFTER="$(ip netns list 2>/dev/null | sort)"
check_eq "no leaked network namespaces after cleanup" "$HOST_NETNS_AFTER" "$HOST_NETNS_BEFORE"

printf '%d checks passed, %d failed (final)\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]

#!/usr/bin/env bash
# TixoLink NEXUS - real-kernel GRE integration test.
#
# Exercises the actual engines/gre.sh code path against the real Linux GRE
# implementation, entirely inside isolated network namespaces. Never
# touches the host's default namespace networking, routing, or firewall.
#
# Topology:
#   ns-entry <--veth--> ns-exit-a   (underlay 192.0.2.0/30)
#   ns-entry <--veth--> ns-exit-b   (underlay 192.0.2.4/30)
# ns-entry hosts two independent GRE tunnels (one server, many tunnels -
# the core multi-tunnel requirement). ns-exit-a/ns-exit-b each represent
# an independent remote peer.
#
# Each side's TixoLink config/state lives under its own sandbox directory
# and is driven through tests/integration/_driver.sh, which runs a fresh
# process per call - exactly simulating independent hosts.

set -uo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "SKIP: this integration suite requires root (CAP_NET_ADMIN) for network namespaces."
    exit 0
fi
if ! command -v ip >/dev/null 2>&1 || ! ip netns list >/dev/null 2>&1; then
    echo "SKIP: iproute2 'ip netns' support is not available in this environment."
    exit 0
fi

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="$TEST_DIR/_driver.sh"

readonly EXIT_VALIDATION=3
readonly EXIT_CONFLICT=4
readonly EXIT_NOT_FOUND=5

SUFFIX="$$"
NS_ENTRY="tixo-it-entry-${SUFFIX}"
NS_EXIT_A="tixo-it-exita-${SUFFIX}"
NS_EXIT_B="tixo-it-exitb-${SUFFIX}"

SANDBOX_ROOT="$(mktemp -d /tmp/tixolink-it.XXXXXXXX)"
SANDBOX_ENTRY="$SANDBOX_ROOT/entry"
SANDBOX_EXIT_A="$SANDBOX_ROOT/exit-a"
SANDBOX_EXIT_B="$SANDBOX_ROOT/exit-b"
# A separate, otherwise-empty "host" for the peer-import test: exit_b
# already has its own manually-created peer for tunnel B (tun-b-peer), so
# importing tunnel B's own export there would correctly collide with it.
# A real peer-import target is a host that doesn't already have that
# tunnel configured - which is the normal case this test should cover.
SANDBOX_IMPORT_TARGET="$SANDBOX_ROOT/import-target"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }

# check <description> <command...> - runs the command, quieting its
# output, and records pass/fail based on its exit status.
check() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

# check_eq <description> <actual> <expected>
check_eq() {
    if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', expected '$3')"; fi
}
check_ne() {
    if [[ "$2" != "$3" ]]; then pass "$1"; else fail "$1 (unexpectedly equal: '$2')"; fi
}

# --- Pre-flight host-state snapshot (to prove no leakage afterwards) -------
HOST_IFACES_BEFORE="$(ip -o link show 2>/dev/null | awk '{print $2}' | sort)"
HOST_NETNS_BEFORE="$(ip netns list 2>/dev/null | sort)"

cleanup() {
    ip netns del "$NS_ENTRY" >/dev/null 2>&1 || true
    ip netns del "$NS_EXIT_A" >/dev/null 2>&1 || true
    ip netns del "$NS_EXIT_B" >/dev/null 2>&1 || true
    rm -rf -- "$SANDBOX_ROOT"
}
trap cleanup EXIT INT TERM

entry() {
    TIXOLINK_ETC_DIR="$SANDBOX_ENTRY/etc" TIXOLINK_VAR_DIR="$SANDBOX_ENTRY/var" \
        TIXOLINK_RUN_DIR="$SANDBOX_ENTRY/run" TIXOLINK_LOG_FILE="$SANDBOX_ENTRY/tixolink.log" \
        TIXOLINK_NETNS="$NS_ENTRY" bash "$DRIVER" "$@"
}
exit_a() {
    TIXOLINK_ETC_DIR="$SANDBOX_EXIT_A/etc" TIXOLINK_VAR_DIR="$SANDBOX_EXIT_A/var" \
        TIXOLINK_RUN_DIR="$SANDBOX_EXIT_A/run" TIXOLINK_LOG_FILE="$SANDBOX_EXIT_A/tixolink.log" \
        TIXOLINK_NETNS="$NS_EXIT_A" bash "$DRIVER" "$@"
}
exit_b() {
    TIXOLINK_ETC_DIR="$SANDBOX_EXIT_B/etc" TIXOLINK_VAR_DIR="$SANDBOX_EXIT_B/var" \
        TIXOLINK_RUN_DIR="$SANDBOX_EXIT_B/run" TIXOLINK_LOG_FILE="$SANDBOX_EXIT_B/tixolink.log" \
        TIXOLINK_NETNS="$NS_EXIT_B" bash "$DRIVER" "$@"
}
# No network namespace needed: peer::import never probes local address
# existence (a peer document describes a tunnel for a possibly different,
# not-yet-configured host), so this only needs its own config/state dirs.
import_target() {
    TIXOLINK_ETC_DIR="$SANDBOX_IMPORT_TARGET/etc" TIXOLINK_VAR_DIR="$SANDBOX_IMPORT_TARGET/var" \
        TIXOLINK_RUN_DIR="$SANDBOX_IMPORT_TARGET/run" TIXOLINK_LOG_FILE="$SANDBOX_IMPORT_TARGET/tixolink.log" \
        bash "$DRIVER" "$@"
}

ns_link_exists() { ip -n "$1" link show "$2" >/dev/null 2>&1; }
ns_ping() { ip netns exec "$1" ping -c1 -W1 "$2" >/dev/null 2>&1; }
ns_link_mtu() { ip -n "$1" -j link show "$2" 2>/dev/null | jq -r '.[0].mtu'; }
ns_link_ttl() { ip -n "$1" -d -j link show "$2" 2>/dev/null | jq -r '.[0].linkinfo.info_data.ttl'; }
ns_link_is_up() { ip -n "$1" -j link show "$2" 2>/dev/null | jq -r '.[0].flags | index("UP") != null'; }
ns_link_ifindex() { ip -n "$1" -j link show "$2" 2>/dev/null | jq -r '.[0].ifindex'; }

# --- Build the isolated underlay -------------------------------------------
echo "== Building isolated namespace topology =="
ip netns add "$NS_ENTRY" || { echo "FAIL: could not create namespace"; exit 1; }
ip netns add "$NS_EXIT_A"
ip netns add "$NS_EXIT_B"

ip -n "$NS_ENTRY" link set lo up
ip -n "$NS_EXIT_A" link set lo up
ip -n "$NS_EXIT_B" link set lo up

ip link add veth-a-entry netns "$NS_ENTRY" type veth peer name veth-a-exit netns "$NS_EXIT_A"
ip -n "$NS_ENTRY" link set veth-a-entry up
ip -n "$NS_EXIT_A" link set veth-a-exit up
ip -n "$NS_ENTRY" addr add 192.0.2.1/30 dev veth-a-entry
ip -n "$NS_EXIT_A" addr add 192.0.2.2/30 dev veth-a-exit

ip link add veth-b-entry netns "$NS_ENTRY" type veth peer name veth-b-exit netns "$NS_EXIT_B"
ip -n "$NS_ENTRY" link set veth-b-entry up
ip -n "$NS_EXIT_B" link set veth-b-exit up
ip -n "$NS_ENTRY" addr add 192.0.2.5/30 dev veth-b-entry
ip -n "$NS_EXIT_B" addr add 192.0.2.6/30 dev veth-b-exit

check "underlay A reachable (entry -> exit-a)" ns_ping "$NS_ENTRY" 192.0.2.2
check "underlay B reachable (entry -> exit-b)" ns_ping "$NS_ENTRY" 192.0.2.6

# --- Tunnel A: ns-entry <-> ns-exit-a ---------------------------------------
echo "== Tunnel A: create both sides =="
ENTRY_A_ID="$(entry tunnel::create_from_fields "tun-a" "192.0.2.1" "192.0.2.2" \
    "manual" "10.250.0.0/30" "10.250.0.1" "10.250.0.2" "1300" "255" "0")"
check_eq "tunnel A (entry side) create succeeded" "$?" "0"
if [[ "$ENTRY_A_ID" =~ ^[0-9a-f]{8}$ ]]; then
    pass "tunnel A got a valid 8-hex ID"
else
    fail "tunnel A ID malformed: $ENTRY_A_ID"
fi

EXITA_ID="$(exit_a tunnel::create_from_fields "tun-a-peer" "192.0.2.2" "192.0.2.1" \
    "manual" "10.250.0.0/30" "10.250.0.2" "10.250.0.1" "1300" "255" "0")"
check_eq "tunnel A (exit-a side) create succeeded" "$?" "0"

check "tunnel A inner interface exists (entry)" ns_link_exists "$NS_ENTRY" "tixo-${ENTRY_A_ID}"
check "tunnel A inner interface exists (exit-a)" ns_link_exists "$NS_EXIT_A" "tixo-${EXITA_ID}"
check "tunnel A inner ping works (entry -> exit-a)" ns_ping "$NS_ENTRY" 10.250.0.2
check "tunnel A inner ping works (exit-a -> entry)" ns_ping "$NS_EXIT_A" 10.250.0.1

check_eq "tunnel A MTU applied correctly" "$(ns_link_mtu "$NS_ENTRY" "tixo-${ENTRY_A_ID}")" "1300"

# --- Tunnel B: ns-entry <-> ns-exit-b (second, independent tunnel) ----------
echo "== Tunnel B: second independent tunnel on the same entry server =="
ENTRY_B_ID="$(entry tunnel::create_from_fields "tun-b" "192.0.2.5" "192.0.2.6" \
    "manual" "10.251.0.0/30" "10.251.0.1" "10.251.0.2" "1400" "200" "0")"
check_eq "tunnel B (entry side) create succeeded" "$?" "0"
check_ne "tunnel B got a different ID than tunnel A" "$ENTRY_B_ID" "$ENTRY_A_ID"

EXITB_ID="$(exit_b tunnel::create_from_fields "tun-b-peer" "192.0.2.6" "192.0.2.5" \
    "manual" "10.251.0.0/30" "10.251.0.2" "10.251.0.1" "1400" "200" "0")"
check_eq "tunnel B (exit-b side) create succeeded" "$?" "0"

check "tunnel B inner ping works" ns_ping "$NS_ENTRY" 10.251.0.2
check "tunnel A still works while tunnel B exists (multi-tunnel coexistence)" ns_ping "$NS_ENTRY" 10.250.0.2

# --- Idempotency -------------------------------------------------------------
echo "== Idempotency =="
IFINDEX_BEFORE="$(ns_link_ifindex "$NS_ENTRY" "tixo-${ENTRY_A_ID}")"
entry tunnel::start "$ENTRY_A_ID" 0 >/dev/null
check_eq "starting an already-correct tunnel succeeds" "$?" "0"
check_eq "idempotent start did not destroy/recreate the interface" \
    "$(ns_link_ifindex "$NS_ENTRY" "tixo-${ENTRY_A_ID}")" "$IFINDEX_BEFORE"

# --- Stop / repeated stop ----------------------------------------------------
echo "== Stop =="
entry tunnel::stop "$ENTRY_A_ID" 0 >/dev/null
check_eq "stop succeeded" "$?" "0"
check_eq "interface is administratively down after stop" "$(ns_link_is_up "$NS_ENTRY" "tixo-${ENTRY_A_ID}")" "false"
entry tunnel::stop "$ENTRY_A_ID" 0 >/dev/null
check_eq "repeated stop is safe (idempotent)" "$?" "0"

# --- Restart ------------------------------------------------------------------
echo "== Restart =="
entry tunnel::restart "$ENTRY_A_ID" 0 >/dev/null
check_eq "restart succeeded" "$?" "0"
check "tunnel A inner ping works again after restart" ns_ping "$NS_ENTRY" 10.250.0.2

# --- Edit: MTU/TTL change (forces interface recreation for TTL) ------------
echo "== Edit =="
entry tunnel::edit_from_fields "$ENTRY_A_ID" "192.0.2.1" "192.0.2.2" "1350" "200" 0 >/dev/null
check_eq "edit (mtu/ttl change) succeeded" "$?" "0"
check_eq "edited MTU applied" "$(ns_link_mtu "$NS_ENTRY" "tixo-${ENTRY_A_ID}")" "1350"
check_eq "edited TTL applied" "$(ns_link_ttl "$NS_ENTRY" "tixo-${ENTRY_A_ID}")" "200"
check "tunnel A still pings after edit" ns_ping "$NS_ENTRY" 10.250.0.2

# --- Drift detection and repair ---------------------------------------------
echo "== Reconcile / drift =="
ip -n "$NS_ENTRY" link set "tixo-${ENTRY_A_ID}" mtu 1420
DRIFT_STATE="$(entry tunnel::status "$ENTRY_A_ID" | awk -F= '/^STATE=/{print substr($0,7)}')"
check_eq "externally-changed MTU is detected as DRIFTED" "$DRIFT_STATE" "DRIFTED"
entry tunnel::reload "$ENTRY_A_ID" 0 >/dev/null
check_eq "reload (reconcile) succeeded" "$?" "0"
check_eq "reconcile repaired TixoLink-owned drift back to desired MTU" \
    "$(ns_link_mtu "$NS_ENTRY" "tixo-${ENTRY_A_ID}")" "1350"
REPAIRED_STATE="$(entry tunnel::status "$ENTRY_A_ID" | awk -F= '/^STATE=/{print substr($0,7)}')"
check_eq "status is UP after repair" "$REPAIRED_STATE" "UP"

# --- Conflict with an unrelated pre-existing interface ----------------------
echo "== Conflict detection =="
ip -n "$NS_ENTRY" link add tixo-deadbeef type dummy
entry engine_gre_check_conflicts "deadbeef" \
    '{"engine_config":{"interface":"tixo-deadbeef","inner_subnet":"10.252.0.0/30"}}' >/dev/null 2>&1
check_eq "unowned pre-existing interface is rejected as a conflict" "$?" "$EXIT_CONFLICT"
ip -n "$NS_ENTRY" link del tixo-deadbeef

# --- Peer export/import inversion -------------------------------------------
echo "== Peer export/import =="
PEER_DOC="$(entry peer::export "$ENTRY_B_ID")"
echo "$PEER_DOC" | jq -e . >/dev/null 2>&1
check_eq "peer export produced valid JSON" "$?" "0"
PEER_LOCAL="$(jq -r '.engine_config.local_public_ip' <<<"$PEER_DOC")"
PEER_REMOTE="$(jq -r '.engine_config.remote_public_ip' <<<"$PEER_DOC")"
check_eq "peer export inverted local address correctly" "$PEER_LOCAL" "192.0.2.6"
check_eq "peer export inverted remote address correctly" "$PEER_REMOTE" "192.0.2.5"

PEER_FILE="$SANDBOX_ROOT/tun-b.peer.json"
printf '%s' "$PEER_DOC" >"$PEER_FILE"
IMPORTED_ID="$(import_target peer::import "$PEER_FILE" --force)"
check_ne "peer import assigned a new local ID distinct from tunnel B's entry-side ID" "$IMPORTED_ID" "$ENTRY_B_ID"
if [[ -n "$IMPORTED_ID" ]]; then
    pass "peer import produced a non-empty ID"
else
    fail "peer import produced an empty ID"
fi
if ns_link_exists "$NS_EXIT_B" "tixo-${IMPORTED_ID}"; then
    fail "peer import must not auto-start the tunnel"
else
    pass "peer import did not auto-start the tunnel"
fi

# --- Malformed / incompatible peer documents --------------------------------
echo "== Malformed peer import handling =="
BAD_FILE="$SANDBOX_ROOT/bad.json"
printf 'not json' >"$BAD_FILE"
import_target peer::import "$BAD_FILE" --force >/dev/null 2>&1
check_eq "malformed JSON peer file is rejected" "$?" "$EXIT_VALIDATION"

INCOMPATIBLE_FILE="$SANDBOX_ROOT/incompatible.json"
jq -n '{tixolink_peer_schema_version: 99, document_type: "tixolink-peer-config", engine: "gre",
        name: "x", engine_config: {}}' >"$INCOMPATIBLE_FILE"
import_target peer::import "$INCOMPATIBLE_FILE" --force >/dev/null 2>&1
check_eq "incompatible schema version is rejected" "$?" "$EXIT_VALIDATION"

echo "== Delete =="
entry tunnel::delete "$ENTRY_A_ID" 0 1 >/dev/null
check_eq "delete tunnel A succeeded" "$?" "0"
if ns_link_exists "$NS_ENTRY" "tixo-${ENTRY_A_ID}"; then
    fail "tunnel A interface should have been removed"
else
    pass "tunnel A interface removed"
fi
check "tunnel B interface unaffected by deleting tunnel A" ns_link_exists "$NS_ENTRY" "tixo-${ENTRY_B_ID}"
check "tunnel B still pings after deleting tunnel A" ns_ping "$NS_ENTRY" 10.251.0.2

entry tunnel::delete "$ENTRY_A_ID" 0 1 >/dev/null 2>&1
check_eq "repeated delete of an already-deleted tunnel fails safely (not found, no crash)" "$?" "$EXIT_NOT_FOUND"

entry tunnel::delete "$ENTRY_B_ID" 0 1 >/dev/null
check_eq "delete tunnel B succeeded" "$?" "0"
exit_a tunnel::delete "$EXITA_ID" 0 1 >/dev/null
exit_b tunnel::delete "$EXITB_ID" 0 1 >/dev/null
import_target tunnel::delete "$IMPORTED_ID" 0 1 >/dev/null 2>&1 || true

echo
printf '%d checks passed, %d failed\n' "$PASS" "$FAIL"

# --- Verify no TixoLink resources leaked into the host -----------------------
HOST_IFACES_AFTER="$(ip -o link show 2>/dev/null | awk '{print $2}' | sort)"
check_eq "no leaked interfaces in the host default namespace" "$HOST_IFACES_AFTER" "$HOST_IFACES_BEFORE"

trap - EXIT INT TERM
cleanup

HOST_NETNS_AFTER_CLEANUP="$(ip netns list 2>/dev/null | sort)"
check_eq "no leaked network namespaces after cleanup" "$HOST_NETNS_AFTER_CLEANUP" "$HOST_NETNS_BEFORE"

printf '%d checks passed, %d failed (final)\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]

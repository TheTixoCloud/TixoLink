#!/usr/bin/env bash
# TixoLink NEXUS - Phase 5 integration test: tunnel diagnostics, MTU
# probing, and monitor rate calculation against a REAL GRE namespace
# topology. Never touches the host's real networking.
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

SUFFIX="$$"
NS_ENTRY="tixo-diag-entry-${SUFFIX}"
NS_BACKEND="tixo-diag-backend-${SUFFIX}"

SANDBOX_ROOT="$(mktemp -d /tmp/tixolink-diag.XXXXXXXX)"
SANDBOX_ENTRY="$SANDBOX_ROOT/entry"
SANDBOX_BACKEND="$SANDBOX_ROOT/backend"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }
check_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', expected '$3')"; fi; }
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi; }

HOST_NETNS_BEFORE="$(ip netns list 2>/dev/null | sort)"

cleanup() {
    ip netns del "$NS_ENTRY" >/dev/null 2>&1 || true
    ip netns del "$NS_BACKEND" >/dev/null 2>&1 || true
    rm -rf -- "$SANDBOX_ROOT"
}
trap cleanup EXIT INT TERM

entry() {
    TIXOLINK_ETC_DIR="$SANDBOX_ENTRY/etc" TIXOLINK_VAR_DIR="$SANDBOX_ENTRY/var" \
        TIXOLINK_RUN_DIR="$SANDBOX_ENTRY/run" TIXOLINK_LOG_FILE="$SANDBOX_ENTRY/tixolink.log" \
        TIXOLINK_NETNS="$NS_ENTRY" bash "$DRIVER" "$@"
}
backend() {
    TIXOLINK_ETC_DIR="$SANDBOX_BACKEND/etc" TIXOLINK_VAR_DIR="$SANDBOX_BACKEND/var" \
        TIXOLINK_RUN_DIR="$SANDBOX_BACKEND/run" TIXOLINK_LOG_FILE="$SANDBOX_BACKEND/tixolink.log" \
        TIXOLINK_NETNS="$NS_BACKEND" bash "$DRIVER" "$@"
}
in_entry_ns() { ip netns exec "$NS_ENTRY" "$@"; }
# field <key> <text> - extracts KEY=value from a line, robust to the
# exact key length (unlike a hand-computed awk substr offset).
field() { grep "^$1=" <<<"$2" | head -n1 | cut -d= -f2-; }

echo "== Building isolated GRE topology =="
ip netns add "$NS_ENTRY"
ip netns add "$NS_BACKEND"
ip -n "$NS_ENTRY" link set lo up
ip -n "$NS_BACKEND" link set lo up
ip link add veth-entry netns "$NS_ENTRY" type veth peer name veth-backend netns "$NS_BACKEND"
ip -n "$NS_ENTRY" link set veth-entry up
ip -n "$NS_BACKEND" link set veth-backend up
ip -n "$NS_ENTRY" addr add 192.0.2.1/30 dev veth-entry
ip -n "$NS_BACKEND" addr add 192.0.2.2/30 dev veth-backend

TUN_ID="$(entry tunnel::create_from_fields "diag-tun" "192.0.2.1" "192.0.2.2" \
    "manual" "10.250.0.0/30" "10.250.0.1" "10.250.0.2" "1300" "255" "0")"
check_eq "entry-side GRE tunnel created" "$?" "0"
BACKEND_TUN_ID="$(backend tunnel::create_from_fields "diag-tun-peer" "192.0.2.2" "192.0.2.1" \
    "manual" "10.250.0.0/30" "10.250.0.2" "10.250.0.1" "1300" "255" "0")"
check_eq "backend-side GRE tunnel created" "$?" "0"

echo "== Counters reflect real generated traffic (generate first, so later byte checks are meaningful) =="
BEFORE_RX="$(entry sysinfo::iface_counters "tixo-${TUN_ID}" | jq -r '.rx_bytes')"
in_entry_ns ping -c 20 -i 0.05 -W 1 10.250.0.2 >/dev/null 2>&1 || true
AFTER_RX="$(entry sysinfo::iface_counters "tixo-${TUN_ID}" | jq -r '.rx_bytes')"
check "RX byte counter increased after generating real traffic" bash -c "[[ $AFTER_RX -gt $BEFORE_RX ]]"

echo "== Tunnel diagnostics against the real topology =="
DIAG_OUT="$(entry diagnostics::tunnel "$TUN_ID")"
check_eq "diagnostics reports GRE_STATE=UP" "$(field GRE_STATE "$DIAG_OUT")" "UP"
check_eq "diagnostics reports GRE_HEALTH=PASS" "$(field GRE_HEALTH "$DIAG_OUT")" "PASS"
check_eq "diagnostics reports PUBLIC_PEER_HEALTH=PASS (real reachable underlay peer)" \
    "$(field PUBLIC_PEER_HEALTH "$DIAG_OUT")" "PASS"
check_eq "diagnostics reports INNER_PEER_HEALTH=PASS (real reachable GRE inner peer)" \
    "$(field INNER_PEER_HEALTH "$DIAG_OUT")" "PASS"
check_eq "diagnostics distinguishes interface-UP from a separately-measured reachability claim (both present, not collapsed)" \
    "$([[ "$DIAG_OUT" == *"GRE_STATE="* && "$DIAG_OUT" == *"INNER_PEER_HEALTH="* ]] && echo yes || echo no)" "yes"
check "diagnostics reports real non-zero RX byte counter" bash -c "[[ $(field RX_BYTES "$DIAG_OUT") -gt 0 ]]"

echo "== Monitor rate calculation with real generated traffic =="
IFACE="tixo-${TUN_ID}"
R1="$(entry sysinfo::iface_counters "$IFACE")"
T1="$(date +%s%3N)"
in_entry_ns ping -c 30 -i 0.02 -W 1 10.250.0.2 >/dev/null 2>&1 || true
sleep 0.3
R2="$(entry sysinfo::iface_counters "$IFACE")"
T2="$(date +%s%3N)"
ELAPSED="$(awk -v a="$T2" -v b="$T1" 'BEGIN{printf "%.3f", (a-b)/1000}')"
RATE="$(entry monitor::rate "$R1" "$R2" "$ELAPSED")"
check_eq "monitor::rate reports valid=true for real counter deltas" "$(jq -r '.valid' <<<"$RATE")" "true"
check "monitor::rate computed a positive tx_pps from real ICMP traffic" \
    bash -c "[[ \$(jq -r '.tx_pps' <<<'$RATE') -gt 0 ]]"

echo "== MTU / PMTU probing against the real underlay (1500-byte-MTU veth) =="
PMTU="$(entry diagnostics::find_path_mtu 192.0.2.2)"
check_eq "discovered path MTU matches the real 1500-byte veth MTU" "$PMTU" "1500"
REC="$(entry diagnostics::mtu_recommendation "$PMTU")"
check_eq "GRE MTU recommendation accounts for 24 bytes of GRE/outer-IPv4 overhead" "$REC" "1476"

echo "== Forwarding status integration =="
entry forwarding::set_engine "$TUN_ID" netfilter 0 >/dev/null
MAP_ID="$(entry forwarding::add "$TUN_ID" tcp "8080" "0.0.0.0" "" "nat" 0)"
check_eq "netfilter mapping added" "$?" "0"
DIAG_OUT2="$(entry diagnostics::tunnel "$TUN_ID")"
check_eq "diagnostics reports FORWARDING_ENGINE=netfilter" \
    "$(field FORWARDING_ENGINE "$DIAG_OUT2")" "netfilter"
check "diagnostics reports the mapping as ACTIVE/PASS" \
    bash -c "echo '$DIAG_OUT2' | grep -q 'FORWARDING_MAPPING=.*STATE=ACTIVE HEALTH=PASS'"
entry forwarding::remove "$TUN_ID" "$MAP_ID" 0 >/dev/null

echo "== Support report over the real topology =="
REPORT="$(entry diagnostics::generate_report --privacy)"
check "privacy-mode report redacts this tunnel's real public IP" \
    bash -c "! tar xzOf '$REPORT' --wildcards '*/tunnels/${TUN_ID}.txt' 2>/dev/null | grep -q '192.0.2.1'"
rm -f "$REPORT"

entry tunnel::delete "$TUN_ID" 0 1 >/dev/null
backend tunnel::delete "$BACKEND_TUN_ID" 0 1 >/dev/null

echo
printf '%d checks passed, %d failed\n' "$PASS" "$FAIL"

trap - EXIT INT TERM
cleanup

HOST_NETNS_AFTER="$(ip netns list 2>/dev/null | sort)"
check_eq "no leaked network namespaces after cleanup" "$HOST_NETNS_AFTER" "$HOST_NETNS_BEFORE"

printf '%d checks passed, %d failed (final)\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]

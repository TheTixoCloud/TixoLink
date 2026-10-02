#!/usr/bin/env bash
# TixoLink NEXUS - forwarding engine migration tests, including mandatory
# failure-injection coverage in both directions (netfilter<->haproxy).
#
# Failure injection is real, not mocked:
#   - netfilter -> haproxy: TIXOLINK_HAPROXY_CFG points at a directory
#     that does not exist, so haproxy::_apply_candidate's real
#     "config directory does not exist" check genuinely fails.
#   - haproxy -> netfilter: TIXOLINK_NETNS is pointed at a network
#     namespace name that does not exist, so every netfilter::_ipt
#     (`ip netns exec <ns> iptables ...`) invocation genuinely fails with
#     a real "Cannot open network namespace" error from iproute2.
set -uo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "SKIP: this test requires root (CAP_NET_ADMIN) for network namespaces."
    exit 0
fi
if ! command -v ip >/dev/null 2>&1 || ! ip netns list >/dev/null 2>&1; then
    echo "SKIP: iproute2 'ip netns' support is not available in this environment."
    exit 0
fi
if ! command -v haproxy >/dev/null 2>&1; then
    echo "SKIP: haproxy is not installed in this environment."
    exit 0
fi

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="$TEST_DIR/_driver.sh"

readonly EXIT_ROLLED_BACK=9

SUFFIX="$$"
NS_ENTRY="tixo-mig-entry-${SUFFIX}"
SANDBOX_ROOT="$(mktemp -d /tmp/tixolink-mig.XXXXXXXX)"
SANDBOX_ENTRY="$SANDBOX_ROOT/entry"
REAL_HAPROXY_CFG="$SANDBOX_ROOT/haproxy.cfg"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }
check_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', expected '$3')"; fi; }
# grep_count <pattern> <file> - like `grep -c`, but always prints exactly
# one line regardless of match count (grep -c exits 1 on zero matches,
# which would otherwise also trigger a `|| echo 0` fallback and print a
# second, spurious line).
grep_count() { [[ -f "$2" ]] && { grep -c "$1" "$2" 2>/dev/null || true; } || echo 0; }

HOST_NETNS_BEFORE="$(ip netns list 2>/dev/null | sort)"
HAPROXY_PID_FILE="$SANDBOX_ROOT/haproxy.pid"

cleanup() {
    [[ -f "$HAPROXY_PID_FILE" ]] && ip netns exec "$NS_ENTRY" kill "$(cat "$HAPROXY_PID_FILE")" >/dev/null 2>&1
    ip netns del "$NS_ENTRY" >/dev/null 2>&1 || true
    rm -rf -- "$SANDBOX_ROOT"
}
trap cleanup EXIT INT TERM

# Drives a real throwaway HAProxy *process* (not systemd) for reload/
# is_active, same technique as test_haproxy_forwarding.sh, so migration
# "retry succeeds" assertions reflect a genuinely working reload path.
cat > "$SANDBOX_ROOT/overrides.sh" <<EOF
haproxy::_reload() {
    if [[ -f "$HAPROXY_PID_FILE" ]]; then
        ip netns exec "$NS_ENTRY" kill "\$(cat "$HAPROXY_PID_FILE")" >/dev/null 2>&1 || true
        sleep 0.2
    fi
    ip netns exec "$NS_ENTRY" haproxy -f "\$TIXOLINK_HAPROXY_CFG" -D -p "$HAPROXY_PID_FILE" >"$SANDBOX_ROOT/haproxy_run.log" 2>&1
    sleep 0.3
    [[ -f "$HAPROXY_PID_FILE" ]] && kill -0 "\$(cat "$HAPROXY_PID_FILE")" >/dev/null 2>&1
}
haproxy::_is_active() {
    [[ -f "$HAPROXY_PID_FILE" ]] && ip netns exec "$NS_ENTRY" kill -0 "\$(cat "$HAPROXY_PID_FILE")" >/dev/null 2>&1
}
EOF

# A base config with its own listener (see test_haproxy_forwarding.sh for
# why this matters: HAProxy refuses to run with zero listeners anywhere).
cat > "$REAL_HAPROXY_CFG" <<'EOF'
global
    log /dev/log local0

defaults
    mode tcp
    timeout connect 5s
    timeout client 50s
    timeout server 50s

frontend admin_stats
    mode http
    bind 127.0.0.1:19999
    stats uri /stats
EOF

entry() {
    TIXOLINK_ETC_DIR="$SANDBOX_ENTRY/etc" TIXOLINK_VAR_DIR="$SANDBOX_ENTRY/var" \
        TIXOLINK_RUN_DIR="$SANDBOX_ENTRY/run" TIXOLINK_LOG_FILE="$SANDBOX_ENTRY/tixolink.log" \
        TIXOLINK_HAPROXY_CFG="$REAL_HAPROXY_CFG" TIXOLINK_NETNS="$NS_ENTRY" \
        TIXOLINK_TEST_OVERRIDES_FILE="$SANDBOX_ROOT/overrides.sh" \
        bash "$DRIVER" "$@"
}
# Same tunnel/config store, but with a broken HAProxy config path -
# real, not mocked, failure for the netfilter -> haproxy direction.
entry_broken_haproxy() {
    TIXOLINK_ETC_DIR="$SANDBOX_ENTRY/etc" TIXOLINK_VAR_DIR="$SANDBOX_ENTRY/var" \
        TIXOLINK_RUN_DIR="$SANDBOX_ENTRY/run" TIXOLINK_LOG_FILE="$SANDBOX_ENTRY/tixolink.log" \
        TIXOLINK_HAPROXY_CFG="/nonexistent-directory-${SUFFIX}/haproxy.cfg" TIXOLINK_NETNS="$NS_ENTRY" \
        TIXOLINK_TEST_OVERRIDES_FILE="$SANDBOX_ROOT/overrides.sh" \
        bash "$DRIVER" "$@"
}
# Same tunnel/config store, but with a nonexistent namespace - real
# failure for every netfilter `ip netns exec` call, for the
# haproxy -> netfilter direction.
entry_broken_netfilter() {
    TIXOLINK_ETC_DIR="$SANDBOX_ENTRY/etc" TIXOLINK_VAR_DIR="$SANDBOX_ENTRY/var" \
        TIXOLINK_RUN_DIR="$SANDBOX_ENTRY/run" TIXOLINK_LOG_FILE="$SANDBOX_ENTRY/tixolink.log" \
        TIXOLINK_HAPROXY_CFG="$REAL_HAPROXY_CFG" TIXOLINK_NETNS="tixo-does-not-exist-${SUFFIX}" \
        TIXOLINK_TEST_OVERRIDES_FILE="$SANDBOX_ROOT/overrides.sh" \
        bash "$DRIVER" "$@"
}

echo "== Setup =="
ip netns add "$NS_ENTRY"
ip -n "$NS_ENTRY" link set lo up
ip -n "$NS_ENTRY" addr add 192.0.2.1/30 dev lo 2>/dev/null || true

TUN_ID="$(entry tunnel::create_from_fields "mig-tun" "192.0.2.1" "192.0.2.2" \
    "manual" "10.250.0.0/30" "10.250.0.1" "10.250.0.2" "1300" "255" "0")"
check_eq "tunnel created" "$?" "0"

# =============================================================
# Direction 1: none -> netfilter -> haproxy (forced apply failure)
# =============================================================
echo "== Migration none -> netfilter =="
entry forwarding::set_engine "$TUN_ID" netfilter 0 >/dev/null
check_eq "forwarding engine set to netfilter" "$?" "0"
MAP1="$(entry forwarding::add "$TUN_ID" tcp "8080" "0.0.0.0" "" "nat" 0)"
check_eq "netfilter mapping added" "$?" "0"

echo "== Migration netfilter -> haproxy: forced APPLY failure (bad config path) =="
entry_broken_haproxy forwarding::migrate "$TUN_ID" haproxy 0 >/dev/null 2>&1
MIGRATE1_STATUS=$?
check_eq "migration to haproxy fails and reports rolled-back" "$MIGRATE1_STATUS" "$EXIT_ROLLED_BACK"

STILL_NETFILTER="$(entry config::tunnel_read "$TUN_ID" | jq -r '.forwarding.engine')"
check_eq "(failure-injection) old engine (netfilter) remains configured" "$STILL_NETFILTER" "netfilter"

NF_STATE="$(entry forwarding::status "$TUN_ID" | grep "^MAPPING=$MAP1" | awk '{for(i=1;i<=NF;i++) if ($i ~ /^STATE=/) print substr($i,7)}')"
check_eq "(failure-injection) old netfilter mapping is still ACTIVE after failed migration" "$NF_STATE" "ACTIVE"

check_eq "(failure-injection) no stray haproxy managed block was left behind" \
    "$(grep_count "tixolink:${TUN_ID}" "$REAL_HAPROXY_CFG")" "0"

echo "== Retry with a working HAProxy path succeeds =="
entry forwarding::migrate "$TUN_ID" haproxy 0 >/dev/null
check_eq "(retry) migration to haproxy succeeds this time" "$?" "0"
NOW_ENGINE="$(entry config::tunnel_read "$TUN_ID" | jq -r '.forwarding.engine')"
check_eq "(retry) tunnel now uses haproxy" "$NOW_ENGINE" "haproxy"
check_eq "(retry) old netfilter rules were removed after successful migration" \
    "$(ip netns exec "$NS_ENTRY" iptables -t nat -S TIXOLINK-DNAT 2>/dev/null | grep -c "tixolink:${TUN_ID}:${MAP1}")" "0"
check_eq "(retry) haproxy config now references the mapping" \
    "$(grep -c "tixolink:${TUN_ID}:${MAP1}" "$REAL_HAPROXY_CFG")" "1"

# =============================================================
# Direction 2: haproxy -> netfilter (forced apply failure)
# =============================================================
echo "== Migration haproxy -> netfilter: forced APPLY failure (nonexistent namespace) =="
entry_broken_netfilter forwarding::migrate "$TUN_ID" netfilter 0 >/dev/null 2>&1
MIGRATE2_STATUS=$?
check_eq "migration to netfilter fails and reports rolled-back" "$MIGRATE2_STATUS" "$EXIT_ROLLED_BACK"

STILL_HAPROXY="$(entry config::tunnel_read "$TUN_ID" | jq -r '.forwarding.engine')"
check_eq "(failure-injection) old engine (haproxy) remains configured" "$STILL_HAPROXY" "haproxy"
check_eq "(failure-injection) haproxy config still references the mapping (untouched)" \
    "$(grep -c "tixolink:${TUN_ID}:${MAP1}" "$REAL_HAPROXY_CFG")" "1"

echo "== Retry with a working namespace succeeds =="
entry forwarding::migrate "$TUN_ID" netfilter 0 >/dev/null
check_eq "(retry) migration to netfilter succeeds this time" "$?" "0"
FINAL_ENGINE="$(entry config::tunnel_read "$TUN_ID" | jq -r '.forwarding.engine')"
check_eq "(retry) tunnel now uses netfilter" "$FINAL_ENGINE" "netfilter"
check_eq "(retry) haproxy managed block no longer references this tunnel" \
    "$(grep_count "tixolink:${TUN_ID}" "$REAL_HAPROXY_CFG")" "0"
check_eq "(retry) netfilter rules are active again" \
    "$(ip netns exec "$NS_ENTRY" iptables -t nat -C TIXOLINK-DNAT -p tcp --dport 8080 \
        -m comment --comment "tixolink:${TUN_ID}:${MAP1}" -j DNAT --to-destination 10.250.0.2:8080 \
        >/dev/null 2>&1 && echo yes || echo no)" "yes"

echo "== Ownership ledger consistency =="
LEDGER_IFACE="$(entry state::get ".tunnels[\"$TUN_ID\"].interface" 2>/dev/null)"
check_eq "GRE ownership ledger entry is still correct after all migrations" "$LEDGER_IFACE" "tixo-${TUN_ID}"

entry forwarding::remove "$TUN_ID" "$MAP1" 0 >/dev/null
entry tunnel::delete "$TUN_ID" 0 1 >/dev/null

echo
printf '%d checks passed, %d failed\n' "$PASS" "$FAIL"

trap - EXIT INT TERM
cleanup

HOST_NETNS_AFTER="$(ip netns list 2>/dev/null | sort)"
check_eq "no leaked network namespaces after cleanup" "$HOST_NETNS_AFTER" "$HOST_NETNS_BEFORE"

printf '%d checks passed, %d failed (final)\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]

#!/usr/bin/env bash
# TixoLink NEXUS - isolated HAProxy forwarding test.
#
# Never touches the real /etc/haproxy/haproxy.cfg or the real haproxy
# systemd service: TIXOLINK_HAPROXY_CFG is pointed at a scratch file for
# the whole test, and haproxy::_reload/_is_active are overridden (via
# _driver.sh's TIXOLINK_TEST_OVERRIDES_FILE seam) to drive a throwaway
# HAProxy *process* (not systemd) inside an isolated network namespace,
# exactly as the brief requires.
set -uo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "SKIP: this test requires root (CAP_NET_ADMIN) for network namespaces."
    exit 0
fi
if ! command -v haproxy >/dev/null 2>&1; then
    echo "SKIP: haproxy is not installed in this environment."
    exit 0
fi
if ! command -v ip >/dev/null 2>&1 || ! ip netns list >/dev/null 2>&1; then
    echo "SKIP: iproute2 'ip netns' support is not available in this environment."
    exit 0
fi
if ! command -v socat >/dev/null 2>&1; then
    echo "SKIP: socat is not available to run the real backend service."
    exit 0
fi

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="$TEST_DIR/_driver.sh"

SUFFIX="$$"
NS_ENTRY="tixo-hap-entry-${SUFFIX}"
NS_BACKEND="tixo-hap-backend-${SUFFIX}"

SANDBOX_ROOT="$(mktemp -d /tmp/tixolink-hap.XXXXXXXX)"
SANDBOX_ENTRY="$SANDBOX_ROOT/entry"
FAKE_HAPROXY_CFG="$SANDBOX_ROOT/haproxy.cfg"
HAPROXY_PID_FILE="$SANDBOX_ROOT/haproxy.pid"
RELOAD_LOG="$SANDBOX_ROOT/reload_count"
printf '0' >"$RELOAD_LOG"

# Simulates an administrator who already has HAProxy serving something
# else (a stats page here) - representative of real deployments, and
# needed so that removing TixoLink's last managed mapping leaves an
# overall config that still has a listener (HAProxy refuses to run with
# zero listeners anywhere, including in the administrator's own part).
cat > "$FAKE_HAPROXY_CFG" <<'EOF'
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

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi; }
check_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', expected '$3')"; fi; }

HOST_NETNS_BEFORE="$(ip netns list 2>/dev/null | sort)"

cleanup() {
    [[ -f "$HAPROXY_PID_FILE" ]] && ip netns exec "$NS_ENTRY" kill "$(cat "$HAPROXY_PID_FILE")" >/dev/null 2>&1
    [[ -n "${BACKEND_PID:-}" ]] && kill "$BACKEND_PID" >/dev/null 2>&1
    ip netns del "$NS_ENTRY" >/dev/null 2>&1 || true
    ip netns del "$NS_BACKEND" >/dev/null 2>&1 || true
    rm -rf -- "$SANDBOX_ROOT"
}
trap cleanup EXIT INT TERM

echo "== Building isolated topology =="
ip netns add "$NS_ENTRY"
ip netns add "$NS_BACKEND"
ip -n "$NS_ENTRY" link set lo up
ip -n "$NS_BACKEND" link set lo up
ip link add veth-entry netns "$NS_ENTRY" type veth peer name veth-backend netns "$NS_BACKEND"
ip -n "$NS_ENTRY" link set veth-entry up
ip -n "$NS_BACKEND" link set veth-backend up
ip -n "$NS_ENTRY" addr add 192.0.2.1/30 dev veth-entry
ip -n "$NS_BACKEND" addr add 192.0.2.2/30 dev veth-backend

cat > "$SANDBOX_ROOT/overrides.sh" <<EOF
haproxy::_reload() {
    local count
    count="\$(cat "$RELOAD_LOG" 2>/dev/null || echo 0)"
    echo "\$((count + 1))" > "$RELOAD_LOG"
    if [[ -f "$HAPROXY_PID_FILE" ]]; then
        ip netns exec "$NS_ENTRY" kill "\$(cat "$HAPROXY_PID_FILE")" >/dev/null 2>&1 || true
        sleep 0.2
    fi
    ip netns exec "$NS_ENTRY" haproxy -f "$FAKE_HAPROXY_CFG" -D -p "$HAPROXY_PID_FILE" >"$SANDBOX_ROOT/haproxy_run.log" 2>&1
    sleep 0.3
    [[ -f "$HAPROXY_PID_FILE" ]] && kill -0 "\$(cat "$HAPROXY_PID_FILE")" >/dev/null 2>&1
}
haproxy::_is_active() {
    [[ -f "$HAPROXY_PID_FILE" ]] && ip netns exec "$NS_ENTRY" kill -0 "\$(cat "$HAPROXY_PID_FILE")" >/dev/null 2>&1
}
EOF

entry() {
    TIXOLINK_ETC_DIR="$SANDBOX_ENTRY/etc" TIXOLINK_VAR_DIR="$SANDBOX_ENTRY/var" \
        TIXOLINK_RUN_DIR="$SANDBOX_ENTRY/run" TIXOLINK_LOG_FILE="$SANDBOX_ENTRY/tixolink.log" \
        TIXOLINK_HAPROXY_CFG="$FAKE_HAPROXY_CFG" TIXOLINK_NETNS="$NS_ENTRY" \
        TIXOLINK_TEST_OVERRIDES_FILE="$SANDBOX_ROOT/overrides.sh" \
        bash "$DRIVER" "$@"
}
# A plain variant with no HAProxy overrides, for ops unrelated to haproxy
# (GRE create/delete) where TIXOLINK_HAPROXY_CFG doesn't matter.
entry_plain() {
    TIXOLINK_ETC_DIR="$SANDBOX_ENTRY/etc" TIXOLINK_VAR_DIR="$SANDBOX_ENTRY/var" \
        TIXOLINK_RUN_DIR="$SANDBOX_ENTRY/run" TIXOLINK_LOG_FILE="$SANDBOX_ENTRY/tixolink.log" \
        TIXOLINK_NETNS="$NS_ENTRY" bash "$DRIVER" "$@"
}

TUN_ID="$(entry_plain tunnel::create_from_fields "hap-tun" "192.0.2.1" "192.0.2.2" \
    "manual" "10.250.0.0/30" "10.250.0.1" "10.250.0.2" "1300" "255" "0")"
check_eq "GRE tunnel created" "$?" "0"

BACKEND_SANDBOX="$SANDBOX_ROOT/backend"
backend() {
    TIXOLINK_ETC_DIR="$BACKEND_SANDBOX/etc" TIXOLINK_VAR_DIR="$BACKEND_SANDBOX/var" \
        TIXOLINK_RUN_DIR="$BACKEND_SANDBOX/run" TIXOLINK_LOG_FILE="$BACKEND_SANDBOX/tixolink.log" \
        TIXOLINK_NETNS="$NS_BACKEND" bash "$DRIVER" "$@"
}
BACKEND_TUN_ID="$(backend tunnel::create_from_fields "hap-tun-peer" "192.0.2.2" "192.0.2.1" \
    "manual" "10.250.0.0/30" "10.250.0.2" "10.250.0.1" "1300" "255" "0")"
check_eq "backend-side GRE tunnel created" "$?" "0"

echo "== Starting a real backend TCP service =="
ip netns exec "$NS_BACKEND" socat TCP4-LISTEN:9090,bind=10.250.0.2,fork,reuseaddr EXEC:cat \
    >"$SANDBOX_ROOT/backend.log" 2>&1 &
BACKEND_PID=$!
sleep 0.3
check "backend TCP service is running" kill -0 "$BACKEND_PID"

echo "== Configuring HAProxy forwarding =="
entry forwarding::set_engine "$TUN_ID" haproxy 0 >/dev/null
check_eq "forwarding engine set to haproxy" "$?" "0"
MAPPING_ID="$(entry forwarding::add "$TUN_ID" tcp "9090" "0.0.0.0" "" "nat" 0)"
check_eq "add TCP mapping (9090->9090)" "$?" "0"

check "generated config references this tunnel/mapping" grep -q "tixolink:${TUN_ID}:${MAPPING_ID}" "$FAKE_HAPROXY_CFG"
check "candidate HAProxy config validates with the real haproxy binary" haproxy -c -f "$FAKE_HAPROXY_CFG"
check "HAProxy process is running after apply" bash -c "[[ -f '$HAPROXY_PID_FILE' ]] && kill -0 \"\$(cat '$HAPROXY_PID_FILE')\""

echo "== Real TCP forwarding through HAProxy =="
check "client -> haproxy TCP listener -> backend (through GRE)" \
    bash -c "echo HAPROXY_HELLO | ip netns exec '$NS_ENTRY' timeout 3 socat - TCP4:192.0.2.1:9090 | grep -q HAPROXY_HELLO"

echo "== Change detection: re-applying an identical mapping triggers no reload =="
RELOADS_BEFORE="$(cat "$RELOAD_LOG")"
CURRENT_TUNNEL_JSON="$(entry config::tunnel_read "$TUN_ID")"
SAME_MAPPING="$(printf '%s' "$CURRENT_TUNNEL_JSON" | jq -c --arg mid "$MAPPING_ID" '.forwarding.mappings[] | select(.id == $mid)')"
entry forwarder::dispatch haproxy apply "$CURRENT_TUNNEL_JSON" "$SAME_MAPPING" 0 >/dev/null 2>&1
RELOADS_AFTER="$(cat "$RELOAD_LOG")"
check_eq "re-applying an identical mapping triggers no additional reload" "$RELOADS_AFTER" "$RELOADS_BEFORE"

echo "== Invalid candidate is rejected without reloading =="
RELOADS_BEFORE="$(cat "$RELOAD_LOG")"
entry forwarder::dispatch haproxy validate '{}' \
    '{"id":"badmap01","protocol":"udp","listen_address":"0.0.0.0","local_port":"53","remote_port":"53","remote_address":null,"nat_mode":"nat"}' \
    >/dev/null 2>&1
INVALID_STATUS=$?
RELOADS_AFTER="$(cat "$RELOAD_LOG")"
check_eq "UDP+HAProxy mapping rejected at validation" "$INVALID_STATUS" "3"
check_eq "rejected candidate caused no reload" "$RELOADS_AFTER" "$RELOADS_BEFORE"

echo "== Cleanup =="
entry forwarding::remove "$TUN_ID" "$MAPPING_ID" 0 >/dev/null
check_eq "remove mapping succeeded" "$?" "0"
check "managed block no longer references the removed mapping" bash -c "! grep -q '${TUN_ID}:${MAPPING_ID}' '$FAKE_HAPROXY_CFG'"

entry_plain tunnel::delete "$TUN_ID" 0 1 >/dev/null
backend tunnel::delete "$BACKEND_TUN_ID" 0 1 >/dev/null
kill "$BACKEND_PID" >/dev/null 2>&1
BACKEND_PID=""

echo
printf '%d checks passed, %d failed\n' "$PASS" "$FAIL"
check "real /etc/haproxy/haproxy.cfg was never touched" bash -c "! grep -q 'tixolink:' /etc/haproxy/haproxy.cfg 2>/dev/null"
check "real haproxy systemd service was never activated by this test" bash -c "[[ \"\$(systemctl is-active haproxy 2>/dev/null)\" != 'active' ]]"

trap - EXIT INT TERM
cleanup

HOST_NETNS_AFTER="$(ip netns list 2>/dev/null | sort)"
check_eq "no leaked network namespaces after cleanup" "$HOST_NETNS_AFTER" "$HOST_NETNS_BEFORE"

printf '%d checks passed, %d failed (final)\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]

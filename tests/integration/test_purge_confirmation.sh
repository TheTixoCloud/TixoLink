#!/usr/bin/env bash
# TixoLink NEXUS - purge confirmation hardening test.
#
# Proves the exact confirmation matrix mandated for `uninstall.sh --purge`:
#   interactive, no --force      -> strong typed "PURGE" confirmation required
#   interactive, --force         -> may bypass the typed prompt (documented,
#                                    consistent with --force everywhere else)
#   non-interactive               -> BOTH --force AND --confirm-purge required;
#                                    either one alone must refuse
# "Interactive" is simulated with `script -qec` (a real pseudo-tty), since
# -t 0/-t 1 both need to be true for uninstall.sh to take the interactive
# branch at all. Entirely sandboxed via TIXOLINK_ROOT; never touches the
# real host.
set -uo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$TEST_DIR/../.." && pwd)"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }
check_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', expected '$3')"; fi; }
check() { if "$2"; then pass "$1"; else fail "$1"; fi; }

fresh_sandbox() {
    local root="$1"
    rm -rf -- "$root"
    TIXOLINK_ROOT="$root" "$REPO_ROOT/install.sh" --force >/dev/null 2>&1
    mkdir -p "$root/etc/tixolink/tunnels"
    cat >"$root/etc/tixolink/tunnels/deadbeef.json" <<'EOF'
{"schema_version":1,"name":"present","engine":"gre","engine_config":{"interface":"tixo-deadbeef","local_public_ip":"192.0.2.1","remote_public_ip":"192.0.2.2","inner_subnet":"10.200.0.0/30","inner_local_ip":"10.200.0.1","inner_remote_ip":"10.200.0.2","mtu":1300,"ttl":255},"forwarding":{"engine":"none","mappings":[]}}
EOF
}

cleanup_all() { rm -rf -- /tmp/tixolink-purge-confirm-*; }
trap cleanup_all EXIT

# --- Non-interactive matrix: neither flag alone is sufficient ---------------

R1=/tmp/tixolink-purge-confirm-1
fresh_sandbox "$R1"
TIXOLINK_ROOT="$R1" "$REPO_ROOT/uninstall.sh" --purge </dev/null >/dev/null 2>&1
check_eq "non-interactive: --purge alone refused" "$?" "2"
check "non-interactive: --purge alone -> data survives" bash -c "[[ -f '$R1/etc/tixolink/tunnels/deadbeef.json' ]]"

R2=/tmp/tixolink-purge-confirm-2
fresh_sandbox "$R2"
TIXOLINK_ROOT="$R2" "$REPO_ROOT/uninstall.sh" --purge --force </dev/null >/dev/null 2>&1
check_eq "non-interactive: --purge --force (no --confirm-purge) refused" "$?" "2"
check "non-interactive: --purge --force alone -> data survives" bash -c "[[ -f '$R2/etc/tixolink/tunnels/deadbeef.json' ]]"

R3=/tmp/tixolink-purge-confirm-3
fresh_sandbox "$R3"
TIXOLINK_ROOT="$R3" "$REPO_ROOT/uninstall.sh" --purge --confirm-purge </dev/null >/dev/null 2>&1
check_eq "non-interactive: --purge --confirm-purge (no --force) refused" "$?" "2"
check "non-interactive: --confirm-purge alone -> data survives" bash -c "[[ -f '$R3/etc/tixolink/tunnels/deadbeef.json' ]]"

R4=/tmp/tixolink-purge-confirm-4
fresh_sandbox "$R4"
TIXOLINK_ROOT="$R4" "$REPO_ROOT/uninstall.sh" --purge --force --confirm-purge --backup-output "$R4.bak.tar.gz" </dev/null >/dev/null 2>&1
check_eq "non-interactive: --purge --force --confirm-purge succeeds" "$?" "0"
check "non-interactive: both flags -> data removed" bash -c "[[ ! -e '$R4/etc/tixolink' ]]"

# --- Interactive (real pty), no --force: requires typed "PURGE" -------------

R5=/tmp/tixolink-purge-confirm-5
fresh_sandbox "$R5"
TIXOLINK_ROOT="$R5" script -qec "'$REPO_ROOT/uninstall.sh' --purge" /dev/null <<<'n' >/dev/null 2>&1
check "interactive: decline first confirm -> data survives" bash -c "[[ -f '$R5/etc/tixolink/tunnels/deadbeef.json' ]]"

R6=/tmp/tixolink-purge-confirm-6
fresh_sandbox "$R6"
TIXOLINK_ROOT="$R6" script -qec "'$REPO_ROOT/uninstall.sh' --purge" /dev/null <<<$'y\nNOTPURGE' >/dev/null 2>&1
check "interactive: wrong typed word -> data survives" bash -c "[[ -f '$R6/etc/tixolink/tunnels/deadbeef.json' ]]"

R7=/tmp/tixolink-purge-confirm-7
fresh_sandbox "$R7"
TIXOLINK_ROOT="$R7" script -qec "'$REPO_ROOT/uninstall.sh' --purge --skip-backup" /dev/null <<<$'y\nPURGE' >/dev/null 2>&1
check "interactive: typed PURGE exactly -> data removed" bash -c "[[ ! -e '$R7/etc/tixolink' ]]"

# --- Interactive + --force: documented bypass of the typed prompt ----------

R8=/tmp/tixolink-purge-confirm-8
fresh_sandbox "$R8"
TIXOLINK_ROOT="$R8" script -qec "'$REPO_ROOT/uninstall.sh' --purge --force --confirm-purge --skip-backup" /dev/null </dev/null >/dev/null 2>&1
check "interactive + --force: no stdin needed, data removed" bash -c "[[ ! -e '$R8/etc/tixolink' ]]"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]

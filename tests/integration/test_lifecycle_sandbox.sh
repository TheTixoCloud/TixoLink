#!/usr/bin/env bash
# TixoLink NEXUS - Phase 6 mandatory end-to-end lifecycle test.
#
# Exercises install.sh/uninstall.sh and the backup/restore/factory-reset
# commands entirely under a private TIXOLINK_ROOT sandbox - this test
# NEVER installs into, or otherwise touches, the real host filesystem
# (/usr/local, /etc, /var/lib, /var/log, /etc/systemd/system). Sentinel
# files are planted next to (never inside) the managed sandbox paths to
# prove every destructive step stays scoped to TixoLink's own paths.
set -uo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$TEST_DIR/../.." && pwd)"

SANDBOX="$(mktemp -d /tmp/tixolink-lifecycle.XXXXXXXX)"
export TIXOLINK_ROOT="$SANDBOX"

BIN="$SANDBOX/usr/local/bin/tixolink"
LIBD="$SANDBOX/usr/local/lib/tixolink"
ETCD="$SANDBOX/etc/tixolink"
VARD="$SANDBOX/var/lib/tixolink"
LOGD="$SANDBOX/var/log/tixolink"
RUND="$SANDBOX/run/tixolink"
UNIT="$SANDBOX/etc/systemd/system/tixolink@.service"

# Every process this script spawns (install.sh/uninstall.sh directly, and
# the installed binary via run_cli) must log inside the sandbox, never to
# the real host's /var/log/tixolink - exporting it once here, before any
# of those are invoked, covers all of them via environment inheritance.
export TIXOLINK_LOG_FILE="$LOGD/tixolink.log"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }
check() { if "$2"; then pass "$1"; else fail "$1"; fi; }
check_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', expected '$3')"; fi; }

cleanup() { rm -rf -- "$SANDBOX" "$SANDBOX.pre-purge.tar.gz" /tmp/tixolink-lifecycle-*.log; }
trap cleanup EXIT

run_cli() {
    TIXOLINK_LIB_DIR="$LIBD" TIXOLINK_ENGINES_DIR="$LIBD/engines" \
        TIXOLINK_MODULES_DIR="$LIBD/modules" TIXOLINK_FORWARDERS_DIR="$LIBD/forwarders" \
        TIXOLINK_ETC_DIR="$ETCD" TIXOLINK_VAR_DIR="$VARD" TIXOLINK_RUN_DIR="$RUND" \
        "$BIN" "$@"
}

plant_sentinels() {
    mkdir -p "$SANDBOX/etc" "$SANDBOX/usr/local/bin" "$SANDBOX/var/lib/unrelated-app"
    printf 'unrelated\n' >"$SANDBOX/etc/unrelated.conf"
    printf 'unrelated\n' >"$SANDBOX/usr/local/bin/unrelated-tool"
    printf 'data\n' >"$SANDBOX/var/lib/unrelated-app/data"
}

sentinels_checksum() {
    ( cd "$SANDBOX" && sha256sum etc/unrelated.conf usr/local/bin/unrelated-tool var/lib/unrelated-app/data 2>/dev/null )
}

HOST_USR_LOCAL_BEFORE="$(find /usr/local -maxdepth 2 2>/dev/null | sort)"
HOST_ETC_TIXOLINK_BEFORE="$([[ -e /etc/tixolink ]] && echo present || echo absent)"
HOST_VAR_TIXOLINK_BEFORE="$([[ -e /var/lib/tixolink ]] && echo present || echo absent)"

# 1. create empty sandbox root
check "1. sandbox root created and empty" bash -c "[[ -d '$SANDBOX' ]] && [[ -z \"\$(ls -A '$SANDBOX')\" ]]"
plant_sentinels
SENTINELS_BEFORE="$(sentinels_checksum)"

# 2. fresh install
"$REPO_ROOT/install.sh" --force >/tmp/tixolink-lifecycle-install.log 2>&1
check_eq "2. fresh install exit 0" "$?" "0"

# 3. verify files/permissions/layout
check "3a. binary installed" bash -c "[[ -x '$BIN' ]]"
check "3b. lib dir installed" bash -c "[[ -f '$LIBD/common.sh' ]]"
check "3c. config dir created" bash -c "[[ -d '$ETCD' ]]"
check "3d. var dir created" bash -c "[[ -d '$VARD' ]]"
check "3e. systemd unit installed" bash -c "[[ -f '$UNIT' ]]"
check_eq "3f. bin mode 0755" "$(stat -c '%a' "$BIN")" "755"
check_eq "3g. etc dir mode 0750" "$(stat -c '%a' "$ETCD")" "750"

# 4. verify installed CLI
INSTALLED_VERSION="$(run_cli version)"
SOURCE_VERSION="$(head -n1 "$REPO_ROOT/VERSION")"
check_eq "4. installed CLI reports source version" "$INSTALLED_VERSION" "$SOURCE_VERSION"

# 5. create representative config/state fixtures
run_cli create >/dev/null 2>&1 </dev/null
TID="deadbeef"
mkdir -p "$ETCD/tunnels"
cat >"$ETCD/tunnels/${TID}.json" <<EOF
{"schema_version":1,"name":"sandbox-tunnel","engine":"gre",
 "engine_config":{"interface":"tixo-${TID}","local_public_ip":"192.0.2.1","remote_public_ip":"192.0.2.2",
   "inner_subnet":"10.200.0.0/30","inner_local_ip":"10.200.0.1","inner_remote_ip":"10.200.0.2","mtu":1300,"ttl":255},
 "forwarding":{"engine":"none","mappings":[]}}
EOF
chmod 0640 "$ETCD/tunnels/${TID}.json"
LIST_OUT="$(run_cli list)"
check "5. fixture tunnel visible via list" bash -c "echo '$LIST_OUT' | grep -q sandbox-tunnel"

# 6. reinstall same version
"$REPO_ROOT/install.sh" --force >/tmp/tixolink-lifecycle-reinstall.log 2>&1
check_eq "6. reinstall exit 0" "$?" "0"

# 7. prove user data preserved
check "7. fixture tunnel survives reinstall" bash -c "[[ -f '$ETCD/tunnels/${TID}.json' ]]"
check_eq "7b. tunnel name intact after reinstall" "$(jq -r .name "$ETCD/tunnels/${TID}.json")" "sandbox-tunnel"

# 8. simulate upgrade (bump the manifest's recorded version down so the real
#    source tree, at its real VERSION, is seen as newer)
jq '.tixolink_version = "0.0.1"' "$VARD/install-manifest.json" >"$VARD/install-manifest.json.tmp"
mv "$VARD/install-manifest.json.tmp" "$VARD/install-manifest.json"
UPGRADE_OUT="$("$REPO_ROOT/install.sh" --force 2>&1)"
check "8. install detects upgrade kind" bash -c "echo '$UPGRADE_OUT' | grep -q 'Kind:.*upgrade'"

# 9. prove user data preserved
check "9. fixture tunnel survives upgrade" bash -c "[[ -f '$ETCD/tunnels/${TID}.json' ]]"

# 10. create a backup
BACKUP_FILE="$(run_cli backup)"
BACKUP_PATH="$(echo "$BACKUP_FILE" | grep -oE '/[^ ]+\.tar\.gz')"
check "10. backup archive created" bash -c "[[ -f '$BACKUP_PATH' ]]"

# 11. mutate sandboxed state
jq '.name = "MUTATED"' "$ETCD/tunnels/${TID}.json" >"$ETCD/tunnels/${TID}.json.tmp"
mv "$ETCD/tunnels/${TID}.json.tmp" "$ETCD/tunnels/${TID}.json"
echo '{"schema_version":1,"name":"extra-not-in-backup","engine":"gre","engine_config":{"interface":"tixo-extra01"},"forwarding":{"engine":"none","mappings":[]}}' >"$ETCD/tunnels/extra0001.json"

# 12. restore backup
run_cli restore "$BACKUP_PATH" --force >/tmp/tixolink-lifecycle-restore.log 2>&1
check_eq "12. restore exit 0" "$?" "0"

# 13. prove exact expected restoration
check_eq "13a. mutated name reverted" "$(jq -r .name "$ETCD/tunnels/${TID}.json")" "sandbox-tunnel"
check "13b. tunnel absent from backup is removed" bash -c "[[ ! -f '$ETCD/tunnels/extra0001.json' ]]"

# 14. default uninstall
"$REPO_ROOT/uninstall.sh" --force >/tmp/tixolink-lifecycle-uninstall.log 2>&1
check_eq "14. default uninstall exit 0" "$?" "0"
check "14b. binary removed" bash -c "[[ ! -e '$BIN' ]]"
check "14c. lib dir removed" bash -c "[[ ! -e '$LIBD' ]]"

# 15. prove persistent user data preserved
check "15. tunnel config survives default uninstall" bash -c "[[ -f '$ETCD/tunnels/${TID}.json' ]]"
check "15b. backups dir survives default uninstall" bash -c "[[ -d '$VARD/backups' ]]"

# 16. reinstall
"$REPO_ROOT/install.sh" --force >/tmp/tixolink-lifecycle-reinstall2.log 2>&1
check_eq "16. reinstall after uninstall exit 0" "$?" "0"
check "16b. previously-preserved tunnel still present" bash -c "[[ -f '$ETCD/tunnels/${TID}.json' ]]"

# 17. factory reset
run_cli factory-reset --force --skip-backup >/tmp/tixolink-lifecycle-factory-reset.log 2>&1
check_eq "17. factory-reset exit 0" "$?" "0"

# 18. prove TixoLink state removed/reset
check "18a. tunnel config removed by factory reset" bash -c "[[ ! -f '$ETCD/tunnels/${TID}.json' ]]"
check_eq "18b. app config reset to defaults" "$(jq -r .subnet_pool "$ETCD/config.json")" "10.200.0.0/16"
check "18c. TixoLink itself still installed" bash -c "[[ -x '$BIN' ]]"

# 19. purge uninstall
"$REPO_ROOT/uninstall.sh" --purge --force --confirm-purge --backup-output "$SANDBOX.pre-purge.tar.gz" >/tmp/tixolink-lifecycle-purge.log 2>&1
check_eq "19. purge exit 0" "$?" "0"

# 20. prove only TixoLink-owned paths removed
check "20a. etc/tixolink removed" bash -c "[[ ! -e '$ETCD' ]]"
check "20b. var/lib/tixolink removed" bash -c "[[ ! -e '$VARD' ]]"
check "20c. binary removed" bash -c "[[ ! -e '$BIN' ]]"
check "20d. lib dir removed" bash -c "[[ ! -e '$LIBD' ]]"
check "20e. systemd unit removed" bash -c "[[ ! -e '$UNIT' ]]"
check "20f. log dir removed" bash -c "[[ ! -e '$LOGD' ]]"

# 21. prove unrelated sentinel files survive, byte-identical
SENTINELS_AFTER="$(sentinels_checksum)"
check_eq "21. sentinel files byte-identical after full lifecycle" "$SENTINELS_AFTER" "$SENTINELS_BEFORE"

# --- Host-state verification: nothing outside the sandbox ever moved ---------
HOST_USR_LOCAL_AFTER="$(find /usr/local -maxdepth 2 2>/dev/null | sort)"
check_eq "host /usr/local unchanged" "$HOST_USR_LOCAL_AFTER" "$HOST_USR_LOCAL_BEFORE"
check_eq "host /etc/tixolink presence unchanged" "$([[ -e /etc/tixolink ]] && echo present || echo absent)" "$HOST_ETC_TIXOLINK_BEFORE"
check_eq "host /var/lib/tixolink presence unchanged" "$([[ -e /var/lib/tixolink ]] && echo present || echo absent)" "$HOST_VAR_TIXOLINK_BEFORE"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]

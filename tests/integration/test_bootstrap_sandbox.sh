#!/usr/bin/env bash
# TixoLink NEXUS - end-to-end sandbox test for the public bootstrap
# installer (TixoLink.sh), exercising it against the REAL install.sh/lib
# tree so fresh-install/reinstall/upgrade/downgrade-refusal behavior is
# proven for real, not re-implemented here. Every network call is
# redirected to local fixture files (bootstrap::http_get_file is
# redefined) and every install.sh invocation is forced into a private
# TIXOLINK_ROOT sandbox (bootstrap::_install_extra_args is redefined) -
# this test NEVER touches the real host filesystem.
set -uo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$TEST_DIR/../.." && pwd)"

SANDBOX="$(mktemp -d /tmp/tixolink-boot-sandbox.XXXXXXXX)"
FIXTURES="$(mktemp -d /tmp/tixolink-boot-fixtures.XXXXXXXX)"
export TIXOLINK_ROOT="$SANDBOX"

BIN="$SANDBOX/usr/local/bin/tixolink"
LIBD="$SANDBOX/usr/local/lib/tixolink"
ETCD="$SANDBOX/etc/tixolink"
VARD="$SANDBOX/var/lib/tixolink"
LOGD="$SANDBOX/var/log/tixolink"
RUND="$SANDBOX/run/tixolink"
export TIXOLINK_LOG_FILE="$LOGD/tixolink.log"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL - %s\n' "$1"; }
check() { if "$2"; then pass "$1"; else fail "$1"; fi; }
check_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (got '$2', expected '$3')"; fi; }

HOST_USR_LOCAL_BEFORE="$(find /usr/local -maxdepth 2 2>/dev/null | sort)"
cleanup() {
    rm -rf -- "$SANDBOX" "$FIXTURES"
    HOST_USR_LOCAL_AFTER="$(find /usr/local -maxdepth 2 2>/dev/null | sort)"
    check_eq "host /usr/local unchanged" "$HOST_USR_LOCAL_AFTER" "$HOST_USR_LOCAL_BEFORE"
}
trap cleanup EXIT

run_cli() {
    TIXOLINK_LIB_DIR="$LIBD" TIXOLINK_ENGINES_DIR="$LIBD/engines" \
        TIXOLINK_MODULES_DIR="$LIBD/modules" TIXOLINK_FORWARDERS_DIR="$LIBD/forwarders" \
        TIXOLINK_ETC_DIR="$ETCD" TIXOLINK_VAR_DIR="$VARD" TIXOLINK_RUN_DIR="$RUND" \
        "$BIN" "$@"
}

# build_package <version> - packages the REAL repo tree (install.sh, lib/,
# engines/, forwarders/, modules/, bin/, systemd/) at the given version
# into $FIXTURES/tixolink-<version>.tar.gz + a sibling SHA256SUMS, without
# ever touching the real working tree's own VERSION file.
build_package() {
    local version="$1"
    local stage="$FIXTURES/stage-$version"
    local pkg="$stage/tixolink-${version}"
    install -d "$pkg"
    cp -p "$REPO_ROOT"/install.sh "$pkg/"
    cp -p "$REPO_ROOT"/uninstall.sh "$pkg/" 2>/dev/null || true
    cp -a "$REPO_ROOT/lib" "$pkg/lib"
    cp -a "$REPO_ROOT/engines" "$pkg/engines"
    cp -a "$REPO_ROOT/forwarders" "$pkg/forwarders"
    cp -a "$REPO_ROOT/modules" "$pkg/modules"
    cp -a "$REPO_ROOT/bin" "$pkg/bin"
    cp -a "$REPO_ROOT/systemd" "$pkg/systemd"
    printf '%s' "$version" >"$pkg/VERSION"
    ( cd "$stage" && tar -czf "$FIXTURES/tixolink-${version}.tar.gz" "tixolink-${version}" )
    ( cd "$FIXTURES" && sha256sum "tixolink-${version}.tar.gz" >"SHA256SUMS-${version}" )
    rm -rf -- "$stage"
}

REAL_VERSION="$(head -n1 "$REPO_ROOT/VERSION")"
build_package "$REAL_VERSION"
build_package "9.9.9"

source "$REPO_ROOT/TixoLink.sh"
# TixoLink.sh sets -Eeuo pipefail on `source` too; this test relies on
# capturing non-zero exits from bootstrap::main itself rather than having
# the whole test script die on the first one.
set +e

bootstrap::_current_uid() { printf '0'; }
bootstrap::_os_release_file() { printf 'ID=ubuntu\nVERSION_ID=24.04\n' >"$FIXTURES/osr"; printf '%s' "$FIXTURES/osr"; }
bootstrap::_arch() { printf 'x86_64'; }
bootstrap::_has_curl() { return 0; }
bootstrap::_curl_supports_https() { return 0; }
bootstrap::_install_extra_args() { printf '%s\n' '--root' "$SANDBOX"; }

# The real install.sh installs into $SANDBOX (never the real host), so
# bootstrap::main's post-install `command -v tixolink` / `tixolink
# version` check needs the sandbox bin dir on PATH and the same
# TIXOLINK_*_DIR overrides run_cli() uses - exactly what a real install
# gets for free from /usr/local/bin being on PATH and the binary's own
# hardcoded default paths, which this sandbox cannot use.
export PATH="$SANDBOX/usr/local/bin:$PATH"
export TIXOLINK_LIB_DIR="$LIBD" TIXOLINK_ENGINES_DIR="$LIBD/engines" \
    TIXOLINK_MODULES_DIR="$LIBD/modules" TIXOLINK_FORWARDERS_DIR="$LIBD/forwarders" \
    TIXOLINK_ETC_DIR="$ETCD" TIXOLINK_VAR_DIR="$VARD" TIXOLINK_RUN_DIR="$RUND"
bootstrap::http_get_file() {
    local url="$1" dest="$2"
    case "$url" in
        *"tixolink-${REAL_VERSION}.tar.gz") cp "$FIXTURES/tixolink-${REAL_VERSION}.tar.gz" "$dest" ;;
        *"tixolink-9.9.9.tar.gz") cp "$FIXTURES/tixolink-9.9.9.tar.gz" "$dest" ;;
        *SHA256SUMS)
            case "$url" in
                *"/v${REAL_VERSION}/"*) cp "$FIXTURES/SHA256SUMS-${REAL_VERSION}" "$dest" ;;
                *"/v9.9.9/"*) cp "$FIXTURES/SHA256SUMS-9.9.9" "$dest" ;;
            esac
            ;;
    esac
}

# 1. fresh install at the real current version
( TIXOLINK_VERSION="$REAL_VERSION" bootstrap::main >"$FIXTURES/install1.log" 2>&1 )
check_eq "1. fresh install exit 0" "$?" "0"
check "1b. binary installed" bash -c "[[ -x '$BIN' ]]"
check_eq "1c. installed CLI reports expected version" "$(run_cli version 2>/dev/null)" "$REAL_VERSION"

# 2. reinstall same version (idempotency)
( TIXOLINK_VERSION="$REAL_VERSION" bootstrap::main >"$FIXTURES/install2.log" 2>&1 )
check_eq "2. reinstall exit 0" "$?" "0"
check "2b. reinstall plan reports 'reinstall' kind" bash -c "grep -q 'Kind:.*reinstall' '$FIXTURES/install2.log'"

# 3. upgrade to a newer version
( TIXOLINK_VERSION="9.9.9" bootstrap::main >"$FIXTURES/install3.log" 2>&1 )
check_eq "3. upgrade exit 0" "$?" "0"
check_eq "3b. installed CLI reports upgraded version" "$(run_cli version 2>/dev/null)" "9.9.9"

# 4. downgrade refusal (back to the original version, no --allow-downgrade)
( TIXOLINK_VERSION="$REAL_VERSION" bootstrap::main >"$FIXTURES/install4.log" 2>&1 )
DOWNGRADE_RC=$?
check_eq "4. downgrade without override is refused (nonzero exit)" "$([[ "$DOWNGRADE_RC" != "0" ]] && echo refused || echo allowed)" "refused"
check_eq "4b. installed CLI still reports the newer version" "$(run_cli version 2>/dev/null)" "9.9.9"

# 5. final CLI availability checks
check "5a. tixolink binary resolvable at expected sandbox path" bash -c "command -v '$BIN' >/dev/null"
check_eq "5b. tixolink version prints a bare version string" "$(run_cli version 2>/dev/null)" "9.9.9"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]

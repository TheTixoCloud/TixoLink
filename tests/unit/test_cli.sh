#!/usr/bin/env bash
# Exercises bin/tixolink as a subprocess rather than sourcing lib/cli.sh
# directly, since cli::main calls exit (by design — see docs/architecture.md).
set -Eeuo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$TEST_DIR/../.." && pwd)"

TIXOLINK_TEST_ROOT="$(mktemp -d /tmp/tixolink-test.XXXXXXXX)"
cleanup() { rm -rf -- "$TIXOLINK_TEST_ROOT"; }
trap cleanup EXIT

# shellcheck source=tests/lib/test_harness.sh
source "$REPO_ROOT/tests/lib/test_harness.sh"

run_tixolink() {
    TIXOLINK_LOG_FILE="$TIXOLINK_TEST_ROOT/tixolink.log" \
        "$REPO_ROOT/bin/tixolink" "$@"
}

test_version_command_exits_zero_and_prints_version() {
    local out status=0
    out="$(run_tixolink version)" || status=$?
    [[ "$status" -eq 0 ]] && [[ "$out" == "0.1.0-dev" ]]
}

test_help_command_exits_zero() {
    local status=0
    run_tixolink help >/dev/null || status=$?
    [[ "$status" -eq 0 ]]
}

test_unknown_command_exits_with_usage_code() {
    local status=0
    run_tixolink totally-not-a-command >/dev/null 2>&1 || status=$?
    [[ "$status" -eq 2 ]]
}

test_no_command_non_interactive_exits_with_usage_code() {
    local status=0
    run_tixolink </dev/null >/dev/null 2>&1 || status=$?
    [[ "$status" -eq 2 ]]
}

th::run test_version_command_exits_zero_and_prints_version
th::run test_help_command_exits_zero
th::run test_unknown_command_exits_with_usage_code
th::run test_no_command_non_interactive_exits_with_usage_code

th::summary

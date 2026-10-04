#!/usr/bin/env bash
# TixoLink NEXUS - integration test driver.
#
# Sources the full library/engine/module stack (everything bin/tixolink
# sources except the UI menu and CLI dispatcher) and then calls the
# function named in $1 with the remaining arguments. Each invocation is a
# fresh process, so the readonly per-process config/state/run directories
# (TIXOLINK_ETC_DIR/TIXOLINK_VAR_DIR/TIXOLINK_RUN_DIR, set by the caller's
# environment) and TIXOLINK_NETNS correctly simulate one independent
# "host" per invocation, exactly like separate real machines would be.
set -Eeuo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$TEST_DIR/../.." && pwd)"

TIXOLINK_LIB_DIR="$REPO_ROOT/lib"
TIXOLINK_ENGINES_DIR="$REPO_ROOT/engines"
TIXOLINK_MODULES_DIR="$REPO_ROOT/modules"
TIXOLINK_FORWARDERS_DIR="$REPO_ROOT/forwarders"
export TIXOLINK_LIB_DIR TIXOLINK_ENGINES_DIR TIXOLINK_MODULES_DIR TIXOLINK_FORWARDERS_DIR

# shellcheck source=lib/common.sh
source "$TIXOLINK_LIB_DIR/common.sh"
# shellcheck source=lib/logging.sh
source "$TIXOLINK_LIB_DIR/logging.sh"
# shellcheck source=lib/ui.sh
source "$TIXOLINK_LIB_DIR/ui.sh"
# shellcheck source=lib/validation.sh
source "$TIXOLINK_LIB_DIR/validation.sh"
# shellcheck source=lib/platform.sh
source "$TIXOLINK_LIB_DIR/platform.sh"
# shellcheck source=lib/locking.sh
source "$TIXOLINK_LIB_DIR/locking.sh"
# shellcheck source=lib/config.sh
source "$TIXOLINK_LIB_DIR/config.sh"
# shellcheck source=lib/state.sh
source "$TIXOLINK_LIB_DIR/state.sh"
# shellcheck source=lib/subnet.sh
source "$TIXOLINK_LIB_DIR/subnet.sh"
# shellcheck source=lib/ports.sh
source "$TIXOLINK_LIB_DIR/ports.sh"
# shellcheck source=lib/dependency.sh
source "$TIXOLINK_LIB_DIR/dependency.sh"
# shellcheck source=lib/transaction.sh
source "$TIXOLINK_LIB_DIR/transaction.sh"
# shellcheck source=lib/sysinfo.sh
source "$TIXOLINK_LIB_DIR/sysinfo.sh"
# shellcheck source=lib/manifest.sh
source "$TIXOLINK_LIB_DIR/manifest.sh"
# shellcheck source=lib/migration.sh
source "$TIXOLINK_LIB_DIR/migration.sh"
# shellcheck source=engines/engine_api.sh
source "$TIXOLINK_ENGINES_DIR/engine_api.sh"
# shellcheck source=engines/gre.sh
source "$TIXOLINK_ENGINES_DIR/gre.sh"
# shellcheck source=forwarders/forwarder_api.sh
source "$TIXOLINK_FORWARDERS_DIR/forwarder_api.sh"
# shellcheck source=forwarders/none.sh
source "$TIXOLINK_FORWARDERS_DIR/none.sh"
# shellcheck source=forwarders/netfilter.sh
source "$TIXOLINK_FORWARDERS_DIR/netfilter.sh"
# shellcheck source=forwarders/haproxy.sh
source "$TIXOLINK_FORWARDERS_DIR/haproxy.sh"
# shellcheck source=modules/tunnel.sh
source "$TIXOLINK_MODULES_DIR/tunnel.sh"
# shellcheck source=modules/peer.sh
source "$TIXOLINK_MODULES_DIR/peer.sh"
# shellcheck source=modules/forwarding.sh
source "$TIXOLINK_MODULES_DIR/forwarding.sh"
# shellcheck source=modules/diagnostics.sh
source "$TIXOLINK_MODULES_DIR/diagnostics.sh"
# shellcheck source=modules/benchmark.sh
source "$TIXOLINK_MODULES_DIR/benchmark.sh"
# shellcheck source=modules/optimizer.sh
source "$TIXOLINK_MODULES_DIR/optimizer.sh"
# shellcheck source=modules/bbr.sh
source "$TIXOLINK_MODULES_DIR/bbr.sh"
# shellcheck source=modules/monitor.sh
source "$TIXOLINK_MODULES_DIR/monitor.sh"
# shellcheck source=modules/backup.sh
source "$TIXOLINK_MODULES_DIR/backup.sh"
# shellcheck source=modules/restore.sh
source "$TIXOLINK_MODULES_DIR/restore.sh"
# shellcheck source=modules/update.sh
source "$TIXOLINK_MODULES_DIR/update.sh"
# shellcheck source=modules/lifecycle.sh
source "$TIXOLINK_MODULES_DIR/lifecycle.sh"

# Test-only seam: lets a specific test substitute a handful of functions
# (e.g. haproxy::_reload/_is_active, to drive a throwaway process instead
# of the real systemd service) without duplicating the sourcing list above.
if [[ -n "${TIXOLINK_TEST_OVERRIDES_FILE:-}" && -f "$TIXOLINK_TEST_OVERRIDES_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$TIXOLINK_TEST_OVERRIDES_FILE"
fi

"$@"

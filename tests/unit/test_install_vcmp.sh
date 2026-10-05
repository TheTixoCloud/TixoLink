#!/usr/bin/env bash
# install.sh deliberately duplicates its own version-compare function
# (install::_vcmp) instead of sourcing modules/update.sh, so it works
# standalone on a brand-new target before modules/ exists on disk - see the
# comment above install::_vcmp in install.sh. That duplication means it
# needs its own test coverage; this extracts just the function body (via
# sed) rather than sourcing the whole script, since install.sh runs its
# PRECHECK/STAGE/ACTIVATE sequence unconditionally once sourced.
set -Eeuo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$TEST_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/test_harness.sh"

FN_SRC="$(sed -n '/^install::_vcmp()/,/^}/p' "$REPO_ROOT/install.sh")"
[[ -n "$FN_SRC" ]] || { echo "could not extract install::_vcmp from install.sh" >&2; exit 1; }
eval "$FN_SRC"

test_vcmp_equal() { th::assert_eq "$(install::_vcmp "0.6.0-dev" "0.6.0-dev")" "0"; }
test_vcmp_dev_lt_rc1() { th::assert_eq "$(install::_vcmp "0.6.0-dev" "1.0.0-rc1")" "-1"; }
test_vcmp_rc1_lt_rc2() { th::assert_eq "$(install::_vcmp "1.0.0-rc1" "1.0.0-rc2")" "-1"; }
test_vcmp_rc1_lt_bare() { th::assert_eq "$(install::_vcmp "1.0.0-rc1" "1.0.0")" "-1"; }
test_vcmp_rc2_lt_bare() { th::assert_eq "$(install::_vcmp "1.0.0-rc2" "1.0.0")" "-1"; }
test_vcmp_bare_lt_patch() { th::assert_eq "$(install::_vcmp "1.0.0" "1.0.1")" "-1"; }
test_vcmp_dev_lt_patch() { th::assert_eq "$(install::_vcmp "0.6.0-dev" "1.0.1")" "-1"; }
test_vcmp_rc10_gt_rc2() { th::assert_eq "$(install::_vcmp "1.0.0-rc10" "1.0.0-rc2")" "1"; }
test_vcmp_v_prefix_ignored() { th::assert_eq "$(install::_vcmp "v1.2.0" "1.2.0")" "0"; }

th::run test_vcmp_equal
th::run test_vcmp_dev_lt_rc1
th::run test_vcmp_rc1_lt_rc2
th::run test_vcmp_rc1_lt_bare
th::run test_vcmp_rc2_lt_bare
th::run test_vcmp_bare_lt_patch
th::run test_vcmp_dev_lt_patch
th::run test_vcmp_rc10_gt_rc2
th::run test_vcmp_v_prefix_ignored

th::summary

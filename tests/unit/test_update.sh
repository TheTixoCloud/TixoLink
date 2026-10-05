#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$TEST_DIR/../.." && pwd)"
TIXOLINK_LIB_DIR="$REPO_ROOT/lib"
export TIXOLINK_LIB_DIR

TIXOLINK_TEST_ROOT="$(mktemp -d /tmp/tixolink-test.XXXXXXXX)"
export TIXOLINK_ETC_DIR="$TIXOLINK_TEST_ROOT/etc"
export TIXOLINK_VAR_DIR="$TIXOLINK_TEST_ROOT/var"
export TIXOLINK_LOG_FILE="$TIXOLINK_TEST_ROOT/tixolink.log"
export TIXOLINK_TMP_DIR="$TIXOLINK_TEST_ROOT/tmp"
mkdir -p "$TIXOLINK_TMP_DIR"

cleanup() { rm -rf -- "$TIXOLINK_TEST_ROOT"; }
trap cleanup EXIT

source "$REPO_ROOT/tests/lib/test_harness.sh"
source "$TIXOLINK_LIB_DIR/common.sh"
source "$TIXOLINK_LIB_DIR/logging.sh"
source "$TIXOLINK_LIB_DIR/ui.sh"
source "$REPO_ROOT/modules/update.sh"

# --- version compare -----------------------------------------------------------

test_vcmp_equal() { th::assert_eq "$(update::_version_compare "0.6.0-dev" "0.6.0-dev")" "0"; }
test_vcmp_numeric_greater() { th::assert_eq "$(update::_version_compare "0.7.0" "0.6.0")" "1"; }
test_vcmp_numeric_less() { th::assert_eq "$(update::_version_compare "0.5.0" "0.6.0")" "-1"; }
test_vcmp_dev_is_less_than_bare() { th::assert_eq "$(update::_version_compare "0.6.0-dev" "0.6.0")" "-1"; }
test_vcmp_bare_is_greater_than_dev() { th::assert_eq "$(update::_version_compare "0.6.0" "0.6.0-dev")" "1"; }
test_vcmp_v_prefix_ignored() { th::assert_eq "$(update::_version_compare "v1.2.0" "1.2.0")" "0"; }

# --- RC1 release-readiness SemVer matrix (TixoLink#Phase 8) ---------------------
# 0.6.0-dev < 1.0.0-rc1 < 1.0.0-rc2 < 1.0.0 < 1.0.1, verified pairwise rather
# than assuming transitivity, plus the two-digit rc ordering a plain lexical
# suffix compare would get backwards ("rc10" vs "rc2").
test_vcmp_dev_lt_rc1() { th::assert_eq "$(update::_version_compare "0.6.0-dev" "1.0.0-rc1")" "-1"; }
test_vcmp_rc1_lt_rc2() { th::assert_eq "$(update::_version_compare "1.0.0-rc1" "1.0.0-rc2")" "-1"; }
test_vcmp_rc1_lt_bare() { th::assert_eq "$(update::_version_compare "1.0.0-rc1" "1.0.0")" "-1"; }
test_vcmp_rc2_lt_bare() { th::assert_eq "$(update::_version_compare "1.0.0-rc2" "1.0.0")" "-1"; }
test_vcmp_bare_lt_patch() { th::assert_eq "$(update::_version_compare "1.0.0" "1.0.1")" "-1"; }
test_vcmp_dev_lt_patch() { th::assert_eq "$(update::_version_compare "0.6.0-dev" "1.0.1")" "-1"; }
test_vcmp_rc1_eq_rc1() { th::assert_eq "$(update::_version_compare "1.0.0-rc1" "1.0.0-rc1")" "0"; }
test_vcmp_rc2_gt_rc10_would_be_wrong_lexically() { th::assert_eq "$(update::_version_compare "1.0.0-rc2" "1.0.0-rc10")" "-1"; }
test_vcmp_rc10_gt_rc2() { th::assert_eq "$(update::_version_compare "1.0.0-rc10" "1.0.0-rc2")" "1"; }

# --- update::check (mocked HTTP) -----------------------------------------------

FIXTURE_RELEASE_NEWER='{"tag_name":"v9.9.9","html_url":"https://example.invalid/r","body":"notes"}'
# "same as currently installed" must track whatever VERSION actually is,
# not a hardcoded string, or this fixture silently goes stale on every
# version bump (it did, across the 0.1.0-dev -> 0.6.0-dev -> 1.0.0-rc1
# transitions).
FIXTURE_RELEASE_SAME="$(printf '{"tag_name":"v%s","html_url":"https://example.invalid/r","body":"notes"}' "$(common::version)")"
FIXTURE_RELEASE_OLDER='{"tag_name":"v0.0.1","html_url":"https://example.invalid/r","body":"notes"}'
FIXTURE_RATE_LIMIT='{"message":"API rate limit exceeded","documentation_url":"https://docs.github.com"}'

test_check_detects_newer_release() {
    update::_http_get() { printf '%s' "$FIXTURE_RELEASE_NEWER"; }
    local result; result="$(update::check)"
    th::assert_eq "$(jq -r '.update_available' <<<"$result")" "true"
    th::assert_eq "$(jq -r '.latest_version' <<<"$result")" "9.9.9"
}

test_check_reports_up_to_date() {
    update::_http_get() { printf '%s' "$FIXTURE_RELEASE_SAME"; }
    local result; result="$(update::check)"
    th::assert_eq "$(jq -r '.update_available' <<<"$result")" "false"
}

test_check_older_release_not_available() {
    update::_http_get() { printf '%s' "$FIXTURE_RELEASE_OLDER"; }
    local result; result="$(update::check)"
    th::assert_eq "$(jq -r '.update_available' <<<"$result")" "false"
}

test_check_handles_network_failure() {
    update::_http_get() { return 1; }
    ! update::check >/dev/null 2>&1
}

test_check_handles_malformed_response() {
    update::_http_get() { printf 'not json'; }
    ! update::check >/dev/null 2>&1
}

test_check_handles_rate_limit_response() {
    update::_http_get() { printf '%s' "$FIXTURE_RATE_LIMIT"; }
    ! update::check >/dev/null 2>&1
}

# --- update::apply (mocked HTTP + downloads) -----------------------------------

make_fake_release_package() {
    local dir="$1" version="$2"
    local pkg="$dir/TixoLink-${version}"
    install -d "$pkg"
    printf '%s' "$version" >"$pkg/VERSION"
    cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
echo "fake installer invoked: $*"
exit 0
EOF
    chmod +x "$pkg/install.sh"
    ( cd "$dir" && tar -czf "artifact.tar.gz" "TixoLink-${version}" )
    ( cd "$dir" && sha256sum "artifact.tar.gz" | awk '{print $1, "artifact.tar.gz"}' >SHA256SUMS )
}

test_apply_rejects_checksum_mismatch() {
    local dir="$TIXOLINK_TEST_ROOT/pkg1"
    install -d "$dir"
    make_fake_release_package "$dir" "9.9.9"
    sed -i 's/^[0-9a-f]\{64\}/0000000000000000000000000000000000000000000000000000000000000000/' "$dir/SHA256SUMS"

    update::_http_get() {
        case "$1" in
            *releases/latest) printf '{"tag_name":"v9.9.9","assets":[{"name":"artifact.tar.gz","browser_download_url":"fixture://artifact"},{"name":"SHA256SUMS","browser_download_url":"fixture://checksums"}]}' ;;
        esac
    }
    update::_http_get_file() {
        case "$1" in
            fixture://artifact) cp "$dir/artifact.tar.gz" "$2" ;;
            fixture://checksums) cp "$dir/SHA256SUMS" "$2" ;;
        esac
    }
    ! update::apply --force >/dev/null 2>&1
}

test_apply_rejects_missing_artifact() {
    update::_http_get() { printf '{"tag_name":"v9.9.9","assets":[]}'; }
    ! update::apply --force >/dev/null 2>&1
}

test_apply_noop_when_up_to_date() {
    update::_http_get() { printf '%s' "$FIXTURE_RELEASE_SAME"; }
    update::apply --force >/dev/null 2>&1
}

# Regression test: packaging/build-release.sh (and the real GitHub
# release) names the checksum asset "SHA256SUMS", not "checksums.sha256" -
# a mismatch that previously made every real update silently fail at
# asset selection. This exercises the full apply path end-to-end against
# that exact asset name.
test_apply_succeeds_with_real_asset_naming() {
    local dir="$TIXOLINK_TEST_ROOT/pkg2"
    local fake_lib="$TIXOLINK_TEST_ROOT/fake-lib-$$"
    install -d "$dir" "$fake_lib"
    printf '0.0.1' >"$fake_lib/VERSION"
    make_fake_release_package "$dir" "9.9.9"
    # The shared fixture's fake install.sh only echoes; make it actually
    # write the new VERSION into a private fake TIXOLINK_LIB_DIR (never
    # the real repo's lib/) so update::apply's post-install version check
    # has something real to verify against.
    cat >"$dir/TixoLink-9.9.9/install.sh" <<EOF
#!/usr/bin/env bash
printf '9.9.9' >"${fake_lib}/VERSION"
exit 0
EOF
    chmod +x "$dir/TixoLink-9.9.9/install.sh"
    ( cd "$dir" && tar -czf "artifact.tar.gz" "TixoLink-9.9.9" )
    ( cd "$dir" && sha256sum "artifact.tar.gz" | awk '{print $1, "artifact.tar.gz"}' >SHA256SUMS )

    (
        TIXOLINK_LIB_DIR="$fake_lib"
        update::_http_get() {
            case "$1" in
                *releases/latest) printf '{"tag_name":"v9.9.9","assets":[{"name":"artifact.tar.gz","browser_download_url":"fixture://artifact"},{"name":"SHA256SUMS","browser_download_url":"fixture://sha256sums"}]}' ;;
            esac
        }
        update::_http_get_file() {
            case "$1" in
                fixture://artifact) cp "$dir/artifact.tar.gz" "$2" ;;
                fixture://sha256sums) cp "$dir/SHA256SUMS" "$2" ;;
            esac
        }
        update::apply --force >/dev/null 2>&1
    )
}

th::run test_vcmp_equal
th::run test_vcmp_numeric_greater
th::run test_vcmp_numeric_less
th::run test_vcmp_dev_is_less_than_bare
th::run test_vcmp_bare_is_greater_than_dev
th::run test_vcmp_v_prefix_ignored
th::run test_vcmp_dev_lt_rc1
th::run test_vcmp_rc1_lt_rc2
th::run test_vcmp_rc1_lt_bare
th::run test_vcmp_rc2_lt_bare
th::run test_vcmp_bare_lt_patch
th::run test_vcmp_dev_lt_patch
th::run test_vcmp_rc1_eq_rc1
th::run test_vcmp_rc2_gt_rc10_would_be_wrong_lexically
th::run test_vcmp_rc10_gt_rc2
th::run test_check_detects_newer_release
th::run test_check_reports_up_to_date
th::run test_check_older_release_not_available
th::run test_check_handles_network_failure
th::run test_check_handles_malformed_response
th::run test_check_handles_rate_limit_response
th::run test_apply_rejects_checksum_mismatch
th::run test_apply_rejects_missing_artifact
th::run test_apply_noop_when_up_to_date
th::run test_apply_succeeds_with_real_asset_naming

th::summary

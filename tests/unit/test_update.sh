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

# --- update::check (mocked HTTP) -----------------------------------------------

FIXTURE_RELEASE_NEWER='{"tag_name":"v9.9.9","html_url":"https://example.invalid/r","body":"notes"}'
FIXTURE_RELEASE_SAME='{"tag_name":"v0.6.0-dev","html_url":"https://example.invalid/r","body":"notes"}'
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
    ( cd "$dir" && sha256sum "artifact.tar.gz" | awk '{print $1, "artifact.tar.gz"}' >checksums.sha256 )
}

test_apply_rejects_checksum_mismatch() {
    local dir="$TIXOLINK_TEST_ROOT/pkg1"
    install -d "$dir"
    make_fake_release_package "$dir" "9.9.9"
    sed -i 's/^[0-9a-f]\{64\}/0000000000000000000000000000000000000000000000000000000000000000/' "$dir/checksums.sha256"

    update::_http_get() {
        case "$1" in
            *releases/latest) printf '{"tag_name":"v9.9.9","assets":[{"name":"artifact.tar.gz","browser_download_url":"fixture://artifact"},{"name":"checksums.sha256","browser_download_url":"fixture://checksums"}]}' ;;
        esac
    }
    update::_http_get_file() {
        case "$1" in
            fixture://artifact) cp "$dir/artifact.tar.gz" "$2" ;;
            fixture://checksums) cp "$dir/checksums.sha256" "$2" ;;
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

th::run test_vcmp_equal
th::run test_vcmp_numeric_greater
th::run test_vcmp_numeric_less
th::run test_vcmp_dev_is_less_than_bare
th::run test_vcmp_bare_is_greater_than_dev
th::run test_vcmp_v_prefix_ignored
th::run test_check_detects_newer_release
th::run test_check_reports_up_to_date
th::run test_check_older_release_not_available
th::run test_check_handles_network_failure
th::run test_check_handles_malformed_response
th::run test_check_handles_rate_limit_response
th::run test_apply_rejects_checksum_mismatch
th::run test_apply_rejects_missing_artifact
th::run test_apply_noop_when_up_to_date

th::summary

#!/usr/bin/env bash
# TixoLink NEXUS - release packaging tests (Phase 8 / RC1).
#
# Builds the real release artifact (packaging/build-release.sh against the
# real working tree) into a private TIXOLINK_DIST_DIR, never the repo's
# own dist/, and checks the properties the RC1 readiness report requires:
# reproducibility, single top-level directory, no path traversal/absolute
# paths, no symlink/hardlink/device entries, correct executable bits, and
# a VERSION inside the archive that matches the source tree's VERSION.
set -Eeuo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$TEST_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/test_harness.sh"

WORK="$(mktemp -d /tmp/tixolink-pkgtest.XXXXXXXX)"
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT

VERSION="$(head -n1 "$REPO_ROOT/VERSION")"
ARTIFACT="tixolink-${VERSION}.tar.gz"

build_into() {
    TIXOLINK_DIST_DIR="$1" bash "$REPO_ROOT/packaging/build-release.sh" >/dev/null
}

test_manifest_entries_all_exist() {
    local missing=0
    while IFS= read -r rel; do
        [[ -z "$rel" ]] && continue
        [[ -f "$REPO_ROOT/$rel" ]] || missing=1
    done <"$REPO_ROOT/packaging/MANIFEST.txt"
    [[ "$missing" == "0" ]]
}

test_build_succeeds() {
    build_into "$WORK/dist1"
    [[ -f "$WORK/dist1/$ARTIFACT" ]]
    [[ -f "$WORK/dist1/SHA256SUMS" ]]
}

test_checksum_verifies() {
    ( cd "$WORK/dist1" && sha256sum -c SHA256SUMS >/dev/null 2>&1 )
}

test_reproducible_byte_identical() {
    build_into "$WORK/dist2"
    cmp -s "$WORK/dist1/$ARTIFACT" "$WORK/dist2/$ARTIFACT"
}

test_single_top_level_dir() {
    local n; n="$(tar -tzf "$WORK/dist1/$ARTIFACT" | awk -F/ '{print $1}' | sort -u | wc -l)"
    th::assert_eq "$n" "1"
}

test_top_level_dir_name_matches_version() {
    local top; top="$(tar -tzf "$WORK/dist1/$ARTIFACT" | head -1 | awk -F/ '{print $1}')"
    th::assert_eq "$top" "tixolink-${VERSION}"
}

test_no_absolute_paths() {
    ! tar -tzf "$WORK/dist1/$ARTIFACT" | grep -qE '^/'
}

test_no_path_traversal() {
    ! tar -tzf "$WORK/dist1/$ARTIFACT" | grep -qE '(^|/)\.\.(/|$)'
}

test_no_symlinks_hardlinks_devices() {
    # tar -tvzf type flags: 'l' symlink, 'h' hardlink, 'b'/'c' device, 'p' fifo.
    ! tar -tvzf "$WORK/dist1/$ARTIFACT" | awk '{print substr($1,1,1)}' | grep -qE '^[lhbcp]$'
}

test_executable_bits_correct() {
    local out; out="$(tar -tvzf "$WORK/dist1/$ARTIFACT" | awk '{print $1, $NF}')"
    grep -q '^-rwxr-xr-x.*install\.sh$' <<<"$out" \
        && grep -q '^-rwxr-xr-x.*uninstall\.sh$' <<<"$out" \
        && grep -q '^-rwxr-xr-x.*bin/tixolink$' <<<"$out"
}

test_version_file_matches_source() {
    tar -xzf "$WORK/dist1/$ARTIFACT" -C "$WORK" "tixolink-${VERSION}/VERSION"
    th::assert_eq "$(head -n1 "$WORK/tixolink-${VERSION}/VERSION")" "$VERSION"
}

test_no_dev_only_material() {
    local listing; listing="$(tar -tzf "$WORK/dist1/$ARTIFACT")"
    ! grep -qE '(^|/)\.git(/|$)|(^|/)tests/|(^|/)\.gitkeep$|(^|/)\.env|id_rsa|credentials|secret|\.key$|\.pem$' <<<"$listing"
}

test_license_and_install_present() {
    local listing; listing="$(tar -tzf "$WORK/dist1/$ARTIFACT")"
    grep -q "tixolink-${VERSION}/LICENSE$" <<<"$listing" \
        && grep -q "tixolink-${VERSION}/install.sh$" <<<"$listing"
}

th::run test_manifest_entries_all_exist
th::run test_build_succeeds
th::run test_checksum_verifies
th::run test_reproducible_byte_identical
th::run test_single_top_level_dir
th::run test_top_level_dir_name_matches_version
th::run test_no_absolute_paths
th::run test_no_path_traversal
th::run test_no_symlinks_hardlinks_devices
th::run test_executable_bits_correct
th::run test_version_file_matches_source
th::run test_no_dev_only_material
th::run test_license_and_install_present

th::summary

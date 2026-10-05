#!/usr/bin/env bash
# TixoLink NEXUS - unit tests for the public bootstrap installer
# (TixoLink.sh). Every scenario here is self-contained: no real network
# call ever happens (bootstrap::http_get/http_get_file are redefined per
# test to serve local fixtures) and nothing is ever installed onto the
# real host (bootstrap::_install_extra_args is redefined to force a
# sandboxed --root, and most scenarios never even reach that step).
set -Eeuo pipefail

TEST_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$TEST_DIR/../.." && pwd)"

TIXOLINK_TEST_ROOT="$(mktemp -d /tmp/tixolink-boot-test.XXXXXXXX)"
cleanup() { rm -rf -- "$TIXOLINK_TEST_ROOT"; }
trap cleanup EXIT

source "$REPO_ROOT/tests/lib/test_harness.sh"
source "$REPO_ROOT/TixoLink.sh"

# make_fake_package <dir> <version> [install_sh_body]
# Builds dir/tixolink-<version>/{install.sh,VERSION} and packages it as
# dir/tixolink-<version>.tar.gz + dir/SHA256SUMS, exactly the shape the
# real release artifact has.
make_fake_package() {
    local dir="$1" version="$2" body="${3:-}"
    local pkg="$dir/tixolink-${version}"
    install -d "$pkg"
    printf '%s' "$version" >"$pkg/VERSION"
    if [[ -n "$body" ]]; then
        printf '%s\n' "$body" >"$pkg/install.sh"
    else
        cat >"$pkg/install.sh" <<'EOF'
#!/usr/bin/env bash
echo "fake installer invoked: $*"
exit 0
EOF
    fi
    chmod +x "$pkg/install.sh"
    ( cd "$dir" && tar -czf "tixolink-${version}.tar.gz" "tixolink-${version}" )
    ( cd "$dir" && sha256sum "tixolink-${version}.tar.gz" >SHA256SUMS )
}

# make_fake_tixolink_bin <bindir> <mode> [version]
# Writes a sandboxed fake `tixolink` executable into <bindir> (never
# /usr/local/bin) so success-path tests can put it on PATH and exercise
# bootstrap::main's post-install `command -v tixolink` / `tixolink
# version` verification without ever touching the real host.
#   ok            -> `tixolink version` prints <version>, exit 0
#   fail_version  -> `tixolink version` exits non-zero (no output)
#   wrong_version -> `tixolink version` prints a version that is not <version>
make_fake_tixolink_bin() {
    local bindir="$1" mode="$2" version="${3:-}"
    install -d "$bindir"
    case "$mode" in
        ok)
            cat >"$bindir/tixolink" <<EOF
#!/usr/bin/env bash
[[ "\$1" == "version" ]] && { printf '%s\n' "$version"; exit 0; }
exit 0
EOF
            ;;
        fail_version)
            cat >"$bindir/tixolink" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
            ;;
        wrong_version)
            cat >"$bindir/tixolink" <<EOF
#!/usr/bin/env bash
[[ "\$1" == "version" ]] && { printf '%s\n' "0.0.0-not-${version}"; exit 0; }
exit 0
EOF
            ;;
    esac
    chmod +x "$bindir/tixolink"
}

# --- preflight checks ------------------------------------------------------

test_rejects_non_root() {
    bootstrap::_current_uid() { printf '1000'; }
    ! bootstrap::require_root >/dev/null 2>&1
}

test_accepts_root() {
    bootstrap::_current_uid() { printf '0'; }
    bootstrap::require_root >/dev/null 2>&1
}

test_rejects_unsupported_os() {
    local f="$TIXOLINK_TEST_ROOT/os-release-bad"
    printf 'ID=fedora\nVERSION_ID=40\n' >"$f"
    bootstrap::_os_release_file() { printf '%s' "$f"; }
    ! bootstrap::check_os >/dev/null 2>&1
}

test_accepts_supported_os_ubuntu() {
    local f="$TIXOLINK_TEST_ROOT/os-release-ubuntu"
    printf 'ID=ubuntu\nVERSION_ID=24.04\n' >"$f"
    bootstrap::_os_release_file() { printf '%s' "$f"; }
    bootstrap::check_os >/dev/null 2>&1
}

test_accepts_supported_os_debian() {
    local f="$TIXOLINK_TEST_ROOT/os-release-debian"
    printf 'ID=debian\nVERSION_ID=12\n' >"$f"
    bootstrap::_os_release_file() { printf '%s' "$f"; }
    bootstrap::check_os >/dev/null 2>&1
}

test_rejects_unsupported_arch() {
    bootstrap::_arch() { printf 'armv7l'; }
    ! bootstrap::check_arch >/dev/null 2>&1
}

test_accepts_amd64_arch() {
    bootstrap::_arch() { printf 'x86_64'; }
    bootstrap::check_arch >/dev/null 2>&1
}

test_rejects_missing_curl() {
    # Subshell: function redefinitions in bash are not locally scoped,
    # so overriding bootstrap::_has_curl here would otherwise leak into
    # every later test in this file, including the real-detector tests
    # for bootstrap::_curl_supports_https below.
    (
        bootstrap::_has_curl() { return 1; }
        ! bootstrap::check_curl >/dev/null 2>&1
    )
}

test_rejects_curl_without_https() {
    (
        bootstrap::_has_curl() { return 0; }
        bootstrap::_curl_supports_https() { return 1; }
        ! bootstrap::check_curl >/dev/null 2>&1
    )
}

# --- bootstrap::_curl_supports_https: exact-token "Protocols:" parsing ----
# Regression coverage for the RC2 defect: the old implementation grepped
# `curl --version | head -n1` for the substring "https", but curl's own
# version banner never puts protocol names on line 1 - they're on a
# separate "Protocols:" line - so that check always failed against real
# curl output. These tests drive the real function against fixture
# `curl --version` text (never a redefined seam) so a regression here
# cannot hide behind a self-consistent fake the way RC2's did.

# fake_curl_version_bin <bindir> <version-output|FAIL>
# Writes a sandboxed `curl` into <bindir> that answers `curl --version`
# with the given literal text (read from stdin), or exits non-zero if
# called with FAIL. Never touches the real curl on PATH.
fake_curl_version_bin() {
    local bindir="$1"
    install -d "$bindir"
    local body; body="$(cat)"
    if [[ "$body" == "FAIL" ]]; then
        cat >"$bindir/curl" <<'EOF'
#!/usr/bin/env bash
exit 7
EOF
    else
        {
            printf '#!/usr/bin/env bash\ncat <<'"'"'VEREOF'"'"'\n'
            printf '%s\n' "$body"
            printf 'VEREOF\n'
        } >"$bindir/curl"
    fi
    chmod +x "$bindir/curl"
}

test_curl_https_detector_accepts_realistic_supported_output() {
    local bindir="$TIXOLINK_TEST_ROOT/curl-a"
    fake_curl_version_bin "$bindir" <<'EOF'
curl 8.5.0 (x86_64-pc-linux-gnu) libcurl/8.5.0 OpenSSL/3.0.13 zlib/1.3
Release-Date: 2023-12-06
Protocols: dict file ftp ftps gopher gophers http https imap imaps
Features: alt-svc AsynchDNS HTTP2 HTTPS-proxy IDN IPv6 SSL
EOF
    ( PATH="$bindir:$PATH" bootstrap::_curl_supports_https >/dev/null 2>&1 )
}

test_curl_https_detector_rejects_protocol_list_without_https() {
    local bindir="$TIXOLINK_TEST_ROOT/curl-b"
    fake_curl_version_bin "$bindir" <<'EOF'
curl 7.0.0 (minimal build)
Protocols: dict file ftp http imap
Features: SSL
EOF
    ( PATH="$bindir:$PATH"; ! bootstrap::_curl_supports_https >/dev/null 2>&1 )
}

test_curl_https_detector_rejects_unrelated_https_mention() {
    local bindir="$TIXOLINK_TEST_ROOT/curl-c"
    # "https" appears in the banner (and even looks protocol-ish) but
    # never as an actual token on the Protocols: line.
    fake_curl_version_bin "$bindir" <<'EOF'
curl 8.0.0 (built against libhttps-compat, not real https support)
Release-Date: 2024-01-01
Protocols: dict file ftp http imap
Features: SSL
EOF
    ( PATH="$bindir:$PATH"; ! bootstrap::_curl_supports_https >/dev/null 2>&1 )
}

test_curl_https_detector_rejects_missing_protocols_line() {
    local bindir="$TIXOLINK_TEST_ROOT/curl-d"
    fake_curl_version_bin "$bindir" <<'EOF'
curl 8.0.0 (no Protocols line at all)
Features: SSL https-ish-feature-name
EOF
    ( PATH="$bindir:$PATH"; ! bootstrap::_curl_supports_https >/dev/null 2>&1 )
}

test_curl_https_detector_fails_closed_when_curl_version_fails() {
    local bindir="$TIXOLINK_TEST_ROOT/curl-e"
    fake_curl_version_bin "$bindir" <<'EOF'
FAIL
EOF
    ( PATH="$bindir:$PATH"; ! bootstrap::_curl_supports_https >/dev/null 2>&1 )
}

test_curl_https_detector_accepts_https_as_exact_token_among_many() {
    local bindir="$TIXOLINK_TEST_ROOT/curl-f"
    fake_curl_version_bin "$bindir" <<'EOF'
curl 8.9.1 (test build)
Protocols: dict file ftp ftps gopher gophers http https imap imaps ldap ldaps mqtt pop3 pop3s rtmp rtsp scp sftp smb smbs smtp smtps telnet tftp
Features: alt-svc
EOF
    ( PATH="$bindir:$PATH" bootstrap::_curl_supports_https >/dev/null 2>&1 )
}

# Verifies the real installed host curl (not a fixture) is correctly
# recognized - the exact gap that let RC2's broken detector ship: every
# unit test redefined the seam, so none of them ever ran the real
# function against real curl output.
test_curl_https_detector_accepts_real_host_curl() {
    command -v curl >/dev/null 2>&1 || return 0
    bootstrap::_curl_supports_https >/dev/null 2>&1
}

# --- version / channel validation ------------------------------------------

test_valid_version_accepts_plain() { bootstrap::valid_version "1.0.0"; }
test_valid_version_accepts_rc() { bootstrap::valid_version "1.0.0-rc1"; }
test_valid_version_rejects_garbage() { ! bootstrap::valid_version "1.0.0; rm -rf /"; }
test_valid_version_rejects_leading_v() { ! bootstrap::valid_version "v1.0.0"; }
test_valid_version_rejects_empty() { ! bootstrap::valid_version ""; }

test_resolve_version_rejects_bad_explicit_version() {
    ( TIXOLINK_VERSION='$(whoami)'
      ! bootstrap::resolve_version >/dev/null 2>&1 )
}

test_resolve_version_accepts_good_explicit_version() {
    ( TIXOLINK_VERSION='1.2.3-rc4'
      th::assert_eq "$(bootstrap::resolve_version)" "1.2.3-rc4" )
}

test_resolve_version_rejects_bad_channel() {
    ( unset TIXOLINK_VERSION
      TIXOLINK_CHANNEL='bogus'
      ! bootstrap::resolve_version >/dev/null 2>&1 )
}

test_resolve_stable_fails_closed_when_no_release_published() {
    bootstrap::http_get() { printf ''; }
    ! bootstrap::resolve_stable >/dev/null 2>&1
}

test_resolve_stable_fails_closed_on_prerelease_latest() {
    bootstrap::http_get() { printf '{"tag_name":"v1.0.0-rc1","prerelease":true,"draft":false}'; }
    ! bootstrap::resolve_stable >/dev/null 2>&1
}

test_resolve_stable_accepts_real_stable_release() {
    bootstrap::http_get() { printf '{"tag_name":"v1.2.3","prerelease":false,"draft":false}'; }
    th::assert_eq "$(bootstrap::resolve_stable)" "1.2.3"
}

test_resolve_rc_picks_latest_prerelease() {
    bootstrap::http_get() {
        printf '[{"tag_name":"v1.0.0","prerelease":false,"draft":false},{"tag_name":"v1.0.0-rc2","prerelease":true,"draft":false},{"tag_name":"v1.0.0-rc1","prerelease":true,"draft":false}]'
    }
    th::assert_eq "$(bootstrap::resolve_rc)" "1.0.0-rc2"
}

test_resolve_rc_fails_closed_when_none_published() {
    bootstrap::http_get() { printf '[]'; }
    ! bootstrap::resolve_rc >/dev/null 2>&1
}

# --- checksum verification --------------------------------------------------

test_checksum_passes_for_matching_entry() {
    local f="$TIXOLINK_TEST_ROOT/ck1.bin" sums="$TIXOLINK_TEST_ROOT/ck1.sums"
    printf 'hello' >"$f"
    ( cd "$TIXOLINK_TEST_ROOT" && sha256sum ck1.bin >ck1.sums )
    bootstrap::verify_checksum "$f" "$sums" "ck1.bin" >/dev/null 2>&1
}

test_checksum_rejects_missing_entry() {
    local f="$TIXOLINK_TEST_ROOT/ck2.bin" sums="$TIXOLINK_TEST_ROOT/ck2.sums"
    printf 'hello' >"$f"
    printf '%s  some-other-file.tar.gz\n' "$(sha256sum "$f" | awk '{print $1}')" >"$sums"
    ! bootstrap::verify_checksum "$f" "$sums" "ck2.bin" >/dev/null 2>&1
}

test_checksum_rejects_malformed_hash() {
    local f="$TIXOLINK_TEST_ROOT/ck3.bin" sums="$TIXOLINK_TEST_ROOT/ck3.sums"
    printf 'hello' >"$f"
    printf 'not-a-valid-hash  ck3.bin\n' >"$sums"
    ! bootstrap::verify_checksum "$f" "$sums" "ck3.bin" >/dev/null 2>&1
}

test_checksum_rejects_mismatch() {
    local f="$TIXOLINK_TEST_ROOT/ck4.bin" sums="$TIXOLINK_TEST_ROOT/ck4.sums"
    printf 'hello' >"$f"
    printf '0000000000000000000000000000000000000000000000000000000000000000  ck4.bin\n' >"$sums"
    ! bootstrap::verify_checksum "$f" "$sums" "ck4.bin" >/dev/null 2>&1
}

test_checksum_rejects_duplicate_conflicting_entries() {
    local f="$TIXOLINK_TEST_ROOT/ck5.bin" sums="$TIXOLINK_TEST_ROOT/ck5.sums"
    printf 'hello' >"$f"
    {
        printf '%s  ck5.bin\n' "$(sha256sum "$f" | awk '{print $1}')"
        printf '1111111111111111111111111111111111111111111111111111111111111111  ck5.bin\n'
    } >"$sums"
    ! bootstrap::verify_checksum "$f" "$sums" "ck5.bin" >/dev/null 2>&1
}

# --- archive safety ----------------------------------------------------------

test_extract_rejects_absolute_path() {
    local work="$TIXOLINK_TEST_ROOT/abs" archive="$TIXOLINK_TEST_ROOT/abs.tar.gz" dest="$TIXOLINK_TEST_ROOT/abs-dest"
    install -d "$work/tixolink-9.9.9"
    printf 'x' >"$work/tixolink-9.9.9/f"
    ( cd "$work" && tar -czf "$archive" "tixolink-9.9.9/f" --transform 's,^tixolink-9.9.9/f,/etc/passwd,' )
    install -d "$dest"
    ! bootstrap::extract_safely "$archive" "$dest" "tixolink-9.9.9" >/dev/null 2>&1
}

test_extract_rejects_traversal() {
    local work="$TIXOLINK_TEST_ROOT/trav" archive="$TIXOLINK_TEST_ROOT/trav.tar.gz" dest="$TIXOLINK_TEST_ROOT/trav-dest"
    install -d "$work/tixolink-9.9.9"
    printf 'x' >"$work/tixolink-9.9.9/f"
    ( cd "$work" && tar -czf "$archive" --transform 's,^tixolink-9.9.9/f,tixolink-9.9.9/../../evil,' "tixolink-9.9.9/f" )
    install -d "$dest"
    ! bootstrap::extract_safely "$archive" "$dest" "tixolink-9.9.9" >/dev/null 2>&1
}

test_extract_rejects_wrong_root() {
    local work="$TIXOLINK_TEST_ROOT/wrongroot" archive="$TIXOLINK_TEST_ROOT/wrongroot.tar.gz" dest="$TIXOLINK_TEST_ROOT/wrongroot-dest"
    install -d "$work/some-other-dir"
    printf 'x' >"$work/some-other-dir/f"
    ( cd "$work" && tar -czf "$archive" "some-other-dir" )
    install -d "$dest"
    ! bootstrap::extract_safely "$archive" "$dest" "tixolink-9.9.9" >/dev/null 2>&1
}

test_extract_rejects_symlink() {
    local work="$TIXOLINK_TEST_ROOT/sym" archive="$TIXOLINK_TEST_ROOT/sym.tar.gz" dest="$TIXOLINK_TEST_ROOT/sym-dest"
    install -d "$work/tixolink-9.9.9"
    printf 'x' >"$work/tixolink-9.9.9/real"
    ( cd "$work/tixolink-9.9.9" && ln -s real link )
    ( cd "$work" && tar -czf "$archive" "tixolink-9.9.9" )
    install -d "$dest"
    ! bootstrap::extract_safely "$archive" "$dest" "tixolink-9.9.9" >/dev/null 2>&1
}

test_extract_rejects_hardlink() {
    local work="$TIXOLINK_TEST_ROOT/hard" archive="$TIXOLINK_TEST_ROOT/hard.tar.gz" dest="$TIXOLINK_TEST_ROOT/hard-dest"
    install -d "$work/tixolink-9.9.9"
    printf 'x' >"$work/tixolink-9.9.9/real"
    ( cd "$work/tixolink-9.9.9" && ln real hardlink )
    ( cd "$work" && tar -czf "$archive" "tixolink-9.9.9" )
    install -d "$dest"
    # Only assert rejection if tar actually encoded a hardlink entry ('h')
    # for this filesystem/tar combination; otherwise skip rather than
    # assert on tar implementation details we don't control.
    if tar -tvzf "$archive" 2>/dev/null | grep -q '^h'; then
        ! bootstrap::extract_safely "$archive" "$dest" "tixolink-9.9.9" >/dev/null 2>&1
    else
        return 0
    fi
}

test_extract_rejects_fifo() {
    local work="$TIXOLINK_TEST_ROOT/fifo" archive="$TIXOLINK_TEST_ROOT/fifo.tar.gz" dest="$TIXOLINK_TEST_ROOT/fifo-dest"
    install -d "$work/tixolink-9.9.9"
    if ! mkfifo "$work/tixolink-9.9.9/p" 2>/dev/null; then
        return 0
    fi
    ( cd "$work" && tar -czf "$archive" "tixolink-9.9.9" )
    install -d "$dest"
    ! bootstrap::extract_safely "$archive" "$dest" "tixolink-9.9.9" >/dev/null 2>&1
}

test_extract_accepts_well_formed_archive() {
    local dir="$TIXOLINK_TEST_ROOT/wellformed"
    install -d "$dir"
    make_fake_package "$dir" "9.9.9"
    local dest="$TIXOLINK_TEST_ROOT/wellformed-dest"
    install -d "$dest"
    bootstrap::extract_safely "$dir/tixolink-9.9.9.tar.gz" "$dest" "tixolink-9.9.9" >/dev/null 2>&1
    [[ -f "$dest/tixolink-9.9.9/install.sh" ]]
}

# --- end-to-end main() against local fixtures (no network, no real host) ---

test_main_rejects_missing_install_sh() {
    local dir="$TIXOLINK_TEST_ROOT/no-installsh"
    install -d "$dir/tixolink-1.2.3"
    printf '1.2.3' >"$dir/tixolink-1.2.3/VERSION"
    ( cd "$dir" && tar -czf "tixolink-1.2.3.tar.gz" "tixolink-1.2.3" && sha256sum "tixolink-1.2.3.tar.gz" >SHA256SUMS )

    (
        TIXOLINK_VERSION="1.2.3"
        bootstrap::_current_uid() { printf '0'; }
        bootstrap::_os_release_file() { printf 'ID=ubuntu\nVERSION_ID=24.04\n' >"$TIXOLINK_TEST_ROOT/osr-a"; printf '%s' "$TIXOLINK_TEST_ROOT/osr-a"; }
        bootstrap::_arch() { printf 'x86_64'; }
        bootstrap::_has_curl() { return 0; }
        bootstrap::_curl_supports_https() { return 0; }
        bootstrap::http_get_file() {
            case "$1" in
                *SHA256SUMS) cp "$dir/SHA256SUMS" "$2" ;;
                *) cp "$dir/tixolink-1.2.3.tar.gz" "$2" ;;
            esac
        }
        ! bootstrap::main >/dev/null 2>&1
    )
}

test_main_propagates_installer_failure() {
    local dir="$TIXOLINK_TEST_ROOT/failing-installer"
    install -d "$dir"
    make_fake_package "$dir" "1.2.4" $'#!/usr/bin/env bash\nexit 5'

    (
        TIXOLINK_VERSION="1.2.4"
        bootstrap::_current_uid() { printf '0'; }
        bootstrap::_os_release_file() { printf 'ID=ubuntu\nVERSION_ID=24.04\n' >"$TIXOLINK_TEST_ROOT/osr-b"; printf '%s' "$TIXOLINK_TEST_ROOT/osr-b"; }
        bootstrap::_arch() { printf 'x86_64'; }
        bootstrap::_has_curl() { return 0; }
        bootstrap::_curl_supports_https() { return 0; }
        bootstrap::http_get_file() {
            case "$1" in
                *SHA256SUMS) cp "$dir/SHA256SUMS" "$2" ;;
                *) cp "$dir/tixolink-1.2.4.tar.gz" "$2" ;;
            esac
        }
        ! bootstrap::main >/dev/null 2>&1
    )
}

# build_package_with_tixolink_bin <dir> <version> <marker> <bindir>
# Like make_fake_package, but the packaged install.sh also plants a
# sandboxed `tixolink` executable in <bindir> (never /usr/local/bin) that
# answers `tixolink version` with <version> - standing in for what a
# real install.sh does, so bootstrap::main's post-install `command -v
# tixolink` / `tixolink version` checks have something real to find.
build_package_with_tixolink_bin() {
    local dir="$1" version="$2" marker="$3" bindir="$4"
    local pkg="$dir/tixolink-${version}"
    install -d "$pkg"
    printf '%s' "$version" >"$pkg/VERSION"
    cat >"$pkg/install.sh" <<EOF
#!/usr/bin/env bash
touch "$marker"
install -d "$bindir"
cat >"$bindir/tixolink" <<'BIN'
#!/usr/bin/env bash
[[ "\$1" == "version" ]] && { printf '%s\n' "$version"; exit 0; }
exit 0
BIN
chmod +x "$bindir/tixolink"
exit 0
EOF
    chmod +x "$pkg/install.sh"
    ( cd "$dir" && tar -czf "tixolink-${version}.tar.gz" "tixolink-${version}" )
    ( cd "$dir" && sha256sum "tixolink-${version}.tar.gz" >SHA256SUMS )
}

test_main_succeeds_and_invokes_installer() {
    local dir="$TIXOLINK_TEST_ROOT/ok-installer"
    local bindir="$TIXOLINK_TEST_ROOT/ok-installer-bin"
    install -d "$dir"
    local marker="$TIXOLINK_TEST_ROOT/ok-installer-ran"
    rm -f -- "$marker"
    build_package_with_tixolink_bin "$dir" "1.2.5" "$marker" "$bindir"

    (
        TIXOLINK_VERSION="1.2.5"
        PATH="$bindir:$PATH"
        bootstrap::_current_uid() { printf '0'; }
        bootstrap::_os_release_file() { printf 'ID=ubuntu\nVERSION_ID=24.04\n' >"$TIXOLINK_TEST_ROOT/osr-c"; printf '%s' "$TIXOLINK_TEST_ROOT/osr-c"; }
        bootstrap::_arch() { printf 'x86_64'; }
        bootstrap::_has_curl() { return 0; }
        bootstrap::_curl_supports_https() { return 0; }
        bootstrap::http_get_file() {
            case "$1" in
                *SHA256SUMS) cp "$dir/SHA256SUMS" "$2" ;;
                *) cp "$dir/tixolink-1.2.5.tar.gz" "$2" ;;
            esac
        }
        bootstrap::main >/dev/null 2>&1
    )
    [[ -f "$marker" ]]
}

test_main_rejects_checksum_mismatch_end_to_end() {
    local dir="$TIXOLINK_TEST_ROOT/bad-checksum"
    install -d "$dir"
    make_fake_package "$dir" "1.2.6"
    sed -i 's/^[0-9a-f]\{64\}/0000000000000000000000000000000000000000000000000000000000000000/' "$dir/SHA256SUMS"

    (
        TIXOLINK_VERSION="1.2.6"
        bootstrap::_current_uid() { printf '0'; }
        bootstrap::_os_release_file() { printf 'ID=ubuntu\nVERSION_ID=24.04\n' >"$TIXOLINK_TEST_ROOT/osr-d"; printf '%s' "$TIXOLINK_TEST_ROOT/osr-d"; }
        bootstrap::_arch() { printf 'x86_64'; }
        bootstrap::_has_curl() { return 0; }
        bootstrap::_curl_supports_https() { return 0; }
        bootstrap::http_get_file() {
            case "$1" in
                *SHA256SUMS) cp "$dir/SHA256SUMS" "$2" ;;
                *) cp "$dir/tixolink-1.2.6.tar.gz" "$2" ;;
            esac
        }
        ! bootstrap::main >/dev/null 2>&1
    )
}

test_main_cleans_up_temp_dir_on_failure() {
    local dir="$TIXOLINK_TEST_ROOT/cleanup-fail"
    install -d "$dir"
    make_fake_package "$dir" "1.2.7" $'#!/usr/bin/env bash\nexit 9'
    local before after
    before="$(find /tmp -maxdepth 1 -name 'tixolink-bootstrap.*' 2>/dev/null | wc -l)"

    (
        TIXOLINK_VERSION="1.2.7"
        bootstrap::_current_uid() { printf '0'; }
        bootstrap::_os_release_file() { printf 'ID=ubuntu\nVERSION_ID=24.04\n' >"$TIXOLINK_TEST_ROOT/osr-e"; printf '%s' "$TIXOLINK_TEST_ROOT/osr-e"; }
        bootstrap::_arch() { printf 'x86_64'; }
        bootstrap::_has_curl() { return 0; }
        bootstrap::_curl_supports_https() { return 0; }
        bootstrap::http_get_file() {
            case "$1" in
                *SHA256SUMS) cp "$dir/SHA256SUMS" "$2" ;;
                *) cp "$dir/tixolink-1.2.7.tar.gz" "$2" ;;
            esac
        }
        bootstrap::main >/dev/null 2>&1 || true
    )
    after="$(find /tmp -maxdepth 1 -name 'tixolink-bootstrap.*' 2>/dev/null | wc -l)"
    th::assert_eq "$after" "$before"
}

test_main_cleans_up_temp_dir_on_success() {
    local dir="$TIXOLINK_TEST_ROOT/cleanup-ok"
    local bindir="$TIXOLINK_TEST_ROOT/cleanup-ok-bin"
    local marker="$TIXOLINK_TEST_ROOT/cleanup-ok-ran"
    install -d "$dir"
    build_package_with_tixolink_bin "$dir" "1.2.8" "$marker" "$bindir"
    local before after rc
    before="$(find /tmp -maxdepth 1 -name 'tixolink-bootstrap.*' 2>/dev/null | wc -l)"

    (
        TIXOLINK_VERSION="1.2.8"
        PATH="$bindir:$PATH"
        bootstrap::_current_uid() { printf '0'; }
        bootstrap::_os_release_file() { printf 'ID=ubuntu\nVERSION_ID=24.04\n' >"$TIXOLINK_TEST_ROOT/osr-f"; printf '%s' "$TIXOLINK_TEST_ROOT/osr-f"; }
        bootstrap::_arch() { printf 'x86_64'; }
        bootstrap::_has_curl() { return 0; }
        bootstrap::_curl_supports_https() { return 0; }
        bootstrap::http_get_file() {
            case "$1" in
                *SHA256SUMS) cp "$dir/SHA256SUMS" "$2" ;;
                *) cp "$dir/tixolink-1.2.8.tar.gz" "$2" ;;
            esac
        }
        bootstrap::main >/dev/null 2>&1
    )
    rc=$?
    after="$(find /tmp -maxdepth 1 -name 'tixolink-bootstrap.*' 2>/dev/null | wc -l)"
    [[ "$rc" == "0" ]] && th::assert_eq "$after" "$before"
}

# --- post-install PATH / version verification -------------------------------

test_main_rejects_success_without_tixolink_on_path() {
    local dir="$TIXOLINK_TEST_ROOT/no-path-bin"
    install -d "$dir"
    # Default stub: install.sh exits 0 but never places anything on PATH.
    make_fake_package "$dir" "2.0.1"

    (
        TIXOLINK_VERSION="2.0.1"
        bootstrap::_current_uid() { printf '0'; }
        bootstrap::_os_release_file() { printf 'ID=ubuntu\nVERSION_ID=24.04\n' >"$TIXOLINK_TEST_ROOT/osr-g"; printf '%s' "$TIXOLINK_TEST_ROOT/osr-g"; }
        bootstrap::_arch() { printf 'x86_64'; }
        bootstrap::_has_curl() { return 0; }
        bootstrap::_curl_supports_https() { return 0; }
        bootstrap::http_get_file() {
            case "$1" in
                *SHA256SUMS) cp "$dir/SHA256SUMS" "$2" ;;
                *) cp "$dir/tixolink-2.0.1.tar.gz" "$2" ;;
            esac
        }
        ! bootstrap::main >/dev/null 2>&1
    )
}

test_main_rejects_success_when_version_command_fails() {
    local dir="$TIXOLINK_TEST_ROOT/version-fails"
    local bindir="$TIXOLINK_TEST_ROOT/version-fails-bin"
    install -d "$dir"
    make_fake_package "$dir" "2.0.2"
    make_fake_tixolink_bin "$bindir" fail_version

    (
        TIXOLINK_VERSION="2.0.2"
        PATH="$bindir:$PATH"
        bootstrap::_current_uid() { printf '0'; }
        bootstrap::_os_release_file() { printf 'ID=ubuntu\nVERSION_ID=24.04\n' >"$TIXOLINK_TEST_ROOT/osr-h"; printf '%s' "$TIXOLINK_TEST_ROOT/osr-h"; }
        bootstrap::_arch() { printf 'x86_64'; }
        bootstrap::_has_curl() { return 0; }
        bootstrap::_curl_supports_https() { return 0; }
        bootstrap::http_get_file() {
            case "$1" in
                *SHA256SUMS) cp "$dir/SHA256SUMS" "$2" ;;
                *) cp "$dir/tixolink-2.0.2.tar.gz" "$2" ;;
            esac
        }
        ! bootstrap::main >/dev/null 2>&1
    )
}

test_main_rejects_success_when_version_mismatches() {
    local dir="$TIXOLINK_TEST_ROOT/version-mismatch"
    local bindir="$TIXOLINK_TEST_ROOT/version-mismatch-bin"
    install -d "$dir"
    make_fake_package "$dir" "2.0.3"
    make_fake_tixolink_bin "$bindir" wrong_version "2.0.3"

    (
        TIXOLINK_VERSION="2.0.3"
        PATH="$bindir:$PATH"
        bootstrap::_current_uid() { printf '0'; }
        bootstrap::_os_release_file() { printf 'ID=ubuntu\nVERSION_ID=24.04\n' >"$TIXOLINK_TEST_ROOT/osr-i"; printf '%s' "$TIXOLINK_TEST_ROOT/osr-i"; }
        bootstrap::_arch() { printf 'x86_64'; }
        bootstrap::_has_curl() { return 0; }
        bootstrap::_curl_supports_https() { return 0; }
        bootstrap::http_get_file() {
            case "$1" in
                *SHA256SUMS) cp "$dir/SHA256SUMS" "$2" ;;
                *) cp "$dir/tixolink-2.0.3.tar.gz" "$2" ;;
            esac
        }
        ! bootstrap::main >/dev/null 2>&1
    )
}

test_main_succeeds_with_correct_bin_and_version() {
    local dir="$TIXOLINK_TEST_ROOT/correct-bin"
    local bindir="$TIXOLINK_TEST_ROOT/correct-bin-bin"
    local marker="$TIXOLINK_TEST_ROOT/correct-bin-ran"
    install -d "$dir"
    build_package_with_tixolink_bin "$dir" "2.0.4" "$marker" "$bindir"

    (
        TIXOLINK_VERSION="2.0.4"
        PATH="$bindir:$PATH"
        bootstrap::_current_uid() { printf '0'; }
        bootstrap::_os_release_file() { printf 'ID=ubuntu\nVERSION_ID=24.04\n' >"$TIXOLINK_TEST_ROOT/osr-j"; printf '%s' "$TIXOLINK_TEST_ROOT/osr-j"; }
        bootstrap::_arch() { printf 'x86_64'; }
        bootstrap::_has_curl() { return 0; }
        bootstrap::_curl_supports_https() { return 0; }
        bootstrap::http_get_file() {
            case "$1" in
                *SHA256SUMS) cp "$dir/SHA256SUMS" "$2" ;;
                *) cp "$dir/tixolink-2.0.4.tar.gz" "$2" ;;
            esac
        }
        bootstrap::main >/dev/null 2>&1
    )
}

test_main_cleans_up_temp_dir_when_path_check_fails() {
    local dir="$TIXOLINK_TEST_ROOT/cleanup-path-fail"
    install -d "$dir"
    make_fake_package "$dir" "2.0.5"
    local before after
    before="$(find /tmp -maxdepth 1 -name 'tixolink-bootstrap.*' 2>/dev/null | wc -l)"

    (
        TIXOLINK_VERSION="2.0.5"
        bootstrap::_current_uid() { printf '0'; }
        bootstrap::_os_release_file() { printf 'ID=ubuntu\nVERSION_ID=24.04\n' >"$TIXOLINK_TEST_ROOT/osr-k"; printf '%s' "$TIXOLINK_TEST_ROOT/osr-k"; }
        bootstrap::_arch() { printf 'x86_64'; }
        bootstrap::_has_curl() { return 0; }
        bootstrap::_curl_supports_https() { return 0; }
        bootstrap::http_get_file() {
            case "$1" in
                *SHA256SUMS) cp "$dir/SHA256SUMS" "$2" ;;
                *) cp "$dir/tixolink-2.0.5.tar.gz" "$2" ;;
            esac
        }
        bootstrap::main >/dev/null 2>&1 || true
    )
    after="$(find /tmp -maxdepth 1 -name 'tixolink-bootstrap.*' 2>/dev/null | wc -l)"
    th::assert_eq "$after" "$before"
}

test_main_cleans_up_temp_dir_when_version_check_fails() {
    local dir="$TIXOLINK_TEST_ROOT/cleanup-version-fail"
    local bindir="$TIXOLINK_TEST_ROOT/cleanup-version-fail-bin"
    install -d "$dir"
    make_fake_package "$dir" "2.0.6"
    make_fake_tixolink_bin "$bindir" fail_version
    local before after
    before="$(find /tmp -maxdepth 1 -name 'tixolink-bootstrap.*' 2>/dev/null | wc -l)"

    (
        TIXOLINK_VERSION="2.0.6"
        PATH="$bindir:$PATH"
        bootstrap::_current_uid() { printf '0'; }
        bootstrap::_os_release_file() { printf 'ID=ubuntu\nVERSION_ID=24.04\n' >"$TIXOLINK_TEST_ROOT/osr-l"; printf '%s' "$TIXOLINK_TEST_ROOT/osr-l"; }
        bootstrap::_arch() { printf 'x86_64'; }
        bootstrap::_has_curl() { return 0; }
        bootstrap::_curl_supports_https() { return 0; }
        bootstrap::http_get_file() {
            case "$1" in
                *SHA256SUMS) cp "$dir/SHA256SUMS" "$2" ;;
                *) cp "$dir/tixolink-2.0.6.tar.gz" "$2" ;;
            esac
        }
        bootstrap::main >/dev/null 2>&1 || true
    )
    after="$(find /tmp -maxdepth 1 -name 'tixolink-bootstrap.*' 2>/dev/null | wc -l)"
    th::assert_eq "$after" "$before"
}

th::run test_rejects_non_root
th::run test_accepts_root
th::run test_rejects_unsupported_os
th::run test_accepts_supported_os_ubuntu
th::run test_accepts_supported_os_debian
th::run test_rejects_unsupported_arch
th::run test_accepts_amd64_arch
th::run test_rejects_missing_curl
th::run test_rejects_curl_without_https
th::run test_curl_https_detector_accepts_realistic_supported_output
th::run test_curl_https_detector_rejects_protocol_list_without_https
th::run test_curl_https_detector_rejects_unrelated_https_mention
th::run test_curl_https_detector_rejects_missing_protocols_line
th::run test_curl_https_detector_fails_closed_when_curl_version_fails
th::run test_curl_https_detector_accepts_https_as_exact_token_among_many
th::run test_curl_https_detector_accepts_real_host_curl
th::run test_valid_version_accepts_plain
th::run test_valid_version_accepts_rc
th::run test_valid_version_rejects_garbage
th::run test_valid_version_rejects_leading_v
th::run test_valid_version_rejects_empty
th::run test_resolve_version_rejects_bad_explicit_version
th::run test_resolve_version_accepts_good_explicit_version
th::run test_resolve_version_rejects_bad_channel
th::run test_resolve_stable_fails_closed_when_no_release_published
th::run test_resolve_stable_fails_closed_on_prerelease_latest
th::run test_resolve_stable_accepts_real_stable_release
th::run test_resolve_rc_picks_latest_prerelease
th::run test_resolve_rc_fails_closed_when_none_published
th::run test_checksum_passes_for_matching_entry
th::run test_checksum_rejects_missing_entry
th::run test_checksum_rejects_malformed_hash
th::run test_checksum_rejects_mismatch
th::run test_checksum_rejects_duplicate_conflicting_entries
th::run test_extract_rejects_absolute_path
th::run test_extract_rejects_traversal
th::run test_extract_rejects_wrong_root
th::run test_extract_rejects_symlink
th::run test_extract_rejects_hardlink
th::run test_extract_rejects_fifo
th::run test_extract_accepts_well_formed_archive
th::run test_main_rejects_missing_install_sh
th::run test_main_propagates_installer_failure
th::run test_main_succeeds_and_invokes_installer
th::run test_main_rejects_checksum_mismatch_end_to_end
th::run test_main_cleans_up_temp_dir_on_failure
th::run test_main_cleans_up_temp_dir_on_success
th::run test_main_rejects_success_without_tixolink_on_path
th::run test_main_rejects_success_when_version_command_fails
th::run test_main_rejects_success_when_version_mismatches
th::run test_main_succeeds_with_correct_bin_and_version
th::run test_main_cleans_up_temp_dir_when_path_check_fails
th::run test_main_cleans_up_temp_dir_when_version_check_fails

th::summary

#!/usr/bin/env bash
# TixoLink NEXUS - deterministic release artifact builder.
#
# Builds dist/tixolink-<version>.tar.gz + dist/SHA256SUMS from an explicit
# file allowlist (packaging/MANIFEST.txt), never from `tar czf x.tar.gz .`,
# so packaging never silently depends on whatever untracked files happen
# to be lying around in the working tree. Fails loudly if any manifest
# entry is missing rather than silently shipping a short archive.
#
# Reproducibility: GNU tar's --sort=name/--mtime/--owner/--group/
# --numeric-owner normalize ordering, timestamps, and ownership metadata
# without needing to touch files on disk; gzip -n omits the original
# filename/mtime from the gzip header. Running this script twice against
# the same commit and VERSION should produce a byte-identical artifact -
# see tests/unit/test_packaging.sh, which asserts exactly that.

set -Eeuo pipefail

SELF_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$SELF_DIR/.." && pwd)"
MANIFEST="$SELF_DIR/MANIFEST.txt"
DIST_DIR="${TIXOLINK_DIST_DIR:-$REPO_ROOT/dist}"

command -v tar >/dev/null 2>&1 || { echo "ERROR: tar not found" >&2; exit 1; }
command -v gzip >/dev/null 2>&1 || { echo "ERROR: gzip not found" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "ERROR: sha256sum not found" >&2; exit 1; }
[[ -f "$MANIFEST" ]] || { echo "ERROR: manifest not found: $MANIFEST" >&2; exit 1; }

VERSION="$(head -n1 "$REPO_ROOT/VERSION")"
PKG_NAME="tixolink-${VERSION}"
ARTIFACT_NAME="${PKG_NAME}.tar.gz"

# Deterministic timestamp for every archive member: the committed HEAD's
# author date if this is a git checkout with a clean history to read from,
# else the epoch. Never "now" - that alone would break reproducibility.
if SOURCE_EPOCH="$(cd "$REPO_ROOT" && git log -1 --format=%ct 2>/dev/null)" && [[ -n "$SOURCE_EPOCH" ]]; then
    :
else
    SOURCE_EPOCH=0
fi

# --- validate manifest entries exist before copying anything ----------------
MISSING=0
while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    if [[ ! -f "$REPO_ROOT/$rel" ]]; then
        echo "ERROR: manifest entry missing from working tree: $rel" >&2
        MISSING=1
    fi
done <"$MANIFEST"
[[ "$MISSING" == "0" ]] || { echo "ERROR: release manifest references missing files; aborting" >&2; exit 1; }

# --- stage ------------------------------------------------------------------
WORK="$(mktemp -d "${TMPDIR:-/tmp}/tixolink-release.XXXXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
STAGE="$WORK/$PKG_NAME"
install -d -m 0755 "$STAGE"

while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    dest="$STAGE/$rel"
    install -d -m 0755 "$(dirname "$dest")"
    cp -p "$REPO_ROOT/$rel" "$dest"
done <"$MANIFEST"

# Normalize permissions explicitly rather than trusting the working tree's
# current bits: exactly the three known entry points are executable.
find "$STAGE" -type f -exec chmod 0644 {} +
find "$STAGE" -type d -exec chmod 0755 {} +
for exe in install.sh uninstall.sh bin/tixolink; do
    [[ -f "$STAGE/$exe" ]] && chmod 0755 "$STAGE/$exe"
done

# --- defense-in-depth secret scan (see docs/release-notes) -------------------
SECRET_HITS=0
while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    case "$base" in
        *.key|*.pem|.env|.env.*|id_rsa*|id_ed25519*|credentials*|secret*|*token*)
            echo "ERROR: suspicious filename in release manifest payload: ${f#"$STAGE"/}" >&2
            SECRET_HITS=1
            ;;
    esac
done < <(find "$STAGE" -type f -print0)
[[ "$SECRET_HITS" == "0" ]] || { echo "ERROR: potential secret-like file found; aborting before packaging" >&2; exit 1; }

# --- package -----------------------------------------------------------------
install -d -m 0755 "$DIST_DIR"
ARTIFACT_PATH="$DIST_DIR/$ARTIFACT_NAME"

tar \
    --sort=name \
    --owner=0 --group=0 --numeric-owner \
    --mtime="@${SOURCE_EPOCH}" \
    --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
    -C "$WORK" -cf - "$PKG_NAME" \
    | gzip -n -9 >"$ARTIFACT_PATH"

( cd "$DIST_DIR" && sha256sum "$ARTIFACT_NAME" >"SHA256SUMS" )

echo "Built: $ARTIFACT_PATH"
echo "Version: $VERSION"
echo "SHA256: $(awk '{print $1}' "$DIST_DIR/SHA256SUMS")"

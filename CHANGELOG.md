# Changelog

All notable changes to this project are documented in this file. Format
loosely follows [Keep a Changelog](https://keepachangelog.com/); versioning
follows [Semantic Versioning](https://semver.org/). Pre-1.0 development
(`0.MINOR.PATCH[-dev]`) allowed breaking changes between `0.x` releases;
`1.0.0-rcN` pre-release tags sort before their corresponding `1.0.0` per
`modules/update.sh:update::_version_compare`.

## [1.0.0-rc3] - RELEASE CANDIDATE

**This is a release candidate, not a declaration of production
stability.** Fixes a release-blocking defect in `TixoLink.sh` discovered
by the real public-bootstrap validation performed after publishing
`1.0.0-rc2`.

### Fixed: bootstrap HTTPS capability detection

`bootstrap::_curl_supports_https` checked for HTTPS support with
`curl --version 2>/dev/null | head -n1 | grep -qi https` - a substring
grep of only curl's *first* version-banner line. Real curl output never
puts protocol names on that line (it's `curl <version> (...)
libcurl/... <ssl-lib> ...`); protocols are listed on a separate
`Protocols:` line further down. The result: this check failed against
every real curl installation tested, including the host used to build
and publish `1.0.0-rc2` itself, so the public one-command installer
(`bash <(curl -fsSL .../TixoLink.sh)`) unconditionally aborted with
`"installed curl has no HTTPS support"` before ever contacting GitHub -
making RC2's flagship feature non-functional in practice. RC2's bootstrap
unit tests all redefined the HTTPS-check seam rather than exercising the
real function against real `curl --version` output, so this defect
passed the full test suite undetected; it was only caught by the final
real (non-fixture) public-bootstrap validation step after RC2's
Git/tag/release publication, before the artifact was exercised against
a live install.

Fixed by replacing the substring grep with an exact-token parse of the
`Protocols:` line (`bootstrap::_curl_supports_https` now requires `https`
as one of that line's space-separated tokens), with new regression tests
that exercise the real function against realistic `curl --version`
fixtures (supported, unsupported, an unrelated "https" substring
elsewhere in the banner, a missing `Protocols:` line, and a failing
`curl --version` invocation) plus a test that runs the real function
against this build host's actual installed curl - closing the exact gap
that let the defect ship. A broader preflight audit (root/OS/arch
detection, `sha256sum`/`tar`/`mktemp`/`awk`/`jq` assumptions, checksum
and archive-listing parsing) against real Ubuntu 22.04/24.04 and Debian
12 command output found no further defects.

RC2's `v1.0.0-rc2` Git tag and GitHub Release remain published and
unmodified, exactly as they shipped with this defect - this is a forward
fix, not a rewrite of RC2's history.

## [1.0.0-rc2] - RELEASE CANDIDATE

**This is a release candidate, not a declaration of production
stability.** Adds the public one-command bootstrap installer and fixes a
release-asset naming defect in the updater discovered while building it.

### Phase 11 — one-command public installer UX

- Added `TixoLink.sh`, a small root-level bootstrap installer for the
  public UX `bash <(curl -fsSL
  https://raw.githubusercontent.com/TheTixoCloud/TixoLink/master/TixoLink.sh)`.
  It checks the host (root, supported OS, amd64, HTTPS-capable curl),
  resolves which GitHub Release to install (`TIXOLINK_CHANNEL=stable`
  default / `rc` / exact `TIXOLINK_VERSION=X.Y.Z[-rcN]`), downloads that
  release's `tixolink-<version>.tar.gz` + `SHA256SUMS`, verifies the
  checksum and the archive's internal structure (absolute paths, `..`
  traversal, wrong top-level directory, symlink/hardlink/device/FIFO
  rejection, and the same per-file/total/entry-count resource limits as
  `common::tar_extract_safely`, reimplemented standalone since that
  library doesn't exist pre-install) before extracting a single byte,
  then delegates to the verified package's own `install.sh --force` -
  the same authoritative lifecycle `modules/update.sh` already delegates
  to. It never runs a second unverified `curl | bash`, never clones the
  repository, and never installs from a working tree. See
  "Public bootstrap installer" in `docs/lifecycle.md`.
- The `stable` channel fails closed (with an explicit message) rather
  than silently installing a prerelease when no stable release is
  published yet - during the `1.0.0-rcN` period, the public one-command
  install is `TIXOLINK_CHANNEL=rc bash TixoLink.sh` or
  `TIXOLINK_VERSION=1.0.0-rc1 bash TixoLink.sh`.
- Added `tests/unit/test_bootstrap.sh` (preflight checks, version/channel
  validation, checksum verification, archive-safety rejections, and
  end-to-end `bootstrap::main` scenarios against local fixtures) and
  `tests/integration/test_bootstrap_sandbox.sh` (fresh install, reinstall,
  upgrade, downgrade refusal, and CLI availability against the real
  `install.sh`/`lib` tree, entirely under a private `TIXOLINK_ROOT`
  sandbox - never the real host filesystem).
- README's Installation section now leads with the one-command bootstrap;
  the manual `git clone` + `./install.sh` path is documented as the
  fully-auditable alternative.
- **Fixed**: `modules/update.sh` selected the release's checksum asset by
  the name `checksums.sha256`, but `packaging/build-release.sh` (and the
  actual published `v1.0.0-rc1` release) names that asset `SHA256SUMS` -
  a mismatch that made every real `tixolink update apply` silently fail
  at asset selection. Discovered while building `TixoLink.sh` against the
  real release layout. Fixed in `update::apply`, `docs/lifecycle.md`, and
  `tests/unit/test_update.sh` (which previously only exercised a
  self-consistent fixture using the wrong name); added
  `test_apply_succeeds_with_real_asset_naming` as a regression test.

## [1.0.0-rc1] - RELEASE CANDIDATE

**This is a release candidate, not a declaration of production
stability.** It is the first build intended as a release artifact rather
than an in-progress development snapshot; it has not yet been exercised
in production, and CLI flags or the on-disk schema may still change
before `1.0.0`. See "RC1 known limitations" below.

### Phase 8 — Release candidate preparation

- `VERSION` bumped `0.6.0-dev` → `1.0.0-rc1`. Application version and
  configuration `schema_version` remain deliberately separate axes (see
  `docs/architecture.md`); this bump does not change any on-disk schema.
- `modules/update.sh:update::_version_compare` (and the standalone,
  deliberately-duplicated `install.sh:install::_vcmp`) now compares a
  pre-release suffix's trailing digit run numerically when both sides
  share the same non-numeric prefix (`rc2` < `rc10`), instead of a plain
  lexical compare that would have ordered `rc10` before `rc2`. Added
  `tests/unit/test_install_vcmp.sh` and an RC-ordering matrix in
  `tests/unit/test_update.sh` covering `0.6.0-dev < 1.0.0-rc1 <
  1.0.0-rc2 < 1.0.0 < 1.0.1` pairwise.
- `lib/cli.sh --help`: removed a stale "lifecycle (install/update/backup)
  commands are not implemented yet" note left over from before Phase 6 —
  those commands are listed earlier in the same help text and have been
  implemented (and tested) since Phase 6.
- Release packaging (`packaging/build-release.sh`): builds a deterministic
  `tixolink-<version>.tar.gz` from an explicit file allowlist
  (`packaging/MANIFEST.txt`) rather than archiving the working tree,
  normalizing file order/ownership/mtimes/permissions for reproducibility,
  and writes a `SHA256SUMS` manifest alongside it. See
  `docs/release-notes/1.0.0-rc1.md` for the RC1 release notes and known
  limitations, and the RC1 readiness report (delivered alongside this
  changelog entry, not committed to the repository) for the full
  install-from-artifact/upgrade-simulation/regression/ShellCheck/security
  results this candidate was validated against.

## Pre-RC1 development history (Phases 1-7, folded into 1.0.0-rc1 above)

This file previously stopped recording changes after the Phase 2
foundation layer, even though Phases 3-5 had since landed. The entries
below catch the record up to the actual repository state as of Phase 6;
nothing in this update changes behavior, only documentation.

### Phase 6 — Lifecycle: install, backup, restore, update, uninstall, factory reset

#### Hardening pass (post-review, pre-commit)

- `lib/common.sh:common::tar_extract_safely` — added bounded archive
  resource limits (compressed size, entry count, per-file size, total
  declared uncompressed size), checked from `tar`'s own metadata before
  any extraction; a size field that doesn't parse as a plain integer is
  rejected, not coerced to zero. Shared by `restore` and `update`;
  applies equally to duplicate-member-path detection (added alongside).
  See `docs/lifecycle.md`'s "Archive resource limits" section.
- `uninstall.sh --backup-output <file>` — lets the automatic pre-purge
  backup target be specified explicitly instead of defaulting to the
  current working directory.
- Restore confirmation/CLI/menu text made explicit that restore rewrites
  on-disk config/state only and never starts/stops/reloads a tunnel.
- `tests/unit/test_archive_limits.sh` (12 tests: entry/size/compressed
  bounds, boundary values, duplicate-path rejection, unparseable-size
  fail-closed behavior, normal small archives unaffected, rejection
  leaves existing config untouched) and
  `tests/integration/test_purge_confirmation.sh` (12 tests, including
  real-pty-simulated interactive prompts, proving the full
  interactive/non-interactive `--purge`/`--force`/`--confirm-purge`
  confirmation matrix).

- `install.sh` — real installer: PRECHECK (root/OS/dependency checks) →
  PLAN → STAGE → VALIDATE (`bash -n` every staged file) → ACTIVATE (atomic
  directory swap, old files renamed aside until verified) → VERIFY
  (invoke the installed CLI, compare reported version) → COMMIT (install
  manifest written), with automatic rollback of program files on VERIFY
  failure. Distinguishes fresh install / reinstall / upgrade / downgrade
  by comparing versions; downgrade requires `--allow-downgrade` and a
  schema-compatibility check. Never overwrites an existing
  `/etc/tixolink`/`/var/lib/tixolink`. Supports a sandboxed `TIXOLINK_ROOT`
  prefix for testing.
- `uninstall.sh` — default mode removes only program files (binary,
  library tree, systemd unit), preserving all user data; `--purge` (with
  mandatory `--confirm-purge` or an interactive typed `PURGE`
  confirmation) additionally tears down owned tunnels/forwarding, restores
  the optimizer/BBR baseline, and removes `/etc/tixolink`/
  `/var/lib/tixolink`/`/var/log/tixolink`.
- `lib/manifest.sh` — the install ownership ledger consumed by the
  installer/uninstaller/updater: exact files (with SHA256) and
  directories TixoLink installed, never inferred from path naming.
- `lib/migration.sh` — the config/tunnel/state schema migration
  framework (ordered per-version migrations, fail-safe on an
  unsupported-newer schema, backup-before-write with rollback on
  verification failure). The production registry is currently empty
  (every component is still schema v1); exercised by
  `tests/unit/test_migration.sh` via fixture migrations.
- `lib/common.sh` — added `common::tar_extract_safely` (shared untrusted-
  archive path/type validation for restore and update) and
  `common::assert_safe_delete_path`/`common::safe_rm_rf` (the sole gate
  for every recursive delete of a TixoLink-owned directory).
- `modules/backup.sh` / `tixolink backup` — archives config/tunnels/
  state/optimizer-baseline into a checksummed `tar.gz`, excluding
  everything else on the host.
- `modules/restore.sh` / `tixolink restore` — validates archive format
  and checksums, checks schema compatibility, previews contents, takes an
  automatic pre-restore snapshot, applies exactly the backed-up state
  (including removing a tunnel not present in the backup), and rolls back
  to the pre-restore snapshot on any failure.
- `modules/update.sh` / `tixolink update check|apply` — GitHub Releases
  updater: downloads and SHA256-verifies the release artifact and its
  checksum manifest, then delegates the actual upgrade to the downloaded
  package's own `install.sh` transaction. No `git pull`/branch-tracking
  update path.
- `modules/lifecycle.sh` / `tixolink factory-reset` — tears down every
  owned tunnel/forwarding mapping, restores the optimizer/BBR baseline to
  the live host and verifies it before resetting config/state to
  defaults; aborts before touching config/state if any step didn't
  verify clean. The owned-resource teardown is shared with
  `uninstall.sh --purge`.
- CLI/menu: `backup`, `restore <archive>`, `update check|apply`, and
  `factory-reset` added to `lib/cli.sh` and `lib/menu.sh`, each gated
  behind an explicit review/confirmation screen for destructive actions.
- `tests/unit/test_manifest.sh`, `test_migration.sh`, `test_backup.sh`,
  `test_restore.sh`, `test_update.sh`, `test_lifecycle.sh`, and
  `tests/integration/test_lifecycle_sandbox.sh` (the mandatory 21-step
  sandboxed install → upgrade → backup → restore → uninstall → reinstall
  → factory-reset → purge walk, with sentinel-file preservation checks).
- VERSION bumped `0.1.0-dev` → `0.6.0-dev` to reflect six completed
  development phases; still pre-release.
- Fixed two defects found during Phase 6 integration testing, unrelated
  to lifecycle code but blocking it: `lib/ui.sh`'s `ui::table` used an
  invalid nested bash parameter expansion and an incorrect nameref-array
  passing convention, breaking `tixolink list`/`status` output whenever
  any tunnel existed; `lib/dependency.sh` checked for a binary literally
  named `iproute2` instead of `ip`, so the required-dependency check
  always reported `iproute2` missing even when installed.

### Phase 5 — Observability and optimization

- `modules/diagnostics.sh` — read-only system and per-tunnel diagnostics
  (PASS/WARN/FAIL/UNKNOWN health model documented in
  `docs/troubleshooting.md`), latency/loss, MTU/PMTU findings, forwarding
  diagnostics, and a privacy-aware redacted support-report archive
  (`diagnostics report --privacy`).
- `modules/benchmark.sh` — latency/loss benchmarking and opt-in `iperf3`
  throughput testing against a server the administrator already controls.
- `modules/monitor.sh` — live, read-only interface-rate dashboard.
- `modules/optimizer.sh` — INSPECT → RECOMMEND → PREVIEW → explicit
  APPLY → VERIFY → RESTORE sysctl tunable management, owning exactly
  `/etc/sysctl.d/99-tixolink.conf`, with baseline-on-first-touch semantics
  so `optimize restore` always returns to the administrator's original
  value.
- `modules/bbr.sh` — BBR congestion-control management built on the
  optimizer's baseline/apply/verify/restore machinery; never claims
  ownership of BBR if it was already active.
- Namespace-based integration tests for diagnostics/monitor and
  optimizer/BBR failure injection.

### Phase 4 — Forwarding

- `forwarders/netfilter.sh` — TCP/UDP forwarding via dedicated
  `TIXOLINK-DNAT`/`TIXOLINK-FWD`/`TIXOLINK-SNAT` chains, one idempotent
  tagged jump rule per built-in chain, NAT and source-preserving modes,
  port ranges/remapping.
- `forwarders/haproxy.sh` — TCP-only forwarding via a fully-validated
  candidate HAProxy config, change detection (no reload when unchanged),
  graceful reload only when needed, rollback on validation failure, no
  stealing of binds/config it didn't create.
- `modules/forwarding.sh` — mapping CRUD, forwarding-engine migration,
  ownership-safe conflict detection.
- Hardening pass: semantic no-op forwarding edits, safer HAProxy
  bind-conflict handling, transaction/ownership behavior.
- Real-namespace packet-forwarding and isolated HAProxy integration
  tests, plus failure injection.

### Phase 3 — GRE IPv4 transport engine

- `engines/gre.sh` — create/start/stop/restart/reload/edit/delete,
  automatic `/30` inner-subnet allocation with collision detection,
  interface ownership verification, conflict detection, transactional
  rollback (notably on endpoint-change recreate failures).
- `modules/tunnel.sh` — tunnel CRUD orchestration; `modules/peer.sh` —
  peer export/import (configuration-only JSON documents, reviewed before
  any import is accepted).
- `systemd/tixolink@.service` — template unit reading each tunnel's
  config by immutable ID at every start/stop/reload, never embedding a
  stale IP/MTU/interface value in a generated per-tunnel file.
- Real Linux GRE network-namespace integration tests, multi-tunnel tests,
  and transactional-rollback-under-real-kernel-failure tests.

## [0.1.0-dev] (Phase 1-2)

### Added

- Repository skeleton (`bin/`, `lib/`, `engines/`, `forwarders/`,
  `modules/`, `systemd/`, `docs/`, `tests/`, `packaging/`).
- Foundation library layer:
  - `lib/common.sh` — strict-mode helpers, exit-code contract, cleanup
    traps, safe temp files.
  - `lib/logging.sh` — leveled logging (ERROR/WARN/INFO/DEBUG) with
    separate terminal and persistent-log thresholds, plus a JSON operation
    history stream.
  - `lib/ui.sh` — color/TTY/`NO_COLOR`-aware headers, prompts
    (confirm/input/select), and table rendering.
  - `lib/validation.sh` — pure validators for IPv4, CIDR, ports/port
    ranges, protocols, MTU, TTL, interface names, tunnel names, tunnel
    IDs, and path-escape protection.
  - `lib/platform.sh` — read-only OS/kernel/arch/virtualization and
    networking-capability detection (GRE module, iptables backend,
    nftables/UFW/Docker/Podman/HAProxy presence, congestion control).
  - `lib/dependency.sh` — centralized `REQUIRED`/`OPTIONAL`/`FEATURE`
    package manifest and single `apt-get install` code path.
  - `lib/config.sh` — atomic JSON config read/write, app config
    initialization, default subnet pool constant.
  - `lib/state.sh` — atomic JSON state read/write (owned-resource ledger
    scaffolding).
  - `lib/locking.sh` — `flock`-based named locks.
  - `lib/transaction.sh` — PRECHECK/BACKUP/PLAN/APPLY/VERIFY/COMMIT/
    ROLLBACK scaffolding with dry-run support.
  - `lib/cli.sh` — non-interactive command dispatcher (`version`, `help`
    implemented initially; tunnel/forwarding commands added in Phase 3-4).
  - `lib/menu.sh` — data-driven interactive main menu.
- `bin/tixolink` launcher with dev-checkout and installed-path resolution.
- Unit test suite (`tests/unit/`) and hand-rolled TAP-style harness
  (`tests/lib/test_harness.sh`) for the foundation layer.
- Apache License 2.0.
- Initial documentation skeleton.

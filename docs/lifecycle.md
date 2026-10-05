# Lifecycle: install, upgrade, backup, restore, update, uninstall, factory reset

This document describes the Phase 6 lifecycle layer: `install.sh`,
`uninstall.sh`, `tixolink backup`/`restore`, `tixolink update`, and
`tixolink factory-reset`. Every mutating workflow here follows the same
shape as `lib/transaction.sh`: PRECHECK → BACKUP → PLAN/STAGE → VALIDATE →
APPLY/ACTIVATE → VERIFY → COMMIT, with rollback on failure before COMMIT.

## Installed filesystem layout

```
/usr/local/bin/tixolink                     launcher (0755)

/usr/local/lib/tixolink/                    program files (0644 each)
    *.sh                                    lib/ flattened directly here
    engines/, forwarders/, modules/
    VERSION

/etc/tixolink/                              desired-state config (0750)
    config.json                             app config (subnet pool, ...)
    tunnels/<id>.json                       one file per tunnel

/var/lib/tixolink/                          TixoLink-managed fact (0750)
    state.json                              owned-resource ledger
    history.jsonl                           operation audit trail
    install-manifest.json                   install ownership ledger (0640)
    backups/                                tixolink backup archives (0700)
    optimizer/
        baseline.json                       administrator's pre-TixoLink values
        applied.json                        tunables TixoLink currently manages

/var/log/tixolink/                          tixolink.log (0750)
/run/tixolink/                              locks/ (ephemeral, tmpfs)
/etc/systemd/system/tixolink@.service       template unit (0644)
```

This deviates from a flat `var/lib/tixolink/state/` subdirectory on
purpose: `lib/state.sh` has addressed `state.json` directly under
`TIXOLINK_VAR_DIR` since Phase 2, and changing that now would be churn
with no benefit — the install manifest and migration framework exist
precisely so paths like this can be documented as-is rather than forced
to match a layout sketched before the code existed.

## Install manifest

`install.sh` writes `/var/lib/tixolink/install-manifest.json`
(`lib/manifest.sh`) recording: `schema_version`, `tixolink_version`,
`previous_version`, `installed_at`/`updated_at`, the resolved prefix paths,
and — critically — the exact list of files it installed (each with a
SHA256 and mode) and directories it created and considers its own to
remove. No secrets are recorded. `uninstall.sh` and `tixolink update` only
ever remove or report on paths this manifest actually lists; ownership is
never inferred from a path merely looking familiar
(`/usr/local/bin/tixolink` is never deleted because of its name — only
because the manifest says so).

## Public bootstrap installer (`TixoLink.sh`)

```
bash <(curl -fsSL https://raw.githubusercontent.com/TheTixoCloud/TixoLink/master/TixoLink.sh)
```

A small, auditable, root-level script (intentionally *not* part of the
installed package) that gives first-time users a single public command.
It does **not** reimplement `install.sh` and never runs a second
unverified `curl | bash`: it checks the host (root, supported OS, amd64,
HTTPS-capable curl), resolves which GitHub Release to install, downloads
that release's `tixolink-<version>.tar.gz` and `SHA256SUMS`, verifies the
checksum and the archive's internal structure (absolute paths, `..`
traversal, wrong top-level directory, symlinks/hardlinks/devices/FIFOs,
and the same per-file/total/entry-count resource limits as
`common::tar_extract_safely` — reimplemented standalone, since that
library doesn't exist on the target yet) **before extracting a single
byte**, and only then delegates to the verified package's own
`install.sh --force` — the exact same authoritative lifecycle
`modules/update.sh` already delegates to. Every network call goes
through `bootstrap::http_get`/`bootstrap::http_get_file`, the seams
`tests/unit/test_bootstrap.sh` and
`tests/integration/test_bootstrap_sandbox.sh` override to serve local
fixtures — no test ever reaches the real GitHub API or installs onto the
real host.

**Release selection:**

| Setting | Behavior |
|---|---|
| *(default)* / `TIXOLINK_CHANNEL=stable` | Latest **non-prerelease** GitHub Release. Fails closed with an explicit message if none is published yet — never silently falls back to a prerelease. |
| `TIXOLINK_CHANNEL=rc` | Latest published prerelease (release candidate). |
| `TIXOLINK_VERSION=X.Y.Z[-rcN]` | Installs exactly that version. Strictly validated against an allowlist regex before it is ever used in a path/filename/URL. Bypasses the GitHub API entirely via GitHub's deterministic `releases/download/<tag>/<asset>` URL, so this mode needs no `jq`. |

During the `1.0.0-rcN` period (no stable `1.0.0` exists yet), the public
one-command install therefore reads `TIXOLINK_CHANNEL=rc bash
TixoLink.sh` or `TIXOLINK_VERSION=1.0.0-rc1 bash TixoLink.sh` — plain
`bash TixoLink.sh` with no overrides deliberately refuses, by design,
rather than quietly redefining "stable" to mean "prerelease."

**Trust model**: identical to the updater's, below — SHA256 verifies the
downloaded bytes match what the release published, not that the release
channel itself is uncompromised.

**Idempotency**: the bootstrap invents no install/upgrade/downgrade logic
of its own; `install.sh --force` alone decides fresh vs. reinstall vs.
upgrade vs. downgrade-refusal, exactly as it does for a manual
`git clone` + `./install.sh` or for `tixolink update apply`.

## Installer (`install.sh`)

```
sudo ./install.sh [--force|--yes] [--dry-run] [--allow-downgrade] [--root <path>]
```

PRECHECK (root, supported-OS check, required-dependency check) → PLAN
(printed, confirmed unless `--force`) → STAGE (copy the source tree into a
temp directory next to the final library location) → VALIDATE (`bash -n`
every staged `*.sh`) → ACTIVATE (atomic directory swap: the old library
directory and binary are renamed aside, not deleted, until VERIFY passes;
config/state directories are created with defaults **only if absent** —
an existing configuration is never overwritten; the systemd unit is
copied in and `daemon-reload` runs only if its content actually changed)
→ VERIFY (invoke the newly-installed CLI's `version` command and compare
to the source tree's `VERSION`) → COMMIT (delete the renamed-aside old
files, write the install manifest). Any VERIFY failure rolls the old
binary/library directory back into place and leaves `/etc/tixolink`
and `/var/lib/tixolink` completely untouched.

Installing never starts a tunnel and never runs `apt-get upgrade`/
`dist-upgrade`/`full-upgrade`.

**Fresh / reinstall / upgrade / downgrade** are distinguished by comparing
the source tree's `VERSION` to the installed manifest's
`tixolink_version` (a small dotted-version + `-suffix` comparison, not a
full SemVer implementation — see `install::_vcmp`). A downgrade is
refused unless `--allow-downgrade` is given, and even then is refused if
any on-disk config/tunnel/state document's `schema_version` is newer than
what the older target version's own `lib/migration.sh` declares as
current — a downgrade is never allowed to leave data the older binary
can't safely read.

## Uninstaller (`uninstall.sh`)

```
sudo ./uninstall.sh [--force|--yes] [--dry-run]
sudo ./uninstall.sh --purge --confirm-purge [--skip-backup] [--backup-output <file>]
```

**Default mode** removes only what the install manifest lists: the
binary, the library directory, the systemd unit — then runs
`systemctl daemon-reload` if the unit was actually removed. It stops (but
does not disable) any currently-active `tixolink@*.service` instances
first, since their `ExecStop`/`ExecReload` would otherwise reference a
binary that's about to disappear. **`/etc/tixolink` and
`/var/lib/tixolink` are never touched** in default mode — tunnel configs,
backups, the optimizer baseline, and the manifest itself all survive, so
a later reinstall picks up exactly where the uninstall left off.

**`--purge`** is the separate, explicitly-confirmed destructive path. It
requires `--confirm-purge` in non-interactive mode (interactively, it
additionally requires typing the literal word `PURGE`) — there is no
single flag that triggers it by accident. Purge: offers (by default,
unless `--skip-backup`) an automatic backup written to the current
working directory, or to `--backup-output <file>` if given (since
`/var/lib/tixolink/backups/` is about to be deleted); tears down every owned tunnel/forwarding mapping and restores
the optimizer/BBR baseline to the live host (via the same
`lifecycle::teardown_owned_resources` helper `factory-reset` uses) and
**aborts before deleting anything** if that restoration doesn't verify
clean; then removes the program files (as default mode does) and finally
`/etc/tixolink`, `/var/lib/tixolink`, and `/var/log/tixolink` in full.

Every recursive directory removal anywhere in `uninstall.sh` (and
`install.sh`'s rollback path) goes through
`common::safe_rm_rf`/`common::assert_safe_delete_path`
(`lib/common.sh`): it refuses to run unless the resolved path's final
path component is literally `tixolink` and the path isn't one of a
hard-coded list of real filesystem roots (`/`, `/etc`, `/var`, `/usr`,
`/home`, …) or fewer than three path segments deep. A misconfigured or
empty `TIXOLINK_ROOT`/env override can produce an error, never a wider
deletion.

## Schema migration framework

`lib/migration.sh` gives every component (`config`, `tunnel`, `state`) an
explicit current schema version and an ordered chain of
`migration::register <component> <from-version> <function>` steps, each
producing `schema_version = from + 1`. `migration::migrate_file`:
BACKUP (copy the original file aside) → APPLY (run the chain in memory,
write the result) → VALIDATE (read the written file back) → on mismatch,
restore the backup and return `EXIT_ROLLED_BACK`. A document whose
`schema_version` is **newer** than this build's registry supports is never
touched — `migration::upgrade` fails safe with `EXIT_VALIDATION` and a
message naming the problem, rather than guessing how to interpret or
downgrade it.

As of this build every component is still at schema version 1, so the
production registry has nothing registered — there is nothing to migrate
yet. `tests/unit/test_migration.sh` proves the mechanism itself works by
registering fixture migrations for a throwaway `widget` component, so the
framework is validated without inventing a fake real migration.
`install.sh` (on downgrade) and `modules/restore.sh` (after applying a
backup) both already call into this framework; it will engage with zero
further changes the day a real schema bump actually happens.

## Backup (`tixolink backup`)

```
tixolink backup [--output <file>] [--force]
```

Archives exactly: `config.json`, every `tunnels/<id>.json`, `state.json`,
and `optimizer/{baseline,applied}.json` — **never** `/etc`, `/var`,
HAProxy's own configuration, firewall rules, or any other host file, and
never `/run` (runtime-only). The archive is `tar.gz`, with a single
`backup/` root containing `manifest.json` (schema version, TixoLink
version, timestamp, the list of included relative paths, and each
component's schema version), `checksums.sha256` (SHA256 of every payload
file), and `payload/...`. The archive file itself is written `0600` under
`/var/lib/tixolink/backups/` (0700) by default, and an existing file at
the target path is never silently overwritten (`--force` required).

**Integrity vs. authentication**: the SHA256 checksums let `restore`
detect accidental corruption or an incomplete archive. They are **not
cryptographic authentication** — anyone who can write the checksums file
can make it match a different payload. Nothing in a TixoLink config
backup is secret-bearing (no SSH keys, API keys, or passwords are ever
collected — peer documents and backups alike carry configuration only),
so the restrictive file permissions plus the integrity check are judged
sufficient for this build; see the updater section below for the same
caveat applied to release artifacts.

## Restore (`tixolink restore <archive>`)

```
tixolink restore <archive> [--dry-run] [--force]
```

INSPECT (list the archive's members, cheaply via `tar -t`/`-tv` — never by
writing anything to disk first) → VERIFY FORMAT (every member must be a
plain file or directory rooted under `backup/`; no absolute paths, no
`..` segments, no symlinks/hardlinks/devices/fifos/sockets, no duplicate
member paths — `common::tar_extract_safely`, shared with the updater) →
VERIFY RESOURCE LIMITS (the compressed archive itself, the entry count,
each declared regular-file size, and the declared total uncompressed size
must each stay under a bounded, centralized constant — see "Archive
resource limits" below; a size field that doesn't parse as a plain
non-negative integer is rejected outright, not treated as zero) → extract
into a private `0700` temp directory (never over `/`) → VERIFY CHECKSUMS
(every payload file must match `checksums.sha256`, every file on disk
must be listed in it, no duplicate entries) → CHECK SCHEMA COMPATIBILITY
(a backup's component schema newer than this build understands is
refused) → PREVIEW (printed; confirmation
required unless `--force`) → an **automatic pre-restore snapshot** is
taken via `backup::create` before anything is touched → APPLY (config.json
and state.json are replaced wholesale; the tunnels directory is replaced
**exactly** — a tunnel present on disk but absent from the backup is
removed, matching "restore to exactly this backup," not "merge") →
MIGRATE IF REQUIRED (idempotent no-op today) → VALIDATE (every restored
document re-read and parses) → on any failure from APPLY onward, the
pre-restore snapshot is re-applied automatically and `EXIT_ROLLED_BACK` is
returned.

Restore **never** starts, stops, or reloads a tunnel, and never touches
live firewall/HAProxy state — it only writes the desired-state files.
Reconciling runtime to the restored configuration is a deliberate,
separate step (`tixolink reload <id>`), left to the administrator.

## Archive resource limits

`common::tar_extract_safely` (`lib/common.sh`) bounds every archive from
an untrusted source — a backup handed to `restore`, a release artifact
downloaded by `update` — against four centralized, overridable constants,
each checked from `tar`'s own metadata *before* a single byte is
extracted:

| Constant | Default | Checked from |
|---|---|---|
| `TIXOLINK_ARCHIVE_MAX_COMPRESSED_BYTES` | 64 MiB | `stat` on the archive file itself, before `tar` ever runs |
| `TIXOLINK_ARCHIVE_MAX_ENTRIES` | 5000 | `tar -tzf` listing line count |
| `TIXOLINK_ARCHIVE_MAX_FILE_BYTES` | 50 MiB | each regular-file entry's declared size in `tar -tvzf` |
| `TIXOLINK_ARCHIVE_MAX_TOTAL_BYTES` | 200 MiB | running sum of every regular-file entry's declared size |

These are sized against what TixoLink itself ever legitimately produces
— a backup is a handful of small JSON documents (realistically under
1 MiB even with hundreds of tunnels); a release artifact is this
project's own source tree (a few hundred files, a few MiB at most) — each
roughly two orders of magnitude above that reality: generous enough to
never bite a real archive, nowhere near large enough to let a hostile one
turn "verify a backup" into "fill the disk" or "peg a CPU for an hour."
Any entry's declared size field that isn't a plain non-negative integer
is rejected outright (fail closed), never coerced to zero. Exceeding any
limit is reported by name (which limit, the observed value, the
configured ceiling) and rejects the archive before `tar -x` is ever
invoked — nothing is written to the staging directory, and nothing
already on disk is touched.

One caveat, documented rather than silently accepted: listing a gzip
archive's members (`tar -t`/`-tv`) still requires decompressing the full
gzip stream, even though no extracted bytes are written to disk for that
step. A pathological archive with an extreme gzip compression ratio could
still cost CPU time during the listing/size-check phase itself, before
the compressed-size-based first gate (checked via a plain `stat()`,
before `tar` runs at all) is the primary defense against that specific
case — see "Remaining Phase 6 limitations" in the Phase 6 hardening
report for the honest bound on what this does and doesn't fully close.

## Updater (`tixolink update check` / `tixolink update apply`)

Targets GitHub Releases at `TheTixoCloud/TixoLink` — never `git pull
origin main`, never an arbitrary branch HEAD. `update check` compares
`VERSION` against the latest release's tag. `update apply`: downloads the
release's `<name>.tar.gz` artifact and its `SHA256SUMS` asset (the same
asset `packaging/build-release.sh` produces), verifies the artifact's
SHA256 against that
manifest (refusing on any mismatch), extracts into a private staging
directory using the same `common::tar_extract_safely` path-safety and
resource-limit checks restore uses, confirms the extracted package's `VERSION` matches the
release tag, and then **delegates the actual upgrade to that package's
own `install.sh --force`** — reusing its PRECHECK/BACKUP/STAGE/VALIDATE/
ACTIVATE/VERIFY/COMMIT transaction and rollback instead of a second,
parallel implementation. All network access goes through
`update::_http_get`, the one seam `tests/unit/test_update.sh` overrides to
serve fixture responses — no test ever reaches the real GitHub API.

**Trust model**: SHA256 verifies that the downloaded bytes match what the
release published. It does **not** authenticate that the release channel
itself is uncompromised — an attacker able to edit a GitHub release could
publish a matching checksum for a malicious artifact. There is no
artifact signing in this build. If that's added later, it slots in as one
more check between "download" and "extract" in `modules/update.sh`
without changing this command surface. One release channel only; there is
no beta/stable split, and pre-release tags (e.g. `0.6.0-dev`) are treated
as less-than their bare counterpart (`0.6.0`) by the version comparator,
so a pre-release build is never silently treated as "newer" than a tagged
release of the same numbers.

## Factory reset (`tixolink factory-reset`)

```
tixolink factory-reset [--force] [--dry-run] [--skip-backup]
```

Differs from uninstall: **TixoLink stays installed.** PLAN (printed) →
backup offer (automatic unless `--skip-backup`) → confirm → for every
tunnel, remove its forwarding mappings then the tunnel itself
(best-effort — one tunnel's failure doesn't stop the rest, but is tracked)
→ **restore the optimizer/BBR baseline to the live host and verify it
actually went clean** → only if that verification succeeds, reset
`config.json`/`state.json` to defaults and remove the optimizer baseline/
applied files. If baseline restoration doesn't verify clean, or any
tunnel failed to remove, config/state are deliberately left untouched —
the administrator has something to retry against instead of a wiped
ledger with half-torn-down resources. This ordering (restore-then-verify-
then-delete) is the one thing in this module that must never be
reordered: deleting the baseline file before confirming the host was
actually restored to it would destroy the only record of what to restore
to.

## Sandboxed testing (`TIXOLINK_ROOT`)

Every path `install.sh`/`uninstall.sh` touch is computed as
`"${TIXOLINK_ROOT}/usr/local/bin/tixolink"`, etc. — with `TIXOLINK_ROOT`
unset (the real-host default), this is simply `/usr/local/bin/tixolink`.
For testing, set `TIXOLINK_ROOT=/tmp/some-sandbox` (or pass `--root`) and
everything — including the config/state paths `lib/config.sh`/
`lib/state.sh` already resolve via their own `TIXOLINK_ETC_DIR`/
`TIXOLINK_VAR_DIR` overrides — stays confined to that prefix. Verifying
the installed CLI under a sandbox additionally requires exporting
`TIXOLINK_LIB_DIR`/`TIXOLINK_ENGINES_DIR`/`TIXOLINK_MODULES_DIR`/
`TIXOLINK_FORWARDERS_DIR` pointing at the sandboxed install, since
`bin/tixolink`'s own dev-vs-installed path heuristic only recognizes the
literal real path `/usr/local/bin` as "installed" — see
`tests/integration/test_lifecycle_sandbox.sh` for the exact invocation
pattern used throughout its 21-step install → upgrade → backup → restore
→ uninstall → reinstall → factory-reset → purge walk, including sentinel
files planted next to (never inside) the sandbox to prove every
destructive step stays scoped to TixoLink's own paths.

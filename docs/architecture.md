# Architecture

This document describes the architecture as actually implemented through
Phase 6 (lifecycle). It started as a Phase 1 design record; the layering
and transaction model it originally specified held up unchanged through
every later phase, so the structure below is current, not aspirational.

## Layering

```
bin/tixolink                          install.sh / uninstall.sh (standalone)
  -> lib/cli.sh, lib/menu.sh            (presentation/dispatch)
       -> modules/*.sh                   (orchestration)
            -> engines/*.sh, forwarders/*.sh   (pluggable backends)
                 -> lib/config.sh, lib/state.sh, lib/locking.sh, lib/transaction.sh,
                    lib/manifest.sh, lib/migration.sh
                      -> lib/validation.sh, lib/platform.sh, lib/logging.sh, lib/common.sh
```

Each layer only calls downward. Engines and forwarders never call `ui::*`
directly and never print to the terminal — only `modules/*.sh` is allowed
to call both an engine/forwarder and the UI layer. `install.sh` and
`uninstall.sh` are the one deliberate exception to "only `bin/tixolink`
sources the stack": they are standalone, `set -Eeuo pipefail` scripts that
source the subset of `lib/` (and, for `uninstall.sh`, `engines/`/
`forwarders/`/`modules/`) they need directly from the source checkout,
because they must work *before* anything is installed, or *during* the
removal of what's installed. See [docs/lifecycle.md](lifecycle.md).

## Foundation layer

| File | Responsibility |
|---|---|
| `lib/common.sh` | Strict-mode bootstrap, the exit-code contract, cleanup traps (EXIT/INT/TERM), safe `mktemp` helpers, `common::tar_extract_safely` (shared untrusted-archive validation for restore/update), `common::assert_safe_delete_path`/`common::safe_rm_rf` (the one gate every recursive delete of a TixoLink-owned directory goes through), small string/array utilities. |
| `lib/logging.sh` | ERROR/WARN/INFO/DEBUG levels with independent terminal and log-file thresholds; append-only JSON operation history stream. |
| `lib/ui.sh` | All terminal rendering: color/`NO_COLOR`/TTY detection, headers, success/error/warning/info lines, confirm/input/select prompts, table rendering. No other file emits raw ANSI escapes. |
| `lib/validation.sh` | Pure validators (no I/O) for every untrusted input type: IPv4, CIDR, port, port range/spec, protocol, MTU, TTL, interface name, tunnel name, tunnel ID, path-escape check. |
| `lib/platform.sh` | Read-only system inspection: OS/version/kernel/arch/virtualization, GRE module availability, iptables backend (nf_tables vs legacy), nft/UFW/Docker/Podman/HAProxy presence, congestion control/qdisc. Never modifies anything. |
| `lib/dependency.sh` | The single declarative package manifest (`REQUIRED`/`OPTIONAL`/`FEATURE:netfilter`/`FEATURE:haproxy`) and the single `apt-get install` code path. Never runs `upgrade`/`dist-upgrade`. |
| `lib/config.sh` | Structured JSON configuration: atomic write (tmp file + `mv -T` + directory sync), `jq`-validated reads, app config defaults/init, per-tunnel config store. Never `source`s or `eval`s configuration. |
| `lib/state.sh` | Owned-resource ledger (what TixoLink currently manages at runtime), kept separate from `config.sh`'s user-editable intent. |
| `lib/locking.sh` | Named `flock`-based mutual exclusion under `/run/tixolink/locks/`. |
| `lib/transaction.sh` | Generic PRECHECK → BACKUP → PLAN → APPLY → VERIFY → COMMIT/ROLLBACK state machine, with dry-run support, reused by tunnel/forwarding/optimizer mutations. |
| `lib/manifest.sh` | The install ownership ledger (`install-manifest.json`): which files/dirs `install.sh` put where, with a SHA256 per file, consumed by `uninstall.sh`/the updater. See [docs/lifecycle.md](lifecycle.md). |
| `lib/migration.sh` | The config/tunnel/state schema migration framework: ordered per-version migration functions, fail-safe on a schema newer than this build understands, backup-before-write with restore-on-verify-failure. The production registry is empty (every component is still schema v1); `tests/unit/test_migration.sh` exercises the mechanism with fixture migrations. |
| `lib/cli.sh` | Non-interactive command dispatcher; the only file that calls `exit`. |
| `lib/menu.sh` | Data-driven interactive menu table. |
| `bin/tixolink` | Thin launcher: resolves its own location (dev checkout vs. installed), sources the library layer, calls `cli::main`. |

## Transport/forwarding plugin contracts

`engines/engine_api.sh` and `forwarders/forwarder_api.sh` are simple
register+dispatch tables: `engine::dispatch <name> <verb> [args...]` calls
`engine_<name>_<verb>`, failing clearly (not silently) if the verb isn't
implemented. `engines/gre.sh` is the only transport engine; `forwarders/
{none,netfilter,haproxy}.sh` are the forwarding backends. `modules/*.sh`
never calls an engine/forwarder function by name directly — always
through dispatch — so a future engine plugs in without touching callers.

## Orchestration modules

| File | Responsibility |
|---|---|
| `modules/tunnel.sh` | Tunnel CRUD orchestration: create/start/stop/restart/reload/edit/delete, wrapping `engine::dispatch` in `lib/transaction.sh`. |
| `modules/peer.sh` | Peer document export/import (see README). |
| `modules/forwarding.sh` | Port mapping CRUD, engine migration, wrapping `forwarder::dispatch`. |
| `modules/diagnostics.sh` | Read-only system/tunnel diagnostics and the privacy-aware support-report archive. |
| `modules/benchmark.sh` | Latency/loss and opt-in `iperf3` throughput. |
| `modules/monitor.sh` | Live interface-rate dashboard. |
| `modules/optimizer.sh` | Sysctl tunable registry, baseline/applied tracking, apply/restore. |
| `modules/bbr.sh` | BBR congestion-control management, built on `modules/optimizer.sh`'s machinery. |
| `modules/backup.sh` | `tixolink backup`: archives config/tunnels/state/optimizer baseline into a checksummed tarball. |
| `modules/restore.sh` | `tixolink restore`: validates, previews, and applies a backup archive, with automatic pre-restore snapshot and rollback. |
| `modules/update.sh` | `tixolink update check`/`apply`: GitHub Releases updater, delegating the actual file swap to the downloaded package's own `install.sh`. |
| `modules/lifecycle.sh` | `tixolink factory-reset` and the shared owned-resource teardown helper also used by `uninstall.sh --purge`. |

## Installed filesystem layout and lifecycle

See [docs/lifecycle.md](lifecycle.md) for the installed filesystem
layout, the install/uninstall/backup/restore/update/factory-reset
workflows, the install manifest format, and the sandboxed
(`TIXOLINK_ROOT`) testing mechanism used by
`tests/integration/test_lifecycle_sandbox.sh`.

## Configuration format decision

JSON, read/written exclusively via `jq`, never `source`d or `eval`'d. Atomic
writes: render to a `mktemp` file in the target directory, `jq -e .` validate,
`mv -T` into place, best-effort directory `sync`. jq is already a required
runtime dependency; a second hand-rolled parser format would be redundant
maintenance surface with no security benefit.

Every persisted document (app config, each tunnel config, the state
ledger, backup archives) carries an explicit integer `schema_version`,
consumed by `lib/migration.sh`. Application version (`VERSION`, currently
`0.6.0-dev`) and configuration schema version are deliberately separate
concepts — a schema bump doesn't require a major version bump, and vice
versa.

## Exit code contract

| Code | Meaning |
|---|---|
| 0 | success |
| 1 | generic/unexpected error |
| 2 | invalid usage / argument error |
| 3 | validation error |
| 4 | conflict detected |
| 5 | not found |
| 6 | permission/root required |
| 7 | dependency missing |
| 8 | lock timeout |
| 9 | transaction rolled back |

Library/module functions `return` one of these; only `lib/cli.sh` calls
`exit` (and, correspondingly, `install.sh`/`uninstall.sh` for their own
standalone runs), keeping everything else sourceable and testable without
terminating the test process.

## Known limitations

- `tixolink create`/`tixolink edit` support both an interactive wizard
  (unchanged) and a flag-driven non-interactive path (added in Phase 7)
  calling the exact same `tunnel::create_from_fields`/
  `tunnel::edit_from_fields` functions the wizard always called. See
  [docs/troubleshooting.md](troubleshooting.md) for the flag reference.
- The updater's integrity check (SHA256 against a published checksum
  manifest) does not authenticate the release channel itself; see
  [docs/lifecycle.md](lifecycle.md)'s trust-model section.

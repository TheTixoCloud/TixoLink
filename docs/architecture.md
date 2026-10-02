# Architecture

This document summarizes the approved Phase 1 architecture. It will grow as
later phases are implemented.

## Layering

```
bin/tixolink
  -> lib/cli.sh, lib/menu.sh            (presentation/dispatch)
       -> modules/*.sh                   (orchestration — Phase 3+)
            -> engines/*.sh, forwarders/*.sh   (pluggable backends — Phase 3/4)
                 -> lib/config.sh, lib/state.sh, lib/locking.sh, lib/transaction.sh
                      -> lib/validation.sh, lib/platform.sh, lib/logging.sh, lib/common.sh
```

Each layer only calls downward. Engines and forwarders never call `ui::*`
directly and never print to the terminal — only `modules/*.sh` is allowed to
call both an engine/forwarder and the UI layer. This keeps engine/forwarder
code testable and reusable from the CLI, the interactive menu, and the test
suite identically.

## Foundation layer (implemented in Phase 2)

| File | Responsibility |
|---|---|
| `lib/common.sh` | Strict-mode bootstrap, the exit-code contract, cleanup traps (EXIT/INT/TERM), safe `mktemp` helpers, small string/array utilities. |
| `lib/logging.sh` | ERROR/WARN/INFO/DEBUG levels with independent terminal and log-file thresholds; append-only JSON operation history stream. |
| `lib/ui.sh` | All terminal rendering: color/`NO_COLOR`/TTY detection, headers, success/error/warning/info lines, confirm/input/select prompts, table rendering. No other file emits raw ANSI escapes. |
| `lib/validation.sh` | Pure validators (no I/O) for every untrusted input type: IPv4, CIDR, port, port range/spec, protocol, MTU, TTL, interface name, tunnel name, tunnel ID, path-escape check. |
| `lib/platform.sh` | Read-only system inspection: OS/version/kernel/arch/virtualization, GRE module availability, iptables backend (nf_tables vs legacy), nft/UFW/Docker/Podman/HAProxy presence, congestion control/qdisc. Never modifies anything. |
| `lib/dependency.sh` | The single declarative package manifest (`REQUIRED`/`OPTIONAL`/`FEATURE:netfilter`/`FEATURE:haproxy`) and the single `apt-get install` code path. Never runs `upgrade`/`dist-upgrade`. |
| `lib/config.sh` | Structured JSON configuration: atomic write (tmp file + `mv -T` + directory sync), `jq`-validated reads, app config defaults/init. Never `source`s or `eval`s configuration. |
| `lib/state.sh` | Owned-resource ledger (what TixoLink currently manages), kept separate from `config.sh`'s user-editable intent. |
| `lib/locking.sh` | Named `flock`-based mutual exclusion under `/run/tixolink/locks/`. |
| `lib/transaction.sh` | Generic PRECHECK → BACKUP → PLAN → APPLY → VERIFY → COMMIT/ROLLBACK state machine, with dry-run support, reused by every later state-changing feature instead of bespoke implementations. |
| `lib/cli.sh` | Non-interactive command dispatcher; the only file that calls `exit`. |
| `lib/menu.sh` | Data-driven interactive menu table. |
| `bin/tixolink` | Thin launcher: resolves its own location (dev checkout vs. installed), sources the library layer, calls `cli::main`. |

## Configuration format decision

JSON, read/written exclusively via `jq`, never `source`d or `eval`'d. Atomic
writes: render to a `mktemp` file in the target directory, `jq -e .` validate,
`mv -T` into place, best-effort directory `sync`. See the Phase 1 record for
the full rationale (jq is already a required runtime dependency; a second
hand-rolled parser format would be redundant maintenance surface with no
security benefit).

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
`exit`, keeping everything else sourceable and testable without terminating
the test process.

## What is intentionally not implemented yet

Transport engines (`engines/`), forwarding engines (`forwarders/`),
orchestration modules (`modules/`), systemd units, installer/updater,
backup/restore, and documentation for those subsystems are placeholders
(empty directories or not yet created) pending their respective approved
phases. See the project's phase plan for the full roadmap: tunnel engine API,
forwarding engine API, GRE engine, netfilter/HAProxy forwarders, systemd
persistence, optimizer/BBR, diagnostics/dashboard/benchmark, backup/restore/
update/uninstall, and the security/quality audit.

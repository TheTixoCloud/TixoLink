# Changelog

All notable changes to this project are documented in this file. Format
loosely follows [Keep a Changelog](https://keepachangelog.com/); versioning
follows [Semantic Versioning](https://semver.org/).

## [0.1.0-dev] - Unreleased

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
    implemented; tunnel/forwarding commands pending later phases).
  - `lib/menu.sh` — data-driven interactive main menu (About and Exit are
    functional; other items report "not implemented yet").
- `bin/tixolink` launcher with dev-checkout and installed-path resolution.
- Unit test suite (`tests/unit/`) and hand-rolled TAP-style harness
  (`tests/lib/test_harness.sh`) for the foundation layer.
- Apache License 2.0.
- Initial documentation skeleton (`docs/architecture.md`,
  `docs/networking.md`, `docs/firewall.md`, `docs/troubleshooting.md`,
  `docs/security.md`).

### Not yet implemented

Tunnel engines (GRE), forwarding engines (netfilter, HAProxy), diagnostics,
dashboard, benchmark, optimizer/BBR manager, installer, updater, backup/
restore, uninstaller. See `docs/architecture.md` for the planned design.

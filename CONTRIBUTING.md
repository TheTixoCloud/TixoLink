# Contributing to TixoLink NEXUS

TixoLink NEXUS is in early development. The project is being built in
controlled phases (see `docs/architecture.md`); large unsolicited pull
requests that cut across multiple phases are unlikely to be mergeable yet.

## Before contributing

- Open an issue describing what you want to change before writing code,
  especially for anything touching networking, firewall, or HAProxy
  behavior — these have strict safety requirements documented in
  `docs/networking.md`, `docs/firewall.md`, and `docs/security.md`.
- Read `docs/architecture.md` to understand the module boundaries (library
  layer vs. engines vs. forwarders vs. orchestration modules) before adding
  code — new functionality should fit the existing plugin contracts rather
  than reaching across layers.

## Code style

- Bash, `set -Eeuo pipefail` at the top of every executable/sourced file.
- One module/library concern per file; no monolithic scripts.
- `local` for all function-scoped variables; arrays for command
  construction (never build a command as a string and hand it to `eval`
  or `bash -c`).
- Every shell file must pass `shellcheck` with no unexplained suppressions.
  If a warning must be suppressed, add a comment immediately above the
  `# shellcheck disable=...` line explaining why.
- Functions are namespaced by file, e.g. `validation.sh` defines
  `validate::ipv4`, `ui.sh` defines `ui::success`, etc.

## Testing

- Unit tests live in `tests/unit/` and must not require root or modify the
  host. Run them with `tests/unit/run_all.sh`.
- Integration tests live in `tests/integration/` and use isolated Linux
  network namespaces; they must never touch the host's default namespace
  networking, routing, or firewall, and must clean up their namespaces even
  on failure.
- Run `shellcheck` across all changed shell files before submitting.

## Commit/PR expectations

- Explain *why* a change is needed, not just what it does.
- Call out any deviation from the documented architecture and the reason
  for it.
- Do not silently weaken a documented safety guarantee (firewall ownership
  scoping, HAProxy non-destructive integration, no `eval`, etc.) — if a
  guarantee needs to change, say so explicitly and explain why.

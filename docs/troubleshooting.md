# Troubleshooting

## Foundation-layer checks

If `tixolink` fails to start from a development checkout:

- Confirm you are running `bin/tixolink` from inside the repository (or
  have set `TIXOLINK_LIB_DIR` explicitly) — the launcher resolves the
  library directory relative to its own location.
- Confirm `jq` is installed (`lib/config.sh` and `lib/state.sh` require it
  for all reads/writes).
- Run with `--debug` for verbose terminal logging.

If running from an installed copy, confirm
`/var/lib/tixolink/install-manifest.json` exists and
`tixolink version` matches what you expect; see
[docs/lifecycle.md](lifecycle.md) for the install/upgrade/uninstall model.

## Diagnostic health thresholds (`modules/diagnostics.sh`)

Every diagnostic check reports one of `PASS`/`WARN`/`FAIL`/`UNKNOWN`
(measurement could not safely be taken — never silently treated as PASS):

| Check | PASS | WARN | FAIL |
|---|---|---|---|
| System load | CPU < 90%, mem < 90%, load1/cpu_count < 2 | any of those thresholds met/exceeded | — |
| Latency/loss to a peer | 0% loss | 0% < loss < 100% | 100% loss (unreachable) |
| Interface drops | zero drops during the observation window | any increase observed | — |
| GRE engine state | `ACTIVE` or `NONE` (no forwarding mappings configured) | `PARTIAL`/`DRIFTED` (recoverable via repair) | `CONFLICT`/`MISSING` while mappings exist |
| Tunnel interface state | `UP` | `DOWN`/`CONFIGURED`/`DRIFTED` | `MISSING`/`CONFLICT` |

An aggregate rolls up as `FAIL` > `WARN` > `UNKNOWN` > `PASS`, but every
individual observation is still printed — the aggregate never hides a
specific failing check.

## Known limitation: `tixolink create`/`tixolink edit` require a TTY

Both commands are interactive wizards (`lib/menu.sh:menu::wizard_create_tunnel`/
`menu::wizard_edit_tunnel`) and refuse to run without one
(`cli::main` returns `EXIT_USAGE` for `create`/`edit` outside a TTY).
This was an accepted Phase 3 scope boundary, not an oversight, but it
blocks fully-scripted provisioning.

**Concrete plan for flag-driven non-interactive create/edit** (deferred to
the Phase 7 CLI-completeness audit rather than squeezed into Phase 6,
since Phase 6 is lifecycle-scoped and this is unrelated surface area):

1. Add `tunnel::create_from_fields`/`tunnel::edit_from_fields` callers
   directly to `lib/cli.sh`'s `create`/`edit` branches when `! -t 0`,
   parsing the same fields the wizard collects (`--name`, `--local-ip`,
   `--remote-ip`, `--mtu`, `--ttl`, `--subnet`/`--inner-local`/
   `--inner-remote` for manual addressing, defaulting to automatic
   allocation otherwise) instead of calling `menu::wizard_*`. Both
   `tunnel::create_from_fields` and `tunnel::edit_from_fields` already
   exist and already do all real validation/transaction work — the
   wizard is a thin interactive collector in front of them, so this is
   additive, not a rewrite.
2. Add the equivalent flags to `cli::cmd_forward add`/`edit` are already
   fully flag-driven today (no TTY requirement) — only tunnel create/edit
   lack this, since those two commands currently only expose the wizard
   path.
3. Reuse `lib/validation.sh`'s existing pure validators for every new
   flag; no new validation logic needed.
4. Required test additions: `tests/unit/test_cli.sh` cases for each new
   flag combination (missing required flag, invalid value per
   validator, successful non-interactive create matching the wizard's
   own output for equivalent input) and one integration test
   (`tests/integration/test_gre_netns.sh` already covers the
   `tunnel::create_from_fields` path directly — extend it to also invoke
   through `cli::main` non-interactively instead of only calling the
   module function, to catch any CLI-layer regression).
5. Estimated size: small (the module-layer functions already exist and
   are already tested; this is argument parsing plus flag documentation
   in `cli::usage` and new CLI-layer tests) — hence "small, safe, and
   well-tested" per the Phase 6 instructions would normally argue for
   doing it now. It is deferred anyway because Phase 6's actual scope
   (lifecycle) is already substantial, and bundling unrelated CLI surface
   into the same phase makes the lifecycle work harder to review in
   isolation.

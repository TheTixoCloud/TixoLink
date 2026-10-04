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

## Non-interactive `tixolink create`/`tixolink edit` (resolved in Phase 7)

Through Phase 6, both commands were wizard-only
(`lib/menu.sh:menu::wizard_create_tunnel`/`menu::wizard_edit_tunnel`) and
refused to run without a TTY. As of Phase 7, `cli::cmd_create`/
`cli::cmd_edit` (`lib/cli.sh`) add a flag-driven path that calls the exact
same `tunnel::create_from_fields`/`tunnel::edit_from_fields` validation
and transaction functions the wizard always called — no business logic
was duplicated.

- **Create**: `tixolink create --name N --local-ip IP --remote-ip IP
  [--mtu M] [--ttl T] [--inner-subnet CIDR --inner-local IP --inner-remote
  IP]`. Giving zero create-specific flags on a TTY still launches the
  wizard unchanged; giving any flag (or running without a TTY) takes the
  non-interactive path instead. Missing `--name`/`--local-ip`/
  `--remote-ip` is a usage error (`EXIT_USAGE`); an invalid value is a
  validation error (`EXIT_VALIDATION`) from the same pure validators
  (`lib/validation.sh`) the wizard uses. `--inner-subnet`/`--inner-local`/
  `--inner-remote` must all be given together (manual addressing) or all
  omitted (automatic `/30` allocation) — giving only some is a usage
  error, not a silently-ignored partial request.
- **Edit**: `tixolink edit <id-or-name> [--local-ip IP] [--remote-ip IP]
  [--mtu M] [--ttl T] --force` (or `--dry-run` to preview without
  `--force`). A flag you omit is resolved from the tunnel's **current**
  config before the call — omitting a flag always means "leave this
  field exactly as it is," never "reset it to a default." Without
  `--force` (and without `--dry-run`), a flag-driven edit is refused with
  a usage error describing exactly that, before touching anything.
- Tests: `tests/integration/test_cli_tunnel_flags.sh` (27 checks) proves
  the required-flag/validation errors, that `--dry-run` writes nothing,
  that omitting `--force` changes nothing, that a single-field edit
  changes only that field (checked against a real GRE interface in an
  isolated network namespace), and that two successive single-field edits
  each preserve everything the other one set.

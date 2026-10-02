# Troubleshooting

This document will hold diagnostic criteria (the documented PASS/WARN/FAIL
thresholds referenced by `modules/diagnostics.sh`) and common failure
scenarios once that module exists (Phase 5).

## Foundation-layer checks

If `tixolink` fails to start from a development checkout:

- Confirm you are running `bin/tixolink` from inside the repository (or
  have set `TIXOLINK_LIB_DIR` explicitly) — the launcher resolves the
  library directory relative to its own location.
- Confirm `jq` is installed (`lib/config.sh` and `lib/state.sh` require it
  for all reads/writes).
- Run with `--debug` for verbose terminal logging.

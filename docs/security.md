# Security Model

TixoLink NEXUS runs as root. Every input — CLI arguments, interactive
prompts, imported peer tokens, configuration files, backup archives — is
treated as untrusted.

## Enforced now (foundation layer)

- No `eval`, anywhere. No `bash -c` with a user-controlled string.
- All validated input types (IPv4, CIDR, port/port-range, protocol, MTU,
  TTL, interface name, tunnel name, tunnel ID) go through pure functions in
  `lib/validation.sh` before being used anywhere else.
- `validate::path_within` resolves a path with `realpath` and confirms it
  is actually inside an expected root, as a defense against symlink-based
  path escapes, for any future file-path input (backup restore, peer
  import).
- Configuration is always structured JSON, validated with `jq`, written via
  temp-file-then-atomic-rename (`lib/config.sh:config::write_json_atomic`).
  Never `source`d, never `eval`'d.
- Temp files are created with `mktemp` inside a TixoLink-owned directory,
  mode `0600`, and registered for cleanup on exit/interrupt
  (`lib/common.sh:common::mktemp_file`).
- State-changing operations acquire a named `flock` before touching shared
  resources (`lib/locking.sh`), preventing concurrent TixoLink invocations
  from racing each other.

## Peer, backup, and release-artifact data (implemented)

- Peer export/import documents (`modules/peer.sh`) are plain JSON,
  schema-validated, always displayed in full before any confirmation
  prompt — no field is applied without being shown. They carry
  configuration data only; never passwords, SSH credentials, API keys, or
  private keys.
- Command construction for `ip`/`iptables`/`nft`/`systemctl` uses Bash
  arrays throughout the engine/forwarder layers, never string
  concatenation handed to a shell.
- Backup archives (`modules/backup.sh`) contain only TixoLink's own
  config/tunnel/state/optimizer-baseline documents — never host secrets,
  environment variables, or unrelated files — and are checksummed
  (SHA256) but not cryptographically signed; see
  [docs/lifecycle.md](lifecycle.md) for exactly what integrity guarantee
  that does and does not provide.
- Release artifacts (`modules/update.sh`) are verified against a
  published SHA256 checksum manifest before extraction; this verifies
  integrity against what the release published, not that the release
  channel itself is uncompromised. Signature verification is a documented
  future slot (see `docs/lifecycle.md`'s updater trust-model section), not
  implemented in this build.

## Lifecycle (install/uninstall/restore/update/factory-reset) hardening

- Untrusted archives (backup restore, update artifacts) are never
  extracted directly over `/`: `common::tar_extract_safely` inspects every
  member first (no absolute paths, no `..` segments, no symlink/hardlink/
  device/fifo/socket entries, no duplicate member paths) and only
  extracts into a private `0700` staging directory.
- The same function bounds every such archive's compressed size, entry
  count, per-file size, and total declared uncompressed size against
  centralized constants, checked entirely from `tar`'s own metadata
  before any extraction — see `docs/lifecycle.md`'s "Archive resource
  limits" section for the exact values and rationale.
- Every recursive directory deletion in `install.sh`/`uninstall.sh`/
  `modules/lifecycle.sh` goes through `common::assert_safe_delete_path`/
  `common::safe_rm_rf`, which refuses to operate on a handful of real
  filesystem roots or any path whose final component isn't literally
  `tixolink` — a misconfigured path override fails loudly instead of
  deleting something unintended.
- Destructive non-interactive operations (`uninstall.sh --purge`,
  `factory-reset`) require an explicit, hard-to-trigger-by-accident flag
  (`--confirm-purge`, `--force`) in addition to the base operation flag;
  interactively, purge additionally requires typing the literal word
  `PURGE`.
- The updater never runs `git pull`/tracks a branch HEAD, and never pipes
  a remote download directly into a shell (`curl | bash`); downloaded
  artifacts are verified, extracted locally, and then run as a local
  script (`install.sh`) from disk.

## Vulnerability reporting

See [SECURITY.md](../SECURITY.md).

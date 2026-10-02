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

## Planned (later phases)

- Peer export/import tokens: base64url-encoded JSON, decoded and schema-
  validated, always displayed in full before any confirmation prompt — no
  field is applied without being shown. Tokens carry configuration data
  only; never passwords, SSH credentials, API keys, or private keys.
- Command construction for `ip`/`iptables`/`nft`/`systemctl` always uses
  Bash arrays, never string concatenation, once the engine/forwarder layers
  exist.
- Release artifact verification (SHA256 now; signature verification is a
  documented future slot in the updater).

## Vulnerability reporting

See [SECURITY.md](../SECURITY.md).

# TixoLink NEXUS

Linux tunnel management suite, by TheTixoCloud.

> **Status: early development (`0.1.0-dev`).** The foundation layer
> (libraries, CLI/menu scaffolding, logging, validation, configuration,
> locking) is implemented. Tunnel engines, forwarding, diagnostics,
> optimizer, dashboard, and installer are not implemented yet — see
> [CHANGELOG.md](CHANGELOG.md) for what currently exists.

## What this is

TixoLink NEXUS manages Linux kernel tunnels (starting with GRE over IPv4)
between a local server and a remote peer, and optionally forwards public
ports through the tunnel to a backend service. The common case is an entry
server receiving internet traffic and a remote exit server running the
actual service, connected by a GRE tunnel — but TixoLink makes no
assumption about geography or roles; it is a generic local↔remote peer tool.

A single server can run many independent tunnels at once, each fully
isolated and independently manageable.

## Why GRE, and what it is not

GRE (IP protocol 47) is a simple, kernel-native Linux tunneling mechanism.
**GRE does not provide encryption or authentication.** Traffic inside a GRE
tunnel is only as confidential as the underlying path — treat it the same
as any other unencrypted transport. If you need confidentiality, add an
encryption layer (e.g. WireGuard, IPsec, TLS) independently; TixoLink does
not claim to provide this and will not market GRE as a VPN. Some networks
filter protocol 47 — plan accordingly.

The transport layer is designed to be pluggable: GRE over IPv4 is the only
engine implemented in the initial release, but the application is not
architected around GRE specifically. Future engines (IP6GRE, IPIP, SIT, …)
are expected to plug into the same internal interface without an
application rewrite.

## Supported systems

- Ubuntu 22.04 LTS
- Ubuntu 24.04 LTS
- Debian 12
- Architecture: amd64/x86_64 initially; the codebase avoids amd64-only
  assumptions where practical, to leave room for future arm64 support.

## Architecture

See [docs/architecture.md](docs/architecture.md) for the full module
breakdown, transport/forwarding plugin contracts, configuration schema,
and transaction model. In short:

- **Bash**, strict mode, no monolithic script — a library layer
  (`lib/`), pluggable transport engines (`engines/`), pluggable
  forwarding engines (`forwarders/`), and orchestration modules
  (`modules/`).
- **Configuration is structured JSON**, validated with `jq`, written
  atomically. Never `source`d, never `eval`'d.
- **Transactional state changes**: precheck → backup → plan → apply →
  verify → commit, with rollback on failure, for every operation that
  touches production state.
- **Firewall and HAProxy ownership is explicit and scoped** — TixoLink
  never flushes a shared chain or overwrites an administrator's
  configuration; see [docs/firewall.md](docs/firewall.md).

## Installation

Not available yet — the installer (`install.sh`) is implemented in a
later development phase. This repository is currently for development use
from a checkout (`bin/tixolink`), not for production installation.

## Security notice

GRE provides no encryption. TixoLink runs as root and treats all input as
untrusted; see [docs/security.md](docs/security.md) and
[SECURITY.md](SECURITY.md) for the security model and vulnerability
reporting process.

## License

Apache License 2.0 — see [LICENSE](LICENSE).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

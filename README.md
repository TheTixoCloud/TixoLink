# TixoLink NEXUS

Linux tunnel management suite, by TheTixoCloud.

> **Status: release candidate (`1.0.0-rc1`).** The foundation layer, the
> GRE transport engine, Netfilter/HAProxy forwarding, diagnostics,
> benchmarking, live monitoring, the network optimizer/BBR manager, the
> non-interactive CLI, and the install/backup/restore/update/uninstall
> lifecycle are all implemented and covered by unit and namespace-based
> integration tests. This is a **release candidate**, not a declaration of
> production stability — it has not yet had a tagged public release, and
> CLI flags or the on-disk schema may still change before `1.0.0`. See
> [CHANGELOG.md](CHANGELOG.md) for the detailed history.

## What this is

TixoLink NEXUS manages Linux kernel tunnels (currently GRE over IPv4)
between a local server and a remote peer, and optionally forwards public
ports through the tunnel to a backend service. The common case is an entry
server receiving internet traffic and a remote exit server running the
actual service, connected by a GRE tunnel — but TixoLink makes no
assumption about geography or roles; it is a generic local↔remote peer tool.

A single server can run many independent tunnels at once, each fully
isolated and independently manageable.

## Why GRE, and what it is not

GRE (IP protocol 47) is a simple, kernel-native Linux tunneling mechanism.
**GRE DOES NOT PROVIDE ENCRYPTION.** Traffic inside a GRE tunnel is only as
confidential as the underlying path — treat it the same as any other
unencrypted transport. If you need confidentiality, add an encryption
layer (e.g. WireGuard, IPsec, TLS) independently; TixoLink does not claim
to provide this and will not market GRE as a VPN. Some networks filter
protocol 47 — plan accordingly.

The transport layer is pluggable through `engines/engine_api.sh`: GRE over
IPv4 (`engines/gre.sh`) is the only engine implemented so far, but nothing
in the application is architected around GRE specifically. Future engines
(IP6GRE, IPIP, SIT, …) are expected to plug into the same dispatch
interface without an application rewrite.

## What's implemented

- **GRE IPv4 tunnels** — create/start/stop/restart/reload/edit/delete,
  automatic `/30` inner-subnet allocation (configurable pool, default
  `10.200.0.0/16`), interface ownership checks, conflict detection,
  transactional rollback, and a systemd template (`tixolink@.service`)
  that reads each tunnel's config by its immutable ID at service-start
  time — never a stale value baked into a generated unit.
- **Peer export/import** — a signed-nothing, reviewed-before-applied JSON
  document (`tixolink peer export|import`) that lets the far side
  configure its half of a tunnel without either party emailing raw IPs
  around by hand. Contains configuration only, never credentials.
- **Port forwarding**, pluggable the same way as transport engines
  (`forwarders/forwarder_api.sh`):
  - **Netfilter** (`forwarders/netfilter.sh`) — TCP and UDP, dedicated
    `TIXOLINK-FWD`/`TIXOLINK-DNAT`/`TIXOLINK-SNAT` chains, one idempotent
    jump rule per built-in chain, every rule tagged
    `--comment "tixolink:<tunnel-id>"`, NAT or source-preserving mode.
  - **HAProxy** (`forwarders/haproxy.sh`) — **TCP only** (no UDP; HAProxy
    itself doesn't forward UDP in this configuration), explicit ownership
    of only the stanzas TixoLink writes, full candidate-config validation
    before any reload, change detection so an unchanged config never
    triggers a reload, graceful reload only when needed, rollback on
    validation failure.
  - Forwarding can be migrated between engines (`tixolink forward migrate`)
    without losing the mapping's logical definition.
- **Diagnostics** (`tixolink diagnostics`) — read-only system and
  per-tunnel checks: health model, latency/loss, MTU/PMTU, forwarding
  state, and a privacy-aware redacted support-report archive
  (`diagnostics report --privacy`).
- **Benchmark** (`tixolink benchmark`) — latency/loss against both the
  public and inner peer addresses, plus an opt-in `iperf3` throughput test
  against a server you already control. Never launches its own iperf3
  server; never runs without being asked.
- **Monitor** (`tixolink monitor`) — a live, read-only interface-rate
  dashboard.
- **Network optimizer** (`tixolink optimize`) — INSPECT → RECOMMEND →
  PREVIEW → explicit APPLY → VERIFY → RESTORE over a deliberately small,
  documented registry of sysctls (see `modules/optimizer.sh`), owning
  exactly one file (`/etc/sysctl.d/99-tixolink.conf`). The administrator's
  original value for any tunable TixoLink ever changes is recorded once,
  on first touch, and is always what `optimize restore` returns to —
  never an intermediate value.
- **BBR manager** (`tixolink bbr`) — a thin, same-machinery layer on top
  of the optimizer for `net.ipv4.tcp_congestion_control`. Verifies the
  running kernel actually exposes `bbr` before offering to enable it, and
  never claims ownership of BBR if it was already the host's active
  congestion control.
- **Lifecycle**: an installer (`install.sh`), uninstaller (`uninstall.sh`,
  with a separate explicit `--purge` mode), `tixolink backup`/`restore`,
  `tixolink update check`/`update apply` against GitHub Releases, and
  `tixolink factory-reset`. See [docs/lifecycle.md](docs/lifecycle.md) for
  the full model — install/backup/restore/update all follow the same
  PRECHECK → BACKUP → STAGE/PLAN → VALIDATE → ACTIVATE/APPLY → VERIFY →
  COMMIT pattern, with rollback on failure.

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
  touches production state — tunnels, forwarding, the optimizer, and the
  install/backup/restore/update lifecycle alike.
- **Firewall and HAProxy ownership is explicit and scoped** — TixoLink
  never flushes a shared chain or overwrites an administrator's
  configuration; see [docs/firewall.md](docs/firewall.md).

## Installation

```
git clone https://github.com/TheTixoCloud/TixoLink.git
cd TixoLink
sudo ./install.sh          # shows a plan and asks for confirmation
```

This installs to `/usr/local/bin/tixolink`, `/usr/local/lib/tixolink/`,
and the `tixolink@.service` systemd template, and creates
`/etc/tixolink/` and `/var/lib/tixolink/` with defaults **if they don't
already exist** — an existing configuration from a prior install is never
overwritten. No tunnel is started automatically by installing. Running
from a development checkout (`bin/tixolink`) continues to work without
installing anything. See [docs/lifecycle.md](docs/lifecycle.md) for
upgrade, backup/restore, update, uninstall, and factory-reset details, and
for the sandboxed (`TIXOLINK_ROOT`) testing mechanism.

## Security notice

GRE provides no encryption. TixoLink runs as root and treats all input as
untrusted; see [docs/security.md](docs/security.md) and
[SECURITY.md](SECURITY.md) for the security model and vulnerability
reporting process.

## License

Apache License 2.0 — see [LICENSE](LICENSE).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

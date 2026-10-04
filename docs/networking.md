# Networking Notes

## GRE security notice

GRE (IP protocol 47) provides **no encryption and no authentication**.
Anyone able to observe or intercept traffic on the path between the two
tunnel endpoints can read and potentially manipulate it, exactly as with
any other unencrypted IP traffic. Do not treat a GRE tunnel as a VPN or as
a confidentiality boundary. Some networks and providers filter protocol 47
entirely, which will prevent GRE from working regardless of correct
configuration.

## GRE engine (`engines/gre.sh`)

- One GRE interface per tunnel, named `tixo-<id>` where `<id>` is the
  tunnel's immutable 8-hex-character ID — never derived from a mutable
  display name.
- Interface ownership is checked (not assumed) before every mutating
  operation: `engine_gre_delete`/`engine_gre_stop` first confirm the
  interface, if it exists, actually matches this tunnel's expected
  (local, remote, inner) tuple; a mismatch returns `EXIT_CONFLICT` rather
  than touching an interface TixoLink doesn't recognize as its own.
- `create`/`start`/`reload` are the same idempotent "ensure correct and
  up" operation; `stop` sets the link administratively down but preserves
  it and its addresses, so bringing it back up is cheap; `delete` treats
  a missing interface as already-deleted, not an error.
- Endpoint changes (local/remote public IP) are creation-time-only GRE
  parameters, so editing them deletes and recreates the interface inside
  a transaction (`lib/transaction.sh`) — a failure recreating it rolls
  back to the pre-edit interface rather than leaving the tunnel half-torn-
  down.

## Inner addressing

- Automatic inner-subnet allocation pool: `10.200.0.0/16` by default,
  configurable via the app config's `subnet_pool`. Each tunnel gets its
  own `/30` out of that pool (`lib/subnet.sh`), with collision detection
  against every other configured tunnel before a `/30` is handed out.
  Manual addressing is also available (see `tixolink create`'s wizard).
- MTU/TTL are per-tunnel, validated (`validate::mtu`/`validate::ttl`) at
  the GRE-over-IPv4 practical range. GRE encapsulation overhead (24 bytes
  for a plain GRE/IPv4 header) is the administrator's responsibility to
  account for when setting MTU relative to the physical path's MTU;
  `tixolink diagnostics tunnel <id>` reports MTU/PMTU findings.
- `rp_filter` is never disabled globally by TixoLink. Source-preserving
  forwarding mode (below) depends on routing being set up correctly on
  the backend side; TixoLink does not attempt to patch `rp_filter` on its
  own behalf.

## Port forwarding: NAT vs. source-preserving

Both `forwarders/netfilter.sh` mapping modes are available per-mapping:

- **NAT/MASQUERADE mode** (default) — the forwarded connection's source
  address is rewritten to the tunnel's inner local address before it
  reaches the backend. Works with no routing changes on the backend side.
  The backend sees the entry server as the client, not the original
  internet client.
- **Source-preserving mode** — the original client's source address is
  preserved end-to-end. This requires the backend to route the original
  client's subnet back through its own tunnel interface (asymmetric
  routing otherwise drops the return path); TixoLink does not configure
  that backend-side routing for you — see the wizard's in-place warning
  when this mode is selected.

See [docs/firewall.md](firewall.md) for how the underlying netfilter
rules are scoped and owned, and [docs/lifecycle.md](lifecycle.md) for how
forwarding is torn down during `factory-reset`/`uninstall --purge`.

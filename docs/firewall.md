# Firewall Ownership Model

This document describes how the netfilter forwarder (`forwarders/
netfilter.sh`) owns and scopes its rules, as actually implemented.

## Absolute rule

TixoLink never flushes a shared chain (`iptables -F`, `iptables -t nat -F`,
`nft flush ruleset`) and never removes a rule it did not create itself.

## Mechanism (implemented)

- All TixoLink rules live in three dedicated chains: `TIXOLINK-DNAT`
  (jumped from `nat PREROUTING`), `TIXOLINK-FWD` (jumped from `filter
  FORWARD`), `TIXOLINK-SNAT` (jumped from `nat POSTROUTING`, only used by
  NAT-mode mappings).
- Exactly one idempotent jump rule per built-in chain
  (`netfilter::_ensure_chain_and_hook`) is the only thing TixoLink adds
  outside its own chains; the jump itself is also tagged
  (`--comment "tixolink:hook:<chain>"`) and its presence is recorded in
  `state.json` so a later removal only ever removes a jump TixoLink
  itself created.
- Every TixoLink-created rule carries a `-m comment --comment
  "tixolink:<tunnel-id>"` tag (or a mapping-scoped variant). Removing a
  mapping or a tunnel's forwarding removes only that tag's rules,
  individually, by rule specification — never a chain flush
  (`netfilter::_wipe_mapping_rules`).
- The active iptables backend (`nf_tables` vs. `legacy`, see
  `platform::iptables_backend`) is detected and logged, not assumed.
- Presence of UFW, Docker, Podman, or a pre-existing nftables ruleset is
  detected (`lib/platform.sh`) and surfaced as a warning where it could
  interact with TixoLink's chains — TixoLink does not attempt to silently
  patch around another firewall manager.

## HAProxy forwarder (`forwarders/haproxy.sh`)

HAProxy forwarding is a separate, non-destructive integration with the
same ownership discipline, for **TCP only** (HAProxy in this
configuration does not forward UDP — use the netfilter forwarder for
UDP mappings):

- TixoLink owns only the `frontend`/`backend` stanzas it writes into the
  managed config, each tagged with a comment identifying the owning
  tunnel/mapping; it never touches stanzas it didn't write.
- Every change is built as a full **candidate configuration**, validated
  (`haproxy -c -f`) before anything is written to the real config file.
- **Change detection**: if the candidate config is byte-for-byte
  equivalent to the live config after normalization, no reload happens —
  an unchanged mapping set never bounces a running HAProxy.
- A **graceful reload** (`systemctl reload haproxy`, never `restart`)
  only happens when the candidate actually differs and validated
  successfully.
- Any validation failure aborts before the real config file is touched;
  the previous config is never left in an intermediate state.
- TixoLink never steals an existing bind/listener it didn't create itself
  — a port conflict with an administrator's own HAProxy config is
  detected and reported (`EXIT_CONFLICT`), not silently overridden.

## Teardown

`tixolink forward remove`, `tixolink delete` on a tunnel's forwarding,
`tixolink factory-reset`, and `uninstall.sh --purge` all remove owned
forwarding through this same idempotent per-mapping removal path (see
[docs/lifecycle.md](lifecycle.md)) — there is no separate "flush
everything" code path anywhere in the forwarding layer.

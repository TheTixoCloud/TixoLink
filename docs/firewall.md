# Firewall Ownership Model

This document describes how TixoLink will own and scope its firewall
rules once the netfilter forwarder (Phase 4) is implemented. Recorded now
so the model is fixed before any rule-writing code exists.

## Absolute rule

TixoLink never flushes a shared chain (`iptables -F`, `iptables -t nat -F`,
`nft flush ruleset`) and never removes a rule it did not create itself.

## Planned mechanism

- All TixoLink rules live in dedicated chains: `TIXOLINK-FWD` (jumped from
  `FORWARD`), `TIXOLINK-DNAT` (jumped from `nat PREROUTING`),
  `TIXOLINK-SNAT` (jumped from `nat POSTROUTING`).
- Exactly one idempotent jump rule per built-in chain is the only thing
  TixoLink adds outside its own chains.
- Every TixoLink-created rule carries a `--comment "tixolink:<tunnel-id>"`
  tag; `state.json` additionally records a hash of each tunnel's expected
  ruleset for drift detection and repair.
- Deleting a tunnel's forwarding removes only that tunnel's tagged rules,
  individually, by handle — never a chain flush.
- The active iptables backend (`nf_tables` vs. `legacy`, see
  `platform::iptables_backend`) is detected and logged, not assumed.
- Presence of UFW, Docker, Podman, or a pre-existing nftables ruleset is
  detected and surfaced as a warning where it could interact with
  TixoLink's chains (e.g. UFW's own forward-chain policy) — TixoLink does
  not attempt to silently patch around another firewall manager.

This mechanism is not yet implemented; `lib/platform.sh` currently only
detects the backend and tool presence (read-only).

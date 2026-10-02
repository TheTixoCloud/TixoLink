# Networking Notes

This document will accumulate GRE/MTU/routing/NAT specifics as the GRE
engine (Phase 3) and forwarding engines (Phase 4) are implemented.

## GRE security notice

GRE (IP protocol 47) provides **no encryption and no authentication**.
Anyone able to observe or intercept traffic on the path between the two
tunnel endpoints can read and potentially manipulate it, exactly as with
any other unencrypted IP traffic. Do not treat a GRE tunnel as a VPN or as
a confidentiality boundary. Some networks and providers filter protocol 47
entirely, which will prevent GRE from working regardless of correct
configuration.

## Planned topics (filled in during Phase 3/4)

- GRE encapsulation overhead and its effect on MTU/PMTU.
- The distinction between physical interface MTU, GRE interface MTU, and
  TCP MSS.
- `rp_filter` and asymmetric routing: TixoLink does not disable `rp_filter`
  globally; any adjustment is scoped as narrowly as possible and only ever
  applied deliberately, documented here when implemented.
- NAT mode vs. source-preserving mode for port forwarding, and the routing
  prerequisites source-preservation actually depends on.
- Automatic inner-subnet allocation pool (`10.200.0.0/16` by default,
  configurable) and the collision-detection algorithm used before handing
  out a `/30`.

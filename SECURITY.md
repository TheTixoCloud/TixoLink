# Security Policy

TixoLink NEXUS runs as root and manages networking, firewall, and tunnel
state on Linux servers. Security issues are taken seriously.

## Reporting a vulnerability

Please report suspected security vulnerabilities privately using
**GitHub's private vulnerability reporting** feature on this repository
(Security tab → "Report a vulnerability" → opens a private GitHub Security
Advisory draft visible only to you and the maintainers), once the
repository is published.

Do not open a public GitHub issue for a suspected vulnerability.

This is the reporting mechanism for now. It is intentionally kept simple so
it can be replaced with a dedicated security contact address later without
requiring changes anywhere else in the project — if TheTixoCloud establishes
a dedicated security contact, this document will be updated to reference it
directly.

## Scope

In scope: the TixoLink NEXUS codebase itself (libraries, engines,
forwarders, modules, installer, updater) and its default configuration
behavior.

Out of scope: vulnerabilities in third-party software TixoLink integrates
with (the Linux kernel, iproute2, iptables/nftables, HAProxy, etc.) — please
report those upstream to the relevant project.

## What to include

- A description of the issue and its potential impact.
- Steps to reproduce, including the OS/kernel version if relevant.
- Whether the issue requires local access, root, or is remotely triggerable.

## Response

As an early-stage open-source project, there is no formal SLA yet. Reports
will be acknowledged and triaged as soon as practical.

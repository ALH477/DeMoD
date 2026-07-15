# Security Policy

## Supported versions

This project is pre-1.0 and under active development; security fixes land on
`main`. Pin a commit if you need stability.

## Reporting a vulnerability

Please **do not** open a public issue for security problems. Email
**alh477@proton.me** with a description, reproduction steps, and impact. You'll get
an acknowledgement, and we'll coordinate a fix and disclosure timeline with you.

Scope note: this repository contains the framework, audio stack, Quanta codec, and the
TERMINUS application layer (`apps/terminus/`). TERMINUS includes stub implementations of
product-level features (integrity checks, Steam, patches) — these are no-op stubs in the
public repo, not live entitlement/marketplace infrastructure. Sibling repos (ArchibaldOS,
Oligarchy, HydraMesh, DeMoD Voice) are separate GitHub repositories.

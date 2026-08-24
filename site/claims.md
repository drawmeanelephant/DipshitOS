---
title: Claims & evidence philosophy
parent: evidence
status: published
tags: [evidence, claims]
---

# Claims & evidence philosophy

The repository runs on **claims**: a claim is a filed unit of work with an id,
a scope, and a gate, and it only flips to observed when the gate passes.

## How a claim works

1. A claim file lands in `docs/claims/` (e.g. `docs/claims/6053-…`).
2. The work lands on a branch with host tests and, where hardware is involved,
   a class B gate.
3. Evidence is saved under `artifacts/` (gitignored — no evidence, no
   "observed").
4. The claim closes when the gate passes; the claim file records what was
   **observed** versus **inferred**.

The canonical index is
[`docs/claims/README.md`](https://github.com/drawmeanelephant/DipshitOS/blob/main/docs/claims/README.md),
regenerated on main after every merge by
`.github/workflows/indexes.yml`; branches never commit table churn, and
the coordination gate checks table structure (not drift) on pull requests.

## Why this matters to you

When a page here says a feature is **live-gated**, that is a pointer to a
named claim and a named gate — not marketing. You can:

- read the claim to see the exact scope and honest bounds;
- run the gate on Apple silicon to reproduce it;
- read the saved evidence to see the actual serial report or capture.

## Observed vs inferred

A hardware fact is `[observed]` only when a matching probe or log exists.
Examples from the hardware contract:

- `[observed]` the entropy device resets at `ExitBootServices`.
- `[observed]` the XHCI controller does not reset there.
- `[observed]` the NAT gateway answers ARP and ICMP but serves no DHCP.

Everything else stays `[inferred]` until proven. The documentation does not
upgrade claims by summarizing them — if it was unit-tested only, the page says
unit-tested only.

<Aside kind="info">

**CLAIM / EVIDENCE.** This is the receipt system that lets the public site be
a trustworthy index into the project's actual state rather than vapor.

</Aside>

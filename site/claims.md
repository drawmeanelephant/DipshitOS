---
title: Claims & evidence philosophy
parent: evidence
status: published
tags: [evidence, claims]
---

# Claims & evidence philosophy

The repository runs on **claims**: a claim is a filed unit of work with a
scope and a gate, and it only flips to observed when the gate passes.
Claims are **GitHub issues labeled `claim`** on the project tracker — they
are not files in the repository (the old `docs/claims/` + `docs/logs/`
file system was deleted 2026-09-03).

## How a claim works

1. A claim issue is filed **before** work starts — one issue per piece of
   work, titled `claim: <title>`, with the owner branch and the files it
   will touch (`- **Touches:**`) in the body.
2. The work lands on a branch with host tests and, where hardware is
   involved, a class B gate.
3. Evidence is saved under `artifacts/` (gitignored — no evidence, no
   "observed").
4. Progress is commented on the issue; the claim **closes** (the issue
   closes, with a final evidence comment) when the gate passes, recording
   what was **observed** versus **inferred**.

Open claim issues are the canonical index:
`gh issue list --label claim --state open`. The coordination gate
(`bash tools/status/verify-issue-coordination.sh`, also CI) fetches the
open claims and fails when two of them from different branches declare
overlapping file touches (one editor per file), and warns when a claim
goes 14+ days without a comment or edit.

## Why this matters to you

When a page here says a feature is **live-gated**, that is a pointer to a
named claim and a named gate — not marketing. You can:

- open the claim issue to see the exact scope and honest bounds;
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

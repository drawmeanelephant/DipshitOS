# ADR 0034: TABWM.BIN is retained as the Zig fallback seat

- Status: ACCEPTED
- Date: 2026-09-19
- Issue: #1451 (this document) · milestone #1436 (M68) · card M68c · closes the
  `TABWM.BIN` row of M60's ledger (#1297)
- Related: ADR 0030 (Go is EL0 — the leftover policy this decides around),
  ADR 0033 (GOTABWM is the tabbed desktop), ADR 0015 (userland WM seat /
  slot 65), ADR 0007 (syscall ABI — untouched), M59 (#1298, the boot-default
  flip), M42 (#1011, the seat's last behaviour work)

> **Decide from strength: keep the Zig seat, permanently, as the
> `settings set wm tabwm` fallback.** No binary is deleted, no default moves,
> no code changes. This ADR is docs-only and it is the only M68 card allowed
> to touch the fallback question.

## Context

M60 (#1297) set the policy this card has to settle against: **no new Zig EL0
apps** (ADR 0030), and leftovers deleted **one binary per card** once the Go
successor is VZ-green. Three have gone that way: `EDIT.BIN` (M60/#1297),
`FILE.BIN` (#1374), `CALC.BIN` (M62h/#1406).

`TABWM.BIN` is not in the same position, for a reason that is in the compiled
contract rather than in anyone's preference:

- M59 (#1298) made the seat a **settings value**: `wm` is a schema-v2 key with
  three legal values — `gotabwm` (the compiled default), `tabwm`, and `none`
  (the explicit shim-only VM). `kernel/src/settings.zig` declares
  `WmSeat { gotabwm, tabwm, none }` and documents `tabwm` as *the Zig seat*.
- ADR 0030 **D4** already records the intent: "the compiled `wm` default is
  `gotabwm` … `settings set wm tabwm` keeps the Zig seat, and
  `settings set wm none` is the explicit shim-only VM the pre-M59 fleet
  assumed."
- The fallback is not a promise on paper: `go-wm-default` boots it and asserts
  the seat's **own** markers (`wm: autostart tabwm (settings wm=tabwm)`,
  `tabwm: registered`, `tabwm: sidebar-rendered`, `tabwm: registered pid=`),
  alongside the default-seat boot and the M66b corrupt-settings runs.

## Decision

**D1. `TABWM.BIN` stays — permanently, by decision.** It is the Zig seat, not
an M60 leftover awaiting a delete. M60's ledger closes its `TABWM` row as
**RETAINED**.

**D2. The retention is a contract.** `wm=tabwm` remains a legal schema-v2
value, documented in the settings header, and must stay **exercised**: any
change to the seat matrix has to keep `go-wm-default`'s fallback boot green or
replace it with an equivalent proof. A seat value nobody boots is how a
fallback silently rots.

**D3. Nothing else moves here.** No boot-default change (M59 settled it), no
new Zig EL0 development in the seat (ADR 0030 stands — TABWM is frozen at
bug-fix only), and no decision about any other binary (M68's non-goals).

**D4. Why not delete it — the evidence, not a preference.**

- **The delete is a schema change, not a file removal.** `tabwm` is compiled
  into the `wm` key's value set. Deleting the binary means either a dangling
  setting (a share carrying `wm=tabwm` boots toward a file that no longer
  exists) or schema **v3** plus a migration story for shares already writing
  v2. That migration is the expensive-to-reverse part, and it buys no
  capability.
- **Twelve specs name `TABWM.BIN`, and they are two different things.** Four
  are the seat's own behaviour gates (`live-tabwm`, `live-tabwm-bt`,
  `live-tabwm-close`, `live-tabwm-fullscreen`); eight are Go-app gates that
  merely need *a* seat to host their app (`go-calc`, `go-r3d`, `go-edit`,
  `go-files`, `go-tabapp`, `go-selftest`, `go-term`, `go-sh`). Deleting
  retires the first four and re-hosts the other eight — real work, real risk,
  no new capability.

  Eleven of the twelve are on `main` today: the eighth hosted gate, `go-sh`
  (M68a #1449), names `TABWM.BIN` only on PR #1493, which is still open. If
  that spec loses the reference before it lands, the count is eleven and
  nothing in this decision changes — the split is still four retiring and
  seven re-hosting, and the cost asymmetry below is unaffected.
- **It would leave the desktop with one implementation.** The Go seat is the
  default; the Zig seat is the only other renderer that has ever held slot 65.
  Keeping a frozen second seat is cheap. Rediscovering one after deleting it
  is not.
- **Cost asymmetry decides it.** Keeping costs a frozen `user/src/tabwm.zig`
  and one already-green gate run. Deleting costs a schema migration, four
  coverage retirements or retargets, and eight spec re-hosts.

## Consequences

- **M60's ledger now reads:** deleted `EDIT`/`FILE`/`CALC`; **retained
  `TABWM`** (this ADR); still open — `SH.BIN` (#1450, M68b: GOSH has no serial
  front-end, no `whoami`/`id`/`secrets`, no `net`, and not the M19 scripting
  depth `live-sh5` asserts) and `NOTEPAD.BIN` (#1485, M66c-followup: five
  feature specs still need a home). **M60 closes when those two rows settle** —
  which is why #1451's "close M60" half is deferred rather than declared done.
- The seat matrix is final unless a later ADR supersedes this one:
  `gotabwm` (default) | `tabwm` (Zig fallback, frozen) | `none` (shim-only).
- Revisiting this requires all of: a schema change with a `wm=tabwm`
  migration, a home (or an explicit coverage-loss note) for the four
  `live-tabwm-*` gates, and a re-host of the eight Go-app specs.

## Not decided here

- The boot default (M59, #1298, settled).
- `SSH.BIN` / TLS helper fates — their own cards, outside M68.
- Whether GOTABWM ever needs a non-Go fallback for a reason *other* than "the
  Zig seat already exists". That would be a future ADR, from evidence.

## Evidence

Observed on a main-based tree (`5d4d0038`, branch
`agent/buffy/m68c-tabwm-decide`, `dirty-files=0`), 2026-09-19:

```text
$ bash tools/go/build-gotabwm.sh && bash tools/go/build-gocalc.sh
build-gotabwm: wrote .build/go/GOTABWM.ELF (1245344 bytes)
build-gocalc:  wrote .build/go/GOCALC.ELF (1245344 bytes)

$ just gate go-wm-default
=== result ===
vgate go-wm-default: PASS (4/4 runs)
--- [1/1] PASS go-wm-default (111s)
FLEET RESULT: 1/1 PASS
```

Run 02 is the decision's load-bearing one — the persisted fallback boot — and
its asserts are the seat's own markers: `wm: autostart tabwm (settings
wm=tabwm)`, `tabwm: registered`, `tabwm: sidebar-rendered`, `tabwm: registered
pid=`, `rx-m59-fallback-ok`, with `[EXC] parking:` and `exited status=139`
absent. Runs 01/03/04 cover the compiled default, the corruption staging, and
the fail-closed-plus-heal path (M66b/#1444).

Spec: `tools/gate/specs/go-wm-default.spec`. The settings contract is
`kernel/src/settings.zig` (header lines 13–14, the `wm` row at 52, `wm_default`
at 77, `WmSeat` at 182–191).

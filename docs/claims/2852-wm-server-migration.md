# Claim: M32 window-manager server migration — ADR + roadmap

- **Owner:** buffy (`agent/buffy/docs-pass`)
- **Prompt / plan:** architecture analysis + decision (full userland WM migration, seam A) — see `docs/march-m32-wm-migration.md` and `docs/decisions/0015-window-server-render-seam.md`
- **Scope:** planning slice of M32 — the ADR (render seam, slot 65, kind 18) and the migration roadmap. Implementation claims follow per card.
- **Touches:** docs/decisions/0015-window-server-render-seam.md, docs/march-m32-wm-migration.md, docs/status.md, docs/logs/agent-buffy-docs-pass.md
- **Depends on:** none (post-M31 planning)
- **Heartbeat:** 2026-08-28
- **Status:** 🔄 agent/buffy/docs-pass

## Notes (2026-08-28 — issue scoping addendum)

The ten GitHub issues (#621–#630, milestone 16) were scoped from the card plan:
each body now carries a fixed template — Goal / Why this order (depends +
blocks) / In scope (checkboxes) / Out of scope / Acceptance (gate) / Risks /
Touches. Scoping additions beyond the draft, marked per-issue: WMS2 WM-death
teardown (kernel falls back to the shim when the registered WM exits), WMS3
bootstrap + hung-WM watchdog, WMS5 input-seam handover (the WM hit-tests; the
kernel only fans the stream out), WMS7 mailbox-size decision grounded in the
real 8×64 B mailbox bound, WMS9 prior art (slot 46 `sys_win_fill_batch`
already exists — measure it first, extend its payload, no new slot).
`docs/march-m32-wm-migration.md` carries the dependency-phases map; the
original planning notes below are unchanged.

### WMS1 acceptance proposal (folded in — canonical copy)

The WMS1 ready-to-apply proposal below was originally drafted as
`docs/m32-wms1-acceptance-proposal.md` (now deleted here and folded in so this
claim is the single canonical source on the milestone PR; the same content is
also posted as a comment on issue #621). It is the acceptance checklist + the
verbatim ADR text and encoding blocks the WMS1 implementation claim applies. No
code in WMS1.

> **What this is:** the concrete acceptance checklist for issue **#621 (WMS1 —
> ADR 0015 accepted + slot 65 reservation)**, with the verbatim ADR text and
> encoding tables the implementing claim applies. Everything below is grounded
> in verified anchors: ADR 0007's amendment format (slots 63/64 tail), the real
> `ErrorCode` enum (`kernel/src/syscall.zig:284`), the event-kind table
> (`kernel/src/events.zig`, kind 17 = `WIN_UNSAVED` highest), and the
> event-wire layout (ADR 0009 D1, 16-byte `Event`).

#### Checklist (the acceptance gate)

- [ ] **ADR 0015 status flip:** `docs/decisions/0015-window-server-render-seam.md`
      `PROPOSED — needs ack` → `ACCEPTED`, amendment log carries the WMS1 claim
      number and date.
- [ ] **ADR 0007 amendment appended** (verbatim block below) with the slot-65
      row, the subcommand encoding table, and the error-contract table.
- [ ] **ADR 0009 D2 table extended** with the kind-18 row (verbatim below) and
      a one-line note that kind 18 is delivered ONLY to the registered WM
      process (the routing note is the substantive change, not the row).
- [ ] **`kernel/src/events.zig` doc line only** (no handler): add
      `pub const COMPOSITE_TICK: u16 = 18;` with the ADR 0015 comment — the
      constant existing without a pusher is exactly the "reserved but not
      delivered" posture ADR 0013 codified. (If the WMS1 claim wants to stay
      100% docs-only, this one line may move to WMS2 instead — pick one and
      note it in the claim.)
- [ ] **ADR 0007 "not yet implemented" note:** until the WMS2 claim lands,
      slot 65 is **not registered in `dispatch_table`** — a call falls through
      `syscall.zig:444`'s `handler orelse` to `-ENOSYS` naturally; kind 18 is
      never pushed. State this explicitly in the amendment (the ADR 0013
      posture).
- [ ] **Cross-references updated:** `docs/march-m32-wm-migration.md` WMS1 row
      → ✅; `docs/status.md` M32 paragraph notes ADR 0015 accepted; ADR 0015's
      open-issues list marks the encoding item resolved.
- [ ] **`zig build` + `zig fmt --check` green** (the events.zig line, if
      taken, must compile; a doc-only variant must not touch code at all).
- [ ] **Existing gates untouched** — no gate behavior change; the 40+ gate
      scripts are non-interference evidence by not being modified.

#### Frozen decisions this checklist resolves (new — the draft left them open)

The ADR 0015 D2 sketch said "calls from any process other than the registered
WM return `EPERM`" — **`EPERM` does not exist in the kernel's frozen
`ErrorCode` enum** (`einval, ebadf, efault, enosys, enospc, enoent, eacces,
enametoolong, enxio, enomem` at `syscall.zig:285-296`). Adding a new errno
value to a frozen ABI is exactly the kind of drift ADR 0007 exists to prevent.
Decision: **`EACCES` (-7)** carries the WM-exclusive refusal (existing value,
correct semantics — "permission denied", and `sys_ping_send`'s seam already
uses `.eacces` for a caller-privilege refusal at `syscall.zig:590`). Three
more open points are frozen the same way:

1. **Seat taken:** a second `REGISTER` while a WM is registered → `EACCES`
   (same refusal class; the monitor can force-unregister via a new EL1h-only
   `wm unregister` subcommand when needed — EL1h bypasses the EL0 check, the
   `dui close` precedent).
2. **No GPU / unarmed compositor:** `REGISTER` with no gpu attached (default
   VM) → `ENXIO` (-9, the `sys_audio_play` honest no-device precedent).
3. **Tick cadence:** the kernel delivers `COMPOSITE_TICK` once per scheduler
   tick pass while a WM is registered (the same tick seam `app_timers` fires
   from); the WM paces presents against that cadence. Cadence tuning is
   WMS3's problem, not the ABI's — `arg0` (sequence) is what parity gates
   count.

#### Verbatim block 1 — ADR 0007 amendment (append at end of file)

```markdown
## Amendment (2026-08-XX, claim <NNNN> — the WMS1 render-server reservation)

Milestone 32 card WMS1 accepts ADR 0015 (window-server render seam) and
freezes slot 65 `sys_wmctl` — the WM server's exclusive control surface over
the kernel render server (following slot 64 `sys_munmap`; every existing
syscall number 0–64 stays frozen):

| 65 | `sys_wmctl` | `wmctl(cmd, a0, a1, a2, ptr, len) -> i64` | The registered WM server's control surface over the kernel render server (ADR 0015 seam A). Subcommands below; `ptr/len` are reserved for descriptor payloads (first used by SET_WINDOW chrome descriptors, WMS4). Calls from any process other than the registered WM return `EACCES`; with no WM registered, every call returns `ENOSYS`; an unknown `cmd` returns `EINVAL`. Reserved until the WMS2 claim registers the handler — until then slot 65 is not in `dispatch_table` and a call returns `-ENOSYS` naturally (the ADR 0013 reserved posture). |

### Slot-65 subcommand encoding (frozen by this amendment)

`cmd` values (x0), with argument mapping for x1–x5 (`a0..a2` + `ptr` + `len`):

| cmd | Name | Value | Args | Returns | Errors |
|:----|:-----|:-----:|:-----|:--------|:-------|
| REGISTER | `WMCTL_REGISTER` | 1 | all reserved (0) | 0 = registered | `EACCES` seat taken; `ENXIO` no gpu / unarmed compositor; `EINVAL` non-process caller |
| SET_WINDOW | `WMCTL_SET_WINDOW` | 2 | a0 = window id, a1 = packed rect (x\|y<<16), a2 = packed wh (w\|h<<16); `ptr` → chrome descriptor (WMS4; 0 = none), `len` = descriptor length | 0 = accepted | `EACCES` caller not the WM; `EINVAL` bad id/rect/len |
| REQUEST_PRESENT | `WMCTL_REQUEST_PRESENT` | 3 | all reserved (0) | 0 = present scheduled | `EACCES` caller not the WM |

Unknown/zero `cmd` → `EINVAL`. `REGISTER` is one-seat: a second registration
refuses `EACCES`; the registered pid is observable in the monitor's `wm`
report (WMS2).

`implemented_count` becomes 66 when WMS2 registers the handler (this
amendment reserves the row; the `syscalls` report prints rows 0–64 until
then). Proof program and live gate ride the WMS2 claim
(`tools/verify-live-wmctl-register.sh`).

As with slots 63/64, this is the milestone-32 set's ABI amendment; the ABI —
x8 number, x0–x5 arguments, x0 result, reserved 66–127, error codes — is
otherwise unchanged.
```

*(Slot-count note: `slot_count` is already 128 (`syscall.zig:239`), so the
"reserved 66–127" tail is the true remaining space — earlier amendments wrote
"reserved …–63" from the original 64-slot table; the 128-wide table has been
live since M16. WMS1's amendment is the first to write the honest bound.)*

#### Verbatim block 2 — ADR 0009 D2 kind-18 row (append to the kind table)

```markdown
| 18 | `COMPOSITE_TICK` | Composite/present cadence tick, delivered ONLY to the registered WM server's process queue (ADR 0015 D3). | Present sequence (monotonic, wraps at 2³²) | 0 (reserved) | 0 |
```

Plus one line after the table:

```markdown
Kind 18 is the first kind with a ROUTING RESTRICTION: every kind 1–17 fans
out to the owning/focused process per its own contract; kind 18 is delivered
exclusively to the process that registered via `sys_wmctl REGISTER` (slot
65). When no WM is registered, kind 18 is never generated. Routing lives in
`events.push`'s caller (the WMS2 kernel path); the wire format is unchanged.
```

#### Verbatim block 3 — `events.zig` constant (optional in WMS1, mandatory by WMS2)

```zig
/// ADR 0015 (M32 WMS1): composite/present cadence tick for the registered
/// WM server. RESERVED — no kernel path pushes it until the WMS2 claim
/// lands the render-server register; delivered ONLY to the registered WM
/// (the first routing-restricted kind, ADR 0009 D2 note).
pub const COMPOSITE_TICK: u16 = 18;
```

#### Verbatim block 4 — ADR 0015 status + amendment-log lines

```markdown
Status: **ACCEPTED** · Date: 2026-08-28 · Milestone: thirty-two (M32) ·
Accepted by: claim <NNNN> (WMS1, issue #621)
```

```markdown
## Amendment log

- 2026-08-XX — claim <NNNN> (WMS1, issue #621): accepted as binding; slot 65
  `sys_wmctl` + kind 18 `COMPOSITE_TICK` reservations frozen in ADR 0007 /
  ADR 0009; subcommand encoding + error contract frozen in the ADR 0007
  amendment (`EACCES` for the WM-exclusive refusal — the draft's `EPERM` does
  not exist in the frozen `ErrorCode` enum; see the proposal's frozen
  decisions). Open issue "exact sys_wmctl subcommand encoding" resolved.
```

#### What WMS1 deliberately does NOT do

- No `dispatch_table` registration (that is WMS2 — the row is textually
  frozen, not implemented).
- No `SET_WINDOW` chrome-descriptor layout (WMS4 freezes the payload shape;
  only `ptr/len` being reserved-for-descriptors is frozen here).
- No app↔WM mailbox message layout (WMS7).
- No kernel BSS for the WM registry (WMS2 sizes it; ADR 0015's open-issues
  list keeps that item open).

#### Self-check for the implementing claim

Run before flipping the WMS1 row to ✅:

```bash
export PATH="/opt/homebrew/bin:$PATH"
bash tools/verify-coordination.sh   # claim file + log structure
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build                            # full guest build
# grep-level doc checks:
rg -n "ACCEPTED" docs/decisions/0015-window-server-render-seam.md
rg -n "sys_wmctl" docs/decisions/0007-syscall-abi.md
rg -n "COMPOSITE_TICK" docs/decisions/0009-application-events.md
```

All green + the checklist boxes ticked = WMS1 accepted. The implementing claim
applies the blocks above verbatim — this claim (2852) is the canonical copy.

## Notes

Today the entire desktop window-management *policy* is a ~4,740-line kernel
component (`kernel/src/driving_award.zig`) composited from the shell idle loop,
with apps reaching it only through draw syscalls. This claim scopes how we make
it viable to build on: move policy out into a userland **WM server**, leaving
the kernel a thin render + input + surface server (seam A), shim-and-slim so no
M18–M31 gate regresses. This claim delivers the two binding documents (ADR 0015
reserving slot 65 `sys_wmctl` + event kind 18 `COMPOSITE_TICK`, and the
`march-m32-wm-migration.md` card plan); the code is claimed per-card (WMS2+) by
their own claims citing ADR 0015.

**Verified when:** ADR 0015 present + not yet accepted, the march doc lists the
ordered cards, docs/status.md points to M32, and the branch log carries this
entry. Docs-only — no code in this claim.
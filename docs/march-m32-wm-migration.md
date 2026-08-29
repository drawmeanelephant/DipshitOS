# Milestone thirty-two march — window-manager server migration (living tracker)

> [`docs/status.md`](status.md) is the canonical source for milestone-level
> facts. This file holds M32's per-card detail, order, and ABI notes. A card's
> row flips to ✅ only with real observed evidence.
> Architectural binding: **[ADR 0015](decisions/0015-window-server-render-seam.md)** (proposed) — seam A,
> slot 65 `sys_wmctl`, event kind 18 `COMPOSITE_TICK`, shim-and-slim.

## Where we are

Everything below the WM layer is done (M0–M31). The window manager itself is a
~4,740-line kernel component (`kernel/src/driving_award.zig`) carrying all
desktop *policy*, composited from the shell idle loop (`shell.zig:3425`), with
apps reaching the desktop only through draw syscalls. M32 does **not** add
desktop features — it re-architects the *boundary* so the desktop can grow:
**move policy into a userland WM server, leave the kernel as a thin render +
input + surface server.** Extract, don't rewrite: the kernel compositor stays
as the fully-gated **shim** until the server proves parity.

## The cards, in order

> Each card is tracked as a GitHub issue in milestone 16
> (<https://github.com/drawmeanelephant/DipshitOS/milestone/16>): WMS1 = #621
> … WMS10 = #630. The issue bodies carry the full per-card scope (goal, in/out
> of scope, acceptance gate, risks, touches); this table is the order + ABI
> summary. Phases: 0 contract → 1 unlock → 2 drain-out → 3 protocol →
> 4 payoff/perf; WMS10 deferred.

| # | Card | Phase | Depends on | Status | ABI | Notes |
|---:|------|:------|------------|--------|-----|-------|
| WMS1 | [#621](https://github.com/DipshitOS/issues/621) **ADR 0015 accepted + slot 65 reservation** — `sys_wmctl` register/set-window/request-present; kind 18 `COMPOSITE_TICK`. | 0 — contract | — | ✅ claim 1484 | 1 slot (65) | ADR 0015 read ACCEPTED; slot-65 subcommand encoding + error contract frozen in ADR 0007; kind-18 routing note in ADR 0009; `COMPOSITE_TICK = 18` reserved in `events.zig` (+ userspace mirror). No handler — slot 65 still `-ENOSYS`, kind 18 not delivered. |
| WMS2 | [#622](https://github.com/DipshitOS/issues/622) **Kernel render-server register** — `wmctl REGISTER` moves composite pacing off the shell idle to the registered WM; kernel delivers kind 18 ticks; `REQUEST_PRESENT` flushes. **WM-death teardown: unregistered WM → pacing falls back to the shim.** | 1 — unlock | WMS1 | ✅ claim 8482 | slot 65 | `wm_server.zig` (new, beside the unchanged shim): REGISTER (one seat, `ENXIO` unarmed-compositor) / SET_WINDOW (`EINVAL` reserved) / REQUEST_PRESENT (present-seq counter, G1 transfer+flush); kind-18 `COMPOSITE_TICK` to the registrant's queue off the scheduler tick; exit-path unregister → shim fallback; `wm` monitor row; WNDSTUB.BIN grounds the live gate. Gate **PASS 2026-08-29**. Present-sequence counter = the parity-cards' observability primitive. |
| WMS3 | [#623](https://github.com/DipshitOS/issues/623) **WM server process scaffold** — a long-lived EL0 server (`user/src/wnd.zig`) with its own event/loop, registered via `sys_wmctl REGISTER`, owning the registry data. **Bootstrap defined here (who execs WND.BIN; default VM stays shim-only).** | 1 — unlock | WMS2 | ✅ claim 3881 | — | `user/src/wnd.zig` (WND.BIN, ~300 B naked asm): REGISTER at startup, then a wait-event loop servicing kind-18 `COMPOSITE_TICK` and issuing REQUEST_PRESENT at its OWN cadence (every 2 ticks) with an alive marker (`wnd: present`) — the first pacing that is NOT the shell idle. `wnd start` monitor command execs it (the defined bootstrap; the default VM stays shim-only because nothing auto-starts it); `kill WND.BIN` → status 137 → WMS2 teardown → shim fallback → fresh re-register. Gate **PASS 2026-08-29** (3-phase lifecycle incl. the kill/reap/fallback round-trip). |
| WMS4 | [#624](https://github.com/DipshitOS/issues/624) **Chrome moves out** — title bars, borders, focus ring, close/minimize/pin buttons rendered via `SET_WINDOW` chrome descriptors instead of kernel `draw_chrome()`. | 2 — drain | WMS3 | ✅ claim 2491 | slot 65 | `ChromeDesc` (40 B flat struct) frozen in `wnd_core.zig` + ADR 0007; SET_WINDOW broadcast (ALL) policy + per-window overrides; REQUEST_PRESENT composites from descriptors when a WM is registered; WND.BIN issues the dark-theme policy at startup; `wm` observability (submissions, policy kind, per-window kind); WM teardown clears chrome → shim fallback. Gate **PASS 2026-08-29** — pixel parity vs the shim gates (ring 31/31, label ink 156, close-red 19; unfocused CHROME-METRICS-OK). Establishes the bypass→parity→(WMS8) delete runbook. |
| WMS5 | [#625](https://github.com/DipshitOS/issues/625) **Geometry policy moves out** — move/resize/tile/snap/workspaces/minimize/maximize/fullscreen/always-on-top become WM-server logic issuing `SET_WINDOW`; kernel only blits the resulting rects. **Input-seam handover defined here: the WM hit-tests and decides focus; the kernel only fans the stream out.** | 2 — drain | WMS4 | ✅ claim 9849 | slot 65 + kinds 19/20 | Gate 1 of the issue's sanctioned split (input seam + SET_WINDOW rects; tile/snap/workspaces state machines are Gate 2): kind 19 `WM_POINTER` + kind 20 `WM_WINDOW` routing-restricted fan-outs (ADR 0009 D2); `wm_owns_input` gates the kernel's geometry consumption off while a WM is registered (cursor stays a kernel blit); SET_WINDOW `a1/a2` rect encoding activates (WM proposes, kernel clamps via `user_move`/`user_resize`; broadcast stays chrome-only); WND.BIN mirrors the registry, hit-tests the title band, and drags via SET_WINDOW rects (naked asm, `wnd: grab/drag/drop` markers). Gate **PASS 2026-08-29** — headless pointer injection drove a WM-owned drag: NOTEPAD moved (56,56) → (256,292), the exact drag math, with zero kernel geometry decisions. |
| WMS6 | [#626](https://github.com/DipshitOS/issues/626) **Desktop chrome moves out** — notification center, dock, tray, alt-tab, tooltips, modal/transient dialogs, about/preview become WM-server policy. | 2 — drain | WMS5 | ⬜ | — | Rehouses the M21/M27 non-geometry features in userland. Completes the policy inventory WMS8 deletes against. |
| WMS7 | [#627](https://github.com/DipshitOS/issues/627) **App↔WM IPC protocol** — apps re-point policy queries (open/raise/move/config/frame) at the WM server over Mailbox IPC (slots 5/6) instead of syscall slots; toolkit (`ui.zig`/`LIBUI.SO`) learns the protocol. | 3 — protocol | WMS3 (parallel-friendly with WMS4–WMS6) | ⬜ | — | Decide mailbox size vs. new bounded message type per ADR 0015 open issue — prefer growing the mailbox constant (`message_max` 64 B / 8 slots today) over a new syscall. Sync-shaped toolkit API, async transport decided explicitly. |
| WMS8 | [#628](https://github.com/DipshitOS/issues/628) **Slim the kernel** — delete each drained-out policy block from `driving_award.zig`, one gate at a time; kernel converges to surfaces + blit + input fan-out + the D2/D3 registers. Slots 12–20 stay frozen. | 4 — payoff | WMS4, WMS5, WMS6, WMS7 | ⬜ | — | The end-state: kernel `driving_award` is a thin render server, ~90% lighter than today. Deletion only — no rewriting while deleting. |
| WMS9 | [#629](https://github.com/DipshitOS/issues/629) **Surface seam perf** — batched spans/raw-region push in the toolkit so text stops being 64 fills/glyph (the standing perf debt from `ui.zig draw_char`). | 4 — payoff | WMS7 | ⬜ | — | Side-effect win of the rewrite. **Prior art first:** slot 46 `sys_win_fill_batch` already exists (issue #205 follow-on) — measure it before designing anything new; extend its payload shape rather than adding a slot. Pixel-identical output is the bar. |
| WMS10 | [#630](https://github.com/DipshitOS/issues/630) **(Deferred) Seam B** — cross-process shared anonymous mmap so apps render into their own memory and the WM composites; the deeper pixel-ownership end-state. | deferred | WMS1–WMS9 all | ⬜ | new MMU fundamental | Explicitly deferred by ADR 0015 D5; do NOT start until WMS1–WMS9 land. Its issue body carries the scoping seed (shared-anon mmap, damage tracking, capability/security ADR). |

### Dependency phases (why this order)

```text
Phase 0  contract        WMS1 ──────────────────────────────┐ freezes slot 65 + kind 18
Phase 1  unlock          WMS2 → WMS3                        │ kernel seam + server exist
Phase 2  drain-out       WMS4 → WMS5 → WMS6                 │ policy moves with parity proof
Phase 3  protocol        WMS7  (parallel-friendly with WMS4–WMS6 after WMS3) │ apps get a message seam
Phase 4  payoff          WMS8 + WMS9                        │ deletions + perf on the final shape
Deferred WMS10           seam B                             │ post-M32; needs shared-anon mmap
```

Hard edges: WMS2 before WMS3 (the server cannot register against a seam that
does not exist). WMS4 before WMS5 (the descriptor transport must be
parity-proven before the much larger geometry surface rides it). WMS6 after
WMS5 (overlays position against WM-owned geometry). WMS8 strictly last of the
kernel cards — deletion is only safe after every behavior has a proven userland
owner. WMS9 after WMS7 (the toolkit re-point is the excuse; don't touch every
call site twice). No card gates on WMS9; if perf work runs late, WMS8's
deletions are unaffected.

### The per-card scope template (what each issue body carries)

Every issue body (#621–#630) now follows one template so cards stay
well-scoped as work starts: **Goal** (one paragraph) · **Why this order**
(depends/blocks rationale) · **In scope** (checkboxes; each new consideration
added during scoping is marked "new — not in the draft") · **Out of scope**
(explicit non-goals) · **Acceptance (gate)** (which gates pass, which class) ·
**Risks / notes** (the things most likely to go sideways) · **Touches** (the
files/scripts the card's claim must declare).

## Notes

1. **Order matters:** WMS1 → WMS2 → WMS3 unlock the server; WMS4–WMS6 migrate
   policy by feature with parity; WMS7 gives apps the message seam; WMS8 is
   the payoff (kernel slimming); WMS9 is the perf win; WMS10 is out of scope
   for this pass. (The dependency-phases diagram above is the binding form.)
2. **Zero-regression contract:** the kernel compositor stays as the shim until
   each drained feature is observed-different from nothing. Every M18–M31 gate
   (M21 window-depth, M27 polish, etc.) doubles as the parity suite. The
   unregistered path is byte-identical to today — WMS2's rule is "no WM
   registered → nothing changes," and the same rule holds per drained feature
   through WMS4–WMS6 (shim behavior persists beside the WM path until WMS8
   deletes it).
3. **ABI budget:** one slot (65) and one event kind (18) total. Headroom in the
   128-slot table: highest used is 64, so 65+ are free. ADR 0007 is amended per
   implementing claim; ADR 0015 tracks the reservation. **Slot 46
   (`sys_win_fill_batch`, issue #205) already exists** — WMS9 extends its
   payload shape instead of adding a slot, keeping the budget at 66.
4. **Doc discipline:** the WM-server source, its `sys_wmctl` opcode encoding,
   and the app↔WM message layout are normative in `docs/hardware-contract.md`
   / the slot-65 claim's ADR 0007 amendment, per repo convention.
5. **Robustness properties (added at scoping):** WMS2 owns WM-death teardown
   (kernel unregisters on WM exit, pacing falls back to the shim); WMS3 owns
   the hung-WM watchdog and the bootstrap rule (who execs `WND.BIN`; the
   default VM stays shim-only so every existing gate is non-interference
   green); WMS7 owns the async-RPC posture for apps. These are card-level
   acceptance criteria, not stretch goals.
6. **Verification-first ordering:** the observability primitives each card
   needs (present-sequence counter in WMS2, `wm` monitor row in WMS2/WMS3,
   fill/batch counters in WMS9) land in the *earlier* card so the later cards
   gate on counters that already exist.
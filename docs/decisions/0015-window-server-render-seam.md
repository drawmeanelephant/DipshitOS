# ADR 0015: Window-server render seam (userland window manager migration)

Status: **ACCEPTED** · Date: 2026-08-28 · Milestone: thirty-two (M32) ·
Accepted by: claim 1484 (WMS1, issue #621)

> **Accepted by M32 WMS1 (claim 1484).** Slot 65 and event kind 18 below are now
> **freeze reservations**: the exact `sys_wmctl` subcommand encoding is frozen
> in the live `docs/decisions/0007-syscall-abi.md` slot-65 amendment, and kind
> 18 `COMPOSITE_TICK` (with its routing restriction) in ADR 0009 D2. Each later
> WMS claim implements one reservation, citing this ADR. Until the relevant
> claim lands its handler, slot 65 is not in `dispatch_table` (a call returns
> `-ENOSYS` -4 naturally) and kind 18 is not delivered.

## Context

The desktop composition + window-management *policy* today lives entirely in the
kernel, in `kernel/src/driving_award.zig` (~4,740 lines): window registry,
z-order, hit-testing, chrome (title bars, borders, focus ring, close/minimize/
pin buttons), geometry (move/resize/tile/snap/workspaces/minimize/maximize/
fullscreen/always-on-top), and the desktop chrome (notification center, dock,
tray, alt-tab, tooltips, modal/transient dialogs, about/preview). Three couplings
are too deep:

1. **Policy in the privileged component.** Every desktop behavior is a kernel
   change — high blast radius, no isolation, no hot-reload, cannot grow without
   a new milestone.
2. **Compositing rides the shell idle loop.** `shell.zig:3425` calls
   `driving_award.drain(...)`. Present pacing, animation, and click handling all
   inherit the shell's idle cadence (the reason pointer gates pace clicks at
   ~2.5 s).
3. **Apps touch the desktop only through syscalls.** No app↔WM↔desktop
   message protocol; the toolkit (`user/src/lib/ui.zig`, `LIBUI.SO`) issues
   per-rect fill syscalls (one `win_fill` per 1×1 glyph pixel).

The downside is not a missing feature — it is a missing *boundary*. This ADR
moves desktop policy out of the kernel and into a userland **window-manager
server process**, leaving the kernel a thin **render + input + surface server**.

## Enabling seams that already exist

- **Per-process event queues** (`events.zig`): input already flows as kinds
  (KEY_*, MOUSE_MOVE/DOWN/UP, WIN_FOCUS/BLUR, WIN_RESIZE, DRAG_*, WIN_UNSAVED)
  to owning processes.
- **Cross-process IPC** slots 5/6 (`sys_ipc_send`/`sys_ipc_recv`, bounded
  per-process mailboxes) — the transport for an app↔WM protocol.
- **Process lifecycle**: `sys_exec` (28), `sys_kill` (29), `sys_wait` (8),
  anonymous mmap (63/64), dynamic linking (M30/M31) — a long-lived EL0 server
  process is a supported shape.
- **Thin GPU interface**: `virtio_gpu` is transfer+flush of a 3.52 MiB BSS
  scanout; all the *weight* is policy stacked on `driving_award`.

## Decisions

### D1. Target architecture — seam A (render-server)

The kernel keeps **surfaces + blit + input fan-out**; a userland **WM server
process** owns all *policy*:

```
+---------------+   IPC (slots 5/6)   +------------------+   sys_wmctl (65)   +----------------------+
|  Apps (EL0)   | <-----------------> |  WM server (EL0) | <----------------> | kernel: render server |
| talk win-msgs  |   win-open/close/   |   registry, z-ish,|   submit window   | surfaces + blit +     |
| to server       |   raise/move/frame  |   chrome, hittest,|   list/chrome,    | input fan-out; hands  |
+---------------+                    |   geometry, nodes |   request-present  | event 18 (composite   |
                                     +------------------+                    | tick) to the WM        |
                                      * policy lives here *                  +----------------------+
```

- The kernel keeps **kernel-owned per-window surfaces and the blitter**, but
  exercises them **only on the WM server's instruction** via a single control
  syscall (D2) — it makes no policy decision of its own.
- The WM server drives present pacing itself (D3) instead of the shell idle.
- Apps keep rendering into their own kernel-owned surface slots for now; the
  toolkit's *policy* queries (open/raise/move/request-frame/config) re-point to
  the WM server over IPC, not to syscall slots.

### D2. Syscall reservation — slot 65 `sys_wmctl`

`0x41 (65)` — first free slot in the 128-wide table (highest used today: 64,
`sys_munmap`).

| Slot | Name | Signature | One-line semantics |
|:---:|:---|:---|:---|
| 65 | `sys_wmctl` | `wmctl(cmd, a0, a1, a2, ptr, len) -> i64` | The **WM server's** exclusive control surface over the kernel render server. Subcommands (a design sketch; each implementing claim freezes its exact encoding): `REGISTER` (this process becomes the active compositor — ownership of composite pacing moves off the shell idle; refused if another is registered), `SET_WINDOW` (submit one window's z-order rank, rect, chrome kind/colors, visibility, workspace — the kernel blits that surface per this geometry), `REQUEST_PRESENT` (ask the kernel to transfer+flush now). Calls from any process other than the registered WM return `EPERM`; no WM registered → `ENOSYS`. |

The moving policy (D1's right-hand side) is **not** part of this syscall — it
is WM-server-internal and exposed to apps only via IPC.

### D3. Event-kind reservation — kind 18 `COMPOSITE_TICK`

Kind 18 is the present/composite cadence the kernel delivers to the **registered
WM server** (arg0 = present sequence, arg1 = reserved). The WM server uses it to
drive its own composite loop, releasing the shell idle dependency. Kind 17
(`WIN_UNSAVED`) remains the highest live kind; 18 reserves the first free value.

### D4. Shim-and-slim migration (extract, don't rewrite)

- **Shim phase (frozen ABI stays the shim):** slots 12–20 (`sys_win_*`) and the
  existing kernel `driving_award` compositor remain fully functional and fully
  gated. Every M18–M31 gate stays green. The userland WM server (new EL0
  process under `user/src/`) grows beside it, reusing `driving_award`'s *pure*
  geometry/logic as userland code so the two never drift behaviorally.
- **Prove parity** through the shim: the WM server commands the kernel render
  server (D2) to reproduce what the kernel WM did — same geometry, chrome,
  z-order, focus rules.
- **Slim the kernel:** once parity is observed behind the shim, the policy code
  drains out of `driving_award.zig`, which shrinks to "surfaces + blit + input
  fan-out + the D2/D3 registers." Slots 12–20 remain frozen (back-compat, and
  used by the shim path until removed); individual claims delete one policy
  block at a time, each behind its gate.
- **Rewire the toolkit** (`ui.zig`/`LIBUI.SO`) on the surface seam (batched
  spans, not per-pixel fills) as the desktop-wide performance side effect.

### D5. Deferred option — seam B (full pixel ownership)

The deeper end-state — apps render into their own mmap'd memory and the WM
composites + presents one final buffer — is **not** chosen for the first pass.
It requires **cross-process shared anonymous mmap** (shared surface between two
EL0 address spaces), a genuinely new MMU fundamental. It is deferred; seam B
can be layered on top of the D1 render-server boundary without re-architecting
it (the render server already separates policy from blit).

## What this is not

- Not POSIX, libc, `errno`, or a compatibility ABI. The WM protocol uses the
  Mailbox IPC (slots 5/6), not signals or sockets.
- Not a kernel rewrite. Seam A keeps the blitter; only *policy* moves.
- Not a uaccess change, scheduler change, or MMU change (in this pass).
- Not a commit. Each M32 claim amends ADR 0007 (slot 65) or the event table
  (kind 18), citing **this** ADR.

## Consequences

- Desktop policy becomes a **hot-replaceable userland component** with its own
  process boundary, own memory, own fault tombstone — the kernel no longer
  faults on find-the-typo-in-my-focus-rule.
- The shell idle loop no longer owns compositing; the WM server does (D3).
- Apps grow a real app↔WM message protocol instead of a syscall-drawn surface.
- Existing behavior is preserved the whole way through the shim (D4) — no
  capability regression at any intermediate commit.

## Amendment log

- 2026-08-28 — claim 1484 (WMS1, issue #621): **accepted as binding**; slot 65
  `sys_wmctl` + kind 18 `COMPOSITE_TICK` reservations frozen in ADR 0007 /
  ADR 0009. The `sys_wmctl` subcommand encoding and error contract are frozen in
  the ADR 0007 slot-65 amendment — `EACCES` (-7) for the WM-exclusive refusal
  (the draft's `EPERM` does not exist in the frozen `ErrorCode` enum; see claim
  1484), seat-taken also `EACCES` (EL1h force-unregister escapes), no-GPU
  `REGISTER` → `ENXIO` (-9), `COMPOSITE_TICK` on the scheduler tick seam; the
  ADR 0007 amendment writes the honest `reserved 66–127` tail (`slot_count` is
  128). The `SET_WINDOW` chrome-descriptor layout remains open (WMS4).

## Open issues (left to implementing claims)

- ~~Exact `sys_wmctl` subcommand encoding (opcode constants, arg layout, return
  codes)~~ — **resolved by WMS1 (claim 1484)**: freezed in the ADR 0007
  slot-65 amendment (REGISTER=1 / SET_WINDOW=2 / REQUEST_PRESENT=3 + error
  contract). The `SET_WINDOW` **chrome descriptor** layout stays open (WMS4).
- Kernel BSS for the WM registry (the D2 register + composite-tick sequence);
  the scanout fb (3.52 MiB) is untouched.
- Whether mailboxes (8 × 64 B today) suffice for the app↔WM protocol or a larger
  bounded message type is needed — the WM-server claim decides; prefer growing
  the mailbox data-path constant over a new syscall.
  **Resolved by WMS7 Gate A (claim 9604, issue #627):** the WM_RPC wire format
  fits the FROZEN 64-byte slot — the size decision is "grow nothing". `WmRpc`
  (single-sourced in `kernel/src/wnd_core.zig`, compiled by both WND.BIN and
  WMRPC.BIN) packs kind / target id / seq / reply pid / applied flag / u16 rect /
  a ≤24-byte bounded title into 64 B, so `message_max` (8 × 64 B, the
  `verify-live-ipc.sh` exact-capacity contract) and BSS are untouched. Requests
  ride `sys_ipc_send`/`sys_ipc_recv` (slots 5/6) to the registered WM's own
  inbox; the WM serves them in its 1 Hz kind-18 wake (≤ 1 s latency, accepted),
  applies through its OWN clamped primitives (WIN_RAISE → the ALT_TAB-commit
  path, WIN_CONFIG → the SET_WINDOW rect path), replies an ack (kind | 0x80) to
  the requesting app's pid, and emits `wnd: mail` (the gate grep target). Apps
  poll their own inbox for the ack; with no WM the app prints `wmrpc: no-wm`
  and parks (additive back-compat — frozen syscalls untouched).
- **Toolkit re-point (WMS7 Gate B, claim 9274):** `user/src/lib/ui.zig` — the
  toolkit compiled into every static app — carries the WM_RPC client. It holds a
  FROZEN wire mirror of `WmRpc` (byte-identical layout; `lib/ui.zig`'s module
  path cannot import `kernel/src/`, so the 28 app modules get the mirror and
  the live gate's byte-level round-trip is the integration drift guard, plus a
  host test in `wmrpc.zig` locks `ui.wm_rpc_*`/`ui.WmRpc` byte-size to
  `wnd_core`'s). `wm_raise_front(id, self_name)` / `wm_config(id, x,y,w,h,
  self_name)` are the re-pointed policy calls: send WIN_RAISE / WIN_CONFIG mail
  to the WM and await the ack (synchronous-shaped — the issue's async-inversion
  note answered: no async break), falling back to the FROZEN `sys_win_raise_front`
  (slot 49) / `sys_win_move` (slot 16) when no WM is registered (additive).
  The shipped `LIBUI.SO` note: it is a bare-syscall thunk library generated by
  `tools/mkdyn-elf.py`, so async mail (send + poll + fallback) cannot be
  exposed there without duplicating the client in emitted asm — the client
  lives in `lib/ui.zig` and grows the toolkit, but dynamic-app (ELF) mail is
  out of scope; `libui_so.zig`/`ld.zig` untouched.
- Which `driving_award` policy block drains out of the kernel first (recommended:
  chrome, being minimal and highly observable).
# Log — `m13-pointer-route`: VZ synthesized-pointer root cause (claim 4769)

## 2026-08-16 — branch opened

- User request: "Investigate why VZ does not translate synthesized mouse
  events (CGEventPost, even with trust) into guest USB HID pointer reports,
  and try a route that does." Branch from `origin/main`.

## 2026-08-16 — branch work

- **Instrumented the runner** for route-by-route probing:
  - `TraceView` — a `VZVirtualMachineView` subclass logging every
    NSResponder mouse method that actually fires (`PTR-TRACE: TRACE
    mouseDown/Up/Moved… key=<isKeyWindow>`), so a probe run can tell "the
    event never reached the view" from "VZ dropped it internally".
  - Per-post diagnostics on the cg route: window key state, app active
    state, frontmost app, and the REAL cursor position after the post.
  - Four new routes: `direct` (view.mouseDown/Up/Moved straight on the
    responder — the exact pattern the WORKING keyboard seam uses), `pid`
    (CGEventPostToPid into our own app queue), `warp` (warp the real
    cursor over the view first, then post at the HID tap), `diag`/`drag`
    (force key + first responder; drag events).
  - `tools/probe-pointer-routes.sh` — the route-sweep driver (one VZ boot
    per route, guest `input` accounting + host TRACE evidence).
- **Probe gap fixed:** claim 5776's gate never ran the guest's `input`
  command, so its `ptr-reports=0` was the grep-miss default. The probe
  scripts run `input` after the sequence — the guest's own accounting.
- **Live findings (all on VZ, artifacts/pointer-route-*.txt):**
  1. Trusted CG posts work at the OS level: real cursor warps to the post
     (`cursor=1220,916` matches), runner becomes frontmost
     (`front=VMRunner`).
  2. The window NEVER becomes key: `key=false active=false` across every
     route and the full activation ladder (`.regular` policy,
     `finishLaunching`, modern + deprecated `NSApp.activate`,
     `NSRunningApplication.activate` all options, `acceptsFirstMouse`,
     NSTrackingArea, and running from inside a proper signed `.app`
     bundle). macOS 14+ refuses focus-stealing while another app holds
     focus; the frontmost app kept changing under us (Discord/Manus/
     Firefox/Nova) — the machine is in active use.
  3. VZ only translates input for its KEY window: `direct` calls fire all
     8 responder methods on the view yet the guest ring stays
     `events=0 ptr-reports=0`.
  4. NOT pointer-specific: the keyboard seam (same `view.keyDown`
     pattern; walked the B4 desktop menu at 17:58 the same day) later
     yields `events=0` with the byte-identical STOCK runner (probe
     changes stashed). The runner didn't change; the machine state did
     (idle → busy). Synthesized input of any kind only translates while
     the runner's window can become key.
  5. First CG click is click-through (consumed for activation, which
     never completes) — zero clicks ever reach the view on the cg route.
- **Conclusion:** the only route that works is a real human click (class-C
  gate, claim 9015) — the OS performs the activation itself. The class-B
  CG gate (claim 3692) can only pass when the machine is idle.
- Hardware contract updated with the activation-wall finding (claim 4769).
- PR #174 opened (claim 4769).

## 2026-08-16 — idle-machine retest + gate fixes

- Reran `verify-live-pointer-cg.sh` with the machine idle (the runner stayed
  frontmost the whole sequence — `front=VMRunner` on every post, cursor
  warped correctly to each posted position). Result unchanged:
  `pointer-cg: rc=0 ready=1 focus-lines=0 distinct=0 ptr-reports=0 done=1
  cursor=1 untrusted=0` — FAILED. **The idle-machine hypothesis is
  refuted:** even frontmost with the real cursor over the window, macOS
  refuses to make the window key (`key=false active=false`), so VZ never
  translates.
- **New finding — the keyboard seam ALSO fails now** (`events=0` in the
  guest ring), even though the B4 desktop gate's chords delivered at 17:59
  the same day (`desktop: select app` ×8 in `live-file-browser-serial.log`).
  Reproduced with the byte-identical STOCK runner (probe changes stashed).
  The kernel delta since 17:59 is only the win→dui rename (pure string
  renames, nothing near input/xhci); the guest USB stack is healthy
  (`usb: enumerated=0x0000000000000002 ok`, ring armed). The machine's
  console session was re-established at 19:33 (after 17:59) — the session
  state, not the code, is the delta.
- **Gate fixes** (commit `c0a729b`): the pixel assertion never ran — the
  gate globbed `$SCREEN_BASE-after.png` but the runner writes
  `$SCREEN_BASE-after`; and the pixel-check python exits 1 on no-cursor,
  which under `set -e` aborted the script before the summary. Both fixed;
  the gate now runs to completion and prints the honest summary.

## Handoff state (2026-08-16)

- Branch `agent/buffy/m13-pointer-route` @ `c0a729b`, PR #174 OPEN/MERGEABLE.
- Committed: claim 4769 + branch log + hardware-contract update + runner
  probe tooling (TraceView, direct/pid/warp/diag/drag routes,
  `tools/probe-pointer-routes.sh`) + the two gate fixes.
- The runner probe additions keep non-pointer runs byte-identical.
- Open question for the next session: the keyboard `events=0` regression
  since 17:59 (session state vs something else) — worth a fresh boot of
  the input gate to confirm it recovers after a clean GUI session.

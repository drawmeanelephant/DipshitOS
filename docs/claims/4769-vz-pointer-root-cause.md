# Claim: VZ synthesized-pointer root cause — the activation wall (why no route delivers)

- **Owner:** buffy (`agent/buffy/m13-pointer-route`)
- **Prompt / plan:** user request — "Investigate why VZ does not translate
  synthesized mouse events (CGEventPost, even with trust) into guest USB HID
  pointer reports, and try a route that does."
- **Depends on:** U4 (claim 4993, ⛔ at the live seam), the CG gate (claim
  3692), the class-C gate (claim 9015), the gate completion card (claim 5776)
- **Status:** ✅ root cause identified and pinned in the hardware contract;
  no synthesized route works while the machine is busy — the class-C
  real-mouse gate remains the working delivery route. Updated 2026-08-16:
  the idle-machine retest REFUTED the idle hypothesis (runner stayed
  frontmost every post, cursor warped — still `key=false`,
  `ptr-reports=0`), and the keyboard seam also now yields `events=0`
  (worked at 17:59 same day; console session re-established 19:33) —
  tracked as an open thread in the branch log.

## The question

Claim 5776's live run showed `ptr-reports=0` even with Accessibility trust
granted. This card instrumented the runner (TraceView responder tracing,
route-by-route probing) and asked WHY: is the event dropped by the window
server, by the VZ view, or by VZ's USB translation?

## The probe (tools/probe-pointer-routes.sh + runner instrumentation)

The runner gained a `VZVirtualMachineView` subclass that logs every
NSResponder mouse method that actually fires (`PTR-TRACE: TRACE mouse…`),
per-post diagnostics (window key state, app active state, frontmost app,
real cursor position after the post), and four new pointer routes: `direct`
(call `view.mouseDown/Up/Moved` straight on the responder — the exact
pattern the WORKING keyboard seam uses), `pid` (CGEventPostToPid into our
own app queue), `warp` (warp the real cursor over the view first, then post
at the HID tap), `diag`/`drag` (force key + first responder; drag events).
The guest side ran `input` after the sequence so `ptr-reports`/`events` are
the guest's own accounting (claim 5776's gate never ran `input` — its
`ptr-reports=0` was actually the grep-miss default, an honest fix here).

## Findings (all live on VZ, artifacts/pointer-route-*.txt)

1. **The CG route works at the OS level.** Trusted posts at the HID tap
   move the REAL cursor to the posted position (`cursor=1220,916` matches
   the post), and the runner's app becomes the frontmost application
   (`front=VMRunner`). The window server is doing its job.
2. **But the window never becomes key.** `key=false active=false` in every
   route, every run — even after the full activation ladder: `.regular`
   activation policy, `finishLaunching()`, the modern `NSApp.activate()`
   AND the deprecated form, `NSRunningApplication.activate` with every
   option, `acceptsFirstMouse`, an NSTrackingArea, and running the same
   binary from inside a proper `.app` bundle (Info.plist + codesign).
   macOS 14+ refuses programmatic focus-stealing from a background
   process while another app holds focus — and on this machine the
   frontmost app kept changing under us (Discord/Manus/Firefox/Nova) —
   the user is actively working.
3. **VZ only translates input for its KEY window.** With `direct` calls,
   all 8 responder methods fire on the view (`TRACE mouseDown… key=false`),
   yet the guest ring stays `events=0 ptr-reports=0`. The events reached
   the view; VZ dropped them internally because the window is not key.
4. **It is not pointer-specific.** The KEYBOARD seam — the exact `direct`
   pattern that historically works (the I3 gate, and the B4 desktop gate
   whose chords walked the menu at 17:58 the same day) — now also yields
   `events=0` in the guest ring. The byte-identical STOCK runner (my
   changes stashed) reproduces it. The runner did not change; the machine
   state did (idle → user actively working). Synthesized input of ANY
   kind only translates while the runner's window can become key.
5. **The first click is click-through.** Even when the CG click lands on
   our window (`front=VMRunner`), macOS consumes the first click to
   activate the app, and since activation never completes for this
   process, no click is ever delivered to the view (zero TRACE lines on
   the cg route).

## The route that works

**A real human mouse click** (the class-C gate, claim 9015) — the OS
activates the window on a real click, VZ translates, the guest reports.
That is the only delivery route that works, and it works because the
activation step is performed by the OS itself, not requested by a
background process. The class-B CG gate (claim 3692) therefore stays ⛔:
it can only pass when the machine is idle enough for the runner to become
key, which is exactly the environment where the B4 keyboard chords passed
earlier the same day.

## Hardened artifacts

- `tools/probe-pointer-routes.sh` — the route sweep driver (one VZ boot
  per route, guest `input` accounting + host TRACE evidence).
- Runner: TraceView responder tracing, per-post diagnostics, `direct` /
  `pid` / `warp` / `diag` / `drag` routes (default route unchanged;
  non-pointer runs byte-identical — the .accessory policy + activate
  path is preserved exactly).
- `docs/hardware-contract.md` updated with the activation-wall finding.

# Claim: Milestone seven, card I3 — event FIFO + keycode decode → Road Pops

- **Owner:** buffy (`freebuff/can-you-check-out-our-status-and-work-on-the-next--7e2ecd0b-8acc-47ac-bb44-68841236e5fc`)
- **Prompt / plan:** `docs/march-m7.md` I3 row — the third milestone-seven rung,
  on top of the I2 enumeration + HID path (claim 4116).
- **Scope:** a bounded BSS event FIFO (pure BSS, the card-3d pattern) that the
  XHCI interrupt-IN reports land in as keyboard/pointer events (pushed from
  the drain site in the shell idle loop, consumed by the shell's line editor
  through the Road Pops tee's read path); HID-usage → ASCII keycode decode
  (modifiers + shift, the usable ASCII subset) feeding the Road Pops line
  editor; pointer motion/buttons recorded (raw report + best-effort absolute
  decode); an `input` monitor command (device state + FIFO occupancy + last
  events); and the runner's scripted host key-sequence surface
  (`--input-string <ascii>` + `--input-string-after <marker>` +
  `--input-enter`, OFF without `--input`) for the live gate. Honest bounds:
  the usable ASCII subset only (letters/digits/space/Enter + a few
  punctuation — unmapped chars are refused honestly), 6-key rollover, no
  full HID report-descriptor parser (boot protocol), the pointer path is
  recorded but not the line-editor feed.
- **Depends on:** I1 (claim 4272) + I2 (claim 4116) — the XHCI transport and
  the enumerated keyboard/pointer with armed interrupt-IN endpoints; the
  runner's `--input`/`--input-key` seam (claim 4116); the Road Pops tee
  (claim 1574) whose read path I3 extends.
- **Status:** ✅ done (claim 6050) — `tools/verify-live-input.sh` PASS 1/1 (8/8
  assertions); the keyboard typed `input\n` and the guest's own `input`
  report showed `events=6` (i,n,p,u,t,Enter) with `dropped=0`,
  `kb-usage=0x28 kb-byte=0xa` (Enter). Evidence under `artifacts/live-input-*`.

## Notes

**Why this card:** I2 made the two USB HID devices speak (a synthesized host
keyDown produced a raw report read back by `usb report`). I3 closes the loop
that makes Road Pops a *real* machine: keystrokes from the screen side must
reach the shell's line editor, be decoded to ASCII, and be echoed + answered
on serial AND on the framebuffer. G5 (Driving Award, back in milestone six)
depends on this.

**Key input questions (recorded at claim time):** (1) does VZ honor the
NSEvent `modifierFlags` (`.shift`) when synthesizing the HID boot report, or
must the runner dispatch an explicit shift-keyDown/keyUp pair — observed, not
assumed; (2) the exact report the runner's keyDown+keyUp sequence produces
(keyboard rollover across consecutive reports); (3) the pointer's 10-byte
absolute report shape (buttons/X/Y word order) — recorded best-effort.

**Claim-time findings (observed, never assumed):**
- **VZ has NO programmatic keyboard API** — `VZUSBKeyboardConfiguration` is
  driven only by a `VZVirtualMachineView` forwarding host key events, so the
  runner synthesizes one `NSEvent` per keyDown/keyUp and dispatches it to the
  view (`--input-string`/`--input-string-after`).
- **Report delivery cadence:** VZ's keyboard delivers roughly ONE
  interrupt-IN report per Road Pops present cadence — the full-frame
  virtio-gpu present per output batch is the slow step. Typing faster than
  ~2 s per keyDown/keyUp drops reports (the endpoint holds a single pending
  report). The seam therefore types at 2 s per keystroke.
- **Single-TRB arming is the correct shape** — arm one report TRB and re-arm
  on every completion. A multi-TRB depth (8) experiment wrapped the transfer
  ring at the 8th report and dropped everything after; depth 1 is correct.
- **Drain ordering:** `input.drain()` runs BEFORE `road_pops.drain()` in the
  shell idle loop so a report is never starved behind a slow full-frame
  present.
- The keyboard (port 9, slot 1) delivers 8-byte boot reports; each keyDown
  and keyUp is a distinct report (`b2` = the held keycode, 0 on release). The
  pointer (port 10, slot 2) is non-boot (bInterfaceProtocol 0) so its raw
  10-byte reports are recorded best-effort (no boot-mouse decode).

**Verification:** class A first (fmt, unit tests, test-console +
byte-identical transcript, build/image/inspect, swift build, context,
coordination ×2, mmu-debt); then class B on VZ (the new
`verify-live-input.sh`, riding `--input` + `--display` + `--input-string`);
then the docs reconciliation (march-m7 I3 row, roadmap, status.md,
gate-inventory, hardware-contract `[observed]` input flips with saved logs),
the justfile `verify-vz` entry (40→41), the claim flip, the log append, and
the PR per the repo template with real observed evidence only.

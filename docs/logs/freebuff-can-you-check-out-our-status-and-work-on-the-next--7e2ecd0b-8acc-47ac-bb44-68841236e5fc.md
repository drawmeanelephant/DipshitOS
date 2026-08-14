# Log — freebuff/can-you-check-out-our-status-and-work-on-the-next (milestone six, G4)

- **2026-08-13 (reconciliation):** found the worktree was STALE — HEAD was the
  N7/N8 planning-first prompt `0fcd96b` while origin/main had advanced to
  `f644c73` (N7–N11 — NAT/DHCP/DHCP-renew/TCP/TCP-RTO — and milestone six
  G1–G3 all landed). The earlier N7 work (claim 8325) was therefore a
  duplicate of the already-merged claim 4678; it was stashed (recoverable) and
  the branch fast-forwarded to origin/main `f644c73`. The real next card is
  milestone six G4 — virtio keyboard + pointer input.

- **2026-08-13 (claim 3868, milestone six card G4 — virtio keyboard + pointer
  input):** claimed G4 on this branch from origin/main `f644c73`. Scope per
  `docs/march-m6.md` G4 row: DISCOVERY FIRST (device DID + event format are
  `[inferred]` until observed — the 0x1052 virtio-input hypothesis vs a USB
  controller is a claim-time finding), then the runner's flag-gated `--input`
  mode + scripted key injection, `kernel/src/virtio_input.zig` (transport +
  bounded event FIFO + keycode decode into the line editor + pointer), the
  `input` monitor command, and the live gate `tools/verify-live-input.sh`
  (scripted host key events drive Road Pops end to end).

- **2026-08-13 (G4 discovery — decisive finding, claim 3868 handed back):**
  the discovery-first boot OBSERVED the device and **the card's virtio-input
  premise is wrong**. `--input` (VZUSBKeyboardConfiguration +
  VZUSBScreenCoordinatePointingDeviceConfiguration) adds exactly ONE PCI device:
  an **Apple XHCI USB host controller** `VID=0x106b DID=0x1a06 CLS=0x0c0330`
  (two MMIO BARs 0x50001000 + 0x50000000), with keyboard/pointer as USB HID
  devices behind it. No 0x1052 virtio-input device exists anywhere on the bus.
  The SDK confirms there is no virtio-input device config at all — only USB HID
  configs (plus VZCustomVirtioDeviceConfiguration, macOS 27+, a host-implemented
  custom virtio device — a different, larger lift). G4 therefore cannot be built
  as a virtio-input transport; screen-side input needs a full USB XHCI + HID
  stack (its own milestone-scale effort). Claim flipped ⛔ with the finding; the
  flag-gated `--input` runner mode is left in place (OFF by default, so the
  default VM stays byte-identical). Evidence: `artifacts/g4-discovery/`
  (input-boot-serial.log vs noboot-serial.log: 4 PCI devices without --input,
  5 with — the 5th is the XHCI controller).

- **2026-08-13 (milestone seven split):** G4 was split into milestone seven
  per the user's direction — `docs/march-m7.md` with cards **I1 XHCI
  host-controller transport** → **I2 USB enumeration + HID** → **I3 event
  FIFO + keycode decode** feeding Road Pops. roadmap/status/march-m6/
  claim-3868 all re-pointed; indexes refreshed, coordination green.

- **2026-08-13 (claim 4272, milestone seven card I1 — XHCI host-controller
  transport):** claimed I1 on this branch from origin/main `f644c73`. Scope
  per `docs/march-m7.md` I1 row: `kernel/src/xhci.zig` (pre-exit PCI
  discovery of DID 0x1a06; post-MMU MMIO init — CAPLENGTH/HCIVERSION/
  HCSPARAMS/DBOFF/RTSOFF, command ring + event ring + ERST + primary
  interrupter, a NO-OP command TRB driven to a Command Completion Event,
  port-status reads), the `usb` monitor command (registry 37→38), and the
  live gate `tools/verify-live-xhci.sh` riding the runner's `--input` mode.
  NO HID, NO enumeration, NO transfer rings (I2); polled event-ring drain.
  Claim-time observations (BAR base, HCSPARAMS, reset-at-EBS, NO-OP, ports)
  recorded in `docs/hardware-contract.md` with saved logs.

- **2026-08-13 (claim 4272 DONE — XHCI transport live on VZ):** I1
  complete. The discovery-first boot observed the device on bus 0 **dev 8**
  (DID 0x1a06 CLS 0x0c0330), BAR0=0x50001000 (cap regs) / BAR1=0x50000000,
  CAPLENGTH=0x20 / HCIVERSION=0x110 / DBOFF=0x940 / RTSOFF=0x520 /
  HCSPARAMS1=0x10002010 (16 slots/32 intrs/16 ports). **Claim-time fix:**
  the interrupter register set i lives at RTSOFF+0x20+(0x20×i) — writing
  ERSTSZ into the MFINDEX region (RTSOFF+0x00) wedged the emulation (a
  no-fault boot hang; stage-attributable via the debug seam), moved to +0x20.
  **Observed:** VZ does NOT reset the controller at ExitBootServices
  (pre-reset USBSTS=0x9/USBCMD=0x0); after HCRST+RS USBSTS=0x0 and the NO-OP
  command completed with CC=1 (the ring machinery proven). **Ports 9 and 10
  report CCS=1** — exactly the two HID devices (keyboard + pointer), the I2
  handoff; ports 1-8/11-16 report CCS=0. `usb` monitor command (registry
  37→38). Gate `tools/verify-live-xhci.sh` PASS 1/1 (14/14 assertions; the
  guest's own `usb` report is the evidence — the card's gate-shape change:
  byte-exact host capture does not apply to a memory-mapped controller).
  Class A green (fmt, 341 unit tests, test-console + byte-identical
  transcript, build/image/inspect, swift build, context, coordination ×2,
  mmu-debt); the default VM stays byte-identical (`zig build run` green, no
  XHCI lines in the default serial log — `--input` is flag-gated OFF). Docs
  reconciled: march-m7 I1 row ✅, roadmap, status.md (milestone-seven row +
  next-rung → I2),  gate-inventory (new `live-xhci` gate + verify-vz 38→39),
  hardware-contract XHCI bullet, justfile. Claim 4272 flipped ✅.

- **2026-08-13 (claim 4116, milestone seven card I2 — USB enumeration + HID):**
  claimed I2 on top of I1. Scope per `docs/march-m7.md` I2 row: port reset →
  Enable Slot → Address Device → device/config descriptors over the control
  endpoint (Setup/Data/Status TRBs) → select config 1 → arm the interrupt-IN
  endpoint → HID boot-protocol report parsing; `usb devices` + `usb report`.
  Key-input question resolved at claim time: VZ has no programmatic
  keyboard-injection API — `VZUSBKeyboardConfiguration` is driven only by a
  `VZVirtualMachineView` forwarding host key events (SDK verified); I2 adds a
  minimal synthesized-keyDown seam, the full scripted surface stays I3.

- **2026-08-13 (claim 4116 DONE — milestone seven card I2 — USB enumeration + HID):**
  implemented the enumeration + HID path in `kernel/src/xhci.zig` (DCBAA +
  device contexts + input context, per-slot control transfer rings, Enable
  Slot / Address Device / Configure Endpoint / Set Address commands, Setup/
  Data/Status transfer TRBs, interrupt-IN arming, HID boot-protocol report
  parse) and the `usb devices`/`usb report` subcommands. **Live on VZ:** BOTH
  devices enumerate end to end — the keyboard (port 9, slot 1, VID 0x05ac PID
  0x8105, boot protocol=1, EP1-IN maxpkt 8, boot=1) and the absolute pointer
  (port 10, slot 2, VID 0x05ac PID 0x8106, protocol=0 — NOT a boot mouse —
  EP1-IN maxpkt 10, Set_Protocol(boot) honestly REFUSED boot=0). A synthesized
  host keyDown (macOS keyCode 0, dispatched by the runner's minimal
  `--input-key`/`--input-key-after` seam — VZ has no programmatic keyboard API)
  produced the observed 8-byte report `00 00 04 00 00 00 00 00` (mod 0, HID
  usage 0x04 = 'a'). Gate `tools/verify-live-usb.sh` PASS 1/1 (11/11
  assertions; the guest's own `usb devices`/`usb report` lines are the
  evidence — no host-side byte-exact capture applies to a memory-mapped
  controller). Class A green (fmt, unit tests, test-console + byte-identical
  transcript, build/image/inspect, swift build, context, coordination ×2,
  mmu-debt); the default VM stays byte-identical (no XHCI/USB lines in the
  default serial log). Docs reconciled: march-m7 I2 row ✅, roadmap,
  status.md (milestone-seven row + next-rung → I3), gate-inventory (new
  `live-usb` gate + verify-vz 39→40), hardware-contract HID bullet, justfile.
  Claim 4116 flipped ✅.

- **2026-08-13 (claim 6050, milestone seven card I3 — event FIFO + keycode decode → Road Pops):**
  claimed I3 on top of I2. Scope per `docs/march-m7.md` I3 row: a bounded BSS
  event FIFO (interrupt-IN reports → keyboard/pointer events, pushed from the
  shell-idle-loop drain site, consumed by the Road Pops line editor),
  HID-usage → ASCII decode (modifiers + shift, the usable subset), pointer
  motion/buttons recorded, the `input` monitor command, and the runner's
  scripted key-sequence surface (`--input-string`). Key input questions
  recorded at claim time: does VZ honor the NSEvent `modifierFlags` (.shift)
  in the HID report, or must the runner dispatch an explicit shift key —
  observed, not assumed; the pointer's 10-byte absolute report shape —
  recorded best-effort.

- **2026-08-13 (claim 6050 — I3 DONE):** the full pipeline landed and is
  live-gated. `kernel/src/input.zig` (a bounded pure-BSS event FIFO +
  HID-usage → ASCII keymap + the shell-idle drain) decodes the XHCI
  interrupt-IN reports into bytes that the Road Pops tee's read path hands to
  the line editor; `input` monitor command (registry 38→39). The runner's
  `--input-string`/`--input-string-after` synthesizes one NSEvent per
  keyDown/keyUp into the VZVirtualMachineView (VZ has NO keyboard API).
  **Claim-time findings (observed, never assumed):** VZ delivers ~one report
  per Road Pops present cadence — typing faster than ~2 s per keystroke drops
  reports — so the seam types at 2 s spacing; single-TRB arming (re-armed per
  completion) is the correct shape (a multi-TRB depth-8 experiment wrapped the
  transfer ring at the 8th report and dropped everything after — reverted);
  `input.drain()` runs BEFORE `road_pops.drain()` so a report is never starved
  behind a slow full-frame present. New class-B gate
  `tools/verify-live-input.sh` **PASS 1/1 (8/8 assertions)**: the keyboard
  typed `input\n` and the guest's own `input` report showed `events=6`
  (i,n,p,u,t,Enter) with `dropped=0`, `kb-usage=0x28 kb-byte=0xa` (Enter).
  Class A green (fmt, 341 unit tests, test-console + byte-identical
  transcript, build/image/inspect, swift build, context, coordination ×2,
  mmu-debt); the default VM stays byte-identical (no xhci/input/usb lines in
  the default serial log). Docs reconciled: march-m7 I3 row ✅, roadmap,
  status.md (milestone-seven row + next-rung → G5), gate-inventory (new
  `live-input` gate + verify-vz 40→41), hardware-contract report-cadence
  bullet, justfile. Claim 6050 flipped ✅.

## Milestone six card G5 — Driving Award (claim 1543)

Claimed 2026-08-13 on `freebuff/can-you-check-out-...-5fc`. The window
manager: a bounded fixed-BSS window registry, z-order, focus, hit-testing,
dirty-rect redraw, and a compositor blitting window buffers into the G1
framebuffer. Road Pops becomes window 0 (the terminal); a 1 Hz clock window
overlaps it and proves distinct window content + focus. `win` monitor
command, host tests pin the hit-test + redraw contracts, and the live gate
asserts two overlapping windows with the right z-order and keyboard input
landing in the focused terminal.

## Milestone six card G5 — Driving Award (claim 1543) ✅

DONE 2026-08-13, live-gated on VZ. `kernel/src/driving_award.zig` is a
bounded fixed-BSS window registry (max 8) with z-order = array order,
focus tracked by id, topmost-window hit-testing, and a dirty-rect
compositor that repaints from the LOWEST dirty window up and pushes one
transfer + flush per dirty batch. Road Pops is window 0 (the full-screen
terminal; its buffer IS the G1 framebuffer); window 1 is a 1 Hz clock
overlay (960,16 304x192) with its own BSS back-buffer (amber title bar
0xb58900 / navy body 0x0a1a2e), redrawn from `timer.ticks` by the shell
idle loop. The G3 tee's present routes through the compositor
(`rp_text_present` -> `driving_award.composite`), `text put`/`clear`
composite too, and the I3 keyboard read source is gated on
`terminal_focused()` — screen-side input lands in the focused terminal.
`win`/`win focus <n>`/`win raise <n>`/`win hit <x> <y>` (registry 39->40);
9 host tests pin the hit-test/raise/focus/repaint-from-lowest-dirty/clock/
blit contracts. `tools/verify-live-win.sh` PASS 1/1: the serial session
(windows=2, hit-test focusing the clock then the terminal) + a
keyboard-typed `uname` landing in the focused terminal (`DipshitOS
aarch64`), and the decoded capture shows two overlapping windows with the
right z-order (amber title bar + navy body over the terminal; no terminal
foreground inside the clock rect; green glyphs beside it). Full class A
green (fmt, 361 unit tests incl. 9 driving_award, byte-identical
transcript with the `win` help entry, build/image/inspect, swift build,
context, coordination x2, mmu-debt); the default VM stayed byte-identical
(no win/clock lines without --display). Added driving_award + input + xhci
to the unit-test module list. Docs reconciled: march-m6 G5 row ✅,
roadmap, status.md (milestone six + seven rows flip to done, next-rung ->
G6), gate-inventory (new `live-win` gate + verify-vz 41->42), 
hardware-contract G5 color-pipeline bullet, justfile.

## G6 — draw/window syscall seam (claim 0487) ✅ live 2026-08-13

Milestone six closed. ADR 0007 amendment slots 12/13/14
(`sys_win_open`/`sys_win_fill`/`sys_win_present`, implemented 12 → 15):
`sys_win_open(x,y,w,h)` opens a bounded kernel-owned user window (id 2..3,
fixed BSS back-buffer ≤ 256×192 B8G8R8X8), `sys_win_fill` fills a rect,
`sys_win_present` marks it dirty for the compositor — no uaccess (plain
numbers; the kernel owns the buffers), no per-process ownership (the
window persists after exit, the honest bound). `driving_award.zig` gained
the `.user` kind + two back-buffers + the paint path (3 new tests);
`syscall.zig` gained the three handlers + the EINVAL/ENOSPC mapping (1 new
test); `user/src/win.zig` (WIN.BIN, the first graphics user program, 1
test) drives open → fill (dark-blue 0x1a2b3c bg + red/cyan/white blocks)
→ present → exit 87. build.zig/image/make-image.sh/mkfat32.py embed
WIN.BIN. Claim-time fix: the bg-color immediate was encoded as
`movz #0x1a2b,lsl#16` + `movk #0x3c` (0x1a2b003c — above the 24-bit cap,
so the fill EINVAL'd and the program parked after `win: open id=2`);
corrected to `movz #0x1a,lsl#16` + `movk #0x2b3c`. Live gate
`tools/verify-live-win-syscall.sh` PASS 1/1 (9/9 serial + the decoded
capture): the program's markers, `win: windows=3 focused=2` +
`win[2]: user user rect=64,64,256,192` z=2, `syscalls` implemented=15
(open=1/fill=4/present=1), and the window's own red/cyan/white +
dark-blue content over the terminal (no terminal foreground showing
through). Full class A green (fmt, 365 unit tests, byte-identical
transcript, build/image/inspect with WIN.BIN embedded, swift build,
context, coordination ×2, mmu-debt); the default VM stayed byte-identical
(sys_win_open returns EINVAL when the manager is unarmed — no gpu). Docs:
march-m6 G6 row ✅, roadmap, status.md (milestone six row → cards G1–G6
live, closed), gate-inventory (new `live-win-syscall` gate + verify-vz
42→43), hardware-contract G6 color bullet, ADR 0007 amendment, justfile.

## G6 teardown follow-on — `win close` + `sys_win_close` ✅ 2026-08-13

The G6 seam could open windows but not release them, so a user window
leaked until reboot. This follow-on adds the teardown half (no new card,
the claim-0487 branch): `driving_award.user_close(id)` frees a user slot
(2..3), un-presents the window, and recomposites (refusing the fixed
terminal 0 + clock 1 — one new driving_award test pins open → close →
re-open + the fixed-window refusal). `sys_win_close` = slot 15
(`implemented_count` 15 → 16) is the EL0 half; the monitor's
`win close <n>` is the EL1h half — both call `user_close`. The syscall
close round-trip (open → fill → present → close → re-open → ENOSPC) is
host-tested in `syscall.zig`; the monitor `win` help/usage and the
`syscalls` report grow to 16 rows (`  15 sys_win_close calls=0`), and the
transcript fixture re-derived byte-identical. The live gate
`tools/verify-live-win-syscall.sh` now asserts implemented=16 with slot 15
registered (calls=0 — WIN.BIN still lets its window persist, the G6 pixel
proof). Docs: ADR 0007 slot-15 row, claim 0487 follow-on note, march-m6
G6 row, roadmap, status, gate-inventory, claims README, justfile.

## G6 teardown follow-on 2 — WINCLOSE.BIN live release proof ✅ 2026-08-13

The close slot + `win close` command landed (follow-on 1), but the release
path was only host-tested — WIN.BIN still lets its window persist (the G6
pixel proof depends on it). This follow-on adds a SEVENTH image
`user/src/winclose.zig` → WINCLOSE.BIN (open → fill → present → CLOSE via
slot 15 → exit 88, 'X') that proves the teardown LIVE from EL0, embedded
through build.zig / make-image.sh / mkfat32.py (2 host tests pin the
marker shapes). New class-B gate `tools/verify-live-win-close.sh` PASS 1/1
(8/8): `win: close ok` x2, `win: open id=2` x2 (never id=3 — the freed
slot reused, not leaked), `procs WINCLOSE.BIN exited status=88` x2,
`win: windows=2` + no `win[2]:` row (the window disappeared from the
registry), and the pre-re-exec `syscalls` snapshot implemented=16 with
open=1/close=1. verify-vz aggregate 43 → 44. Docs: ADR 0007 (WINCLOSE.BIN
as the EL0 release proof), claim 0487, march-m6 G6 row, roadmap, status,
gate-inventory (new `live-win-close` gate), claims README, justfile.

## G6 ownership follow-on — per-process windows + auto-close ✅ 2026-08-13

The seam could open/close windows but they were kernel-global (persisted
after the owner exited — the original G6 "honest bound"). This follow-on
adds REAL teardown semantics: `driving_award.Window` gains `owner: ?usize`,
`user_open(x,y,w,h,owner)` records the caller's pid, `user_owner(id)`
exposes it, and `close_owner(pid)` releases every window owned by a process
(a shared `remove_user_at` primitive behind `user_close` + `close_owner`).
The syscall layer records the caller (`process.find_by_task(scheduler.current_id())`)
at `sys_win_open` and restricts `sys_win_fill`/`present`/`close` to the
owner (EINVAL otherwise); the EL1h `win close` stays privileged. The
scheduler's `exit_current` calls `close_owner(pid)` so a process's windows
auto-close when it exits. Host tests: a driving_award `close_owner` test
(two windows → both released → slot reused) and a rewritten syscall
round-trip test (open records owner, fill/present/close owner-restricted,
cross-process refusals, and exit → auto-close with `sys_win_close` calls
still 3 — the teardown is not a syscall). WIN.BIN's window now vanishes on
exit, so an EIGHTH image WINLOOP.BIN (`user/src/winloop.zig`) opens the
same window and yield-loops forever, keeping it on the scanout. The
restructured `tools/verify-live-win-syscall.sh` PASS 1/1: WIN.BIN's markers
+ auto-close (`win: windows=2`, `sys_win_close calls=0` after exit),
WINLOOP's persistent window (`windows=3` + `win[2]:` row, open=2/fill=8/
present=2), and the decoded capture still pixel-proves EL0 rendering.
`tools/verify-live-win-close.sh` still PASS 1/1 (explicit close + slot
reuse). Full class A green (fmt, 367 unit tests, byte-identical transcript,
build/image/inspect with WINLOOP.BIN embedded). Docs: ADR 0007 ownership
amendment, claim 0487, march-m6 G6 row, roadmap, status, gate-inventory,
claims README, justfile (WINLOOP build/image). verify-vz count unchanged
(44 — the G6 gate was restructured, not added).

## Runtime-visible ownership (claim 0487 follow-on)

`win` now surfaces per-process ownership: each registry row carries an
`owner=` column (the owning pid for a `.user` window, `-` for the fixed
kernel-owned terminal + clock), and `win list <pid>` filters the registry
to one process's windows (header `win list: pid=<pid> matches=<n>` then the
matching rows via the shared `print_win_row` formatter). The G6 live gate
(`tools/verify-live-win-syscall.sh`) re-ran PASS 1/1 with four new
assertions: `win[2] ... owner=2`, the fixed windows `owner=-`,
`win list 2` → matches=1, and a non-owner `win list 0` → matches=0. Full
class A green (fmt, 367 unit tests, byte-identical transcript with the
updated `win` help entry, build/image/inspect); the default VM is
unchanged (the owner column is part of the `win` report, which only exists
under `--display`). Docs: claim 0487, gate-inventory (live-win-syscall row
+ GATE id line). verify-vz count unchanged (44).

## win_move/win_raise syscall slots (claim 0487 follow-on)

The draw/window seam now moves and restacks: ADR 0007 slots 16/17
(`sys_win_move` / `sys_win_raise`, implemented 16 → 18) reposition and
raise the CALLER'S window from EL0 — `driving_award.user_move` clamps
on-scanout (a window never moves off-screen) and `driving_award.user_raise`
reorders the z-order, both owner-restricted like fill/present/close. The
monitor's `win move <n> <x> <y>` is the EL1h half (`win raise <n>` already
existed). A NINTH image WINMOVE.BIN (`user/src/winmove.zig`, 608 B)
drives it live: open → fill → present → move(800,400) → move(1200,700) —
the CLAMP proof, clamps to (1024,528) — → raise → yield-forever. New
class-B gate `tools/verify-live-win-move.sh` **PASS 1/1** (14/14 serial
assertions + the decoded capture): the clamped rect (`win[2]: user user
rect=1024,528,256,192 owner=<pid>`), the counters (implemented=18,
open=1/fill=4/present=3/move=2/raise=1/close=0), the EL1h halves
(`win move 2 1024 528` + `win raise 2`), and the window's red/cyan/white
blocks + dark-blue background at the NEW position with the terminal where
it used to be. The `syscalls` implemented count moved 16 → 18, so the
win-syscall + win-close gates were re-derived (both re-ran PASS 1/1).
Full class A green (fmt, 368 unit tests incl. 1 new driving_award + the
syscall move/raise round-trip, byte-identical transcript with the `win
move` help entry, build/image/inspect with WINMOVE.BIN embedded, swift
build); the default VM is byte-identical (no win/sys_win lines without
--display). Docs: ADR 0007 slots 16/17, claim 0487, march-m6 G6 row,
roadmap, status, gate-inventory (new live-win-move gate + GATE id line),
justfile. verify-vz aggregate 44 → 45.

**Read-back follow-on (this branch):** `sys_win_get` (slot 18,
implemented 18 → 19) copies the caller's window rect (x, y, w, h as four
u32 LE words — 16 bytes) OUT through uaccess — the ONE pointer-taking win
slot — so an EL0 program reads its clamped position back after
`sys_win_move` (the move is silent). `kernel/src/driving_award.zig`
gains `user_rect(id)` (+ a clamp read-back test); `kernel/src/syscall.zig`
gains `handle_win_get` (owner-restricted like fill/present/close, EFAULT
for a bad buf — 1 new host test covering the open rect, the clamped rect,
EFAULT, and the unknown/fixed/non-owner EINVALs) and the report grows to
19 rows. WINMOVE.BIN now calls slot 18 after its clamped move and prints
`winmove: get 1024,528,256,192` (a decimal-print subroutine, the
peer/counter `udiv` pattern) — 879 B. `tools/verify-live-win-move.sh`
re-derived: the get=1 marker + implemented=19 + `18 sys_win_get calls=1`
assertions; win-syscall + win-close gates re-derived to implemented=19.
Full class A green (fmt, 370 scheduler + 355 monitor + the new
driving_award/syscall/winmove tests, byte-identical transcript,
build/image/inspect with the larger WINMOVE.BIN embedded, swift build);
the default VM is byte-identical (no win/sys_win lines without
--display). Docs: ADR 0007 slot 18, claim 0487, march-m6 G6 row,
roadmap, status, gate-inventory, justfile, claims README. verify-vz
count unchanged (45 — the move gate was extended, not added).

**Full-state query follow-on (this branch):** `sys_win_query` (slot 19,
implemented 19 → 20) copies the caller's window FULL state (x, y, w, h,
z, focused, visible, dirty as eight u32 LE words — 32 bytes) OUT through
uaccess — the second pointer-taking win slot — so an EL0 program
introspects z-order rank + focus + visible/dirty, not just the rect.
`kernel/src/driving_award.zig` gains `user_query(id)` (+ a test pinning
the open state, a second window's focus/z, and the raise reorder);
`kernel/src/syscall.zig` gains `handle_win_query` (owner-restricted,
EFAULT for a bad buf — 1 new host test) and the report grows to 20 rows
(the report mock capacity was bumped 512 → 1024 to fit). WINMOVE.BIN now
calls slot 19 after its clamped move and prints
`winmove: query 1024,528,256,192 z=2 focused=1 visible=1 dirty=1` — 1198 B.
`tools/verify-live-win-move.sh` re-derived: the query=1 marker +
implemented=20 + `19 sys_win_query calls=1`; win-syscall + win-close
gates re-derived to implemented=20. All three win gates re-ran PASS 1/1
on VZ. Full class A green (fmt, 372 unit tests, byte-identical
transcript, build/image/inspect with the larger WINMOVE.BIN embedded,
swift build); the default VM is byte-identical. Docs: ADR 0007 slot 19,
claim 0487, march-m6 G6 row, roadmap, status, gate-inventory, justfile,
claims README. verify-vz count unchanged (45 — the move gate was
extended, not added).

## sys_win_set_visible (slot 20) — hide/show from EL0 + pixel disappear/return

The set_visible follow-on (ADR 0007 slot 20, implemented 20 → 21): an
EL0 program can HIDE (`visible` 0) or SHOW (`visible` 1) its OWN window
through `sys_win_set_visible(id, visible)` — `driving_award.user_set_visible`
toggles the `visible` flag (owner-restricted: the fixed terminal + clock
are refused, a non-0/1 flag is EINVAL). Hiding marks the terminal dirty so
the next composite repaints over the hidden window; showing marks the
window dirty so it reappears — the back-buffer + z-order rank are
untouched (only the flag flips). `kernel/src/driving_award.zig` gains
`user_set_visible` (+ a test pinning hide/show idempotence and the
fixed-window refusal); `kernel/src/syscall.zig` gains
`handle_win_set_visible` (+ a host test covering hide/show, the non-0/1
flag EINVAL, and the unknown/fixed/cross-process refusals); the report
grows to 21 rows. WINMOVE.BIN now hides its window, sleeps 2 ticks
(holding it hidden while the gate captures the GONE frame), shows it
again, and prints `winmove: hide ok` / `winmove: show ok` — 1340 B.

The live gate's pixel proof now needs TWO captures: the marker-driven
capture (a NEW `--screenshot-after <marker>` VMRunner flag that captures
the framebuffer once when a serial marker appears) proves the PIXEL
DISAPPEARS, and the LATEST fixed capture proves it RETURNS.
`tools/verify-live-win-move.sh` re-derived: hide=1/show=1/set_visible=2 +
implemented=21 + the two-capture decode (no red/cyan/white blocks at the
clamped spot while hidden; the blocks back after the show); win-syscall +
win-close gates re-derived to implemented=21. All three win gates re-ran
PASS 1/1 on VZ. Full class A green (fmt, 374 unit tests, byte-identical
transcript, build/image/inspect with the larger WINMOVE.BIN embedded,
swift build); the default VM is byte-identical. Docs: ADR 0007 slot 20,
claim 0487, march-m6 G6 row, roadmap, status, gate-inventory, justfile,
claims README. verify-vz count unchanged (45 — the move gate was
extended, not added).

- **2026-08-14** — *buffy*: claim 4755 complete — the public documentation
  site + Boris GitHub Pages publication. New `site/` corpus (8 trunks + 17
  satellites, wiki-linked; home, getting started, architecture, capabilities,
  roadmap, names/lore, evidence/testing, development), `themes/dipshitos/`
  (dark "technical manual" theme, phosphor-green accent, system fonts, no JS,
  a11y), `.github/boris-pin.json` (revision 30805ab, Boris v0.8.1, the same
  revision Oliver pins), `.github/workflows/docs-gate.yml` +
  `.github/workflows/github-pages.yml` (shared pin, `configure-pages`
  project-site resolution, `prepare-github-pages-artifact.sh` public/proof
  boundary, pinned actions, optional post-deploy audit), and a rewritten
  concise README. `site/index.assets/screenshot.png` is a fresh live capture
  (Road Pops + Driving Award clock). Verified locally against the pinned Boris
  binary: plan → project-site `/DipshitOS`; validate → 1 target ok; compile →
  25 pages + sitemap + assets; prepare → 28 files, `proof_paths_excluded:
  true`, no `_boris/proof` in the public tree. Kernel/tests untouched. ✅ done

- **2026-08-14** — *buffy*: claim 8938 complete — milestone-eight card U0, the
  human interface guidelines (docs only). Wrote `docs/decisions/0008-human-interface-guidelines.md`
  (D1 command grammar + grouped help, D2 prompt/editing model, D3 error/usage
  contract, D4 Driving Award visible focus + click/raise/cycling, D5 support
  surface, D6 gate-enforceability) and `docs/march-m8.md` (the U0–U8 card
  ladder — help/catalog, editing/history, error contract, pointer focus,
  window HIG, first-boot, sysinfo, persistent settings — each with its gate,
  plus the collision-free agent split). Explicitly NOT an ADR 0007 change and
  NOT a POSIX/readline promise. Also recorded a docs follow-on: post the
  source-available-not-open-source license clearly on the public site. ✅ done

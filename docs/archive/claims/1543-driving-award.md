# Claim: Milestone six, card G5 — Driving Award, the window manager

- **Owner:** buffy (`freebuff/can-you-check-out-our-status-and-work-on-the-next--7e2ecd0b-8acc-47ac-bb44-68841236e5fc`)
- **Prompt / plan:** `docs/march-m6.md` G5 row — the final milestone-six rung, on
  top of G1 virtio-gpu (claim 6053), G2 text (claim 3194), G3 Road Pops
  (claim 1574), and milestone seven's I1/I2/I3 input path (claims
  4272/4116/6050).
- **Scope:** a bounded window manager (`kernel/src/driving_award.zig`): a
  fixed-BSS window registry with z-order, focus, hit-testing, dirty-rect
  redraw, and a compositor that blits window buffers into the G1
  framebuffer. Road Pops (the G3 boot terminal) becomes the FIRST window;
  a second demo window (a live 1 Hz clock) proves multiple overlapping
  windows with distinct content + focus. The `win` monitor command reports
  the registry, and host tests pin the hit-test + redraw contracts.
- **Depends on:** milestone seven I3 (claim 6050) — G5 consumes the input
  path so keystrokes land in the focused window.
- **Status:** ✅ done 2026-08-13 — live-gated on VZ (`tools/verify-live-win.sh` PASS 1/1, 8/8 serial assertions + the decoded-capture phase): two overlapping windows with the right z-order (the clock's amber title bar + navy body over the terminal) and a keyboard-typed `uname` landing in the focused terminal

Copy to `docs/claims/<NNNN>-<slug>.md`, fill it in, set Status to
`🔄 <branch>` **before** starting work, then run
`bash tools/status/refresh-indexes.sh` to regenerate the index (never
hand-edit it). Flip Status to `✅`/`⛔` on completion.

## Notes

Driving Award is the window manager: the machine boots to Road Pops as a
registered window (window 0, the terminal), with a small clock window
(window 1) overlapping its top-right corner. The compositor repaints dirty
windows in z-order into the shared scanout framebuffer and pushes one
transfer + flush per dirty batch. The clock redraws on the 1 Hz generic
timer, proving a window whose content changes without terminal output.
Input (the I3 keyboard path) keeps feeding the Road Pops line editor
whenever Road Pops is focused; `win focus <n>` / `win raise <n>` /
`win hit <x> <y>` exercise the focus + hit-test contracts live.

Verified by `tools/verify-live-win.sh`: two overlapping windows in the
captured frame (the clock's distinct color family over the terminal's
green glyphs), the right z-order, and a keyboard-typed command landing in
the focused terminal.

# Log — `agent/buffy/m23-m24-gate-sweep`

## 2026-08-25 — M23/M24 gate sweep blocked by two kernel bugs

Attempted to write and run class-B VZ gates for M23 EDIT.BIN (E2-E5) and
M24 CALC.BIN (K1-K16). Found two kernel bugs that block ALL desktop-launched
GUI app gates:

### Bug 1: #562 — sys_exec ENOENT for ELF binaries through desktop

When DESKTOP.BIN launches an ELF binary (CALC.BIN) via sys_exec (slot 28),
the kernel returns ENOENT (-6). DSK1 (FILE.BIN) and DSK3 (EDIT.BIN)
binaries launch fine. The monitor's `exec CALC.BIN` works at any point
(same exec_file function). After a monitor exec primes the lookup, the
desktop's sys_exec also works — intermittent behavior suggesting a FAT
directory-walk cache issue.

### Bug 2: #563 — virtio INPUT queue stops polling after app launch

After DESKTOP.BIN launches a GUI app (EDIT.BIN), the idle loop's
poll_input() stops processing completions from the custom-virtio INPUT
queue. Keyboard events sent via --via-virtio are enqueued by the host
(confirmed: CUSTOM-VIRTIO-INPUT: sequence complete n=32 ok=true) but the
guest never processes them. Down arrows and Return key work (desktop
receives them), but after EDIT launches, no more keyboard events are
processed. This blocks ALL desktop-launched GUI app gates.

### What was accomplished
- Wrote verify-live-editor-undo.sh gate script (M23 E2) — validates on
  disk but cannot pass due to #563
- Confirmed EDIT.BIN launches through desktop (pid=2, edit: ready)
- Confirmed FILE.BIN launches through desktop (pid=2, file: ready)
- Confirmed CALC.BIN FAILS through desktop (err=6) — #562
- Confirmed --via-virtio bypasses the NSEvent activation wall (#179)
- Confirmed all 32 keyboard strokes reach the guest's virtio queue
- Filed both bugs with full reproduction steps and serial evidence

### What's needed to unblock
Fix #562 (FAT lookup cache for ELF binaries) and #563 (idle loop polling
after app launch). Both are kernel-level issues invisible to host tests.

### Touches
tools/verify-live-editor-undo.sh (new, gate script), docs/claims/4354
(claim flipped ⛔), docs/logs (this file). No kernel or userland code
changes — bugs filed, not fixed.

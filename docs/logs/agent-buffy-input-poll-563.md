# Log — agent/buffy/input-poll-563

- **2026-08-26** — *buffy (agent/buffy/input-poll-563)*: claim 1382 opened → issue #563 (virtio INPUT queue stops polling after desktop launches a GUI app). Static analysis of the existing repro evidence (`artifacts/repro563-serial.log`): all 16 injected strokes decoded (`events=16`, `kb-usage=0x8`), but EDIT.BIN never wakes (window 5 dirty=1, presents stuck at 13) and `dui` reports `focused=3` while desktop holds window 4 and EDIT holds window 5. The `poll_input()`-stops hypothesis is contradicted by the counters — the decoded KEY_DOWNs must be routed to the wrong owner or wake delivery to the blocked task fails. Two boot-time user windows (ids 2,3) exist at DESKTOP's `win_open` (restore_state from WINDOWS.SAV with owner 99) and are gone by the report — focus/id bookkeeping around restored windows is the prime suspect. 🔄 in progress.- **2026-08-26** — *buffy (agent/buffy/input-poll-563)*: claim 1382 progressing — instruments + repro. Added transient `wm:`/`kb:` trace markers (dbg seam, later stripped) and re-ran the SPIKE repro on a fresh image: the smoking gun — all 32 injected reports were drained and routed to **DESKTOP (pid 1)** (`kb: app=0x1`) while `sys_exec` was still in flight; `wm: open EDIT` + `wm: focus` land AFTER the burst was already consumed. Made the runner's chord injection repeatable locally (ordered `--input-chords` pairs; later reverted — collides with another active claim) and proved with split injection (launch, then type post-`edit: ready`) that the guest post-launch path is 100% healthy: EDIT decoded 5/5 letters and woke (`kb: app=0x2`). **Root cause: not a poll stall — a burst-drain race in the repro harness; the input pipeline is fine.** Real defects found instead: (1) the desktop printed a hardcoded `open id=4` while real ids shift with restored WINDOWS.SAV state — manufactured the phantom `focused=3` window-id confusion; (2) no gate proved *typing into a desktop-launched app*. Fix: `user/src/desktop.zig` prints the real returned window id; new gate `tools/verify-live-desktop-typing.sh` (launch CALC, close, Enter-drag on EDIT, then `--input-string "abcde"` post-`edit: ready`; asserts 5 events decoded + white-glyph pixel clusters x194–266/y169–182). Gate PASSES (92 samples). During canary runs `tools/verify-live-desktop.sh` failed identically on clean main (`err=6` ENOENT for CALC.BIN via ESP lookup) — pre-existing breakage, tracked as follow-up, not in scope. Final: claim flipped ✅; `zig build` + unit tests + `verify-coordination.sh` all pass.

## 2026-08-26 — desktop-gate CALC ENOENT fixed (claim 0478)

Took over the interrupted investigation of `tools/verify-live-desktop.sh`
failing on clean main: `sys_exec("CALC.BIN")` from the desktop returned
`err=6` (ENOENT) even though the ESP snapshot listed CALC.BIN.

Root-caused via transient `execdiag` instrumentation (monitor command + LBA
ring + per-call counters; all stripped before landing):
1. `wf_scan=109107` — the FAT first-fit allocator re-reads each FAT sector
   once per cluster. The ESP's files span clusters 2..21814 (KERNEL.BIN
   alone is 10.5 MB), so every `write_file` scanned ~21.8k clusters (~21.8k
   sector reads). The shell's per-command history save + the M21
   WINDOWS.SAV persist (every 300 idle cycles ≈ 1/s at the real idle rate,
   `wf_calls=57`) issued ~110k transport reads per gate run.
2. The polled virtio-blk transport (queue depth 1) intermittently failed to
   complete a request within its ~2s poll budget (~4× per run; observed
   `fail_avail == fail_used` — the device completes just past the budget).
   A timeout during CALC's root-directory walk returned EOC for
   `fat_entry(2)`, truncating the chain → the slot was never found → ENOENT.
3. Once the exec worked, M24 (595bc71) surfaced: CALC.BIN's window is 424
   tall, above the kernel's 384 user back-buffer → `calc: failed to open
   window`; and the gate's sweep (`echo done-desktop-sweep` BEFORE
   procs/syscalls) let the runner stop the VM mid-`syscalls` report.

Fixes: `FatScan` (one sector of read caching in the alloc scans — 128×
fewer reads, 109,107 → 684); skip byte-identical WINDOWS.SAV persists;
one retry-on-timeout in `virtio_blk.submit` (drain the late completion and
re-issue); `user_buf_h` 384→424 (+ the affected unit tests); gate script2
reordered so the expect marker prints last.

Result: `verify-live-desktop.sh` PASS (CALC/NOTEPAD/TOP/DESKTOP/
MANIFEST/LAUNCH/SYS_EXEC), `verify-live-desktop-typing.sh` PASS (92 glyph
samples), unit tests + fmt + coordination gate green. Full details in
`docs/claims/0478-desktop-gate-calc-enoent.md`.

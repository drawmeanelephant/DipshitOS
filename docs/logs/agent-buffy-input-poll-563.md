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
## 2026-08-26 — claim 0590: issue #553 DEVCONS.BIN typed-input gate proof

Took issue #553 (the only remaining open non-milestone issue): the
verify-live-devcons.sh gate only proves the window path, not typed input at
the in-window prompt. The blocker (#179) is closed and claim 9588's
custom-virtio INPUT channel is productionized (proven end-to-end by the
#563 typing gate). Extending the devcons gate: after `devcons: ready`,
type `dir.bin\n` at the prompt via `--input-string`/`--input-string-after`,
assert the `input` events counter, the sys_exec of DIR.BIN, the child's
serial output, and a screenshot pixel proof of the `> dir.bin` echo in the
log pane.
## 2026-08-26 — claim 0590 DONE: issue #553 DEVCONS.BIN typed-input gate proof

verify-live-devcons.sh now PASSes with the typed-input phase (2/2 boots on
VZ): `dir.bin\n` typed at the in-window prompt over the claim 9588
custom-virtio INPUT queue; `input` events=8; child DIR.BIN prints
`dir: listing /data` / `dir: success` on serial; the `> dir.bin` +
`exec: ok` echoes render in the log pane (pixel proof, 493 white samples).
The phase caught a real pre-existing bug in DEVCONS.BIN: the KEY_DOWN
handler compared ev.arg0 (raw HID usage) against ASCII ranges, rejecting
every printable key and never matching Enter — typing was dead in the app
all along, masked by #179. Fixed to the ADR 0009 convention (arg1 ASCII,
arg0 usage). One transient observed: a single earlier gate run failed at
win_open (`devcons: failed to open window`) with no kernel change between
runs — the same class of host-side latency flake seen during #578's
virtio-blk investigation; the gate passes repeatedly on the fixed code.
Also worth recording: `events` counts DECODED reports in BOTH routing
branches, so events=N alone does not prove delivery to a user window —
the gate asserts delivery via the child's serial output + the rendered
echo instead.
## 2026-08-26 — coordination hygiene: claim 6204 flipped 🔄 → ✅

The coordination gate warned that claim 6204 (audit-2026 maintenance,
owner agent/maintenance/audit-2026-issues) had no commit for 14+ days
while still 🔄. Investigation: the claim's entire scope merged 2026-08-11
via PR #98 (commit 90625fc, merge 4c51c4c) — #93 timer-gate evidence
restored (PASS 3/3), #94 AGENTS.md current-milestone drift fixed
(verified on main), #95 claim 7948 superseded annotation (rode 90625fc;
the file later moved to docs/archive/claims/ by the claim-1601 hygiene
prune). The claim was simply never flipped at merge time, and its branch
log was pruned with the archive, leaving no completion record. Per the
coordination rules (past 14 days, work verifiably complete), this log
entry flips 6204 to ✅ done with a Heartbeat of 2026-08-26. No code
changes; docs-only hygiene.
## 2026-08-26 — open-claim sweep: eight stale 🔄/⛔ claims closed (merged-but-never-flipped)

Follow-up to the 6204 flip: swept every open 🔄/⛔ claim in docs/claims/
against main's history and closed the ones whose scope had actually
landed — the same "merged but never flipped" pattern, at milestone scale:

- claim 0819 (ScrollView, Arc1 #218) — ui.zig ScrollView + FILE.BIN
  integration on main.
- claim 2418 (Checkbox/Toggle, Arc1 #219) — both widgets in ui.zig on main.
- claim 2616 (audit-followup-3, DHCP autonomy) — dhcp.step_lifecycle +
  net_dhcp_poll on main; reworked live gates PASS.
- claim 7127 (audit-followup-1, gates/docs) — verify-vz aggregate +
  win-move dedup + site U4–U8 + AGENTS.md/status.md prose + gate-inventory
  flake registry, all verified on main.
- claim 7302 (audit-followup-2, XHCI depth) — max_report_bytes=10 +
  intr_depth=8 in xhci.zig on main.
- claim 7033 (M19 Lane A shell) — P1–P16 all landed; march-m19 rows closed
  (693/693 shell, 526/526 monitor tests).
- claim 9815 (M22 dev-tools lane) — D1–D16 all closed in march-m22.md with
  PASS gates.
- claim 8777 (M21 window sweep) — ⛔ superseded by 1306, which is itself
  ✅ done 2026-08-26; flipped to ✅ resolved.

Kept open as genuinely active: 2539 (ox-alpha M25 Lane B, heartbeat
08-25), 4354 (M23/M24 gate sweep, partial — noted that its #562 blocker
was fixed by PR #579), 4379 (⛔ intentional lane handoff), 4402 (M27
compositor polish, unimplemented cards). Each flip carries a Heartbeat
and a pointer to this log entry per the 6204/6637 precedent.

## 2026-08-26 — claim 4354 M24 K-row sweep complete (calc-depth gate + two real bugs)

- **verify-live-calc-depth.sh PASS 2/2 on VZ**: one booted image drives K16
  stats, K13 dates, K12 settings, K14 rand, K2 memory, K3 units, K10
  clipboard via `--input-chords`, then K4 PI / K7 DEG-RAD / K6 SCI / K9 EXPR
  via `--pointer-virtio` clicks; success marker rides --script2 after the
  LAST pointer marker. K1 prog gate re-verified PASS.
- **Bug 1 (kernel, hardware-only):** CALC `r` key faulted the app — `fault:
  CALC.BIN far=0x0 ec=0x18` (EL0 data abort at addr 0). Root cause: K13/K14
  read CNTPCT_EL0/CNTFRQ_EL0 from EL0 but CNTKCTL_EL1.EL0PCTEN was never
  set, so the read trapped and the fault dispatcher reaped the process.
  Fixed: `timer.allow_el0_counter()` (bits 0-3) called from `timer.init()`.
- **Bug 2 (user):** CALC compared `ev.flags & 0x04` (MOD_ALT) for Ctrl
  chords; ADR 0009 MOD_CTRL = 0x0002, so every Ctrl chord was dead in the
  GUI. Fixed to `ui.MOD_CTRL` (runtime + 12 test fixtures).
- **Plumbing:** `comma`/`ctrl-comma` chord tokens (CSV separator can't carry
  a literal `,`); success markers moved to --script2 after the last input
  marker; K4 pixel proof calibrated to the right-aligned display region.
- Rows flipped ✅ gate on observed PASS; claim 4354 → ✅ done.

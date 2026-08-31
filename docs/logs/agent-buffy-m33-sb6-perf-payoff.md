# Log — agent/buffy/m33-sb6-perf-payoff

## 2026-08-31 — claim 6864 opened (SB6: perf payoff vs WMS9 baselines)

Phase-4 payoff card on `agent/buffy/m33-sb6-perf-payoff` off `origin/main`
(SB5 merged, PR #715). The card's "measured, not asserted" requirement:
documented before/after on the WMS9 dynamic + static apps — fill-SVC counts,
composite cost, and copy volume for a migrated desktop vs the pre-seam-B path,
with host measurement + live VZ numbers in the same gate
(artifacts/m33-sb6-perf-payoff.md).

Design: SB6OLD.BIN (pre-seam-B control, unmigrated, slot-13 fills) and
SB6NEW.BIN (seam B, plain stores, zero fills) render the SAME frame; the WM
compose-N counts composes + bytes. New kernel observables: user_blits /
migrated_skips counters in driving_award (+ dui blits=/skips=). The gate
snapshots `syscalls` (slot 13/46), `dui` (presents, blits, skips, last=),
`wm` (present_count) and diffs before vs after.


## 2026-08-31 — claim 6864 DONE (SB6: perf payoff, live gate PASS)

The gate went green on the third live boot. Bring-up findings:

1. **Sustained yield-spins stall user tasks (~1 s in).** The first apps paced
   frames with `while (spin < 100_000) sys_yield()`. Every user task in a
   long spin stalled after the first timer preemption (~9-17 yields): no
   fault line, no exit, shell/worker keep advancing. Reproduced with SB6OLD
   ALONE (no WM) — pre-existing, independent of seam B. WINLOOP/WINMOVE/
   SB4DAM yield-loop forever but their gates pass because evidence lands
   before the stall. Fixed by pacing the SB6 apps with `sys_sleep(1)`
   (blocking — winmove/notepad/status43 prove the path). Flagged in the
   claim + artifacts/m33-sb6-perf-payoff.md for a future scheduler card.
2. **The runner exits at `--script-expect` before a second script2 command
   prints.** script2 was `syscalls\ndui`; the expect on the syscalls line
   killed the VM before `dui` printed. Reordered script2 to `dui\nsyscalls`.
3. **A 0-byte efi-vars.bin fails the VM start** ("Could not open
   variableStore"); the gate scripts `rm` it so the runner creates a fresh
   one (my isolation experiments had to mirror that).

**Result (one boot, same frame, two paths):** SB6OLD = 576 slot-13 fills +
9 presents, kernel blits=20; SB6NEW = plain stores only (0 fills), kernel
skips=22; SB6WM compose-N'd 196,608 bytes (bytes=196608, readback=0x6B) and
issued the final present. `syscalls` snapshot: `13 sys_win_fill calls=576`
(zero from the seam-B app); `dui: windows=4 presents=24 blits=20 skips=22`.
Gate PASS (runner-rc=0, zero faults). Artifact:
artifacts/m33-sb6-perf-payoff.md. Tracker SB6 -> ✅, claim flipped, PR #TBD.

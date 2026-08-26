# Claim: desktop-gate-calc-enoent

- **Owner:** buffy (`agent/buffy/input-poll-563`)
- **Prompt / plan:** `docs/claims/0478-desktop-gate-calc-enoent.md`
- **Scope:** `tools/verify-live-desktop.sh` fails on clean main — `sys_exec("CALC.BIN")` from DESKTOP returns `err=6` (ENOENT) via the ESP lookup; root-cause + fix + gate to green
- **Touches:** kernel/src/fat.zig,kernel/src/shell.zig,kernel/src/virtio_blk.zig,kernel/src/driving_award.zig,kernel/src/syscall.zig,tools/verify-live-desktop.sh,user/src/desktop.zig
- **Depends on:** claim 1382 (issue #563) — desktop prints the real window id
- **Heartbeat:** 2026-08-26
- **Status:** ✅ done 2026-08-26 — gate PASSES end to end. Root cause (three stacked bugs, all pre-existing on clean main, previously masked by the first): (1) the FAT first-fit cluster allocator re-reads the same FAT sector once per cluster — the ESP's files span ~21.8k clusters, so every `write_file` (shell history + the M21 WINDOWS.SAV persist) issued ~21.8k sector reads; the polled virtio-blk transport (~1 in ~4k requests) timed out mid-burst, and a timed-out read during CALC's root-directory walk truncated the chain → ENOENT. (2) The M21 WINDOWS.SAV persist saved every 300 idle cycles — at the real ~250 Hz idle rate that is ~1/s, keeping the transport continuously busy. (3) M24 (595bc71) grew CALC.BIN's window to 424 tall, above the kernel's 384 user back-buffer — `user_open` rejected it (masked by the ENOENT; surfaced once the exec worked). Fixes: FAT-sector caching in the allocator scans (`FatScan`, 128× fewer reads — 109,107 → 684 per run), skip byte-identical WINDOWS.SAV persists, one retry-on-timeout in the virtio-blk submit (transient host-side spikes complete just past the poll budget), `user_buf_h` 384→424 (+ updated unit tests), and the gate's sweep commands reordered so the `done-desktop-sweep` expect marker prints LAST (the runner stops the VM the poll after the marker — the procs/syscalls report was truncated mid-print). Verification: `verify-live-desktop.sh` PASS (all 7 assertions), `verify-live-desktop-typing.sh` PASS (92 glyph samples), unit tests, `zig fmt --check`, coordination gate ok.

## Notes

Diagnosis path: instrumented the exec/ESP/FAT/blk layers with a transient
`execdiag` monitor command + LBA ring + per-call counters. Key evidence:
`execdiag: name="CALC.BIN" lookup=ok read=FAIL esp_entries=48 ... fat_slots=16
hops=1 c0=2>EOC` — the ESP snapshot (48 entries, CALC at slot 16) was intact,
but `fat.read_file`'s root-chain walk died on its FIRST hop (`fat_entry(2)`
read of LBA 2080 failed at the transport). `wf_calls=5 wf_scan=109107` pinned
the storm: five history/persist writes each scanned ~21,822 clusters, one
`fat_entry` (one sector read) per cluster. `fail_avail == fail_used` at every
transport timeout proved the device completes the request just PAST the
guest's ~2s poll budget — a latency spike, not a lost request — so a single
drain-and-reissue retry recovers it. `wf_last="WINDOWS.SAV" wf_calls=57`
showed the persist firing ~1/s under the real idle-loop rate. The console
interleaving observed during instrumentation (a per-tick serial print
corrupting `desktop: menu ready`) is why the diagnostic prints were removed
before the fix was landed.

Verification: `zig build` + `zig fmt --check` + `verify-unit-tests.sh` (all
monitor modules pass, including the updated `user_buf_h` assertions) +
`bash tools/verify-coordination.sh` (ok) + `verify-live-desktop.sh` PASS +
`verify-live-desktop-typing.sh` PASS on VZ.

# Log — `agent/buffy/fix-810-boot-probe-flake`

Branch: Freebuff worktree `freebuff/get-git-up-to-date-...`

## 2026-09-02 — claim 9094 filed; evidence gathered

- Issue #810 filed + extended during the HF7 gate session (2 comments with
  both signatures: silent-stop 5391-B and parked-exception 6040-B dumps).
- Occurrence stats this session: 8/24 boots; the parked variant shows
  `esr=0x97090010 ec=0x25 data-abort-same iss=0x090010`, `far=0x80000178`,
  `elr=text+0x3e194`, `spsr=0x80000005`, frame `sp=0`, `x2=0x8000`,
  x20/x25 = 0x8000_0000/0x4000_0000, x26 = 0x1004_0080 (GICR+0x80),
  x23 = 0x1e (timer PPI 30), right after `tasks worker advances=2112`
  (timer tick activity), during the probe task's exit window.
- Disassembly at text+0x3e194 shows small accessor tails
  (`mov w9,#0x7ff4; cmp x8,x9; ret` — 0x7ff4 = 32756 = 32 KiB − 12) —
  elr may be real (system registers, not the frame) or garbage; symbol
  lookup via the aarch64-elf nm/objdump toolchain next.
- Next: read the boot-probe exit path in main.zig (userspace: line → the
  exit trace), the exception entry/frame in exceptions.zig (what sp=0
  means), the timer tick path, and the 0x80000178/0x80000000 constants.
## 2026-09-02 (2nd) — #810 forensics: frames trustworthy, faults real, v2 dump shipped

- **sp=0 mystery resolved**: the `[EXC]` report's `sp=` is SP_EL0 (the EL1h
  source reads `mrs sp_el0`), legitimately 0 during pure-EL1h execution —
  the parked frames were NEVER corrupted; esr/far/elr/spsr/x19..x28 are
  real. (Found by reading exceptions.zig `source_sp_el0`.)
- **Faults are real EL1h data aborts** ~1.4 s (≈1400 handled IRQs) into
  boot during desktop+scheduler churn, ~1-in-6 boots, across runs 5/10/11.
  A parallel-agent VM load inflates the rate (run 11 had 3 hang-boots).
- **v2 `[DEEP]` dump** (exceptions.zig): downward stack crawl from raw_sp
  (v1 crawled UP into unused stack), x3..x18, and 8 raw instruction words
  at elr±16. Also masks all DAIF after the report (one clean dump per
  hang — runs 7/8's storm was the v1 dump's OWN unbound reads re-faulting;
  bounded reads are SEA-proof). Healthy boots stay byte-identical
  (EL1h-sync-only).
- **Tooling find**: `root_module.strip = false` CHANGES CODEGEN in this
  Zig/LLVM (14 instructions + layout drift vs the default-strip build;
  verified byte-identical when strip left at the ReleaseSmall default) —
  kernel symbol work must rebuild with default strip.
- **Run-11 boots 2/3 decoded to exact instructions** (byte-identical
  rebuild + instruction-word dump + DWARF):
  * Boot 2: elr text+0x371a4 = `ldrb w9,[x20,#0x178]`, x20 = 0xfcab6000 =
    far−0x178 (dead identity-map space → DFSC=0x10 external abort), in the
    scheduler idle/reap inlined region (DWARF scheduler.zig init/reap).
  * Boot 3: elr text+0x3da00 = `ldr x8,[x8]; br x8` through a −1 function
    pointer (far = −1), same shell frame as boot 2 (identical raw_sp
    0x7da72310, "hello.tx" locals — the `vf cat hello.txt` output path).
- **Unifying observation**: every family's corrupted pointer resolves into
  ONE BSS neighborhood — image+0x5dda0 (12×0x180 table, state byte at
  +0x178), ring +0x64fa0 (0x7dadbfa0), +0xae4000 globals (0x7e55b000) —
  so a SINGLE BSS-corrupting writer (the #803/#808 32 KiB staging class)
  is the working root-cause hypothesis. Candidates: the vf 32 KiB
  `vf_reply_buf` exchanges over virtio_custom queue 5; the scheduler reap
  path.
- Posted full decode to issue #810 (comment 3). Claim 9094 stays 🔄 —
  the corrupting WRITER is not yet named; the v2 dump makes the next hang
  self-decoding.
- **2026-09-02 #810 forensics close-out (claim 9094):** BSS-layout check
  via the unstripped twin (strip-independent .bss) names the corrupted
  objects: `scheduler.tasks` 0x5dd30..0x5edb0 = 11 slots × 0x180, +0x178 =
  the LAST Task field `kill_pending` (read at scheduler.zig:720 in
  `stage_current`, the ring-select path), then `process.processes`; the
  vf 32 KiB staging buffers are FAR from tasks (`vf_reply_buf` 0x4455c0,
  `cmd_write_buf` 0xa84d20, `vf_write_buf` 0xad2f20) — no clean overrun
  adjacency, and `tasks` is adrp-fixed so a wild x20 = 0xfcab6000 means a
  LOADED pointer was already corrupted. Writer = a runtime, timing-
  dependent race (slot varies per boot: A +0x178 read / B −1 fn ptr /
  C dead-space read), prime suspect the vf queue-5 exchange era racing
  the tick ring. Kernel-path stack audit complete: NO `reply_cap`-sized
  stack locals remain in kernel paths (virtio_file.zig:766 is test-only;
  all other locals ≤ 4 KiB; #803's cmd_write_buf fix is the pattern).
  Instrumentation v2 (downward crawl + x3..x17 + raw insn words at elr,
  bounded SEA-proof reads, full DAIF mask on park) committed with this
  entry; run 11 already passed 5/6 boots + measurement with retries.
  Claim 9094 stays 🔄 — writer hunt is the next session's job.
- **2026-09-02 #810 writer-hunt instrument (claim 9094, run 12/13):**
  added `scheduler.audit` — task-ring + process-registry INVARIANT audit,
  instrumentation only. Every virtio_file queue-5 exchange arms at entry /
  checks at exit; `reap_one_zombie` and the tick ring-select validate the
  slot before reading it (the exact +0x178 kill_pending read that faulted
  in run-11 boot 2); the idle loop drains violations. Rules: kernel
  pointers ∈ [0x1000, 0x80000000) (256 MiB @ 0x70000000 class ceiling,
  same as the deep dump), ttbr0 additionally page-aligned, state/name raw
  reads that cannot UB on rogue bytes (typed enum loads of rogue bytes are
  UB in safe builds). Run-12 boot 1 caught a TOO-TIGHT rule: saved PSTATE
  legitimately carries PAN/UAO/DAIF bits up to 0x60000000 and 0x80000005
  (the #810 frames' spsr was itself legal!) — dropped the spsr check,
  added (slot,field) repeat-suppression, fixed a `0x0x` hex prefix, and
  made the virtio_file→scheduler import comptime-conditional (host-test
  binaries must not pull in scheduler's transitive test blocks — the
  driving_award SB4 composite test reaches an unconditional `dc ivac`
  that is an illegal instruction on x86 hosts, ABRTing `zig test
  virtio_file`). Run-13 boot 1: exactly ONE `[AUDIT] task-ring+procs
  audit armed slots=11 procs=16` line on a healthy boot — no noise. The
  next hang (if the flake cooperates) prints slot/field/value/tag/tick
  BEFORE the faulting read, naming the corruption window.
- **2026-09-02 #810 RUN-13 CATCH (claim 9094, audit + v2 dump armed):**
  gate run 13 boot 2 hung exactly in the classic window (count=1408,
  ≈1.4 s) with BOTH instruments live. The `[AUDIT]` ring sweep printed
  ONLY the one armed line — **zero task-ring/process violations**: the
  run-10/11 "BSS-corrupting writer" hypothesis is ruled out for this
  family. Self-decoded fault: `esr=0x97080010` with S1PTW (iss bit 19
  = external abort DURING the stage-1 walk), far=0x20080296 resolved by
  the [DEEP] walk to a VALID leaf (l3 pte 0x20080403 → pa 0x20080296,
  low-RAM) under the ACTIVE user root ttbr0=0x7df39000 — the same table
  chain was walked successfully by the instrument immediately after
  (transient window). Regs: x21=0x2008011e (same page as far),
  x25=0x40000000 (rect/device-ish target in the elr text+0x768 window:
  base 0x7daad000, `x9=x25+x20; strb [x9,#0x20]; stp q0,q1,[x9]`),
  x19/x26 = GIC BARs, x23=0x1e, x2=0x8000. Guest RAM class corrected:
  2 GiB @ 0 (kernel image at 0x7daa… = 2 GiB − 22 MiB); exceptions.zig
  + scheduler.zig class comments fixed (the 0x80000000 ceiling bound
  itself was right). Posted full decode to #810 (comment 4), claim
  updated with finding (6). Working theory for the fix: transient
  translation window in the user root / surface region during the
  exec/rebuild_user_root → TTBR0-switch → first-touch era — next
  session's fix candidate is the TLBI/ISB discipline in
  rebuild_user_root_full/apply_pending.

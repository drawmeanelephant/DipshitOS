# Claim: Fix the boot-time EL0 probe hang/park flake (issue #810)

- **Owner:** buffy (`freebuff/get-git-up-to-date-there-were-quite-a-few-things-d-fe3ff43a-1217-4ca3-a9ad-b6faa6fbe86f`)
- **Prompt / plan:** root-cause + fix issue #810 — an intermittent
  boot-time failure AFTER the kernel's EL0 boot probe prints
  `userspace: el0=1 …` but before `tasks user-el0 exited status=7`: the
  runner never forwards the gate script. Two observed signatures:
  (a) SILENT STOP — serial simply ends after the probe report (run 1
  boot 1); (b) PARKED EXCEPTION — an EL1h data abort with
  `esr=0x97090010`, `far=0x80000178`, `elr=text+0x3e194`, `spsr=0x80000005`,
  frame `sp=0`, x1 rodata, `x2=0x8000` (32 KiB), x20/x25 = 0x80000000 /
  0x40000000, x26 ≈ GICR+0x80, x23 = 0x1e (30 = timer PPI), then
  `[EXC] parking`. Observed 8/24 boots in the HF7 session; the HF7 gate
  now retries around it, but the kernel bug is real (same family as #803,
  whose cmd_write fix was ONE stack offender — this looks like a second
  class in the timer/exit path, right after `tasks worker advances=2112`).
- **Evidence:** `artifacts/live-vf-serial-{1..6}.log` (runs 2/5/6/10/11),
  `artifacts/live-vf-run-*.txt`; committed at 30efba2 + 4cc4c25;
  issue #810 (3 comment updates filed 2026-09-02).
- **Findings (2026-09-02, runs 10-11, v2 dumps):** (1) `sp=0` in the
  parked frames is a NON-issue — the report's `sp=` field is `SP_EL0`
  (`mrs sp_el0`, 0 during pure-EL1h execution); every frame carries real
  esr/far/elr/spsr/x19..x28. (2) The faults are REAL EL1h data aborts,
  ~1.4 s (≈1400 handled IRQs) into boot during desktop+scheduler churn,
  ~1-in-6 boots. (3) The corrupted pointers all resolve into ONE BSS
  neighborhood — image+0x5dda0 (a 12×0x180 table with a state byte at
  +0x178 = the scheduler task-table family), ring base +0x64fa0
  (0x7dadbfa0), +0xae4000 globals (0x7e55b000). (4) Decoded to exact
  instructions: run-11 boot 2 = `ldrb w9,[x20,#0x178]` (text+0x371a4,
  scheduler idle/reap inlined code) with x20 = dead identity-map space
  (0xfcab6000, far = x20+0x178, esr DFSC=0x10 external abort); run-11
  boot 3 = `ldr x8,[x8]; br x8` through a −1 function pointer (text+
  0x3da00), same shell frame (identical raw_sp 0x7da72310, "hello.tx"
  locals → the `vf cat hello.txt` output path). Earlier families: reads
  at 0x80000178 (x20 = 0x80000000 = the FIXED pre-ASLR user-stack VA,
  identity-mapped to PA 0x80000000 = exactly top of 256 MiB RAM @
  0x70000000 → dead space → SEA; x2 = 0x8000 = 32 KiB), and far =
  string bytes. (5) Multiple subsystems read the corrupted region at
  different sites per boot → ONE BSS-corrupting writer (the #803/#808
  "32 KiB staging" family) was the working hypothesis — REFINED by the
  BSS-layout check (unstripped twin, strip-independent .bss):
  `scheduler.tasks` spans 0x5dd30..0x5edb0 = 11×0x180 (0x178 = the LAST
  field, `kill_pending`, read by the ring at scheduler.zig:720
  `stage_current`), directly followed by `process.processes`;
  `user_stack` at 0x66000. The vf staging buffers are FAR away
  (`vf_reply_buf` 0x4455c0, `cmd_write_buf` 0xa84d20, `vf_write_buf`
  0xad2f20) — NO clean overrun-lands-in-tasks adjacency. And `tasks`
  itself is adrp-fixed BSS, so a WILD x20 (0xfcab6000) cannot come from
  a sane `tasks[i]` index — the faulting code dereferenced a LOADED
  pointer that was already corrupted. Writer is therefore a runtime,
  timing-dependent race (different corrupted slot per boot: A=+0x178
  read, B=−1 fn pointer, C=dead-space read), not a static overrun.
  Prime suspects remain the vf reply exchanges (queue-5 era, "hello.tx"
  on both decoded stacks) racing the tick/idle ring.
  (6) **RUN-13 CORRECTION — the audit caught this family red-handed:**
  the live `scheduler.audit` sweep (every vf exchange + reap + tick-
  seam) recorded ZERO task-ring/process violations on the run-13 hang
  boot — the ring is CLEAN, so the corruption hypothesis does NOT fit
  this family. The self-decoded fault: `esr=0x97080010` with **S1PTW**
  (iss bit 19 — external abort DURING a stage-1 walk), `far=0x20080296`
  resolved by the [DEEP] walk to a VALID leaf (l3 pte=0x20080403, pa
  0x20080296, low-RAM 512 MiB+ region) under the ACTIVE user root
  (ttbr0 0x7df39000) — the table chain reads back VALID after the fault
  (a transient window); x21=0x2008011e, x25=0x40000000, x19/x26 = GIC
  BARs, x23=0x1e (timer PPI), x2=0x8000; elr text+0x768 (base
  0x7daad000) in code storing qwords/rects toward 0x40000000-class
  targets while referencing the 0x20080000-class page. Guest RAM class:
  2 GiB @ 0 (image at 2 GiB − 22 MiB) — NOT the earlier "256 MiB @
  0x70000000" guess (comments corrected). Working theory: a transient
  translation window in the user root / surface region during the
  exec/rebuild_user_root → TTBR0-switch → first-touch era (the vf era
  is the scheduling context that coincides). Fix candidate: root-switch
  discipline (TLBI/ISB vs first EL1h access) in
  rebuild_user_root_full/apply_pending.
- **Deep-dump instrumentation v2 (claim 9094, exceptions.zig,
  EL1h-sync-only so healthy boots stay byte-identical):** `[DEEP]` block
  on every unhandled EL1h sync — ttbr0/ttbr1/mair/tcr,
  `userspace.user_stack_va()`, a bounded 4-level PTE walk of FAR, and
  now a DOWNWARD stack crawl from raw_sp (v1 crawled UP into unused
  stack; return addresses live BELOW raw_sp), plus x3..x18 and the 8 raw
  instruction words at elr±16 — the dump names its own fault site (runs
  11 boots 2/3 decoded to exact instructions + DWARF lines within
  minutes). Park path masks all DAIF after an EL1h sync report (one
  clean dump per hang; the run-7/8 storm was the v1 dump's OWN unbound
  reads re-faulting — bounded reads are SEA-proof). Tooling note: setting
  `root_module.strip = false` CHANGES CODEGEN (14 instructions + layout
  drift vs. the default-strip build — verified byte-identical when strip
  is left at the ReleaseSmall default); symbol work must rebuild with
  default strip or offsets lie.
- **Touches:** kernel/src/{exceptions.zig, scheduler.zig, virtio_file.zig,
  process.zig} (instruments landed in commits e27503a/76e989b) ·
  docs/claims/9094-fix-810-boot-probe-flake.md ·
  docs/logs/agent-buffy-m34-hf7-clone-dedup.md (appended entry) ·
  possibly docs/status.md, docs/hardware-contract.md. NOTE: overlap
  with ACTIVE claim 1432 (`agent/buffy/m34-flake803`, exceptions.zig)
  is acknowledged — the #810 fix hunt (root-switch discipline) may land
  under that claim or a new one; 9094 stays 🔄 for the instruments +
  verification only.
- **Depends on:** — (flake observed on main-era builds; #808's
  instrumentation is already in tree)
- **Heartbeat:** 2026-09-02
- **Status:** 🔄 in progress — claim 9094 (id via `bash tools/status/claim-id.sh`);
  instrumentation v2 landed + run-11 hang boots decoded (see Findings);
  the corrupting WRITER is not yet named. Run 13 CAUGHT the flake with
  the audit live: **zero ring violations + S1PTW walk fault on a
  transient user-root window** (see Findings) — the corruption theory
  is now mostly ruled out and the fix hunt moves to the root-switch /
  surface translation discipline (TLBI/ISB ordering), with the vf era
  as the coinciding context. The audit + v2 dump remain armed for the
  next catch. **Writer-hunt instrument ADDED 2026-09-02:**
  `scheduler.audit` — a task-ring + process-registry INVARIANT audit
  (instrumentation only, zero behavior change): every virtio_file
  queue-5 exchange arms at entry / checks at exit; `reap_one_zombie`
  and the tick's ring-select validate the slot before reading it; the
  idle loop drains violations. Rules are strict supersets of observed
  legal values (kernel pointers ∈ [0x1000, 0x80000000), the 256 MiB @
  0x70000000 class ceiling; user VAs like sp_el0 are legal and
  excluded; spsr allows only known-condition-bit shapes; raw enum
  reads so a rogue byte can't UB the audit itself). Run 12 will show
  the one-per-boot `[AUDIT] armed` evidence line; a corruption caught
  prints slot/field/value/tag/tick BEFORE the faulting read.

## Notes

Verification: root cause named from the disassembly + source; fix lands;
class-A green (fmt/build/unit/BSS); `verify-live-vf` 6/6 on VZ (the HF7
gate's retries must NOT be what absorbs the flake on the fixed build —
a repeat run should pass without retries, or with measurably fewer).
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
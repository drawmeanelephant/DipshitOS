# Log — `agent/buffy/m22-devtools-d8-d16`

## 2026-08-25 — claim 5220: M22 Lane-D wave-2 live gates (D8–D16) done

Verification slice for the already-merged D8–D16 implementation (claim 0720,
`3fce71b`): wrote and ran all nine issue-named class-B VZ gates on Apple
silicon / macOS 27 — **9/9 PASS, 1/1 boot each**:

verify-live-stat-find (#331), -sysinfo (#332), -resmon (#333),
-crash-viewer (#334), -dmesg (#335), -time (#336), -devcons (#337),
-ls-l (#338), -inventory (#339). Evidence under this worktree's
`artifacts/live-*`.

Two live bugs found and fixed on the way (both invisible to host tests):

1. **ADR 0005 regression in `is_shell_builtin`** (kernel/src/monitor.zig):
   the const `[]const u8` builtins table landed in rodata with unrelocated
   link-time pointers — `which type` took a data abort on real hardware
   (`far=0x4129a`, `[EXC] parking`). Fixed with a comptime `inline for`
   literal list + a monitor.zig regression test (all 528 module tests pass).
2. **DEVCONS.BIN flat-image BSS abort** (build.zig + image/make-image.sh):
   the app's 2.6 KiB log ring had no writable segment in the flat DSK1
   mapping (`far=0x400928`, status 139 before `ready`). RESMON.BIN carried
   the same latent risk. Both now build as SEGMENTED DSK3 via
   `user/linker-segmented.ld` + `elf2bin.py --segments` (the GLOBALS/NETSTAT
   pattern); make-image.sh's magic checks updated to DSK3.

Honest gaps recorded in docs/march-m22.md:
- D9: fresh-boot `sysinfo` omits storage free=/total until an explicit
  `mount esp` (`fat.geometry()` reads empty off the boot window) — follow-up
  issue needed.
- D14: typed-input proof deferred while issue #179 is open.
- D13: `exec` is async, so the gate pins `time sysinfo` (ticks 25) instead
  of a process run.

Coordination note: mid-verification, another thread switched the shared
checkout to `agent/buffy/m26-net-experience` and stashed this WIP. Work was
recovered intact from `stash@{0}` into a dedicated nested worktree and
completed there; no M26 files touched.

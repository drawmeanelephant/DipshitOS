# Claim: M22 developer tools — Lane D-Tools (D1–D16)

- **Owner:** ox-alpha (`lane-d/m22-dev-tools`)
- **Prompt / plan:** `docs/agent-concurrency-plan.md` Lane D-Tools (Phase 1) — GitHub issues #324–#339
- **Scope:** M22 — kernel ELF loader (`kernel/src/elf.zig`, new), symbol table
  (`kernel/src/symbol.zig`, new), strace seam, disassembler/assembler userland
  apps (`user/src/disas.zig`, `user/src/asm.zig`, new), and monitor-command dev
  utilities in `kernel/src/monitor.zig` (ps/printenv/stat/find/dmesg/time/
  ls -l/which/inventory/crash-viewer/sysinfo extension). One PR per issue,
  closed against its GitHub issue.
- **Depends on:** M18 done ✅ (main); no other lane dependency (Phase 1 lane).
- **Status:** 🔄 in progress

## Notes

Per the concurrency plan this lane owns NEW FILES only, with append-only
additions to shared `kernel/src/syscall.zig` (slots 59/60 if needed) and
`kernel/src/monitor.zig` (registry growth). The D1 issue body itself directs
the magic-sniff approach in `exec.exec_file()` over a dedicated
`sys_elf_load` slot — if that holds, slot 59 stays free and the ABI budget
note in `docs/march-m22.md` gets corrected rather than consumed.

Verification: host `zig test` for every touched module, full
`just verify-portable` before each PR, and class-B live gates where the
card names one (verify-live-elf/asm/symbols/disas/strace/stat-find/dmesg/
time/inventory/printenv/ls-l). Live-gate evidence lands under `artifacts/`.

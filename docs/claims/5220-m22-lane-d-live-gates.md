# Claim: M22 Lane-D wave-2 live gates (D8–D16 verification)

- **Owner:** buffy (`agent/buffy/m22-devtools-d8-d16`)
- **Prompt / plan:** GitHub milestone 10 (M22) — close out issues #331–#339 with observed class-B evidence
- **Scope:** M22 Lane-D wave 2 **verification only** — the D8–D16 implementation already
  landed via claim 0720 (`3fce71b`) with host tests green; what is missing is the nine
  class-B VZ gates the issue bodies name, the `docs/march-m22.md` card rows for D6–D16,
  and live evidence under `artifacts/`.
- **Touches:** tools/verify-live-stat-find.sh tools/verify-live-sysinfo.sh
  tools/verify-live-resmon.sh tools/verify-live-crash-viewer.sh
  tools/verify-live-dmesg.sh tools/verify-live-time.sh tools/verify-live-devcons.sh
  tools/verify-live-ls-l.sh tools/verify-live-inventory.sh docs/march-m22.md
  kernel/src/monitor.zig
- **Depends on:** claim 0720 ✅ (D8–D16 implementation on main)
- **Heartbeat:** 2026-08-25
- **Status:** ✅ done (agent/buffy/m22-devtools-d8-d16)

## Notes

**Live bug found + fixed (2026-08-25):** claim 0720's `is_shell_builtin`
held a const `[]const u8` table — ADR 0005's unrelocated-rodata class.
On VZ, `which type` data-aborted the kernel (`far=0x4129a`); host tests
never caught it because the host linker relocates. Fixed with a comptime
`inline for` list + a regression test in monitor.zig.

Per-card gate shape follows each issue body:
- #331 D8 `verify-live-stat-find.sh` — stat a known ESP file, find *.BIN
- #332 D9 `verify-live-sysinfo.sh` — sysinfo shows version/memory/storage/uptime sections
- #333 D10 `verify-live-resmon.sh` — RESMON.BIN opens its window and reports ready (+ screenshot)
- #334 D11 `verify-live-crash-viewer.sh` — CRASH.ELF tombstone detail shows symbol resolution + serial snapshot
- #335 D12 `verify-live-dmesg.sh` — echoed marker reappears inside the dmesg ring dump
- #336 D13 `verify-live-time.sh` — nonzero elapsed ticks around a timed command
- #337 D14 `verify-live-devcons.sh` — DEVCONS.BIN split-screen ready (+ screenshot); typed-input
  proof deferred while issue #179 (synthesized keyboard seam events=0) is open
- #338 D15 `verify-live-ls-l.sh` — ls -l long listing (type bits, root, size)
- #339 D16 `verify-live-inventory.sh` — which builtin/monitor/app/not-found + inventory listing

Evidence policy: every PASS line cites saved logs under `artifacts/live-*`. Issues are only
referenced for closure after the gates actually pass on this machine.

# Log — `freebuff/m22-lane-d-wave2`

## 2026-08-24 — claim 0720: M22 Lane-D wave 2 (D8–D16) done

Implemented all 9 open issues in the M22 Lane-D milestone (issues #331–#339):

**Monitor commands (kernel/src/monitor.zig):**
- D8: `stat` + `find` — filesystem inspection with glob patterns
- D9: `sysinfo` extension — disk free/total, uptime section
- D11: `crash [<index>]` — detailed report with symbol resolution
- D12: `dmesg` — serial ring buffer viewer
- D13: `time <cmd>` — command timing with elapsed ticks
- D15: `ls [-l]` — long listing format
- D16: `which` + `inventory` — command locator and app listing

**Userland apps:**
- D10: RESMON.BIN — resource monitor window (simplified, honest about missing syscalls)
- D14: DEVCONS.BIN — developer console with command prompt (simplified)

Registry: 59 → 65 commands. All 526 host tests pass. Both userland apps build for aarch64-freestanding.

Evidence: `artifacts/` pending (class-B live gates require VZ boot).

# Claim: M22 Lane-D wave 2 — D8–D16 developer tools

- **Owner:** buffy (`freebuff/make-sure-git-is-current-then-let-s-see-if-we-can--2972776f-3ba7-4bc6-bd62-264908623ff2`)
- **Prompt / plan:** `docs/agent-concurrency-plan.md` Lane D-Tools (Phase 1) — GitHub issues #331–#339
- **Scope:** M22 — D8 (stat/find), D9 (sysinfo extension), D10 (resource monitor), D11 (crash viewer), D12 (dmesg), D13 (time), D14 (developer console), D15 (ls -l), D16 (which/inventory)
- **Touches:** `kernel/src/monitor.zig`, `user/src/resmon.zig`, `user/src/devcons.zig`, `build.zig`
- **Depends on:** M22 D1–D5 already landed ✅ (ELF loader, assembler, symbols, disassembler, strace)
- **Heartbeat:** 2026-08-24
- **Status:** ✅ done

## Implementation

### Monitor commands (kernel/src/monitor.zig)

Added 6 new monitor commands and enhanced 3 existing ones:

| Card | Command | Description |
|------|---------|-------------|
| D8 | `stat <file\|path>` | File metadata: size, type, cluster, path |
| D8 | `find <dir> -name <pattern>` | Recursive glob search (3 levels, 256 results) |
| D9 | `sysinfo` (extended) | Added disk free/total, uptime section |
| D11 | `crash [<index>]` | Enhanced: detailed report with symbol resolution + serial snapshot |
| D12 | `dmesg` | Serial ring buffer viewer (last 512 bytes) |
| D13 | `time <cmd>` | Command timing: elapsed ticks + wall-clock |
| D15 | `ls [-l] [<dir>]` | Long listing format: type, permissions, owner, size |
| D16 | `which <name>` | Locate command: shell builtin / monitor command / ESP app |
| D16 | `inventory` | List all ESP applications with sizes |

Registry grows from 59 → 65 commands.

### Userland apps

| Card | Binary | Description |
|------|--------|-------------|
| D10 | RESMON.BIN | Resource monitor window (process count, auto-refresh 1 Hz) |
| D14 | DEVCONS.BIN | Developer console: split-screen log + command prompt |

Both apps are honest about syscall limitations (no mem/disk/net stats, no sys_dmesg_read).

### Testing

- All 526 host tests pass (67 monitor tests)
- RESMON.BIN and DEVCONS.BIN build successfully for aarch64-freestanding
- D3 shape test updated to skip `time` (wrapper command outputs timing lines)

## Notes

- D10 and D14 are simplified versions that work within the existing ABI budget (61/64 slots). Full implementations would require new syscalls (sys_mem_info, sys_disk_stats, sys_dmesg_read).
- The `find` command uses a recursive glob matcher (*, ?) bounded at 3 levels deep and 256 results.
- The `time` command wraps any monitor command with timer measurement.
- The `which` command checks shell builtins (22 known), monitor commands, and ESP file listing.

# Claim: Roadmap refinement — Milestones 9 through 12 (interactive apps, user files, desktop platform, network apps)

- **Owner:** buffy (`agent/buffy/roadmap-refinement`)
- **Prompt / plan:** `docs/roadmap.md`
- **Scope:** `docs/roadmap.md`, `docs/status.md`
- **Depends on:** —
- **Status:** ✅ done

## Notes

Refines the post-Milestone 8 wishlist into four structured candidate milestones with explicit card ladders, consuming userland applications, and gating contracts:

1. **Milestone Nine — Interactive EL0 Application Event System**: per-process event queues, `sys_event_poll`/`sys_event_wait` ABI (slots 21/22), userland event runtime (`user/src/lib/app.zig`), and interactive consumer app `CLICKME.BIN` / `PAINT.BIN`.
2. **Milestone Ten — Userland Filesystem & Storage ABI**: process file handle table, safe path canonicalization, file syscall ABI (`sys_file_open/read/write/close/dir` slots 23–27), and userland disk consumer `TYPE.BIN` / `SAVETEXT.BIN`.
3. **Milestone Eleven — Desktop Platform & First Real GUI Apps**: micro-widget toolkit (`user/src/lib/ui.zig`), `CALC.BIN` (Calculator), `NOTEPAD.BIN` (Text Editor), `TOP.BIN` (Graphical Task Manager), and `DESKTOP.BIN` (Desktop Launcher).
4. **Milestone Twelve — Userland Network Applications**: TCP syscall seam (`sys_tcp_connect/send/recv/close`), DNS client (UDP 53), and `FETCH.BIN` (EL0 HTTP client).

Preserves the complete 20-item maintainer wishlist as the guiding philosophy and long-term destinations.

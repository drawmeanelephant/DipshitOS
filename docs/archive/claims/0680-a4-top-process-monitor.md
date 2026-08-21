# Claim: `TOP.BIN` (Graphical Task Manager & Process Monitor)

- **Owner:** buffy (`agent/buffy/m11-a4-top`)
- **Prompt / plan:** `docs/march-m11.md` card A4
- **Scope:** `user/src/top.zig`, `user/src/lib/ui.zig`, `build.zig`, `image/make-image.sh`, `docs/claims/0680-a4-top-process-monitor.md`, `docs/logs/agent-buffy-m11-a4-top.md`
- **Depends on:** `docs/claims/8155-a1-micro-widget-toolkit.md`
- **Status:** ✅ done

## Notes

Implements **Card A4 (`TOP.BIN` - Graphical Task Manager & Process Monitor)**:
1. `user/src/top.zig`: Standalone EL0 GUI process monitor that polls `sys_procs` (slot 7), renders live process tables and system statistics, provides interactive row selection via `ListView`, and supports a Refresh button and click-to-terminate actions.
2. `user/src/lib/ui.zig`: Added `get_procs` syscall wrapper (slot 7) and `ProcInfo` parsing helper.
3. Build pipeline integration: Flat binary extraction and embedding onto FAT32 ESP via `build.zig` and `image/make-image.sh`.
4. Class A unit tests covering process table row decoding, formatting, and selection state.

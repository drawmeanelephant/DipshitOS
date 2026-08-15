# Claim: Milestone eleven march — desktop platform & GUI apps (living tracker)

- **Owner:** buffy (`agent/buffy/m11-tracker`)
- **Prompt / plan:** `docs/roadmap.md` milestone eleven, Issue #146
- **Scope:** `docs/march-m11.md`, `docs/claims/0861-m11-march-tracker.md`, `docs/logs/agent-buffy-m11-tracker.md`
- **Depends on:** `docs/claims/2412-m10-march-tracker.md`
- **Status:** ✅ done

## Notes

Defines the living tracker and collision-free agent split for **Milestone Eleven (Desktop Platform & GUI Apps)**:
1. **Cards A0–A5**: ADR 0011 architecture and UI contract, micro-widget toolkit and runtime (`user/src/lib/ui.zig`), `CALC.BIN` (interactive calculator), `NOTEPAD.BIN` (graphical text editor with persistent storage), `TOP.BIN` (graphical task manager and process monitor), and `DESKTOP.BIN` (desktop launcher and environment capstone gate).
2. **Authoritative Spec**: Combines window management (M6), interactive events (M9), and userland persistent filesystem (M10) into a recognizable graphical desktop platform.

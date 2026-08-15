# Claim: `NOTEPAD.BIN` (Graphical Text Editor)

- **Owner:** buffy (`agent/buffy/m11-a3-notepad`)
- **Prompt / plan:** `docs/march-m11.md` card A3
- **Scope:** `user/src/notepad.zig`, `build.zig`, `image/make-image.sh`, `docs/claims/3234-a3-notepad-editor.md`, `docs/logs/agent-buffy-m11-a3-notepad.md`
- **Depends on:** `docs/claims/8155-a1-micro-widget-toolkit.md`
- **Status:** ✅ done

## Notes

Implements **Card A3 (`NOTEPAD.BIN` - Graphical Text Editor)**:
1. `user/src/notepad.zig`: Standalone EL0 GUI text editor with multi-line editing, typing, cursor navigation, and Backspace/Enter line breaking.
2. Persistent file operations: Load and Save from `/data/notes.txt` using the Milestone 10 storage ABI (`sys_file_open`, `sys_file_read`, `sys_file_write`, `sys_file_close`).
3. Build pipeline integration: Flat binary extraction and embedding onto FAT32 ESP via `build.zig` and `image/make-image.sh`.
4. Class A unit tests covering editor text buffer operations and boundary conditions.

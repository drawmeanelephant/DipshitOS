# Claim: Milestone 13 Card B1 — filesystem semantics depth (ADR 0007 slots 34–37)

- **Owner:** buffy (`agent/buffy/m13-b1-fs-semantics`)
- **Prompt / plan:** `docs/march-m13.md`
- **Scope:** Milestone 13, Card B1 (Issue #161: the read-only M10 ABI becomes mutating)
- **Depends on:** Milestone 12 (merged); B2/B3 (merged, PRs #165/#167)
- **Status:** ✅ done 2026-08-16 — the mutating filesystem seam (slots 34–37) is live on VZ: FSTEST.BIN create+write → truncate → read-back → rename → free → delete → prove-gone; tools/verify-live-fs-mutation.sh PASS 1/1, all four slots calls=1

## Notes

The M10 file seam (slots 23–27) is read-only. This card adds the four
mutating operations a real file browser needs:

- `sys_file_delete(path_ptr, path_len)` — slot 34. Free the FAT chain and
  mark the directory slot deleted (0xE5). Directories refused.
- `sys_file_rename(old_ptr, old_len, new_ptr, new_len)` — slot 35. In-place
  same-directory rename (rewrites the 8.3 short name); cross-directory /
  cross-volume renames and a taken target name are refused (EINVAL — no
  EEXIST row in the frozen ABI).
- `sys_file_truncate(handle, size)` — slot 36. Resize the OPEN handle
  (shrink truncates, grow zero-fills, ≤ 2048).
- `sys_file_free(volume)` — slot 37. Free bytes on a volume (0 = DATA,
  1 = ESP).

Layering: `fat.zig` gains `delete_file` / `rename_file` / `truncate_file` /
`free_space`; `file_table.zig` wraps them with the existing negative error
convention; `syscall.zig` registers slots 34–37 and bumps
`implemented_count` 34 → 38. `ui.zig` exposes typed wrappers. `FILE.BIN`
grows Delete/Rename buttons + `d`/`r` keys over the new slots.

- Class-A tests at every layer (fat 19/19, file_table 80/80, syscall
  310/310, ui/file_browser 16/16) plus the fault-safety dispatch test.
- `FSTEST.BIN` (`user/src/fstest.zig`, twenty-second ESP program) drives the
  seam live: create+write → truncate → read-back → rename → free → delete →
  prove-gone.
- `tools/verify-live-fs-mutation.sh` — the capstone live gate.
- ADR 0007 amendment documents slots 34–37.

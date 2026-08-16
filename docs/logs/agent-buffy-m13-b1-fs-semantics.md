# Log — `m13-b1-fs-semantics`: the mutating filesystem syscalls (claim 5801)

## 2026-08-16 — branch opened

- Card B1 of Milestone 13 (issue #161): delete/rename/truncate/free syscalls.
- Plan: four new ADR 0007 slots (34–37) over the M10 file seam; FILE.BIN
  grows Delete/Rename; FSTEST.BIN proves the seam live.
- Branch based on `origin/main` (`ca11eb3`, FILE.BIN merged as PR #167).

## 2026-08-16 — branch work

- `fat.zig`: `delete_file` (free chain + 0xE5 slot), `rename_file`
  (in-place 8.3 rewrite, same-directory only), `truncate_file`
  (shrink/grow via write_file's replace path), `free_space` (clusters ×
  bytes-per-cluster). 19/19 tests.
- `file_table.zig`: `delete`/`rename`/`truncate`/`free_space` wrappers with
  the existing negative error convention. 80/80 tests.
- `syscall.zig`: slots 34–37 constants + handlers + table rows;
  `implemented_count` 34 → 38; report + dispatch tests updated. 310/310.
- `ui.zig`: `file_delete`/`file_rename`/`file_truncate`/`file_free` wrappers.
- `FILE.BIN`: Delete/Rename buttons + `d`/`r` keys over slots 34/35, with
  `file: delete NAME` / `file: rename NAME -> NEW` markers and a `.BAK`
  rename target. 16/16 tests; `verify-live-file-browser.sh` still PASS.
- `FSTEST.BIN` (twenty-second ESP program) + build/make-image/mkfat32
  wiring: create+write → truncate → read-back → rename → free → delete →
  prove-gone.
- `tools/verify-live-fs-mutation.sh`: **PASS 1/1 on VZ** — all four slots
  `calls=1`, and the deleted file is proven gone.
- ADR 0007 amendment documents slots 34–37.

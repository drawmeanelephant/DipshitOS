# Log — M34 HF5 user-data migration to the host folder (issue #739)

Branch: `agent/buffy/m34-hf5-user-data-migration` · Worktree: `../virelaios-buffy`

## 2026-09-01 — claim 3082 filed; survey complete

- **Current state pinned:** `/host` is userland READ-ONLY (HF4) — the
  mutation guards in `file_table.zig` return EACCES/EINVAL for host
  paths; the wire already carries the full HF3 mutation set. The `/data`
  consumers: kernel `settings.zig` (SETTINGS.TXT on DATA, direct fat),
  shell history + env (HISTORY.TXT / ENV.TXT on ESP via `esp`), monitor
  `screenshot` (fat.write_fb_bmp — streams, no big buffer), userland
  settings_panel / notepad / calc (hst+defs+cfg) / download / edit /
  netprof / file_browser (root+RECENT.SAV+.trash) / savetext / type /
  dir. Clipboard: pure BSS, in-memory only (verified — nothing to
  migrate). The DATA partition image content: README.TXT + DATA.TXT
  (mkfat32.py).
- **Design locked:** guest holds the host WRITE handle in the file-table
  FileHandle (new `host_handle` field) — the vf wire has no write-at-offset,
  so the host cursor owns writes; open-with-MODE_WRITE (no append)
  truncates to 0 after OPEN to match the legacy FAT replace semantics;
  reads stay stateless (vf READ at the guest cursor). Process cleanup
  (`reset_process`) closes live host handles. Migration = boot step after
  the probe with a hidden `.virelai-migrated` marker (host LIST skips
  hidden files — no listing-count drift); skip-if-exists so an existing
  user share wins. `/data` deprecation: one-shot line from
  `mount_partition(.data)` via a pub `main.zig.uart_puts` + the migration
  line at boot.
- **Host facts re-verified:** OPEN(create/append) → 8-slot handle table;
  CLOSE flushes + frees; WRITE returns written count; LIST uses
  `.skipsHiddenFiles`; path defense allows dotfiles (component-wise, no
  leading-dot rule).

## 2026-09-01 — implementation + live verification complete (claim flipped ✅)

- **Kernel.** `virtio_file.zig`: pub chunk staging + `read_into` /
  `write_whole` helpers. `file_table.zig`: the `.host` partition is
  READ-WRITE — MODE_WRITE opens a HOST write handle (replace semantics:
  truncate-to-0 unless APPEND; the host owns the cursor, the guest mirrors
  confirmed bytes), MODE_DIR creates a host dir, DELETE/RENAME route to the
  channel, truncate rides the host handle; `reset_process`/`close` free
  host handles; a one-shot `/data` deprecation line prints on DATA mount
  (share boots only). `migrate.zig`: boot step — if the channel is armed
  and `.virelai-migrated` absent, walk `/data` (depth ≤ 3), copy each file
  skip-if-exists, write the marker; prints `migrate: copied N file(s) ...`.
  `settings.zig` (SETTINGS.TXT → share, DATA fallback), `shell.zig`
  (HISTORY.TXT/ENV.TXT → share, ESP fallback), `monitor.zig`
  (`screenshot SHOT.BMP` → streamed to the share when armed, FAT
  fallback), `main.zig` (migration call + `uart_puts` pub + per-PID
  `stdout_owns_open_line` owner fix).
- **Userland re-points** (`/data` → `/host`): settings_panel, notepad,
  calc (hst+defs+cfg), download, edit, netprof, file_browser (root +
  RECENT.SAV + .trash + move-dialog strings), savetext/type/dir — the
  three naked-asm programs needed their embedded `.ascii` path literals
  updated too (the consts alone don't reach the binary). fstest stays on
  `/data` (FAT seam lives until HF6).
- **Runner:** new `--chords-view` flag — `--cvc-file` implies via-virtio,
  which switches `--input-chords` to the cv-input transport paced at
  0.25 s/stroke; the desktop-composition gate's launch-then-focus handoff
  needs the slow view path (--input-chords-delay), so the flag forces the
  VZ-view path even when the cv queue is attached. Zero effect on other
  gates (opt-in).
- **Live gates (all PASS on VZ):** `verify-live-vf` 5/5 with the new HF5
  migrate phase (host-disk README/DATA/marker + SETTINGS.TXT +
  SHOT.BMP + deprecation needle); re-pointed `verify-live-user-fs`,
  `verify-live-n11-download` (host-disk DOWNLOAD.OUT), `verify-live-file-browser`
  (3 entries — the shell's HISTORY.TXT now lands in the share; syscall
  counts 6/3/2 unchanged), `verify-live-filemanager-{bulk,recent,props}`
  (bulk n=3 — HISTORY.TXT is a shutdown background writer, so the
  host-disk ground truth asserts the delete TARGETS only),
  `verify-live-settings` + `verify-live-history` (host-disk SETTINGS.TXT /
  HISTORY.TXT, cross-reboot). Regressions: `verify-live-args`, `-strace`,
  `-desktop` (apps=19 /esp fallback), `-asm` PASS; class-A: fmt, build,
  unit tests 24/24, bss budget (524,904 B headroom), vf-class-a, transcript
  green.
- **Notable live observations:** host-share listings preserve the guest's
  casing (`hello.txt`, not HELLO.TXT — FAT uppercased); the shell history
  write on exit reappears after a batch delete (background writer — assert
  targets, never totals); the migration's skip-if-exists semantics means a
  user-seeded share wins over the `/data` copy.

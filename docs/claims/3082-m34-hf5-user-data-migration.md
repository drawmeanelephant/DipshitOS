# Claim: M34 HF5 — user-data migration to the host folder (issue #739)

- **Owner:** buffy (`agent/buffy/m34-hf5-user-data-migration`)
- **Prompt / plan:** implement M34 HF5 (#739): the guest's persistent user
  data lives in the host folder over queue 5. Scope-in per the issue:
  (1) the `/host` file-table partition becomes READ-WRITE through the
  channel (OPEN/CLOSE/WRITE/TRUNCATE/MKDIR/DELETE/RENAME already on the
  wire from HF3 — HF4 left `/host` userland-read-only); (2) each `/data`
  consumer re-points to a `/host/...` path; (3) a one-time boot migration
  copies existing `/data` content into the share (hidden `.virelai-migrated`
  marker — the host's LIST already skips hidden files); (4) `/data` mount
  emits an honest deprecation line; (5) every persistence gate re-pointed
  and green, verified host-side on disk.
- **Re-point map** (users → `/host/...`): kernel `settings.zig`
  (SETTINGS.TXT — share first, DATA fallback), shell history + env
  (`HISTORY.TXT`/`ENV.TXT` — share first, ESP fallback), monitor
  `screenshot` (SHOT.BMP — streamed to share when armed, FAT fallback),
  userland settings_panel / notepad / calc (history+defs+cfg) / download /
  edit / netprof / savetext / type / dir / file_browser (root + RECENT.SAV
  + .trash). Clipboard is pure in-memory (verified — no disk persistence
  exists to migrate). M10 demo + FSTEST stay on `/data` (the seam still
  exists until HF6).
- **Migration** (`kernel/src/migrate.zig`, boot step after the vf probe):
  if the channel is armed and `.virelai-migrated` absent, walk `/data`
  (depth ≤ 3), copy each file to the share (skip-if-exists — the user's
  share wins), write the marker.
- **Gate:** new HF5 phase in `tools/verify-live-vf.sh` (migration →
  host-disk verify of README.TXT/DATA.TXT/marker; `settings set` →
  host-disk SETTINGS.TXT; `screenshot` → host-disk BMP; deprecation
  needle) + re-pointed `verify-live-settings`, `verify-live-history`,
  `verify-live-n11-download`, `verify-live-user-fs`, `verify-live-file-browser`,
  `verify-live-filemanager-*` (seeded shares, host-side verification).
- **Touches:** `kernel/src/{virtio_file,file_table,migrate,settings,shell,monitor,main}.zig`,
  `user/src/{settings_panel,notepad,calc,calc/history,download,edit,netprof,savetext,type,dir,file_browser}.zig`,
  `tools/verify-live-vf.sh` + the persistence gates above,
  `docs/host-file-channel-scoping.md`, `docs/status.md`,
  `docs/claims/3082-m34-hf5-user-data-migration.md`,
  `docs/logs/agent-buffy-m34-hf5-user-data-migration.md`
- **Depends on:** HF1–HF4 (issues #735–#738, landed)
- **Heartbeat:** 2026-09-01
- **Status:** ✅ — done 2026-09-01 (PR #???, branch merged; issue #739
  closed). All persistence consumers re-pointed to `/host`; one-time
  migration + deprecation live-gated on VZ; every M10–M31 persistence
  gate re-pointed through the channel and verified host-side on disk.

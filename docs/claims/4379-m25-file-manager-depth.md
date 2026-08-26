# Claim: M25 File Manager Depth (GitHub Milestone 13)

- **Owner:** buffy (`agent/buffy/m25-file-manager-depth`)
- **Prompt / plan:** `docs/march-m25.md`
- **Scope:** M25 (file manager depth) cards F1–F18 (GitHub issues #381–#398 in milestone 13): wire `du` monitor command, add live gate `tools/verify-live-filemanager-du.sh`, run the full live gate & test sweep across F1–F18, update docs and close milestone 13 issues with observed evidence.
- **Touches:** kernel/src/monitor.zig, kernel/src/shell.zig, tools/verify-live-filemanager-du.sh, docs/march-m25.md, docs/status.md, docs/claims/4379-m25-file-manager-depth.md, docs/claims/2539-m25-lane-b-mkdir-du-recent.md, docs/logs/agent-buffy-m25-file-manager-depth.md
- **Depends on:** —
- **Heartbeat:** 2026-08-26
- **Status:** ✅ done 2026-08-26 (`agent/buffy/m25-file-manager-depth`)

## Notes

1. Claimed for the complete sweep and closure of Milestone 13 / M25.
2. Kernel `du` command is wired to the merged `fat.dir_size_recursive` engine in `kernel/src/monitor.zig`.
3. Added class-B live gate `tools/verify-live-filemanager-du.sh`.
4. Fixed shell help transcript test in `kernel/src/shell.zig` for the new `du` storage entry.
5. Verified all 5 filemanager live gates (`bulk`, `props`, `mkdir`, `recent`, `du`) on VZ and full unit test suite (`verify-unit-tests.sh`).


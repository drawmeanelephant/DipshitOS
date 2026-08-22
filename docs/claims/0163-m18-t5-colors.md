# Claim: M18 T5 — ANSI terminal colors

- **Owner:** buffy (`agent/buffy/m18-t5-colors`)
- **Prompt / plan:** `docs/march-m18.md`
- **Scope:** M18 card T5 — green prompt via ANSI escapes, `color on/off` command persisted in settings, bold directory names in `ls` output
- **Depends on:** M18 T4 (history)
- **Status:** ✅ done 2026-08-22

## Notes

Implements issue #408 T5: terminal ANSI color support.

### Features

- **Green prompt:** shell wraps prompt in `\x1b[32m` / `\x1b[0m` when `color_enabled`.
- **color_enabled flag:** set in `boot_and_park()` from `settings.get_color()`, defaults to `false` in host tests (preserves transcript byte-identity).
- **`color` command:** `color` shows current state, `color on`/`color off` toggles, persisted via `settings.set()`.
- **`ls` bold dirs:** directory entries wrapped in `\x1b[1m` / `\x1b[0m` in monitor.zig.
- **Settings:** `color` key ("on"/"off") with default "on", getter in settings.zig.
- **Registry:** bumped from 50 to 51 commands.

### Files changed

- **Modified:** `kernel/src/settings.zig` — `get_color()` helper
- **Modified:** `kernel/src/monitor.zig` — `cmd_color`, `color` registry entry, registry_count 51
- **Modified:** `kernel/src/shell.zig` — `color_enabled` field, prompt wrapping, repaint wrapping
- **Modified:** `tests/transcript-console.txt` — `color` line in help output
- **New:** `tools/verify-live-color.sh` — class-B VZ gate

### Live-gate evidence (2026-08-22, claim 0469 session)

`bash tools/verify-live-color.sh` — **class-B PASS 1/1** on real VZ:
`artifacts/live-color-gate.txt`, `live-color-report.txt`,
`live-color-serial-01.log` (banner=1 on=1 dir=1 off=1 done=1 — prompt
wrapped in ANSI escapes, `ls` directories bold, `color` toggle persisted).
The gate needed no changes (pure serial walk).

### Verification

- `zig test kernel/src/shell.zig` — 525/525
- `bash tools/verify-unit-tests.sh` — all pass
- `zig build test-console` — transcript byte-identical
- `zig build kernel` — builds
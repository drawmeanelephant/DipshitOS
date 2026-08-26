# Claim: issue-563-input-poll-gui-app

- **Owner:** buffy (`agent/buffy/input-poll-563`)
- **Prompt / plan:** `docs/claims/1382-issue-563-input-poll-gui-app.md`
- **Scope:** issue #563 — virtio INPUT queue stops polling after DESKTOP.BIN launches a GUI app; root-cause + fix + live proof on VZ
- **Touches:** user/src/desktop.zig,tools/verify-live-desktop-typing.sh
- **Depends on:** —
- **Heartbeat:** 2026-08-26
- **Status:** ✅ done 2026-08-26 — root-caused: NOT a poll stall — guest routing is healthy; the repro burst drained into the in-flight `sys_exec` (strokes consumed by DESKTOP before EDIT's window existed), and the apparent `focused=3` misreading came from the desktop's hardcoded `open id=4` marker while real ids shift with restored WINDOWS.SAV state. Deliverables: `user/src/desktop.zig` prints the real window id; `tools/verify-live-desktop-typing.sh` live gate (split-injection: launch, then type `abcde` after `edit: ready`) PASSES — EDIT decodes all 5 strokes and renders them pixel-proof (92 white-glyph samples on screen). Note: `tools/verify-live-desktop.sh` currently fails on clean main (`err=6` ENOENT for CALC.BIN) — pre-existing, out of scope.

## Notes

Issue #563: after DESKTOP.BIN launches EDIT.BIN via sys_exec (slot 28),
injected keyboard chords over the custom-virtio INPUT queue (queue 3,
claim 9588) are enqueued by the host (`n=32 ok=true`) but never reach the
launched app. Existing artifacts (`artifacts/repro563-serial.log`) show
`input: events=16 kb-usage=0x8` — all 16 strokes WERE decoded through
`decode_keyboard_report` — yet EDIT never processes them (window stays
dirty, no presents, `dui: focused=3` while desktop's window is id 4 /
EDIT's window id 5). Working hypothesis: the decoded KEY_DOWNs are pushed
to the WRONG process (or wake delivery to the blocked EDIT task fails),
not a poll-input scheduling stall. Plan: instrument focus/open/key-route
with transient serial markers, re-run the repro (SPIKE runner,
`--via-virtio`), pin the exact route, fix, and re-prove with a live gate
extension (desktop-launched EDIT receives and renders typed letters).

Verification: `zig build` + `zig fmt --check` + unit tests +
`bash tools/verify-coordination.sh` + the instrumented repro serial log
shows EDIT waking and redrawing (`dui` presents delta / EDIT resumes).
# Claim: issue-563-input-poll-gui-app

- **Owner:** buffy (`agent/buffy/input-poll-563`)
- **Prompt / plan:** `docs/claims/1382-issue-563-input-poll-gui-app.md`
- **Scope:** issue #563 — virtio INPUT queue stops polling after DESKTOP.BIN launches a GUI app; root-cause + fix + live proof on VZ
- **Touches:** kernel/src/input.zig,kernel/src/driving_award.zig,kernel/src/virtio_custom.zig,kernel/src/shell.zig,tools/verify-live-desktop.sh,tools/repro563.sh,artifacts/repro563-*
- **Depends on:** —
- **Heartbeat:** 2026-08-26
- **Status:** 🔄 agent/buffy/input-poll-563

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
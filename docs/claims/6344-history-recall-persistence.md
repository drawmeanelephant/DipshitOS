# Claim: verify-live-history — boot-2 Up-chord recall no-ops because boot-1's HISTORY.TXT never persists

- **Owner:** buffy (`agent/buffy/history-recall-persistence`)
- **Prompt / plan:** root-cause why verify-live-history's Up-arrow/chord recall
  marker never echoes and fix the shell history keybinding path so it passes on main.
- **Scope:** M18 T4 persistent-history gate. Investigation of the boot-2 recall
  no-op; no kernel milestone creep.
- **Touches:** tools/verify-live-history.sh (analysis only — no code change landed)
- **Depends on:** —
- **Heartbeat:** 2026-08-31
- **Status:** 🔄 agent/buffy/history-recall-persistence

## Notes

`verify-live-history` fails red on main with the exact signature
`rc1=0 rc2=0 banner=1 marker=0 report=1 ok=1 runner-flag=1` — the Up-arrow
keyboard chord decodes cleanly once (`input: ... events=1 kb-usage=0x52`
= HID Up), but the recalled `echo T4-third-marker` never appears, and the
only subsequent serial `\r` submits an empty line (`error: no command given`).

Reproduced deterministically on a clean, un-renamed `origin/main` checkout
(as well as the rename branch) — pre-existing, rename-exonerated. The rename
sweep even updated the gate's serial triggers to the new `virelai> ` prompt,
so this is not a prompt-name mismatch.

Mechanism: `esc_state` at the line editor maps `ESC [ A` to `recall_older`,
which no-ops (empty line, nothing echoed) when `hist_count == 0`. No recall
echo AND no `recall_older` beep (only the timer-heartbeat BEL exists in the
boot-2 serial) means the boot-2 history ring is empty. Direct evidence from the
shared `artifacts/disk.img` after the run: `HISTORY.TXT` on the ESP contains
only boot-2's own typed lines (`input`, `echo history-live-ok`) — none of
boot-1's `echo T4-*` commands, so boot-1's per-submit `save_to_history`
writes did not survive for boot-2's `load_history` to reload.

`esp.write_file` → `fat.write_file` runs synchronously and awaits the
virtio-blk completion (guest-side durable), and `esp.disk_ready()` is true
from `set_disk` before the shell — so boot-1's writes are lost at the VM
boundary (host-side: the runner kills boot-1 ≤0.5 s after the `T4-third-marker`
script-expect; the macOS-27 canonical-disk FAT-write/fresh-copy fragility the
gate's own comments document). Boot-2's writes survive the SAME teardown, so
the loss is timing/flush-specific to the shortest-lived writes at boot-1's
exit, not a wholesale write failure.

A durable fix (verified against a boot-1→boot-2 persistence checkpoint before
landing) is the pending next step; no code has been landed blind.
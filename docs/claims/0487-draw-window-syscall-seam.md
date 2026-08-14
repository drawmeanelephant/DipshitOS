# Claim: Milestone six, card G6 — the draw/window syscall seam

- **Owner:** buffy (`freebuff/can-you-check-out-our-status-and-work-on-the-next--7e2ecd0b-8acc-47ac-bb44-68841236e5fc`)
- **Prompt / plan:** `docs/march-m6.md` G6 row — the final milestone-six rung,
  on top of G5 Driving Award (claim 1543) and the ADR 0007 slot-9/10/11
  precedent (claim 1384).
- **Scope:** bounded `sys_*` slots (ADR 0007 amendment) so an EL0 user
  program can open a window and render into it: `sys_win_open` (slot 12),
  `sys_win_fill` (slot 13), `sys_win_present` (slot 14). Driving Award gains
  a `.user` window kind with fixed BSS back-buffers; a new EL0 demo program
  (`user/src/win.zig`, WIN.BIN) opens a window, fills it, presents it, and
  exits. The `syscalls` report grows to 15 rows. Live gate
  `tools/verify-live-win-syscall.sh`.
- **Follow-on (teardown):** `sys_win_close` (slot 15, `implemented_count`
  15 → 16) + the monitor's `win close <n>` release a user window so the
  id (2..3) can be re-opened instead of leaking until reboot; both call
  `driving_award.user_close` (open → fill → present → close → re-open is
  host-tested end to end). A SEVENTH image WINCLOSE.BIN
  (`user/src/winclose.zig`) proves it live from EL0 — the class-B gate
  `tools/verify-live-win-close.sh` PASS 1/1: WINCLOSE.BIN opens/fills/
  presents/CLOSES (slot 15) and exits 88, twice; `win` shows `windows=2`
  after the close (no `win[2]:` row) and the re-exec re-opens id 2 (the
  freed slot reused, never id 3).
- **Follow-on (per-process ownership):** windows are now OWNED by the
  process that opened them and AUTO-CLOSE when it exits (the scheduler's
  `exit_current` calls `driving_award.close_owner(pid)` — the real
  teardown semantic, superseding the original kernel-global bound).
  `sys_win_fill`/`sys_win_present`/`sys_win_close` are owner-restricted
  (the EL1h `win close` stays privileged). WIN.BIN's window now vanishes
  on exit, so an EIGHTH image WINLOOP.BIN (`user/src/winloop.zig`)
  keeps its window alive for the live gate's decoded-capture phase.
- **Follow-on (read-back):** `sys_win_get` (slot 18, `implemented_count`
  18 → 19) copies the caller's window rect (x, y, w, h as four u32 LE
  words — 16 bytes) OUT through uaccess — the ONE pointer-taking win slot
  — so an EL0 program can read its clamped position back after
  `sys_win_move` (the move is silent). Owner-restricted like
  fill/present/close; `EFAULT` for a bad `buf`. WINMOVE.BIN now prints
  `winmove: get 1024,528,256,192` after its clamped move, asserted by
  `tools/verify-live-win-move.sh` (get=1).
- **Follow-on (full-state query):** `sys_win_query` (slot 19,
  `implemented_count` 19 → 20) copies the caller's window FULL state
  (x, y, w, h, z, focused, visible, dirty as eight u32 LE words — 32
  bytes) OUT through uaccess — the second pointer-taking win slot — so an
  EL0 program introspects z-order rank + focus + visible/dirty, not just
  the rect. Owner-restricted like fill/present/close; `EFAULT` for a bad
  `buf`. WINMOVE.BIN now prints `winmove: query 1024,528,256,192 z=2
  focused=1 visible=1 dirty=1`, asserted by `tools/verify-live-win-move.sh`
  (query=1).
- **Depends on:** milestone six G5 (claim 1543) — the window registry +
  compositor this seam renders into.
- **Status:** ✅ done 2026-08-13 — live-gated on VZ (`tools/verify-live-win-syscall.sh` PASS 1/1): WIN.BIN opened a user window, filled it (dark-blue background + red/cyan/white blocks), presented it, and exited 87 — all from EL0 through the ADR 0007 slots 12/13/14; `win` showed `windows=3 focused=2` + `win[2]: user user rect=64,64,256,192`, `syscalls` reported implemented=15 (open=1/fill=4/present=1), and the decoded capture showed the window's own content over the terminal (no terminal foreground showing through). Full class A green; the default VM stayed byte-identical. **Teardown follow-on (same branch):** `sys_win_close` (slot 15, implemented 15 → 16) + the monitor's `win close <n>` release a user window so the id (2..3) can be re-opened instead of leaking until reboot; the live gate's `syscalls` assertion now reads implemented=16 with slot 15 registered, and a SEVENTH image WINCLOSE.BIN proves the release LIVE from EL0 — `tools/verify-live-win-close.sh` PASS 1/1: the window gone (`windows=2`, no `win[2]:` row) and the freed slot re-opened as id 2. **Ownership follow-on (same branch):** windows are owned by their opening process and auto-close on exit (`close_owner` from the scheduler's exit path); `sys_win_fill/present/close` are owner-restricted (host-tested cross-process refusals + auto-close). The G6 gate now proves WIN.BIN's auto-close (`windows=2`, `sys_win_close calls=0` after exit) and pixel-proves WINLOOP.BIN's persistent window — the new EIGHTH image keeps the window on the scanout after WIN.BIN's window vanishes. **Runtime-visibility follow-on (same branch):** the `win` report's per-row `owner=` column shows each window's owning pid (fixed windows `-`) and `win list <pid>` filters the registry to one process's windows — both live-asserted in the G6 gate (`win[2] ... owner=2`, `win list 2` → matches=1, `win list 0` → matches=0). **Read-back follow-on (same branch):** `sys_win_get` (slot 18, implemented 18 → 19) copies the caller's window rect (four u32 LE words) OUT through uaccess — the ONE pointer-taking win slot — so an EL0 program reads its clamped position back after `sys_win_move` (the move is silent); WINMOVE.BIN now prints `winmove: get 1024,528,256,192` and `tools/verify-live-win-move.sh` asserts get=1 + implemented=19. **Full-state query follow-on (same branch):** `sys_win_query` (slot 19, implemented 19 → 20) copies the caller's window FULL state (eight u32 LE words: x, y, w, h, z, focused, visible, dirty) OUT through uaccess — so an EL0 program introspects z-order rank + focus + visible/dirty, not just the rect; WINMOVE.BIN now prints `winmove: query 1024,528,256,192 z=2 focused=1 visible=1 dirty=1` and the gate asserts query=1 + implemented=20. **Visibility follow-on (same branch):** `sys_win_set_visible` (slot 20, implemented 20 → 21) HIDES (`visible` 0) or SHOWS (`visible` 1) the caller's window from EL0 (`driving_award.user_set_visible`, owner-restricted; the fixed terminal + clock are refused, a non-0/1 flag is EINVAL) — hiding marks the terminal dirty so the next composite repaints over the hidden window, showing marks the window dirty so it reappears; the back-buffer + z-order rank are untouched. WINMOVE.BIN now hides its window, sleeps 2 ticks, shows it again, and prints `winmove: hide ok` / `winmove: show ok`; `tools/verify-live-win-move.sh` asserts hide=1/show=1/set_visible=2 + implemented=21 and gained a marker-driven capture (`--screenshot-after "winmove: hide ok"`, a new VMRunner flag) proving the PIXEL DISAPPEARS (no red/cyan/white blocks at the clamped spot while hidden) and RETURNS (the LATEST capture shows them back).

## Notes

The N6 pattern, applied to graphics: `sys_win_open(x, y, w, h)` opens a
user window (back-buffer ≤ 256×192 B8G8R8X8 in fixed BSS, bounded to 2
user windows — ids 2 and 3) OWNED BY THE CALLER and returns its id;
`sys_win_fill(id, x, y, w, h, rgb)` fills a rect in the caller's window's
back-buffer; `sys_win_present(id)` marks it dirty so the compositor blits
it on the next idle-loop pass. No uaccess: the seam is plain numbers +
kernel-owned buffers. WIN.BIN proves EL0 graphics end to end: open → fill
(background + three colored blocks) → present → `sys_exit(87)`.

The close follow-on makes the seam releasable: `win close <n>` (EL1h,
privileged) and `sys_win_close` (EL0, owner-restricted) both free the
user slot, un-present the window, and recomposite — the fixed terminal
(0) + clock (1) windows are refused. The ownership follow-on supersedes
the original "kernel-global" bound: a window is owned by its opening
process and AUTO-CLOSES when that process exits (the scheduler's
`exit_current` calls `driving_award.close_owner`), and fill/present/close
are owner-restricted (a process can only touch its own window —
host-tested cross-process refusals). WIN.BIN's window now vanishes on
exit (the gate asserts `windows=2` with `sys_win_close calls=0`), so the
decoded-capture pixel proof rides WINLOOP.BIN, which keeps its window
alive forever. The move/raise follow-on (slots 16/17) makes the seam able
to reposition and restack: `sys_win_move(id, x, y)` clamps the caller's
window on-scanout (`driving_award.user_move`) and `sys_win_raise(id)`
reorders the z-order (`driving_award.user_raise`), both owner-restricted
like fill/present/close. The EL0 proof rides a NINTH image WINMOVE.BIN
(`user/src/winmove.zig`): open → fill → present → move → move (the second
move clamps to the scanout corner) → raise → yield-forever, and the
class-B gate `tools/verify-live-win-move.sh` shows the clamped rect
(`win[2]: user user rect=1024,528,256,192`) + the counters (open=1/fill=4/
present=3/move=2/raise=1/close=0) + the decoded capture with the window's
colors at the NEW position and the terminal where it used to be.

The get follow-on (slot 18) makes the clamp observable from EL0:
`sys_win_get(id, buf)` copies the caller's window rect (four u32 LE
words) out through uaccess — the ONE pointer-taking win slot — so a
program reads its clamped position back instead of inferring it from the
`win` report. WINMOVE.BIN prints `winmove: get 1024,528,256,192` after
its clamped move (get=1 in the gate's counters), the host-tested
`sys_win_get` contract (unknown id / fixed window / non-owner → EINVAL,
bad buf → EFAULT).

The query follow-on (slot 19) makes the FULL state introspectable from
EL0: `sys_win_query(id, buf)` copies the caller's window rect PLUS the
z-order rank (`z` = the registry index), focus, visible, and dirty flags
(eight u32 LE words — the second pointer-taking win slot), so a program
sees its window the same way the EL1h `win` report does. WINMOVE.BIN
prints `winmove: query 1024,528,256,192 z=2 focused=1 visible=1 dirty=1`
after its clamped move (query=1 in the gate's counters), the host-tested
`sys_win_query` contract (unknown id / fixed window / non-owner → EINVAL,
bad buf → EFAULT).

The set_visible follow-on (slot 20) makes the window HIDEABLE/SHOWABLE
from EL0: `sys_win_set_visible(id, visible)` toggles the caller's
window's `visible` flag (`driving_award.user_set_visible`, owner-restricted
like fill/present/close; the fixed terminal + clock are refused). Hiding
marks the terminal dirty so the next composite repaints over the hidden
window; showing marks the window dirty so it reappears — the back-buffer
and z-order rank are untouched. WINMOVE.BIN hides its window, sleeps 2
ticks (holding it hidden while the gate captures the GONE frame), shows
it again, and prints `winmove: hide ok` / `winmove: show ok`
(set_visible=2 in the gate's counters), the host-tested contract
(unknown id / fixed window / non-owner / non-0-1 flag → EINVAL). The
class-B gate `tools/verify-live-win-move.sh` gained a marker-driven
capture (`--screenshot-after "winmove: hide ok"`, a new VMRunner flag)
that proves the PIXEL DISAPPEARS (no red/cyan/white blocks at the
clamped spot while hidden) and the LATEST fixed capture proves it
RETURNS — the hide/show round trip, not just a registry flip.

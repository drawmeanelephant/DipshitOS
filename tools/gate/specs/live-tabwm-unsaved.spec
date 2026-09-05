# live-tabwm-unsaved.spec -- M42 UX hardening round 2 (2026-09-05, claim #1011, ADR 0018 addendum)
# class-B gate: TABWM's unsaved-changes dialog (dirty tab close interception) end to end.
#
# TWO headless boots with --screen (GPU armed) + --via-virtio (the cv INPUT
# transport for pointer injection). Both boots follow the live-wnd8-unsaved-drain
# seeding pattern: `dui unsaved 2 1` dirties NOTEPAD.BIN headless (the kernel
# fans mirror bit 12 to the registered WM), and both follow the live-tabwm-close
# injection pattern: one click on the active tab's close box (158, 70) - row 0
# y 58..96, close 'x' x 148..168 - which TABWM now routes through the close
# DECISION point (request_close_tab): the tab is DIRTY, so NO close happens -
# the unsaved-changes dialog opens instead (`tabwm: unsaved-dialog id=2`).
#
# The two clicks ride ONE --pointer-virtio ';' chain with a single after-marker
# (the live-wnd8-unsaved-drain approach): the dialog render + marker appear
# within ticks of the first click, so the runner's fixed pointer pacing covers
# the second click; all load-bearing asserts are marker-based, not timing-based.
#
# The dialog marker format is the implemented id-carrying prefix:
#   `tabwm: unsaved-dialog id=2`
# Button hit-tests are the SHARED wnd_core rule at 1280x720 (dialog origin
# 540,310): Save center (580,390), Don't Save center (660,390), Cancel (715,390).
#
# Boot A (SAVE path): click Save (580,390) -> `tabwm: unsaved-save` ->
#   DIALOG action 4: the kernel posts WIN_UNSAVED to NOTEPAD (it saves:
#   `notepad: saved ok`); TABWM then closes the tab via WMCTL_WIN_CLOSE
#   (`tabwm: win-close id=2 closed=1` - the window is still registered
#   when cmd 13 lands, since the owner has not processed WIN_UNSAVED
#   yet). OBSERVED save-path semantics (2026-09-05 hardware): NOTEPAD
#   treats WIN_UNSAVED as save-and-exit - `notepad: win_unsaved` then
#   `notepad: exiting 43` - so the kernel's WIN_CLOSE push goes
#   unconsumed and `notepad: win_close` belongs to the DISCARD path
#   (boot B), where the kernel's user_close inside DIALOG 5 is the only
#   close. script3 reads the WM counters (` dialog=`).
# Boot B (DISCARD path): click Don't Save (660,390) -> `tabwm: unsaved-discard`
#   -> DIALOG action 5: the KERNEL's user_close releases the window - NO local
#   TABWM close, NO save marker (absent-asserted) - NOTEPAD gets WIN_CLOSE and
#   exits; script3's `dui` proves the registry row released (`dui: windows=4`,
#   the four fixed layers only).

vgate_name live-tabwm-unsaved "M42 UX r2: TABWM unsaved-changes dialog (dirty close interception, save + discard paths)"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
tabwm start
exec NOTEPAD.BIN
EOF

vgate_file script2.txt <<'EOF'
dui unsaved 2 1
wm
echo dirty-go
EOF

vgate_file script3-save.txt <<'EOF'
wm
echo unsaved-ok
EOF

vgate_file script3-discard.txt <<'EOF'
dui
wm
echo discard-ok
EOF

# --- boot A: the SAVE path ---
vgate_run save -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' --script2-after "notepad: ready" --script2-delay 15 \
    --pointer-virtio "158,70,c;580,390,c" --pointer-virtio-after "dirty-go" \
    --script3 '$RUN_DIR/script3-save.txt' --script3-after "notepad: saved ok" --script3-delay 20 \
    --script-expect "unsaved-ok" --timeout 260

# The dirty close was INTERCEPTED: dialog opened, no immediate close.
vgate_assert save serial-contains 'tabwm: unsaved-dialog id=2'
# The Save choice: marker FIRST, then DIALOG 4 (kernel posts WIN_UNSAVED).
vgate_assert save serial-contains 'tabwm: unsaved-save'
vgate_assert save serial-contains 'notepad: saved ok'
# The WM closed the tab through the kernel seam (the save-path asymmetry;
# the owner exits on WIN_UNSAVED before consuming the WIN_CLOSE push).
vgate_assert save serial-contains 'tabwm: win-close id=2 closed=1'
vgate_assert save serial-contains 'notepad: win_unsaved'
vgate_assert save serial-contains 'notepad: exiting 43'
# The kernel DIALOG counters moved (script3's `wm` counter line prints
# ` dialog=` among the WM counters - NOT `wm: dialog=`).
vgate_assert save serial-contains ' dialog='
vgate_assert save serial-absent '[EXC] parking:'
vgate_assert save python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'dialog=[1-9][0-9]*', ser), "dialog counter check failed"
assert not re.search(r'tabwm: unsaved-discard', ser), "discard marker on the save boot"
PY

# --- boot B: the DISCARD path ---
vgate_run discard -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' --script2-after "notepad: ready" --script2-delay 15 \
    --pointer-virtio "158,70,c;660,390,c" --pointer-virtio-after "dirty-go" \
    --script3 '$RUN_DIR/script3-discard.txt' --script3-after "notepad: exiting 43" --script3-delay 20 \
    --script-expect "discard-ok" --timeout 260

vgate_assert discard serial-contains 'tabwm: unsaved-dialog id=2'
# The Don't Save choice: the KERNEL closes the window inside DIALOG 5.
vgate_assert discard serial-contains 'tabwm: unsaved-discard'
vgate_assert discard serial-contains 'notepad: win_close'
vgate_assert discard serial-contains 'notepad: exiting 43'
# The kernel registry released the window: the four fixed layers only.
vgate_assert discard serial-contains 'dui: windows=4'
# The asymmetry, negatively proven: the save marker never fires on this boot.
vgate_assert discard serial-absent 'tabwm: unsaved-save'
vgate_assert discard serial-absent '[EXC] parking:'

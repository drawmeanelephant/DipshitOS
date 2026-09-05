# live-tabwm-close.spec -- M42 UX hardening (2026-09-05, claim #1008 / ADR 0018 D2)
# class-B gate: the TABWM tab-close seam end to end on real VZ hardware.
#
# ONE headless boot with --screen (GPU armed) + --via-virtio (the cv INPUT
# transport for pointer injection). The choreography:
#
#   1. `tabwm start`            -> TABWM.BIN registers, renders the sidebar.
#   2. `exec CALC.BIN`          -> calc: open id=2, the tab-aware declaration,
#                                  the full-viewport relayout (calc: ready).
#   3. POINTER INJECTION after "calc: ready": one click at (158, 70) - the
#      active tab pill's close box 'x' (x 148..168, tab row 0 y 58..96) in
#      TABWM's sidebar. TABWM's handle_pointer routes it to close_tab(0).
#   4. close_tab issues the NEW slot-65 WIN_CLOSE seam (cmd 13); the kernel
#      applies its own user_close release: the owner gets the real WIN_CLOSE
#      event, the WM gets the released mirror.
#   5. CALC observes WIN_CLOSE ("calc: win_close"), exits cleanly
#      ("calc: exiting 43"); script3 (after the exit marker) reads the
#      kernel registry: the user window is GONE (dui: windows=4 - the
#      four fixed layers only; pre-M42 it would read 5, the hidden user
#      window still registered).
#
# The load-bearing assertion is `tabwm: win-close id=2 closed=1` - closed=1
# proves the KERNEL (not a hide-only fallback) applied the close. Pre-M42
# the marker was a hide-only `tabwm: win-close id=2` (no closed= field).

vgate_name live-tabwm-close "M42 UX: TABWM tab close seam end to end (WM decision -> kernel release -> app exit)"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
tabwm start
EOF

vgate_file script2.txt <<'EOF'
exec CALC.BIN
EOF

vgate_file script3.txt <<'EOF'
dui
procs
echo rx-close-ok
EOF

vgate_run 01 -- --screen '$RUN_DIR/screen' --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' --script2-after 'tabwm: sidebar-rendered' \
    --pointer-virtio '158,70,c' --pointer-virtio-after 'calc: ready' \
    --script3 '$RUN_DIR/script3.txt' --script3-after 'calc: exiting 43' \
    --script-expect 'rx-close-ok' --timeout 120

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'tabwm: starting TABWM.BIN'
vgate_assert 01 serial-contains 'tabwm: registered'
vgate_assert 01 serial-contains 'tabwm: sidebar-rendered'
vgate_assert 01 serial-contains 'calc: open id=2'
vgate_assert 01 serial-contains 'calc: tab-aware (full-viewport)'
vgate_assert 01 serial-contains 'calc: resize relayout'
vgate_assert 01 serial-contains 'tabwm: tab-switch'
# The new close seam: the WM decided, the kernel applied (closed=1).
vgate_assert 01 serial-contains 'tabwm: win-close id=2 closed=1'
# The app received the kernel's real WIN_CLOSE event and exited cleanly.
vgate_assert 01 serial-contains 'calc: win_close'
vgate_assert 01 serial-contains 'calc: exiting 43'
# The kernel registry released the window: only the FOUR fixed layers
# remain (terminal + wallpaper + taskbar + dock) and no user-kind row.
vgate_assert 01 serial-contains 'dui: windows=4 focused='
vgate_assert 01 serial-absent 'dui: windows=5'
vgate_assert 01 serial-absent ' user rect='
vgate_assert 01 serial-absent '\[EXC\]'
vgate_assert 01 serial-absent '[EXC] parking:'

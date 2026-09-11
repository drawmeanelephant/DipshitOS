# live-tabwm-bt.spec -- M48 BT1-BT6 (umbrella #1120) class-B gate: the
# browser-style tab depth behaviours end to end on real VZ hardware.
#
# ONE headless boot with --screen (GPU armed) + --via-virtio (the HID chord
# transport). The choreography:
#
#   1. `tabwm start`       -> TABWM registers, renders the sidebar.
#   2. script2 `exec CALC.BIN` after the sidebar -> calc opens as tab id=2
#      (tab-aware, full viewport).
#   3. The chord sequence fires AFTER `calc: open id=2` (via-virtio paces
#      chords at 0.25 s/stroke, so gating on the open marker is what makes
#      the tab-dependent chords deterministic):
#        ctrl-shift-p            -> BT3: pin the CALC tab
#        ctrl-shift-f            -> BT6: freeze the CALC tab
#        ctrl-shift-a, escape    -> BT6: tab search opens then closes
#        ctrl-t, escape          -> BT4: the START surface opens then closes
#   4. script3 `echo rx-m48-ok` after `tabwm: start` is the expect terminator.
#
# The class-A suite covers the tranches the runner's chord vocabulary cannot
# express (Ctrl+Shift+PgUp/PgDn reorder, Ctrl+Shift+[ / ] history,
# duplicate/reopen of a WM-launched tab). This gate proves the additive
# M48 markers land on real hardware without an exception.

vgate_name live-tabwm-bt "M48 BT1-BT6: rail-native pin, freeze, start surface, tab search"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
tabwm start
EOF

vgate_file script2.txt <<'EOF'
exec CALC.BIN
EOF

vgate_file script3.txt <<'EOF'
echo rx-m48-ok
EOF

vgate_run 01 -- --screen '$RUN_DIR/screen' --via-virtio \
    --script '$RUN_DIR/script.txt' \
    --script2 '$RUN_DIR/script2.txt' --script2-after 'tabwm: sidebar-rendered' \
    --input-chords 'ctrl-shift-p,ctrl-shift-f,ctrl-shift-a,escape,ctrl-t,escape' \
    --input-chords-after 'calc: open id=2' \
    --script3 '$RUN_DIR/script3.txt' --script3-after 'tabwm: start-surface' \
    --script-expect 'rx-m48-ok' --timeout 200

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'tabwm: starting TABWM.BIN'
vgate_assert 01 serial-contains 'tabwm: registered'
vgate_assert 01 serial-contains 'tabwm: sidebar-rendered'
vgate_assert 01 serial-contains 'calc: open id=2'
# M48 markers.
vgate_assert 01 serial-contains 'tabwm: tab-pin 2 on'
vgate_assert 01 serial-contains 'tabwm: tab-freeze 2 on'
vgate_assert 01 serial-contains 'tabwm: tab-search'
vgate_assert 01 serial-contains 'tabwm: start-surface'
vgate_assert 01 serial-contains 'tabwm: new-tab'
vgate_assert 01 serial-absent '\[EXC\]'
vgate_assert 01 serial-absent '[EXC] parking:'

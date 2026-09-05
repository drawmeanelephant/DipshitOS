# live-sb5-wm-compose-n.spec -- M33 SB5 (claim 7397) class-B gate:
#
# WM compose-N + one final present, live on real VZ hardware.
#
# SB5WM.BIN registers as the WM server (slot 65), binds the SCANOUT writable
# (the SB5 grant — M33_SURF_SCAN_TAG via sys_mmap), and waits for the owner.
# SB5OWN.BIN opens a 256x192 user window at (320,64), binds a shared surface
# as its back-buffer (SB3 handoff), renders with PLAIN STORES ONLY (it NEVER
# calls sys_win_fill), and hands {pid, handle, magic} to the WM. The WM peers

vgate_name live-sb5-wm-compose-n "M33 SB5: WM compose-N + one final present on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec SB5WM.BIN
exec SB5OWN.BIN
EOF

vgate_file script2.txt <<'EOF'
syscalls
EOF

vgate_run 01 -- --screen '$RUN_DIR/screen' --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/script2.txt' --script2-after 'timer heartbeat ticks=20' --script-expect '13 sys_win_fill calls=0' --timeout 180

vgate_assert 01 serial-contains 'sb5: wm registered'
vgate_assert 01 serial-contains 'sb5: wm scanout=1'
vgate_assert 01 serial-contains 'sb5: own opened'
vgate_assert 01 serial-contains 'sb5: own bound'
vgate_assert 01 serial-contains 'sb5: own stored'
vgate_assert 01 serial-contains 'sb5: wm readback=0x5B'
vgate_assert 01 serial-contains 'sb5: wm present'
vgate_assert 01 serial-contains 'sb5: owner done'
vgate_assert 01 serial-contains 'sb5: wm done'
vgate_assert 01 serial-contains '13 sys_win_fill calls=0'
vgate_assert 01 serial-absent 'sb5: wm register-fail'
vgate_assert 01 serial-absent 'sb5: wm scanout-fail'
vgate_assert 01 serial-absent 'sb5: wm attach-fail'
vgate_assert 01 serial-absent 'sb5: wm compose-fail'
vgate_assert 01 serial-absent 'sb5: own open-fail'
vgate_assert 01 serial-absent 'sb5: own bind-fail'
vgate_assert 01 serial-absent 'sb5: own no-wm'
vgate_assert 01 serial-absent '[EXC] parking:'

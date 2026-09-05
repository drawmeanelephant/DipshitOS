# live-wm1.spec -- Lane 1 WM1 (#707, claim 919) class-B gate: eight concurrent user windows

vgate_name live-wm1 "Lane 1 WM1: eight concurrent pool-backed user windows on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec WINLOOP.BIN
exec CALC.BIN
exec NOTEPAD.BIN
exec TOP.BIN
exec DESKTOP.BIN
EOF

vgate_file script2.txt <<'EOF'
exec FILE.BIN
exec SYSMON.BIN
exec PS.BIN
EOF

vgate_file script3.txt <<'EOF'
dui
syscalls
echo done-wm1-sweep
EOF

vgate_run 01 -- --display --input --screen '$RUN_DIR/gpu-screen' --script '$RUN_DIR/script.txt' --script-after "tasks user-el0 exited status=7" --script2 '$RUN_DIR/script2.txt' --script2-after "desktop: ready" --script3 '$RUN_DIR/script3.txt' --script3-after "ps: ready" --script-expect "done-wm1-sweep" --timeout 150

vgate_assert 01 serial-contains 'winloop: open id=2'
vgate_assert 01 serial-contains 'calc: ready'
vgate_assert 01 serial-contains 'notepad: ready'
vgate_assert 01 serial-contains 'top: ready'
vgate_assert 01 serial-contains 'desktop: ready'
vgate_assert 01 serial-contains 'file: ready'
vgate_assert 01 serial-contains 'sysmon: ready'
vgate_assert 01 serial-contains 'ps: ready'
vgate_assert 01 serial-contains '12 sys_win_open calls=8'
vgate_assert 01 serial-contains 'dui: windows=12 '
vgate_assert 01 serial-count ' user rect=' 8
vgate_assert 01 serial-contains 'done-wm1-sweep'
vgate_assert 01 serial-absent '[EXC] parking:'

# live-wm3-taskbar.spec -- M32 WM3 (Lane 1, #707): taskbar shows per-window entries, workspace-aware

vgate_name live-wm3-taskbar "M32 WM3: taskbar per-window entries, workspace-aware"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-A.txt <<'EOF'
exec NOTEPAD.BIN
EOF

vgate_file s2-A.txt <<'EOF'
dui taskbar
dui minimize 2
dui taskbar
dui ws 1
dui taskbar
dui ws 0
dui restore 2
dui taskbar
echo taskbar-a-go
EOF

vgate_file script-B1.txt <<'EOF'
wnd start
exec NOTEPAD.BIN
exec CALC.BIN
EOF

vgate_file s2-B1.txt <<'EOF'
dui
wm
echo taskbar-go
EOF

vgate_file s3-B1.txt <<'EOF'
dui
wm
echo taskbar-b1-done
EOF

vgate_file script-B2.txt <<'EOF'
wnd start
exec NOTEPAD.BIN
exec CALC.BIN
EOF

vgate_file s2-B2.txt <<'EOF'
dui minimize 2
dui
echo taskbar-go
EOF

vgate_file s3-B2.txt <<'EOF'
dui
wm
echo taskbar-b2-done
EOF

vgate_run A -- --screen '$RUN_DIR/screen' --via-virtio --cvc-snap --script '$RUN_DIR/script-A.txt' --script2 '$RUN_DIR/s2-A.txt' --script2-after 'notepad: ready' --script2-delay 20 --script-expect 'echo taskbar-a-go' --timeout 260

vgate_assert A serial-contains 'dui taskbar: entry=0 id=2 focused=1 minimized=0'
vgate_assert A serial-contains 'dui taskbar: entry=0 id=2 focused=0 minimized=1'
vgate_assert A serial-contains 'dui taskbar: ws=1 entries=0'
vgate_assert A serial-contains 'dui taskbar: ws=0 entries=1'
vgate_assert A serial-absent '[EXC] parking:'

vgate_run B1 -- --screen '$RUN_DIR/screen' --via-virtio --cvc-snap --script '$RUN_DIR/script-B1.txt' --script2 '$RUN_DIR/s2-B1.txt' --script2-after 'calc: ready' --script2-delay 20 --pointer-virtio '120,710,c' --pointer-virtio-after 'taskbar-go' --script3 '$RUN_DIR/s3-B1.txt' --script3-after 'taskbar-go' --script3-delay 20 --script-expect 'taskbar-b1-done' --timeout 300

vgate_assert B1 serial-contains 'wnd: taskbar id=2 restore=0'
vgate_assert B1 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'taskbar=[1-9][0-9]*', ser), "taskbar cmd check failed"
assert re.search(r'dui: windows=[0-9]+ focused=2', ser), "focused check failed"
PY
vgate_assert B1 serial-contains 'wnd: present'
vgate_assert B1 serial-absent '[EXC] parking:'

vgate_run B2 -- --screen '$RUN_DIR/screen' --via-virtio --cvc-snap --script '$RUN_DIR/script-B2.txt' --script2 '$RUN_DIR/s2-B2.txt' --script2-after 'calc: ready' --script2-delay 20 --pointer-virtio '120,710,c' --pointer-virtio-after 'taskbar-go' --script3 '$RUN_DIR/s3-B2.txt' --script3-after 'taskbar-go' --script3-delay 20 --script-expect 'taskbar-b2-done' --timeout 300

vgate_assert B2 serial-contains 'wnd: taskbar id=2 restore=1'
vgate_assert B2 python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'taskbar=[1-9][0-9]*', ser), "taskbar cmd check failed"
assert re.search(r'dui: windows=[0-9]+ focused=2', ser), "focused check failed"
PY
vgate_assert B2 serial-contains 'wnd: present'
vgate_assert B2 serial-absent '[EXC] parking:'

# live-wnd6-dock-drain.spec -- WMS6 Gate D: shim and WM-driven dock click

vgate_name live-wnd6-dock-drain "WMS6 Gate D: shim and WM-driven dock click"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-A.txt <<'EOF'
exec NOTEPAD.BIN
EOF

vgate_file s2-A.txt <<'EOF'
dui minimize 2
dui
echo dock-a-go
EOF

vgate_file s3-A.txt <<'EOF'
dui
echo shim-done
EOF

vgate_file script-B.txt <<'EOF'
wnd start
exec NOTEPAD.BIN
EOF

vgate_file s2-B.txt <<'EOF'
dui minimize 2
dui
wm
echo dock-go
EOF

vgate_file s3-B.txt <<'EOF'
dui
dui tooltip-state
wm
echo dock-done
EOF

# --- boot A: shim regression (no WM) ---
vgate_run A -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-A.txt' \
    --script2 '$RUN_DIR/s2-A.txt' --script2-after "notepad: ready" --script2-delay 20 \
    --pointer-virtio "12,18,c" --pointer-virtio-after "dock-a-go" \
    --script3 '$RUN_DIR/s3-A.txt' --script3-after "dock-a-go" --script3-delay 8 \
    --script-expect "echo shim-done" --timeout 260

vgate_assert A serial-contains "dui minimize: minimized id=2"
vgate_assert A serial-absent "[EXC] parking:"
vgate_assert A python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'dui: windows=[0-9]+ focused=2', ser), "focused=2 check failed"
assert not re.search(r'(panic|abort|kernel fault|data abort)', ser), "fault detected"
PY

# --- boot B: the WM-driven dock ---
vgate_run B -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-B.txt' \
    --script2 '$RUN_DIR/s2-B.txt' --script2-after "notepad: ready" --script2-delay 20 \
    --pointer-virtio "12,24;12,18,c" --pointer-virtio-after "dock-go" \
    --script3 '$RUN_DIR/s3-B.txt' --script3-after "dock-go" --script3-delay 20 \
    --script-expect "dock-done" --timeout 260

vgate_assert B serial-contains "wnd: dock idx=0"
vgate_assert B serial-contains "wnd: tooltip"
vgate_assert B serial-contains "dui tooltip-state: visible=yes text=Calc"
vgate_assert B serial-contains "wnd: present"
vgate_assert B serial-absent "[EXC] parking:"
vgate_assert B python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'dock=[1-9][0-9]*', ser), "dock check failed"
assert re.search(r'dui: windows=[0-9]+ focused=2', ser), "focused=2 check failed"
PY

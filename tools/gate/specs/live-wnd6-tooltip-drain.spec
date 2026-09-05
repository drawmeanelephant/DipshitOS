# live-wnd6-tooltip-drain.spec -- WMS6 Gate C: dormant shim and WM-driven tooltip

vgate_name live-wnd6-tooltip-drain "WMS6 Gate C: dormant shim and WM-driven tooltip"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-A.txt <<'EOF'
exec NOTEPAD.BIN
EOF

vgate_file s2-A.txt <<'EOF'
echo hover-a-go
EOF

vgate_file s3-A.txt <<'EOF'
dui tooltip-state
echo shim-done
EOF

vgate_file script-B.txt <<'EOF'
wnd start
exec NOTEPAD.BIN
EOF

vgate_file s2-B.txt <<'EOF'
dui
wm
echo hover-go
EOF

vgate_file s3-B.txt <<'EOF'
dui tooltip-state
wm
echo tooltip-done
EOF

# --- boot A: shim regression (no WM) ---
vgate_run A -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-A.txt' \
    --script2 '$RUN_DIR/s2-A.txt' --script2-after "notepad: ready" --script2-delay 20 \
    --pointer-virtio "1240,700" --pointer-virtio-after "hover-a-go" \
    --script3 '$RUN_DIR/s3-A.txt' --script3-after "hover-a-go" --script3-delay 8 \
    --script-expect "echo shim-done" --timeout 260

vgate_assert A serial-contains "dui tooltip-state: visible=no"
vgate_assert A serial-absent "[EXC] parking:"
vgate_assert A python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert not re.search(r'(panic|abort|kernel fault|data abort)', ser), "fault detected"
PY

# --- boot B: the WM-driven tooltip ---
vgate_run B -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-B.txt' \
    --script2 '$RUN_DIR/s2-B.txt' --script2-after "notepad: ready" --script2-delay 20 \
    --pointer-virtio "1240,700" --pointer-virtio-after "hover-go" \
    --script3 '$RUN_DIR/s3-B.txt' --script3-after "hover-go" --script3-delay 20 \
    --script-expect "tooltip-done" --timeout 260

vgate_assert B serial-contains "wnd: tooltip"
vgate_assert B serial-contains "dui tooltip-state: visible=yes text=Clock"
vgate_assert B serial-contains "wnd: present"
vgate_assert B serial-absent "[EXC] parking:"
vgate_assert B python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'tooltip=[1-9][0-9]*', ser), "tooltip check failed"
PY

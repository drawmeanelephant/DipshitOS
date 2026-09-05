# live-wnd6-notif-drain.spec -- WMS6 Gate B: shim and WM-driven notification center

vgate_name live-wnd6-notif-drain "WMS6 Gate B: shim and WM-driven notification center"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-A.txt <<'EOF'
exec NOTEPAD.BIN
EOF

vgate_file s2-A.txt <<'EOF'
echo click-a-go
EOF

vgate_file s3-A.txt <<'EOF'
dui notif-center-state
echo shim-done
EOF

vgate_file script-B.txt <<'EOF'
wnd start
exec NOTEPAD.BIN
EOF

vgate_file s2-B.txt <<'EOF'
dui
wm
echo chord-go
EOF

vgate_file s3-B.txt <<'EOF'
dui notif-center-state
wm
echo notif-done
EOF

# --- boot A: shim regression (no WM) ---
vgate_run A -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-A.txt' \
    --script2 '$RUN_DIR/s2-A.txt' --script2-after "notepad: ready" --script2-delay 20 \
    --pointer-virtio "1240,710,c" --pointer-virtio-after "click-a-go" \
    --script3 '$RUN_DIR/s3-A.txt' --script3-after "click-a-go" --script3-delay 8 \
    --script-expect "echo shim-done" --timeout 260

vgate_assert A serial-contains "dui notif-center-state: open="
vgate_assert A serial-absent "[EXC] parking:"
vgate_assert A python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'dui notif-center-state: open=(yes|no)', ser), "notif-center-state missing"
assert not re.search(r'(panic|abort|kernel fault|data abort)', ser), "fault detected"
PY

# --- boot B: the WM-driven notification center ---
vgate_run B -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-B.txt' \
    --script2 '$RUN_DIR/s2-B.txt' --script2-after "notepad: ready" --script2-delay 20 \
    --pointer-virtio "1240,710,c" --pointer-virtio-after "chord-go" \
    --script3 '$RUN_DIR/s3-B.txt' --script3-after "chord-go" --script3-delay 20 \
    --script-expect "notif-done" --timeout 260

vgate_assert B serial-contains "wnd: notif-open"
vgate_assert B serial-contains "dui notif-center-state: open=yes"
vgate_assert B serial-contains "wnd: present"
vgate_assert B serial-absent "[EXC] parking:"
vgate_assert B python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'notif=[1-9][0-9]*', ser), "notif check failed"
PY

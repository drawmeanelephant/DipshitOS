# live-wnd8-ptr-drag-delete.spec -- WMS8 Gate 6: kernel title-bar drag decision deleted

vgate_name live-wnd8-ptr-drag-delete "WMS8 Gate 6: kernel title-bar drag decision deleted"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-A.txt <<'EOF'
exec NOTEPAD.BIN
EOF

vgate_file s2-A.txt <<'EOF'
dui
echo drag-a
EOF

vgate_file s3-A.txt <<'EOF'
dui
echo done-a
EOF

vgate_file script-B.txt <<'EOF'
wnd start
exec NOTEPAD.BIN
EOF

vgate_file s2-B.txt <<'EOF'
dui
wm
echo drag-b
EOF

vgate_file s3-B.txt <<'EOF'
dui
wm
echo done-b
EOF

# --- boot A: shim (no WM) -- title-bar drag does not move window ---
vgate_run A -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-A.txt' \
    --script2 '$RUN_DIR/s2-A.txt' --script2-after "notepad: ready" --script2-delay 2 \
    --script3 '$RUN_DIR/s3-A.txt' --script3-after "drag-a" --script3-delay 45 \
    --pointer-virtio "300,64,d;350,80;400,100;450,120;500,300,u" --pointer-virtio-after "notepad: ready" \
    --script-expect "echo done-a" --timeout 240

vgate_assert A serial-contains "rect=56,56,512,384"
vgate_assert A serial-absent "[EXC] parking:"
vgate_assert A python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert not re.search(r'(panic|abort|kernel fault)', ser), "fault in serial A"
PY

# --- boot B: WM registered -- WM owns the drag ---
vgate_run B -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-B.txt' \
    --script2 '$RUN_DIR/s2-B.txt' --script2-after "notepad: ready" --script2-delay 2 \
    --script3 '$RUN_DIR/s3-B.txt' --script3-after "drag-b" --script3-delay 45 \
    --pointer-virtio "300,64,d;350,80;400,100;450,120;500,300,u" --pointer-virtio-after "notepad: ready" \
    --script-expect "done-b" --timeout 240

vgate_assert B serial-contains "wnd: grab"
vgate_assert B serial-contains "wnd: drag"
vgate_assert B serial-contains "wnd: drop"
vgate_assert B serial-absent "[EXC] parking:"
vgate_assert B python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'wm: ptr_fan=[1-9][0-9]*', ser), "ptr_fan check failed"
assert "rect=56,56,512,384" in ser, "initial rect missing"
lines = [l for l in ser.splitlines() if "user user rect=" in l]
assert len(lines) >= 1, "no user rect line found"
last = lines[-1]
assert "rect=56,56,512,384" not in last, f"window did not move: {last}"
PY

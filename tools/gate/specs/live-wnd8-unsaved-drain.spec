# live-wnd8-unsaved-drain.spec -- WMS8 Gate 4: unsaved-changes dialog drains into WND.BIN

vgate_name live-wnd8-unsaved-drain "WMS8 Gate 4: unsaved-changes dialog drains into WND.BIN"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-A.txt <<'EOF'
exec NOTEPAD.BIN
EOF

vgate_file s2-A.txt <<'EOF'
dui unsaved 2 1
wm
echo dirty-a
EOF

vgate_file s3-A.txt <<'EOF'
echo shim-done
EOF

vgate_file script-B.txt <<'EOF'
wnd start
exec NOTEPAD.BIN
EOF

vgate_file s2-B.txt <<'EOF'
dui unsaved 2 1
wm
echo dirty-go
EOF

vgate_file s3-B.txt <<'EOF'
wm
echo unsaved-done
EOF

# --- boot A: shim (no WM) -- dirty close is immediate, no dialog ---
vgate_run A -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-A.txt' \
    --script2 '$RUN_DIR/s2-A.txt' --script2-after "notepad: ready" --script2-delay 15 \
    --pointer-virtio "558,64,c" --pointer-virtio-after "dirty-a" \
    --script3 '$RUN_DIR/s3-A.txt' --script3-after "dirty-a" --script3-delay 20 \
    --script-expect "echo shim-done" --timeout 260

vgate_assert A serial-contains "dui unsaved: id=2 flag=1"
vgate_assert A serial-contains "notepad: win_close"
vgate_assert A serial-absent "wnd: unsaved-dialog"
vgate_assert A serial-absent "notepad: win_unsaved"
vgate_assert A serial-absent "[EXC] parking:"
vgate_assert A python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert not re.search(r'(panic|abort|kernel fault|data abort)', ser), "fault detected"
PY

# --- boot B: WM-driven unsaved-changes dialog ---
vgate_run B -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-B.txt' \
    --script2 '$RUN_DIR/s2-B.txt' --script2-after "notepad: ready" --script2-delay 15 \
    --pointer-virtio "558,64,c;660,390,c" --pointer-virtio-after "dirty-go" \
    --script3 '$RUN_DIR/s3-B.txt' --script3-after "dirty-go" --script3-delay 20 \
    --script-expect "unsaved-done" --timeout 260

vgate_assert B serial-contains "wnd: unsaved-dialog"
vgate_assert B serial-contains "wnd: unsaved-discard"
vgate_assert B serial-contains "notepad: win_close"
vgate_assert B serial-contains "wnd: present"
vgate_assert B serial-absent "[EXC] parking:"
vgate_assert B python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'dialog=[1-9][0-9]*', ser), "dialog check failed"
assert not re.search(r'wnd: (grab|drag|drop)', ser), "drag detected on close click"
PY

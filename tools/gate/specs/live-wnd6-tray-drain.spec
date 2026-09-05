# live-wnd6-tray-drain.spec -- WMS6 Gate E: kernel-derived tray clock and WM-driven tray

vgate_name live-wnd6-tray-drain "WMS6 Gate E: kernel-derived and WM-driven tray"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file sA.txt <<'EOF'
dui tray-state
echo tray-a-done
EOF

vgate_file script-B.txt <<'EOF'
wnd start
exec NOTEPAD.BIN
EOF

vgate_file s2-B.txt <<'EOF'
wm
dui tray-state
clip hello
echo tray-go
EOF

vgate_file s3-B.txt <<'EOF'
wm
dui tray-state
echo tray-done
EOF

# --- boot A: shim regression (no WM) ---
vgate_run A -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/sA.txt' \
    --script-expect "echo tray-a-done" --timeout 180

vgate_assert A serial-absent "[EXC] parking:"
vgate_assert A python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'dui tray-state: clock=[0-9][0-9]:[0-9][0-9] clock_set=no', ser), "kernel clock check failed"
assert not re.search(r'(panic|abort|kernel fault|data abort)', ser), "fault detected"
PY

# --- boot B: the WM-driven tray ---
vgate_run B -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-B.txt' \
    --script2 '$RUN_DIR/s2-B.txt' --script2-after "notepad: ready" --script2-delay 15 \
    --script3 '$RUN_DIR/s3-B.txt' --script3-after "tray-go" --script3-delay 20 \
    --script-expect "tray-done" --timeout 240

vgate_assert B serial-contains "wnd: present"
vgate_assert B serial-absent "[EXC] parking:"
vgate_assert B python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'wnd: tray clock=', ser), "wnd: tray clock missing"
assert re.search(r'wm: .*tray=[1-9][0-9]*', ser), "wm: tray count missing"
assert re.search(r'dui tray-state: clock=[0-9][0-9]:[0-9][0-9] clock_set=yes', ser), "clock_set=yes missing"
assert re.search(r'dui tray-state: .*clip=yes clip_set=yes', ser), "clip=yes check failed"

mclk = re.findall(r'wnd: tray clock=([0-9][0-9]:[0-9][0-9])', ser)
sclk = re.findall(r'dui tray-state: clock=([0-9][0-9]:[0-9][0-9])', ser)
assert mclk and sclk and mclk[-1] == sclk[-1], f"clock mismatch: mclk={mclk} sclk={sclk}"

tray_vals = [int(x) for x in re.findall(r'tray=([0-9]+)', ser)]
assert len(tray_vals) >= 2 and tray_vals[-1] > tray_vals[0], f"tray counter did not grow: {tray_vals}"
PY

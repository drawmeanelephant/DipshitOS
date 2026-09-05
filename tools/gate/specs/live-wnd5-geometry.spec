# live-wnd5-geometry.spec -- WMS5 Geometry: title-bar drag moved via SET_WINDOW

vgate_name live-wnd5-geometry "WMS5 Geometry: title-bar drag moved via SET_WINDOW"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-A.txt <<'EOF'
wnd start
exec NOTEPAD.BIN
EOF

vgate_file s2-A.txt <<'EOF'
dui
wm
echo drag-a
EOF

vgate_file s3-A.txt <<'EOF'
dui
echo done-a
EOF

vgate_run A -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-A' \
    --script '$RUN_DIR/script-A.txt' \
    --script2 '$RUN_DIR/s2-A.txt' --script2-after "notepad: ready" --script2-delay 2 \
    --script3 '$RUN_DIR/s3-A.txt' --script3-after "drag-a" --script3-delay 45 \
    --pointer-virtio "300,64,d;350,80;400,100;450,120;500,300,u" --pointer-virtio-after "notepad: ready" \
    --script-expect "done-a" --timeout 220

vgate_assert A serial-contains "wnd: grab"
vgate_assert A serial-contains "wnd: drag"
vgate_assert A serial-contains "wnd: drop"
vgate_assert A serial-absent "dui: pointer focus="
vgate_assert A serial-absent "[EXC] parking:"
vgate_assert A python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'wm: ptr_fan=[1-9][0-9]*', ser), "ptr_fan check failed"
assert re.search(r'win_mirror=[1-9][0-9]*', ser), "win_mirror check failed"
assert "rect=56,56,512,384" in ser, "initial rect missing"

# Check after rect
lines = [l for l in ser.splitlines() if "user user rect=" in l]
assert len(lines) >= 1, "no user rect line found"
last = lines[-1]
m = re.search(r'rect=([0-9]+),([0-9]+),512,384', last)
assert m, f"last rect line does not match 512,384: {last}"
ax, ay = int(m.group(1)), int(m.group(2))
assert 56 < ax < 700 and 56 < ay < 400, f"landing rect out of expected range: {ax},{ay}"
PY

# live-wnd8-geom-kbd-delete.spec -- WMS8: kernel geometry keyboard decision deleted

vgate_name live-wnd8-geom-kbd-delete "WMS8: kernel geometry keyboard decision deleted"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-A.txt <<'EOF'
exec NOTEPAD.BIN
EOF

vgate_file s2-A.txt <<'EOF'
dui
echo shim-go
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
dui tile 2
dui master
dui minimize 2
dui restore 2
dui maximize 2
dui ws 1
dui ws 0
wm
echo matrix-go
EOF

vgate_file s3-B.txt <<'EOF'
dui
wm
echo ctrl-t-done
EOF

# --- boot A: shim (no WM) -- Ctrl+T now does nothing ---
vgate_run A -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-A.txt' \
    --script2 '$RUN_DIR/s2-A.txt' --script2-after "notepad: ready" --script2-delay 15 \
    --input-chords "ctrl-t" --input-chords-after "shim-go" --input-chords-delay 2 \
    --script3 '$RUN_DIR/s3-A.txt' --script3-after "shim-go" --script3-delay 20 \
    --script-expect "echo shim-done" --timeout 260

vgate_assert A serial-absent "dui: tile="
vgate_assert A serial-absent "rect=24,0,837,700"
vgate_assert A serial-absent "[EXC] parking:"
vgate_assert A python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert not re.search(r'(panic|abort|kernel fault|data abort)', ser), "fault detected"
PY

# --- boot B: WM-registered matrix + WM-driven chord ---
vgate_run B -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-B.txt' \
    --script2 '$RUN_DIR/s2-B.txt' --script2-after "notepad: ready" --script2-delay 20 \
    --input-chords "ctrl-t" --input-chords-after "matrix-go" --input-chords-delay 2 \
    --script3 '$RUN_DIR/s3-B.txt' --script3-after "matrix-go" --script3-delay 20 \
    --script-expect "ctrl-t-done" --timeout 260

vgate_assert B serial-contains "dui tile: id=2 mode=on"
vgate_assert B serial-contains "dui ws: workspace=1"
vgate_assert B serial-contains "wnd: tile"
vgate_assert B serial-absent "dui: tile="
vgate_assert B serial-contains "wnd: present"
vgate_assert B serial-absent "[EXC] parking:"
vgate_assert B python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'key_fan=[1-9][0-9]*', ser), "key_fan check failed"
assert re.search(r'rect=24,0,837,700', ser), "rect check failed"
PY

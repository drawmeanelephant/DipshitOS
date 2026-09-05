# live-wnd2-mission-control.spec -- WM2 mission-control overview (Lane 1, #707)

vgate_name live-wnd2-mission-control "WM2 mission-control overview"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-A.txt <<'EOF'
exec M21DEMO.BIN
EOF

vgate_file s2-A.txt <<'EOF'
dui
wm
echo chord-a
EOF

vgate_file s3-A.txt <<'EOF'
dui
echo done-a
EOF

vgate_file script-B.txt <<'EOF'
wnd start
exec M21DEMO.BIN
EOF

vgate_file s2-B.txt <<'EOF'
ps
dui
wm
echo chord-go
EOF

vgate_file s3-B.txt <<'EOF'
dui
wm
echo overview-done
EOF

vgate_file script-C.txt <<'EOF'
wnd start
exec M21DEMO.BIN
EOF

vgate_file s2-C.txt <<'EOF'
dui
wm
echo chord-go
EOF

vgate_file s3-C.txt <<'EOF'
dui
wm
echo move-done
EOF

vgate_file script-D.txt <<'EOF'
wnd start
exec M21DEMO.BIN
EOF

vgate_file s2-D.txt <<'EOF'
dui
wm
echo chord-go
EOF

vgate_file s3-D.txt <<'EOF'
dui
wm
echo exit-done
EOF

# --- boot A: shim regression (no WM) ---
vgate_run A -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-A.txt' \
    --script2 '$RUN_DIR/s2-A.txt' --script2-after "m21demo: loop ok" --script2-delay 20 \
    --input-chords "ctrl-f12" --input-chords-after "chord-a" --input-chords-delay 2 \
    --script3 '$RUN_DIR/s3-A.txt' --script3-after "chord-a" --script3-delay 15 \
    --script-expect "echo done-a" --timeout 260

vgate_assert A serial-contains "m21demo: loop ok"
vgate_assert A serial-absent "wnd: overview"
vgate_assert A serial-absent "[EXC] parking:"
vgate_assert A python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert not re.search(r'(panic|abort|kernel fault)', ser), "fault in serial A"
# Reset WINDOWS.SAV between boots
p = os.path.join(os.environ["VG_SHARE"], "WINDOWS.SAV")
if os.path.exists(p): os.remove(p)
PY

# --- boot B: WND.BIN registered -- enter + click-to-focus ---
vgate_run B -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-B.txt' \
    --script2 '$RUN_DIR/s2-B.txt' --script2-after "wnd: wallpaper loaded" --script2-delay 30 \
    --input-chords "ctrl-f12" --input-chords-after "chord-go" --input-chords-delay 2 \
    --pointer-virtio "964,336,c" --pointer-virtio-after "wnd: overview-enter" \
    --script3 '$RUN_DIR/s3-B.txt' --script3-after "chord-go" --script3-delay 40 \
    --script-expect "overview-done" --timeout 280

vgate_assert B serial-contains "wnd: overview-enter n=2"
vgate_assert B serial-contains "wnd: overview-focus id="
vgate_assert B serial-contains "wnd: present"
vgate_assert B serial-absent "[EXC] parking:"
vgate_assert B python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'overview=[1-9][0-9]*', ser), "overview counter check failed"
assert re.search(r'key_fan=[1-9][0-9]*', ser), "key_fan counter check failed"
assert re.search(r'wm: ptr_fan=[1-9][0-9]*', ser), "ptr_fan counter check failed"
p = os.path.join(os.environ["VG_SHARE"], "WINDOWS.SAV")
if os.path.exists(p): os.remove(p)
PY

# --- boot C: WND.BIN registered -- drag card 0 to WS 1 moves + switches ---
vgate_run C -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-C.txt' \
    --script2 '$RUN_DIR/s2-C.txt' --script2-after "m21demo: loop ok" --script2-delay 20 \
    --input-chords "ctrl-f12" --input-chords-after "chord-go" --input-chords-delay 2 \
    --pointer-virtio "340,336,d;651,686,u" --pointer-virtio-after "wnd: overview-enter" \
    --script3 '$RUN_DIR/s3-C.txt' --script3-after "chord-go" --script3-delay 40 \
    --script-expect "move-done" --timeout 280

vgate_assert C serial-contains "wnd: overview-enter n=2"
vgate_assert C serial-contains "wnd: overview-move id=2 ws=1"
vgate_assert C serial-absent "[EXC] parking:"
vgate_assert C python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'rect=64,64,512,384.*ws=1', ser), "ws=1 check failed"
assert re.search(r'overview=[1-9][0-9]*', ser), "overview counter check failed"
p = os.path.join(os.environ["VG_SHARE"], "WINDOWS.SAV")
if os.path.exists(p): os.remove(p)
PY

# --- boot D: WND.BIN registered -- Esc exits ---
vgate_run D -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-D.txt' \
    --script2 '$RUN_DIR/s2-D.txt' --script2-after "m21demo: loop ok" --script2-delay 20 \
    --input-chords "ctrl-f12,escape" --input-chords-after "chord-go" --input-chords-delay 2 \
    --script3 '$RUN_DIR/s3-D.txt' --script3-after "chord-go" --script3-delay 25 \
    --script-expect "exit-done" --timeout 260

vgate_assert D serial-contains "wnd: overview-enter n=2"
vgate_assert D serial-contains "wnd: overview-exit"
vgate_assert D serial-absent "[EXC] parking:"
vgate_assert D python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'overview=[1-9][0-9]*', ser), "overview counter check failed"
PY

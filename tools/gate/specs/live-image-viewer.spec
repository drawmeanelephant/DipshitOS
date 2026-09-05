# live-image-viewer.spec -- M36 IMG5 VIEW.BIN on VZ

vgate_name live-image-viewer "M36 IMG5 VIEW.BIN on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_setup_python <<'PYEOF'
import os, shutil
share = os.environ["SHARE"]
shutil.copy("tests/fixtures/qoi/viewer_160x120.qoi", os.path.join(share, "TEST.QOI"))
shutil.copy("tests/fixtures/png/viewer_160x120.png", os.path.join(share, "TEST.PNG"))
PYEOF

vgate_file script-qoi.txt <<'EOF'
exec VIEW.BIN /host/TEST.QOI
EOF

vgate_file script-png.txt <<'EOF'
exec VIEW.BIN /host/TEST.PNG
EOF

vgate_file script2.txt <<'EOF'
syscalls
EOF

# --- Boot 1: QOI fixture ---
vgate_run QOI -- \
    --display --screen '$RUN_DIR/gpu-screen-qoi' \
    --via-virtio \
    --script '$RUN_DIR/script-qoi.txt' --script-after "virelai> " \
    --input-chords "=,=,=,up,left,right,down,down,down,down,0,-,q" --input-chords-after "view: ready" \
    --screenshot-after "view: ready" \
    --script2 '$RUN_DIR/script2.txt' --script2-after "view: ready" \
    --script-expect "user-exec exited status=43" --timeout 90

vgate_assert QOI serial-contains "VirelaiOS kernel has seized control."
vgate_assert QOI serial-contains "exec: loaded VIEW.BIN"
vgate_assert QOI serial-contains "view: ready"
vgate_assert QOI serial-contains "view: title set"
vgate_assert QOI serial-contains "view: zoom z=150%"
vgate_assert QOI serial-contains "view: zoom z=100%"
vgate_assert QOI serial-contains "view: zoom z=66%"
vgate_assert QOI serial-contains "view: quit"
vgate_assert QOI serial-contains "user-exec exited status=43"
vgate_assert QOI python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r"view: open id=[0-9]+ 328x264", ser), "open dimension check failed"
assert re.search(r"view: loaded TEST\.qoi 160x120 QOI bytes=340", ser), "loaded check failed"
assert re.search(r"view: pan ox=[1-9]", ser), "pan x check failed"
assert re.search(r"view: pan ox=[0-9]+ oy=[1-9]", ser), "pan y check failed"
assert re.search(r"sys_win_set_title calls=[0-9]+", ser), "title syscall check failed"
PY

# --- Boot 2: PNG fixture ---
vgate_run PNG -- \
    --display --screen '$RUN_DIR/gpu-screen-png' \
    --via-virtio \
    --script '$RUN_DIR/script-png.txt' --script-after "virelai> " \
    --input-chords "=,=,=,up,left,right,down,down,down,down,0,-,q" --input-chords-after "view: ready" \
    --screenshot-after "view: ready" \
    --script2 '$RUN_DIR/script2.txt' --script2-after "view: ready" \
    --script-expect "user-exec exited status=43" --timeout 90

vgate_assert PNG serial-contains "VirelaiOS kernel has seized control."
vgate_assert PNG serial-contains "exec: loaded VIEW.BIN"
vgate_assert PNG serial-contains "view: ready"
vgate_assert PNG serial-contains "view: title set"
vgate_assert PNG serial-contains "view: zoom z=150%"
vgate_assert PNG serial-contains "view: zoom z=100%"
vgate_assert PNG serial-contains "view: zoom z=66%"
vgate_assert PNG serial-contains "view: quit"
vgate_assert PNG serial-contains "user-exec exited status=43"
vgate_assert PNG python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r"view: open id=[0-9]+ 328x264", ser), "open dimension check failed"
assert re.search(r"view: loaded TEST\.png 160x120 PNG bytes=420", ser), "loaded check failed"
assert re.search(r"view: pan ox=[1-9]", ser), "pan x check failed"
assert re.search(r"view: pan ox=[0-9]+ oy=[1-9]", ser), "pan y check failed"
assert re.search(r"sys_win_set_title calls=[0-9]+", ser), "title syscall check failed"
PY

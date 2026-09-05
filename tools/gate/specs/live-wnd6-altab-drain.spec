# live-wnd6-altab-drain.spec -- WMS6 Gate A: shim self-cycles Alt+Tab and WM-driven Alt+Tab

vgate_name live-wnd6-altab-drain "WMS6 Gate A: shim and WM-driven Alt+Tab"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-A.txt <<'EOF'
exec M21DEMO.BIN
EOF

vgate_file s2-A.txt <<'EOF'
echo shim-go
EOF

vgate_file s3-A.txt <<'EOF'
dui
echo shim-done
EOF

vgate_file script-B.txt <<'EOF'
wnd start
exec M21DEMO.BIN
EOF

vgate_file s2-B.txt <<'EOF'
dui
wm
echo chord-go
EOF

vgate_file s3-B.txt <<'EOF'
dui
wm
echo alt-tab-done
EOF

# --- boot A: shim regression (no WM) ---
vgate_run A -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-A.txt' \
    --script2 '$RUN_DIR/s2-A.txt' --script2-after "m21demo: loop ok" --script2-delay 20 \
    --input-chords "alt-tab" --input-chords-after "shim-go" --input-chords-delay 2 \
    --script3 '$RUN_DIR/s3-A.txt' --script3-after "shim-go" --script3-delay 8 \
    --script-expect "echo shim-done" --timeout 260

vgate_assert A serial-absent "[EXC] parking:"
vgate_assert A python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'dui: alt-tab (active|cycle)', ser), "shim alt-tab check failed"
PY

# --- boot B: the WM-driven Alt+Tab ---
vgate_run B -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-B.txt' \
    --script2 '$RUN_DIR/s2-B.txt' --script2-after "m21demo: loop ok" --script2-delay 20 \
    --input-chords "alt-tab" --input-chords-after "chord-go" --input-chords-delay 2 \
    --script3 '$RUN_DIR/s3-B.txt' --script3-after "chord-go" --script3-delay 20 \
    --script-expect "alt-tab-done" --timeout 260

vgate_assert B serial-contains "wnd: alt-tab id="
vgate_assert B serial-absent "dui: alt-tab"
vgate_assert B serial-contains "wnd: present"
vgate_assert B serial-absent "[EXC] parking:"
vgate_assert B python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'key_fan=[1-9][0-9]*', ser), "key_fan check failed"
assert re.search(r'alt_tab=[1-9][0-9]*', ser), "alt_tab check failed"
PY

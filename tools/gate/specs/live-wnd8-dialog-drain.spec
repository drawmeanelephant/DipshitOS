# live-wnd8-dialog-drain.spec -- WMS8 Gates 2+3: about dialog drains into WND.BIN and kernel decision is deleted

vgate_name live-wnd8-dialog-drain "WMS8 Gates 2+3: about dialog drains into WND.BIN"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-A.txt <<'EOF'
echo bootA-go
EOF

vgate_file s2-A.txt <<'EOF'
echo shim-go
EOF

vgate_file s3-A.txt <<'EOF'
echo shim-done
EOF

vgate_file script-B.txt <<'EOF'
wnd start
exec M21DEMO.BIN
EOF

vgate_file s2-B.txt <<'EOF'
wm
echo chord-go
EOF

vgate_file s3-B.txt <<'EOF'
wm
echo about-done
EOF

# --- boot A: dormant shim (no WM) ---
vgate_run A -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-A.txt' \
    --script2 '$RUN_DIR/s2-A.txt' --script2-after "bootA-go" --script2-delay 6 \
    --input-chords "ctrl-shift-a" --input-chords-after "shim-go" --input-chords-delay 2 \
    --script3 '$RUN_DIR/s3-A.txt' --script3-after "shim-go" --script3-delay 8 \
    --script-expect "echo shim-done" --timeout 260

vgate_assert A serial-absent "dui: about"
vgate_assert A serial-absent "[EXC] parking:"

# --- boot B: the WM-driven about dialog ---
vgate_run B -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-B.txt' \
    --script2 '$RUN_DIR/s2-B.txt' --script2-after "m21demo: loop ok" --script2-delay 10 \
    --input-chords "ctrl-shift-a" --input-chords-after "chord-go" --input-chords-delay 2 \
    --script3 '$RUN_DIR/s3-B.txt' --script3-after "chord-go" --script3-delay 14 \
    --script-expect "about-done" --timeout 260

vgate_assert B serial-contains "wnd: about"
vgate_assert B serial-absent "dui: about"
vgate_assert B serial-contains "wnd: present"
vgate_assert B serial-absent "[EXC] parking:"
vgate_assert B python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'key_fan=[1-9][0-9]*', ser), "key_fan check failed"
assert re.search(r'dialog=[1-9][0-9]*', ser), "dialog check failed"
PY

# live-wnd5-gate2-policy.spec -- WMS5 Gate 2: registered-WM W1–W16 matrix & WM-driven Ctrl+T policy

vgate_name live-wnd5-gate2-policy "WMS5 Gate 2: registered-WM W1-W16 matrix & WM-driven Ctrl+T policy"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-A.txt <<'EOF'
wnd start
exec NOTEPAD.BIN
EOF

vgate_file s2-A.txt <<'EOF'
dui tile 2
dui master
dui minimize 2
dui restore 2
dui maximize 2
dui ws 1
dui ws 0
wm
echo matrix-a
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
dui
wm
tasks
procs
echo ctrl-t-done
EOF

# --- boot A: the registered-WM W1–W16 matrix ---
vgate_run A -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-A.txt' \
    --script2 '$RUN_DIR/s2-A.txt' --script2-after "notepad: ready" --script2-delay 20 \
    --script-expect "echo matrix-a" --timeout 240

vgate_assert A serial-contains "wnd: registered"
vgate_assert A serial-contains "wnd: present"
vgate_assert A serial-contains "dui tile: id=2 mode=on master=2"
vgate_assert A serial-contains "dui master: side="
vgate_assert A serial-contains "dui minimize: minimized id=2"
vgate_assert A serial-contains "dui restore: restored id=2"
vgate_assert A serial-contains "dui maximize: id=2 max=on"
vgate_assert A serial-contains "dui ws: workspace=1"
vgate_assert A serial-absent "[EXC] parking:"
vgate_assert A python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'key_fan=[0-9]+', ser), "key_fan check failed"
PY

# --- boot B: the WM-driven keyboard policy ---
vgate_run B -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-B.txt' \
    --script2 '$RUN_DIR/s2-B.txt' --script2-after "notepad: ready" --script2-delay 20 \
    --input-chords "ctrl-t" --input-chords-after "chord-go" --input-chords-delay 2 \
    --script3 '$RUN_DIR/s3-B.txt' --script3-after "chord-go" --script3-delay 20 \
    --script-expect "ctrl-t-done" --timeout 260

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

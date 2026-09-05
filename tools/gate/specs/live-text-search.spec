# live-text-search.spec -- milestone-twenty card U3 class-B gate (text search in apps)

vgate_name live-text-search "M20 U3 -- NOTEPAD find/goto + FILE.BIN filter on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-A.txt <<'EOF'
exec NOTEPAD.BIN
EOF

vgate_file settle-A.txt <<'EOF'
dui focus 0
echo m20-notepad-search-ok
EOF

vgate_file script-B.txt <<'EOF'
exec FILE.BIN
EOF

vgate_file settle-B.txt <<'EOF'
dui focus 0
echo m20-file-search-ok
EOF

# --- boot A: NOTEPAD find bar + Ctrl+G goto line ---
vgate_run A -- \
    --script '$RUN_DIR/script-A.txt' \
    --input-chords "h,e,l,l,o,return,w,o,r,l,d,return,t,e,x,t,ctrl-f,w,o,r,return,ctrl-g,2,return" --input-chords-after "notepad: ready" \
    --script2 '$RUN_DIR/settle-A.txt' --script2-after "notepad: goto line=2 offset=6" --script2-delay 2 \
    --script-expect "m20-notepad-search-ok" --timeout 150

vgate_assert A serial-contains "notepad: ready"
vgate_assert A serial-contains "notepad: find 'wor' hit=1/1"
vgate_assert A serial-contains "notepad: goto line=2 offset=6"
vgate_assert A serial-contains "m20-notepad-search-ok"
vgate_assert A serial-absent "[EXC] parking:"

# --- boot B: FILE.BIN Ctrl+F filename filter ---
vgate_run B -- \
    --script '$RUN_DIR/script-B.txt' \
    --input-chords "ctrl-f,t,x,t" --input-chords-after "file: ready" \
    --script2 '$RUN_DIR/settle-B.txt' --script2-after "file: filter 'txt'" --script2-delay 2 \
    --script-expect "m20-file-search-ok" --timeout 150

vgate_assert B serial-contains "file: ready"
vgate_assert B serial-contains "m20-file-search-ok"
vgate_assert B serial-absent "[EXC] parking:"
vgate_assert B python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r"file: filter 'txt' shown=[1-9][0-9]* total=[0-9]+", ser), "file filter report missing"
PY

# live-text-search.spec -- milestone-twenty card U3 class-B gate (text search in apps)
# M60 / #1374: boot B (exec FILE.BIN filename filter) retired with Zig FILE.BIN.
# Remaining walk is NOTEPAD find/goto.

vgate_name live-text-search "M20 U3 -- NOTEPAD find/goto on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-A.txt <<'EOF'
exec NOTEPAD.BIN
EOF

vgate_file settle-A.txt <<'EOF'
dui focus 0
echo m20-notepad-search-ok
EOF

# --- boot A: NOTEPAD find bar + Ctrl+G goto line ---
vgate_run A -- \
    --screen '$RUN_DIR/gpu-screen-A' \
    --script '$RUN_DIR/script-A.txt' \
    --input-chords "h,e,l,l,o,return,w,o,r,l,d,return,t,e,x,t,ctrl-f,w,o,r,return,ctrl-g,2,return" --input-chords-after "notepad: ready" \
    --script2 '$RUN_DIR/settle-A.txt' --script2-after "notepad: goto line=2 offset=6" --script2-delay 2 \
    --script-expect "m20-notepad-search-ok" --timeout 150

vgate_assert A serial-contains "notepad: ready"
vgate_assert A serial-contains "notepad: find 'wor' hit=1/1"
vgate_assert A serial-contains "notepad: goto line=2 offset=6"
vgate_assert A serial-contains "m20-notepad-search-ok"
vgate_assert A serial-absent "[EXC] parking:"

# live-desktop.spec -- claim 2427 (Milestone 11, Card A5) Desktop Platform & GUI Apps (ADR 0011)
vgate_name live-desktop "Milestone 11 Desktop Platform & GUI Apps"
vgate_share seed

vgate_file script.txt <<'EOF'
exec NOTEPAD.BIN
exec TOP.BIN
exec DESKTOP.BIN
EOF

vgate_file script2.txt <<'EOF'
procs
syscalls
echo done-desktop-sweep
EOF

vgate_run A -- \
    --display --input --screen '$RUN_DIR/gpu-screen' \
    --script '$RUN_DIR/script.txt' \
    --script-after "tasks user-el0 exited status=7" \
    --input-chords "return" \
    --input-chords-after "desktop: menu ready" \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after "calc: ready" \
    --script-expect "done-desktop-sweep" \
    --timeout 90

vgate_assert A serial-contains "calc: ready"
vgate_assert A serial-contains "notepad: ready"
vgate_assert A serial-contains "top: ready"
vgate_assert A serial-contains "desktop: ready"
vgate_assert A serial-contains "desktop: menu ready"
vgate_assert A serial-contains "desktop: manifest apps="
vgate_assert A serial-contains "desktop: launch CALC.BIN"
vgate_assert A serial-contains "28 sys_exec calls=1"
vgate_assert A serial-contains "done-desktop-sweep"
vgate_assert A serial-absent "[EXC] parking:"

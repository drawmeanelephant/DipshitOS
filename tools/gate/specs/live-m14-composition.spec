# live-m14-composition.spec -- claim 3289 (Milestone 14, Card S3)
#
# class-B gate: the composition capstone. NOTEPAD — the flagship text app —
# uses BOTH shared user services in ONE EL0 session:
#
#   S1 (claim 0169): the shared kernel clipboard. The gate pre-loads the
#   clipboard with the terminal's `clip` command, then NOTEPAD's `selfdemo`
#   mode pastes it (`sys_clipboard_get`, slot 39) and copies the result back
#   out (`sys_clipboard_set`, slot 38) — the paste AND copy directions, live.

vgate_name live-m14-composition "claim 3289 (Milestone 14, Card S3)"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
clip hello world
exec NOTEPAD.BIN selfdemo
EOF

vgate_file script2.txt <<'EOF'
syscalls
echo composition-live-ok
EOF

vgate_run 01 -- --display --script '$RUN_DIR/script.txt' --script-after "tasks user-el0 exited status=7" --script2 '$RUN_DIR/script2.txt' --script2-after "notepad: selfdemo done" --script-expect "procs NOTEPAD.BIN exited status=43" --timeout 90

vgate_assert 01 serial-contains 'notepad: selfdemo pasted'
vgate_assert 01 serial-contains 'notepad: selfdemo copied'
vgate_assert 01 serial-contains 'notepad: cursor blink'
vgate_assert 01 serial-contains 'notepad: selfdemo armed blink'
vgate_assert 01 serial-contains 'notepad: selfdemo done'
vgate_assert 01 serial-contains 'notepad: exiting 43'
vgate_assert 01 serial-contains 'tasks user-exec exited status=43'
vgate_assert 01 serial-contains 'syscalls: slots=64 implemented=61'
vgate_assert 01 serial-contains '38 sys_clipboard_set calls=1'
vgate_assert 01 serial-contains '39 sys_clipboard_get calls=1'
vgate_assert 01 serial-contains '40 sys_timer_set calls=7'
vgate_assert 01 serial-contains 'composition-live-ok'
vgate_assert 01 serial-contains 'input: armed'
vgate_assert 01 serial-contains 'syscalls: slots=64 implemented=61'
vgate_assert 01 serial-absent '[EXC] parking:'

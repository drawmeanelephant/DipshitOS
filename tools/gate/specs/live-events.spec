# live-events.spec -- claim 9328 (milestone nine, card E6) class-B
#
# capstone gate: interactive EL0 event routing and application feedback,
# live on real VZ hardware.
#
# KEYTEST.BIN (`user/src/keytest.zig`, the TENTH ESP user program) drives
# the milestone nine application event system entirely from EL0:
#   1. `sys_win_open(96, 96, 256, 192)` (slot 12) opens user window id 2,
#      which immediately receives focus and queues a synthetic `WIN_FOCUS` event.

vgate_name live-events "claim 9328 (milestone nine, card E6) class-B"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec KEYTEST.BIN
EOF

vgate_file script2.txt <<'EOF'
procs
syscalls
EOF

vgate_run 01 -- --display --input --screen '$RUN_DIR/gpu-screen' --script '$RUN_DIR/script.txt' --input-string "A" --input-string-after "keytest: win_focus" --script2 '$RUN_DIR/script2.txt' --script2-after "keytest: exiting 99" --script-expect "exited status=99" --timeout 60

vgate_assert 01 serial-contains 'keytest: open id=2'
vgate_assert 01 serial-contains 'keytest: present ok'
vgate_assert 01 serial-contains 'keytest: win_focus'
vgate_assert 01 serial-contains 'keytest: key_down'
vgate_assert 01 serial-contains 'keytest: exiting 99'
vgate_assert 01 serial-contains 'exited status=99'
vgate_assert 01 serial-contains 'sys_wait_event calls='
vgate_assert 01 serial-absent '[EXC] parking:'

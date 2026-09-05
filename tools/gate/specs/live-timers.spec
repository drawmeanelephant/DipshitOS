# live-timers.spec -- claim 7323 (Milestone 14, Card S2) class-B gate:
#
# the bounded per-process application timer facility (ADR 0007 slots 40-41)
# verified on real Apple silicon Virtualization.framework hardware.
#
# TIMER.BIN drives the seam from EL0 WITHOUT spinning: arm a 2-tick timer,
# BLOCK in `sys_wait_event`, observe the `TIMER` event the kernel posts when
# the countdown reaches zero (the scheduler tick fires it), prove cancel
# (nothing pending -> 0), re-arm -> fire again, and cancel a live pending

vgate_name live-timers "claim 7323 (Milestone 14, Card S2) class-B gate:"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec TIMER.BIN
EOF

vgate_file script2.txt <<'EOF'
syscalls
echo timers-live-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after "tasks user-el0 exited status=7" --script2 '$RUN_DIR/script2.txt' --script2-after "timertest: done" --script2-delay 3 --script-expect "timers-live-ok" --timeout 90

vgate_assert 01 serial-contains 'timertest: armed 2'
vgate_assert 01 serial-contains 'timertest: fired seq=1'
vgate_assert 01 serial-contains 'timertest: cancel-none'
vgate_assert 01 serial-contains 'timertest: armed 1'
vgate_assert 01 serial-contains 'timertest: fired2 seq=2'
vgate_assert 01 serial-contains 'timertest: canceled'
vgate_assert 01 serial-contains 'timertest: done'
vgate_assert 01 serial-contains 'tasks user-exec exited status=23'
vgate_assert 01 serial-contains 'syscalls: slots=64 implemented='
vgate_assert 01 serial-contains '40 sys_timer_set calls=3'
vgate_assert 01 serial-contains '41 sys_timer_cancel calls=2'
vgate_assert 01 serial-contains 'timers-live-ok'
vgate_assert 01 serial-absent '[EXC] parking:'

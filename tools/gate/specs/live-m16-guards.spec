# live-m16-guards.spec -- claim 8403 (Milestone 16, Card C2) class-B gate:
#
# guard pages + per-segment permissions + the hostile-EL0-refused proof,
# verified on real Apple silicon Virtualization.framework hardware.
#
# GUARD.BIN (the hostile program) prints its alive marker, then steps 12 KiB
# below its stack top — landing 4 KiB BELOW the stack bottom, in the guard
# page the user root leaves unmapped. The store takes a real EL0 data abort
# (ESR EC 0x24); the kernel's fault dispatcher REAPS the process (status 139,

vgate_name live-m16-guards "claim 8403 (Milestone 16, Card C2) class-B gate:"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec COUNTER.BIN
exec GUARD.BIN
EOF

vgate_file script2.txt <<'EOF'
echo guards-live-ok
procs
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after "tasks user-el0 exited status=7" --script2 '$RUN_DIR/script2.txt' --script2-after "tasks user-exec exited status=139" --script-expect "guards-live-ok" --timeout 90

vgate_assert 01 serial-contains 'guard: stepping off'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 serial-contains 'tasks user-exec exited status=139'
vgate_assert 01 serial-contains 'procs GUARD.BIN exited status=139'
vgate_assert 01 serial-contains 'counter: alive'
vgate_assert 01 serial-contains 'procs: id=.*name=COUNTER.BIN state=running'
vgate_assert 01 serial-contains 'procs: id=.*name=GUARD.BIN state=exited.*exit=139'
vgate_assert 01 serial-contains 'guards-live-ok'

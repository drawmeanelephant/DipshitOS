# live-smp1.spec -- claim 2369 class-B gate: a USER program runs on a
#
# SECONDARY core (core 1) through the locked console TX.
#
# The PE-0 tick gate was lifted (claim 9408) and the scheduler state is
# per-core (claim 8477), but user tasks still had to stay on core 0:
# their sys_writes hit the polled virtio TX, which had no lock — two cores
# printing concurrently could interleave bytes and corrupt lines. This
# gate proves the whole chain, end to end, on real VZ hardware:

vgate_name live-smp1 "claim 2369 class-B gate: a USER program runs on a"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
ls
exec -c1 SMP1.BIN
procs
echo rx-smp1-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after "tasks user-el0 exited status=7" --timeout 45

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'SMP1.BIN'
vgate_assert 01 serial-contains 'exec: loaded SMP1.BIN size='
vgate_assert 01 serial-contains 'smp1: hello from core-1 userland'
vgate_assert 01 serial-contains 'smp1: exiting from core 1'
vgate_assert 01 serial-exact 'tasks user-exec exited status=0' 1
vgate_assert 01 serial-exact 'procs SMP1.BIN exited status=0' 1
vgate_assert 01 serial-exact 'tasks user-exec reaped' 1
vgate_assert 01 serial-contains 'smp: secondary runs='
vgate_assert 01 serial-contains 'task=SMP1.BIN'
vgate_assert 01 serial-contains 'rx-smp1-ok'
vgate_assert 01 serial-absent '[EXC] parking:'

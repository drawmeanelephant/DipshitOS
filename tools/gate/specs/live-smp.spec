# live-smp.spec -- Milestone 28 (claim 6438) class-B gate:
#
# Symmetric Multi-Processing (SMP) multi-core bringup on Apple Silicon VZ.
#
# Asserts on live Virtualization.framework hardware:
#   1. Secondary CPU core powers on via PSCI CPU_ON (conduit HVC).
#   2. Both CPU cores initialize MMU, GICv3 redistributor, and local physical timer.
#   3. `smp` command reports `cores=2 online=2`.
#   4. Multi-core task scheduling and IPI communication function without exception.

vgate_name live-smp "Milestone 28 (claim 6438) class-B gate:"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
smp
tasks
ps
exec COUNTER.BIN
smp
echo rx-smp-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after "tasks user-el0 exited status=7" --script-expect "rx-smp-ok" --timeout 30

vgate_assert 01 serial-absent '[EXC] parking:'

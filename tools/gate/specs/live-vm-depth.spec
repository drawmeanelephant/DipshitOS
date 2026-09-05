# live-vm-depth.spec -- Milestone 29 (Issue #598, Claim 8247) Class-B gate:
#
# VM Depth: Demand Paging, Copy-on-Write (COW), and Anonymous mmap on real VZ hardware.
#
# Asserts:
#   1. System boots cleanly under VZ on Apple Silicon.
#   2. `exec VMTEST.BIN` loads and executes the M29 test payload at EL0.
#   3. Anonymous `mmap` registers valid user address space regions.
#   4. Translation faults at unmapped addresses trigger on-demand zero-fill page allocation.

vgate_name live-vm-depth "Milestone 29 (Issue #598, Claim 8247) Class-B gate:"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
exec VMTEST.BIN
EOF

vgate_file script2.txt <<'EOF'
echo rx-vmtest-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after "tasks user-el0 exited status=7" --script2 '$RUN_DIR/script2.txt' --script2-after "vmtest: all tests passed" --script-expect "rx-vmtest-ok" --timeout 60

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'vmtest: mmap ok'
vgate_assert 01 serial-contains 'vmtest: demand read ok'
vgate_assert 01 serial-contains 'vmtest: demand write ok'
vgate_assert 01 serial-contains 'vmtest: munmap ok'
vgate_assert 01 serial-contains 'vmtest: eager mmap ok'
vgate_assert 01 serial-contains 'vmtest: all tests passed'
vgate_assert 01 serial-contains 'rx-vmtest-ok'
vgate_assert 01 serial-absent '[EXC] parking:'

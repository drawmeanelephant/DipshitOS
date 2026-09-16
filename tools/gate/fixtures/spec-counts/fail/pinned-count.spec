# syscall-count guard FIXTURE (issue #1345) -- NOT a gate; it is never executed
# and never enters the fleet.
#
# Shape: the assert pins `implemented=68`, a literal copy of a number the kernel
# counts LIVE from its dispatch table. That is the drift six specs carried while
# the kernel reported 76 -- red on every VZ host, invisible wherever no runner
# is registered.
# Expected: a FAIL naming this file and the pinned count.

vgate_name speccounts-fixture-pinned-count
vgate_share seed

vgate_file script.txt <<'EOF'
syscalls
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'syscalls' --timeout 30

vgate_assert 01 serial-contains 'syscalls: slots=64 implemented=68'

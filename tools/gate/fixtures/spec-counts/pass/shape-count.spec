# syscall-count guard FIXTURE (issue #1345) -- NOT a gate; it is never executed
# and never enters the fleet.
#
# Shape: the assert takes the report's shape and the slot row this gate is
# about. The pinned number it used to carry (implemented=68) survives only in
# this comment, which is exempt by design -- documentation may name a count.
# Expected: no violation.

vgate_name speccounts-fixture-shape-count
vgate_share seed

vgate_file script.txt <<'EOF'
syscalls
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'syscalls' --timeout 30

vgate_assert 01 serial-contains 'syscalls: slots=64 implemented='
vgate_assert 01 serial-contains '65 sys_wmctl calls=2'

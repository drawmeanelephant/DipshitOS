# exec-order guard FIXTURE (claim #1193) -- NOT a gate; it is never executed
# and never enters the fleet.
#
# Shape: the go-hello shape (single exec, run ends on a script-supplied
# marker, no stage gate) but with the intent DECLARED. The marker is not what
# makes the run green: the asserts read output only the program produces, so a
# program that never ran still fails the run.
# Expected: no violation, and the declaration is echoed in the guard's output.

vgate_name execorder-fixture-declared-assert-proven
vgate_share seed

# exec-order: assert-proven -- the assert below reads program output, so the
# stop trigger is not the evidence; residual risk is a late tail, never a
# false pass.

vgate_file script.txt <<'EOF'
exec APP.BIN
echo fixture-done
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'fixture-done' --timeout 30

vgate_assert 01 serial-contains 'fixture-output: done'

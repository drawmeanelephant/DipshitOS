# exec-order guard FIXTURE (claim #1193) -- NOT a gate; it is never executed
# and never enters the fleet.
#
# Shape: a run that ends on a script-supplied marker but launches NO program
# at all -- the most common spec shape in the fleet. There is no ordering to
# lose here, so the guard must stay silent and require no declaration.
# Expected: no violation.

vgate_name execorder-fixture-no-exec
vgate_share seed

vgate_file script.txt <<'EOF'
vf write fixture-out.txt
echo fixture-done
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'fixture-done' --timeout 30

vgate_assert 01 serial-contains 'fixture-done'

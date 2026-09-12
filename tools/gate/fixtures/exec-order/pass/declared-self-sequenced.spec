# exec-order guard FIXTURE (claim #1193) -- NOT a gate; it is never executed
# and never enters the fleet.
#
# Shape: the live-jobs shape (background `&` launches, run ends on a
# script-supplied marker, no stage gate) but with the intent DECLARED. Each
# `fg N` blocks until that job is reaped, so by the time the closing marker is
# echoed both programs have finished and their output is already in the log.
# Expected: no violation, and the declaration is echoed in the guard's output.

vgate_name execorder-fixture-declared-self-sequenced
vgate_share seed

# exec-order: self-sequenced -- blocking `fg` reaps the jobs before the closing
# marker is echoed, so no program is still starting when the VM stops.

vgate_file script.txt <<'EOF'
exec COUNTER.BIN &
jobs
exec STATUS43.BIN &
fg 1
fg 2
echo fixture-jobs-done
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'fixture-jobs-done' --timeout 30

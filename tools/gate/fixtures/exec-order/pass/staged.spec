# exec-order guard FIXTURE (claim #1193) -- NOT a gate; it is never executed
# and never enters the fleet.
#
# Shape: a program IS launched, but the run is held by a stage gate
# (`--script2-after` waits for a marker the GUEST prints) and ends on a
# program marker. This is the graded idiom, so it needs no declaration.
# Expected: no violation.

vgate_name execorder-fixture-staged
vgate_share seed

vgate_file script.txt <<'EOF'
exec APP.BIN
EOF

vgate_file script2.txt <<'EOF'
echo staged-done
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'app: ready' --script-expect 'app: finished' --timeout 30

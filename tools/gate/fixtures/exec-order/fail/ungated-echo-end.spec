# exec-order guard FIXTURE (claim #1193) -- NOT a gate; it is never executed
# and never enters the fleet (tools/gate/fleet.sh globs tools/gate/specs/).
# tools/inventory-gates.sh parses it only, to prove the spec-order guard still
# catches the shape it exists for.
#
# Shape: the script launches a program and the run ends on a marker the script
# itself supplies (`echo fixture-done`), with no stage gate -- so the VM can
# stop while the program is still starting and the run can pass unproven.
# Expected: a VIOLATION naming this file and "no stage gate".

vgate_name execorder-fixture-ungated-echo-end
vgate_share seed

vgate_file script.txt <<'EOF'
exec APP.BIN &
echo fixture-done
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'fixture-done' --timeout 30

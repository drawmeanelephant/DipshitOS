# exec-order guard FIXTURE (claim #1193) -- NOT a gate; it is never executed
# and never enters the fleet.
#
# Shape: the run looks graded -- it has a stage gate -- but the gate marker is
# one the spec's OWN script echoes, so the gate fires on the script's own
# text and sequences nothing. A second script does the same and the run ends
# on its marker. This is the live-wm3-taskbar shape (`--script3-after
# 'taskbar-go'`, which its own s2 script echoes), reduced to a fixture.
# Expected: a VIOLATION naming this file and "no stage gate".

vgate_name execorder-fixture-vacuous-gate
vgate_share seed

vgate_file script.txt <<'EOF'
exec APP.BIN
EOF

vgate_file script2.txt <<'EOF'
echo fixture-go
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'fixture-go' --script-expect 'fixture-go' --timeout 30

# exec-order guard FIXTURE (claim #1193) -- NOT a gate; it is never executed
# and never enters the fleet.
#
# Shape: a file-channel operation follows an `exec` in the same script, so it
# can race that program's own writes -- exactly the failure that landed in
# live-oliver (#1188), where a `vf rm` between two exec'd runs reported the
# file as missing because the first program's write had not landed yet.
#
# The `--script-expect` marker is deliberately a PROGRAM marker (`app: done`),
# which the script does not contain, so only the file-op rule fires here and
# the two fail fixtures stay independent.
# Expected: a VIOLATION naming this file and "follows an exec".

vgate_name execorder-fixture-exec-then-vf
vgate_share seed

vgate_file script.txt <<'EOF'
exec APP.BIN IN.TXT OUT.HTML
vf rm OUT.HTML
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'app: done' --timeout 30

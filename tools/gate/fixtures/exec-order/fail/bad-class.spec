# exec-order guard FIXTURE (claim #1193) -- NOT a gate; it is never executed
# and never enters the fleet.
#
# Shape: an `# exec-order:` declaration whose class is not one of the four
# known classes. A declaration is a promise the guard trusts, so a typo in the
# class must fail loudly instead of silently exempting the spec.
# Expected: a FAIL naming this file and "declaration class".

vgate_name execorder-fixture-bad-class
vgate_share seed

# exec-order: because-i-said-so -- not one of the four known classes

vgate_file script.txt <<'EOF'
exec APP.BIN &
echo fixture-done
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'fixture-done' --timeout 30

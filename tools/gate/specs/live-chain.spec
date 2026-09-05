# live-chain.spec -- milestone-nineteen cards P3+P4 class-B gate
#
# (issues #292, #293): command chaining (`;`, `&&`, `||`) and `$?` exit
# status propagation.
#
# Mechanism: boots the production image and drives the walk over serial:
#   echo chain-a && echo chain-b        -> both lines printed
#   false && echo chain-skip ; echo chain-seq
#                                        -> "chain-seq" printed,
#                                           "chain-skip" NEVER printed
#   exec NOTEXIST.BIN ; echo exit=$?    -> honest exec refusal, exit=1
#   true ; echo ok=$?                   -> ok=0
#   echo chain-done                     -> completion marker

vgate_name live-chain "milestone-nineteen cards P3+P4 class-B gate"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
echo chain-a && echo chain-b
false && echo chain-skip ; echo chain-seq
exec NOTEXIST.BIN ; echo exit=$?
true ; echo ok=$?
echo chain-done
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect "chain-done" --timeout 30

vgate_assert 01 serial-contains 'VirelaiOS kernel'
vgate_assert 01 serial-exact 'chain-a' 1
vgate_assert 01 serial-exact 'chain-b' 1
vgate_assert 01 serial-exact 'chain-skip' 0
vgate_assert 01 serial-exact 'chain-seq' 1
vgate_assert 01 serial-contains 'not found on the host share'
vgate_assert 01 serial-contains 'exit=1'
vgate_assert 01 serial-contains 'ok=0'
vgate_assert 01 serial-contains 'chain-done'
vgate_assert 01 serial-absent '[EXC] parking:'

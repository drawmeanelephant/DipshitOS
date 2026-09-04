# live-pipe.spec -- the pipe operator: left-echo output travels through
# the pipe into `type`, `ls` lists through the pipe, and chained pipes
# are honestly refused.
# Mirrors tools/verify-live-pipe.sh (M19 P1, issue #290).

vgate_name live-pipe "pipe operator cmd1 | cmd2 on VZ"
vgate_share arm
vgate_repeat 1 BOOTS
vgate_fmt boot/src/*.zig kernel/src/*.zig build.zig
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
echo pipe-left-marker | type
ls | type
echo a | echo b | echo c
echo pipe-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'pipe-ok' --timeout 30

vgate_assert 01 serial-contains 'VirelaiOS kernel'
vgate_assert 01 serial-exact 'pipe-left-marker' 1
vgate_assert 01 serial-contains 'ls: host='
vgate_assert 01 serial-contains 'pipes: only one pipe per line (no chaining)'
vgate_assert 01 serial-contains 'pipe-ok'

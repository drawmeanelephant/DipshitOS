# live-calc-prog.spec -- milestone-twenty-four card K1 class-B gate:
#
# programmer mode toggle on real VZ.
#
# Mechanism: boots the production image, execs CALC.BIN from the monitor,
# waits for the app to be ready, sends Ctrl+P to toggle programmer mode,
# and asserts the serial markers prove the toggle happened.
#
# The walk:

vgate_name live-calc-prog "milestone-twenty-four card K1 class-B gate:"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
exec CALC.BIN
EOF

vgate_file script2.txt <<'EOF'
echo calc-prog-live-ok
EOF

vgate_run 01 -- --display --screen '$RUN_DIR/gpu-screen-01' --via-virtio --script '$RUN_DIR/script.txt' --input-chords "ctrl-p,ctrl-p" --input-chords-after "calc: ready" --script2 '$RUN_DIR/script2.txt' --script2-after "timer heartbeat ticks=10" --script-expect "calc-prog-live-ok" --timeout 45

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'calc: ready'
vgate_assert 01 serial-contains 'calc: prog-on'
vgate_assert 01 serial-contains 'calc: prog-off'
vgate_assert 01 serial-contains 'calc-prog-live-ok'
vgate_assert 01 serial-absent '[EXC] parking:'

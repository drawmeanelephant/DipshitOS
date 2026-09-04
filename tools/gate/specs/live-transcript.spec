# live-transcript.spec -- vgate pilot (serial-only + repeat): live RX.
# Host scripted keystrokes reach the kernel end to end and the exact
# `virelai>` transcript lands in vm-serial.log. Mirrors
# tools/verify-live-transcript.sh (claim 6684); proves the serial-contains,
# serial-echo, and repeat (BOOTS) paths.

vgate_name live-transcript "live RX: host keystrokes -> kernel -> vm-serial.log"
vgate_repeat 1 BOOTS
vgate_fmt boot/src/*.zig kernel/src/*.zig build.zig
vgate_note "script: help/version/mem/echo rx-live-ok"

vgate_file script.txt <<'EOF'
help
version
mem
echo rx-live-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect rx-live-ok --timeout 40

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-echo version
vgate_assert 01 serial-contains 'available commands:'
vgate_assert 01 serial-contains 'virelai-kernel'
vgate_assert 01 serial-contains 'mem: descriptors='
vgate_assert 01 serial-contains 'rx-live-ok'

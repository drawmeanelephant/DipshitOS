# live-help.spec -- the ADR 0008 discovery surface live: grouped
# catalog, per-command detail, topic pages, and command-wins-over-topic.
# Mirrors tools/verify-live-help.sh (claim 3275, M8 U1).

vgate_name live-help "ADR 0008 help catalog walk on VZ"
vgate_repeat 1 BOOTS
vgate_fmt boot/src/*.zig kernel/src/*.zig build.zig

vgate_file script.txt <<'EOF'
help
help net
help networking
help windows
help storage
help graphics
help syscalls
echo help-live-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'help-live-ok' --timeout 40

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'machine / identity'
vgate_assert 01 serial-contains 'memory / machine state'
vgate_assert 01 serial-contains 'graphics / input'
vgate_assert 01 serial-contains "type 'help <topic>' for a topic page"
vgate_assert 01 serial-contains 'net - virtio-net transport'
vgate_assert 01 serial-contains 'usage: net [recv'
vgate_assert 01 serial-contains 'virtio-net (DID 0x1041), flag-gated'
vgate_assert 01 serial-contains 'owns the window registry'
vgate_assert 01 serial-contains 'The macOS host share (custom-virtio queue 5'
vgate_assert 01 serial-contains '1280x720 B8G8R8X8, 2D blits only'
vgate_assert 01 serial-contains 'syscalls - numbered syscall table'
vgate_assert 01 serial-contains 'help-live-ok'

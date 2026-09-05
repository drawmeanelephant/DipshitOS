# live-typography.spec -- live-typography
#
#
# Proves, in a live VZ VM on Apple silicon:
#   1. The host share seeds TrueType fonts (/host/INTER.TTF and /host/FIRACODE.TTF).
#   2. On application window creation (NOTEPAD.BIN and EDIT.BIN), ui.init_fonts()
#      automatically probes and loads both Inter and Fira Code fonts.
#   3. The guest emits the serial markers:
#        "typography: Inter TrueType font loaded"

vgate_name live-typography "live-typography"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

# Legacy created this script (exec NOTEPAD.BIN) at runtime; the port
# referenced it but never declared it, so the runner died at startup
# ("could not read script file").
vgate_file script.txt <<'EOF'
exec NOTEPAD.BIN
EOF

vgate_run 01 -- --screen '$RUN_DIR/screen' --via-virtio --cvc-snap --snapshot-out '$RUN_DIR/snap' --script '$RUN_DIR/script.txt' --snapshot-after "notepad: settled" --script-expect "notepad: settled" --script-expect-tail 2 --timeout 120

vgate_assert 01 serial-contains 'typography: Inter TrueType font loaded'
vgate_assert 01 serial-contains 'typography: Fira Code TrueType font loaded'
vgate_assert 01 serial-contains 'notepad: open id='
vgate_assert 01 serial-contains 'notepad: settled'
vgate_assert 01 serial-absent '[EXC] parking:'

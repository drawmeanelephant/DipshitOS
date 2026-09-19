# live-typography.spec -- live-typography
#
#
# Proves, in a live VZ VM on Apple silicon:
#   1. The host share seeds TrueType fonts (/host/INTER.TTF and /host/FIRACODE.TTF).
#   2. On application window creation (SYSMON.BIN), ui.init_fonts()
#      automatically probes and loads both Inter and Fira Code fonts.
#   3. The guest emits the serial markers:
#        "typography: Inter TrueType font loaded"

vgate_name live-typography "live-typography"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

# The legacy Zig notepad created this script at runtime; the port
# referenced it but never declared it, so the runner died at startup
# ("could not read script file"). M66c (#1485): the Zig notepad is retired,
# so the window creator is a Zig app that still ships. It MUST be a Zig app:
# the font engine is `user/src/lib/ui/font.zig`, reached through ui.init_fonts()
# on window creation — the Go clients (NOTE.ELF, GOEDIT.ELF) never touch it, so
# a Go client cannot carry this boot. SYSMON.BIN is the dock's font-heavy Zig app.
vgate_file script.txt <<'EOF'
exec SYSMON.BIN
EOF

vgate_run 01 -- --screen '$RUN_DIR/screen' --via-virtio --cvc-snap --snapshot-out '$RUN_DIR/snap' --script '$RUN_DIR/script.txt' --snapshot-after "sysmon: settled" --script-expect "sysmon: settled" --script-expect-tail 2 --timeout 120

vgate_assert 01 serial-contains 'typography: Inter TrueType font loaded'
vgate_assert 01 serial-contains 'typography: Fira Code TrueType font loaded'
vgate_assert 01 serial-contains 'sysmon: ready'
vgate_assert 01 serial-contains 'sysmon: settled'
vgate_assert 01 serial-absent '[EXC] parking:'

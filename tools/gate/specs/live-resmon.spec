# live-resmon.spec -- M22 D10: RESMON.BIN resource monitor on VZ.
# Loads RESMON.BIN, opens its resource-monitor window, and arms the refresh loop.

vgate_name live-resmon "M22 D10: RESMON.BIN resource monitor on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
exec RESMON.BIN
EOF

vgate_run 01 -- --display --script '$RUN_DIR/script.txt' --script-expect 'resmon: ready' --timeout 45

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded RESMON.BIN size='
vgate_assert 01 serial-contains 'resmon: open'
vgate_assert 01 serial-contains 'resmon: ready'
vgate_assert 01 serial-absent '[EXC] parking:'

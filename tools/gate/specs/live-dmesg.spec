# live-dmesg.spec -- M22 D12: dmesg system log viewer on VZ.
# Echoes a unique marker, then runs dmesg. The serial ring holds the marker
# from the echo output; the dmesg dump must contain it a SECOND time.

vgate_name live-dmesg "M22 D12: dmesg system log viewer on VZ"
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
version
echo dmesg-marker-7777
dmesg
echo rx-dmesg-ok
EOF

vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-expect 'rx-dmesg-ok' --timeout 60

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-count 'dmesg-marker-7777' 2
vgate_assert 01 serial-contains 'rx-dmesg-ok'
vgate_assert 01 serial-absent '[EXC] parking:'

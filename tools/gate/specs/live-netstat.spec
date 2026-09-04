# live-netstat.spec -- NETSTAT.BIN dashboard sections live: iface,
# dhcp, tcp, udp, arp, counters. The --display/--screen pair rides
# along unasserted (manual-inspection capture, as in legacy).
# Mirrors tools/verify-live-netstat.sh (M26 N2, issue #400).

vgate_name live-netstat "NETSTAT.BIN dashboard sections on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
net ip 10.0.0.9
net arp 10.0.0.2
exec NETSTAT.BIN
EOF

vgate_run 01 -- --display --screen '$RUN_DIR/netstat-screen' --script '$RUN_DIR/script.txt' --script-expect 'netstat: ready' --timeout 45

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'netstat: ready'
vgate_assert 01 serial-contains 'netstat: section iface'
vgate_assert 01 serial-contains 'netstat: section dhcp'
vgate_assert 01 serial-contains 'netstat: section tcp'
vgate_assert 01 serial-contains 'netstat: section udp'
vgate_assert 01 serial-contains 'netstat: section arp'
vgate_assert 01 serial-contains 'netstat: section counters'

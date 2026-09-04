# live-n8-netstatus.spec -- net status summary (N8), route inspection
# (N16), and the net log event viewer (N15) running in the monitor.
# Mirrors tools/verify-live-n8-netstatus.sh (M26 N8/N15/N16,
# issues #435, #442, #443).

vgate_name live-n8-netstatus "net status, route, log monitor commands live on VZ"

vgate_file script-1.txt <<'EOF'
net status
net ip 10.0.0.1
net status
net route
net arp 10.0.0.2
net log
echo netstatus-ok
EOF

vgate_run 01 -- --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 --script '$RUN_DIR/script-1.txt' --script-expect $'echo netstatus-ok' --timeout 30

vgate_assert 01 serial-contains 'net status: IP: 0.0.0.0'
vgate_assert 01 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert 01 serial-contains 'net status: IP: 10.0.0.1 Gateway: 10.0.0.2 DNS: 10.0.0.2'
vgate_assert 01 serial-contains 'net route: table'
vgate_assert 01 serial-contains '0.0.0.0/0'
vgate_assert 01 serial-contains 'net log: entries='
vgate_assert 01 serial-contains 'IP: assigned 10.0.0.1'
vgate_assert 01 serial-contains 'ARP: request 10.0.0.2'
vgate_assert 01 serial-contains 'echo netstatus-ok'

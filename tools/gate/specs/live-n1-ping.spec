# live-n1-ping.spec -- PING.BIN (exec'd) pings the host responder 3x
# from EL0: header, three seq replies, statistics, zero loss, exit 0.
# Mirrors tools/verify-live-n1-ping.sh (M26 N1, issue #399).

vgate_name live-n1-ping "PING.BIN 3-packet ICMP round trip from EL0 on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-1.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec PING.BIN -c 3 10.0.0.2
echo ping-launched
EOF

vgate_file script-2.txt <<'EOF'
procs
echo ping-ok
EOF

vgate_run 01 -- --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 --net-icmp-respond 10.0.0.2 --script '$RUN_DIR/script-1.txt' --script2 '$RUN_DIR/script-2.txt' --script2-after 'ping statistics' --script-expect 'tasks user-exec reaped' --timeout 60

vgate_assert 01 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert 01 serial-contains 'PING 10.0.0.2 (10.0.0.2): 56 data bytes'
vgate_assert 01 serial-contains '64 bytes from 10.0.0.2: icmp_seq=1'
vgate_assert 01 serial-contains '64 bytes from 10.0.0.2: icmp_seq=2'
vgate_assert 01 serial-contains '64 bytes from 10.0.0.2: icmp_seq=3'
vgate_assert 01 serial-contains '--- 10.0.0.2 ping statistics ---'
vgate_assert 01 serial-contains '3 packets transmitted, 3 packets received, 0% packet loss'
vgate_assert 01 serial-contains 'round-trip min/avg/max ='
vgate_assert 01 serial-contains 'echo ping-ok'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# Legacy -E pair: ARP resolved either way + the exit-0 reap row.
if not re.search(r"net arp: (request for|resolved)", ser):
    sys.exit("FAIL: no ARP resolution line")
if not re.search(r"PING.BIN.*state=exited.*0|PING.BIN\s+exit=0x0000000000000000", ser):
    sys.exit("FAIL: no PING.BIN exit-0 row")
print("ping arp + reap ok")
PY

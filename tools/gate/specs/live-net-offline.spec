# live-net-offline.spec -- the offline preflight (N13/N14): Run A
# with no net device (both apps exit fast with the diagnosis, never
# connected); Run B with net but no route (no-route exit, no stats);
# Run C the online control (healthy paths unaffected, no
# false-positive preflight).
# Mirrors tools/verify-live-net-offline.sh (claim 8852). One structural
# note: legacy seeds the share for Run A only (B/C run gateless);
# the spec seeds all runs (per-spec share mode) -- behavior-neutral
# for network paths, validated by the equivalence runs.

vgate_name live-net-offline "offline + no-route preflight, online control on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file a1.txt <<'EOF'
exec PING.BIN -c 3 10.0.0.2
exec FETCH.BIN
echo both-launched
EOF

vgate_file a2.txt <<'EOF'
echo offline-ok
EOF

vgate_file b1.txt <<'EOF'
net ip 10.0.0.1
exec PING.BIN -c 1 10.0.0.2
echo ping-noroute-launched
EOF

vgate_file b2.txt <<'EOF'
echo noroute-ok
EOF

vgate_file c1.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec PING.BIN -c 3 10.0.0.2
echo ping-online-launched
EOF

vgate_file c2.txt <<'EOF'
exec FETCH.BIN
EOF

vgate_file c3.txt <<'EOF'
echo online-ok
EOF

vgate_run A -- --script '$RUN_DIR/a1.txt' --script2 '$RUN_DIR/a2.txt' --script2-after 'offline — no IP address' --script-expect 'FETCH.BIN exited status=3' --timeout 90
vgate_run B -- --net '$RUN_DIR/b-cap.bin' --script '$RUN_DIR/b1.txt' --script2 '$RUN_DIR/b2.txt' --script2-after 'ping-noroute-launched' --script-expect 'PING.BIN exited status=3' --timeout 90
vgate_run C -- --net '$RUN_DIR/c-cap.bin' --net-arp-respond 10.0.0.2 --net-icmp-respond 10.0.0.2 --net-tcp-respond 10.0.0.2:80 --script '$RUN_DIR/c1.txt' --script2 '$RUN_DIR/c2.txt' --script2-after 'ping statistics' --script3 '$RUN_DIR/c3.txt' --script3-after 'fetch: starting' --script-expect 'FETCH.BIN exited status=42' --timeout 120

vgate_assert A serial-contains 'ping: offline — no IP address'
vgate_assert A serial-contains 'fetch: offline — no IP address'
vgate_assert A serial-contains 'echo offline-ok'
vgate_assert A serial-absent 'fetch: connected'
vgate_assert A python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# Legacy -cE >= 1 with the ([^0-9]|$) guard (status=2 must not match
# status=20+, hex exit likewise).
if sum(1 for _ in re.finditer(r"PING\.BIN exited status=2([^0-9]|$)|exit=0x0000000000000002", ser)) < 1:
    sys.exit("FAIL: no PING.BIN exit-2")
if sum(1 for _ in re.finditer(r"FETCH\.BIN exited status=3([^0-9]|$)|exit=0x0000000000000003", ser)) < 1:
    sys.exit("FAIL: no FETCH.BIN exit-3")
# Fast exit: the bounded poll never ran -- no statistics footer.
if sum(1 for l in ser.splitlines() if "ping statistics" in l) != 0:
    sys.exit("FAIL: ping statistics present (not a fast exit)")
print("offline A exits ok")
PY

vgate_assert B serial-contains 'net ip: ip=10.0.0.1'
vgate_assert B serial-contains 'ping: no route to 10.0.0.2'
vgate_assert B serial-contains 'echo noroute-ok'
vgate_assert B python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# Legacy -cE >= 1 (guarded) + zero statistics lines (fast exit).
if sum(1 for _ in re.finditer(r"PING\.BIN exited status=3([^0-9]|$)|exit=0x0000000000000003", ser)) < 1:
    sys.exit("FAIL: no PING.BIN exit-3")
if sum(1 for l in ser.splitlines() if "ping statistics" in l) != 0:
    sys.exit("FAIL: ping statistics present (not a fast exit)")
print("offline B exit ok")
PY

vgate_assert C serial-contains 'PING 10.0.0.2 (10.0.0.2): 56 data bytes'
vgate_assert C serial-contains '64 bytes from 10.0.0.2: icmp_seq=1'
vgate_assert C serial-contains 'ping statistics'
vgate_assert C serial-contains '0% packet loss'
vgate_assert C serial-contains 'fetch: connected'
vgate_assert C serial-contains 'HTTP/1.0 200 OK'
vgate_assert C serial-contains 'fetch: done'
vgate_assert C serial-contains 'echo online-ok'
vgate_assert C serial-absent 'offline'
vgate_assert C serial-absent 'no route'
vgate_assert C python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# Legacy -E pair: the exit-0 / exit-42 rows.
if not re.search(r"PING\.BIN exited status=0|PING\.BIN.*exit=0x0000000000000000", ser):
    sys.exit("FAIL: no PING.BIN exit-0 row")
if not re.search(r"FETCH\.BIN exited status=42|FETCH\.BIN.*exit=0x000000000000002a", ser):
    sys.exit("FAIL: no FETCH.BIN exit-42 row")
print("offline C control ok")
PY

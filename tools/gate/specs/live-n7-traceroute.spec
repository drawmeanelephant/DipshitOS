# live-n7-traceroute.spec -- TRACEROU.BIN (exec'd) traces the host
# peer in 1 hop from EL0 and exits 0.
# Mirrors tools/verify-live-n7-traceroute.sh (M26 N7, issue #434).
# One stale-legacy fix: the script execs TRACEROUTE.BIN, not the
# FAT-era 8.3 TRACEROU.BIN (the build product was renamed when exec
# moved to the host share; legacy is red-at-HEAD on the old name).
# The reap ERE is byte-identical to legacy (its TRACEROU.* prefix
# still matches the longer name).

vgate_name live-n7-traceroute "TRACEROU.BIN 1-hop trace from EL0 on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-1.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec TRACEROUTE.BIN
echo trace-launched
EOF

vgate_file script-2.txt <<'EOF'
procs
echo trace-ok
EOF

vgate_run 01 -- --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 --net-icmp-respond 10.0.0.2 --script '$RUN_DIR/script-1.txt' --script2 '$RUN_DIR/script-2.txt' --script2-after 'traceroute: complete' --script-expect 'tasks user-exec reaped' --timeout 60

vgate_assert 01 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert 01 serial-contains 'traceroute: starting'
vgate_assert 01 serial-contains 'traceroute to 10.0.0.2'
vgate_assert 01 serial-contains 'traceroute: reached 10.0.0.2 in 1 hop(s)'
vgate_assert 01 serial-contains 'traceroute: complete'
vgate_assert 01 serial-contains 'echo trace-ok'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# Legacy -E trio: ARP resolved either way, the hop-1 report row, and
# the exit-0 reap row.
if not re.search(r"net arp: (request for|resolved)", ser):
    sys.exit("FAIL: no ARP resolution line")
if not re.search(r"1\s+10\.0\.0\.2", ser):
    sys.exit("FAIL: no hop-1 row")
if not re.search(r"TRACEROU.*state=exited.*0|TRACEROU\s+exit=0x0000000000000000", ser):
    sys.exit("FAIL: no TRACEROU exit-0 row")
print("traceroute arp + hop + reap ok")
PY

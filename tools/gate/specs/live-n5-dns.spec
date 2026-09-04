# live-n5-dns.spec -- DNS.BIN (exec'd) resolves example.com through
# the host responder from EL0 and exits 0.
# Mirrors tools/verify-live-n5-dns.sh (M26 N5, issue #403).

vgate_name live-n5-dns "DNS.BIN resolution from EL0 on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-1.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec DNS.BIN example.com 10.0.0.2
echo dns-launched
EOF

vgate_file script-2.txt <<'EOF'
procs
echo dns-ok
EOF

vgate_run 01 -- --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 --net-dns-respond 10.0.0.2 --script '$RUN_DIR/script-1.txt' --script2 '$RUN_DIR/script-2.txt' --script2-after 'dns: status=ok' --script-expect 'tasks user-exec reaped' --timeout 60

vgate_assert 01 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert 01 serial-contains 'DNS query for example.com via 10.0.0.2:53'
vgate_assert 01 serial-contains 'Answer: example.com -> 93.184.216.34'
vgate_assert 01 serial-contains 'dns: status=ok'
vgate_assert 01 serial-contains 'echo dns-ok'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# Legacy -E pair: ARP resolved either way + the exit-0 reap row.
if not re.search(r"net arp: (request for|resolved)", ser):
    sys.exit("FAIL: no ARP resolution line")
if not re.search(r"DNS.BIN.*state=exited.*0|DNS.BIN\s+exit=0x0000000000000000", ser):
    sys.exit("FAIL: no DNS.BIN exit-0 row")
print("dns arp + reap ok")
PY

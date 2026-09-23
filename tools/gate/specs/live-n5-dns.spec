# live-n5-dns.spec -- GODNS.ELF (exec'd) resolves example.com through
# the host responder from EL0 and exits 0.
# M78a (#1682) retargets the existing RFC 1035/UDP behavior to Go.
# Mirrors tools/verify-live-n5-dns.sh (M26 N5, issue #403).
#
# HOST PREREQUISITE: bash tools/go/build-netdiag.sh -> .build/go/GODNS.ELF

vgate_name live-n5-dns "GODNS.ELF resolution from EL0 on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-1.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GODNS.ELF example.com 10.0.0.2
echo dns-launched
EOF

vgate_file script-2.txt <<'EOF'
procs
echo dns-ok
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GODNS.ELF")
if not os.path.exists(src):
    sys.exit("GODNS.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-netdiag.sh")
shutil.copy(src, os.path.join(share, "GODNS.ELF"))
print("staged GODNS.ELF (%d bytes)" % os.path.getsize(src))
PY

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
if not re.search(r"GODNS.ELF.*state=exited.*0|GODNS.ELF\s+exit=0x0000000000000000", ser):
    sys.exit("FAIL: no GODNS.ELF exit-0 row")
print("dns arp + reap ok")
PY

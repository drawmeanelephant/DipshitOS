# live-n7-traceroute.spec -- GOTRACEROUTE.ELF (exec'd) confirms the host
# peer answers ICMP echo from EL0. Current syscall has no TTL or time-exceeded
# response, so this proves direct-peer reachability, not route discovery.
# M78a (#1682) retargets this existing gate; no extra gate is needed.
#
# HOST PREREQUISITE: bash tools/go/build-netdiag.sh -> .build/go/GOTRACEROUTE.ELF

vgate_name live-n7-traceroute "GOTRACEROUTE.ELF direct-peer ICMP reachability from EL0 on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-1.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOTRACEROUTE.ELF
echo trace-launched
EOF

vgate_file script-2.txt <<'EOF'
procs
echo trace-ok
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOTRACEROUTE.ELF")
if not os.path.exists(src):
    sys.exit("GOTRACEROUTE.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-netdiag.sh")
shutil.copy(src, os.path.join(share, "GOTRACEROUTE.ELF"))
print("staged GOTRACEROUTE.ELF (%d bytes)" % os.path.getsize(src))
PY

vgate_run 01 -- --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 --net-icmp-respond 10.0.0.2 --script '$RUN_DIR/script-1.txt' --script2 '$RUN_DIR/script-2.txt' --script2-after 'traceroute: complete' --script-expect 'tasks user-exec reaped' --timeout 60

vgate_assert 01 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert 01 serial-contains 'traceroute: starting'
vgate_assert 01 serial-contains 'ICMP echo reachability probe to 10.0.0.2'
vgate_assert 01 serial-contains 'traceroute: peer responded 10.0.0.2 after 1 attempt(s)'
vgate_assert 01 serial-contains 'traceroute: complete'
vgate_assert 01 serial-contains 'echo trace-ok'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# ARP and lifecycle are preserved; the echo marker is direct-peer evidence,
# not TTL-based route discovery.
if not re.search(r"net arp: (request for|resolved)", ser):
    sys.exit("FAIL: no ARP resolution line")
if "traceroute: peer responded 10.0.0.2 after 1 attempt(s)" not in ser:
    sys.exit("FAIL: no direct-peer echo response marker")
if not re.search(r"GOTRACEROUTE.ELF.*state=exited.*0|GOTRACEROUTE.ELF\s+exit=0x0000000000000000", ser):
    sys.exit("FAIL: no GOTRACEROUTE.ELF exit-0 row")
print("traceroute arp + peer echo + reap ok")
PY

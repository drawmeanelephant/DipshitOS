# live-netstat.spec -- GONETSTAT.ELF dashboard sections live: iface,
# dhcp, tcp, udp, arp, counters. The --display/--screen pair rides
# along unasserted (manual-inspection capture, as in legacy).
# M78a (#1682) retargets the slot-62 window proof from its Zig original.
# Mirrors tools/verify-live-netstat.sh (M26 N2, issue #400).
#
# HOST PREREQUISITE: bash tools/go/build-netdiag.sh -> .build/go/GONETSTAT.ELF

vgate_name live-netstat "GONETSTAT.ELF dashboard sections on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
net ip 10.0.0.9
net arp 10.0.0.2
exec GONETSTAT.ELF
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GONETSTAT.ELF")
if not os.path.exists(src):
    sys.exit("GONETSTAT.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-netdiag.sh")
shutil.copy(src, os.path.join(share, "GONETSTAT.ELF"))
print("staged GONETSTAT.ELF (%d bytes)" % os.path.getsize(src))
PY

vgate_run 01 -- --display --screen '$RUN_DIR/netstat-screen' --script '$RUN_DIR/script.txt' --script-expect 'netstat: ready' --timeout 45

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'netstat: ready'
vgate_assert 01 serial-contains 'netstat: section iface'
vgate_assert 01 serial-contains 'netstat: section dhcp'
vgate_assert 01 serial-contains 'netstat: section tcp'
vgate_assert 01 serial-contains 'netstat: section udp'
vgate_assert 01 serial-contains 'netstat: section arp'
vgate_assert 01 serial-contains 'netstat: section counters'

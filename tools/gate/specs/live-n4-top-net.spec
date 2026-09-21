# live-n4-top-net.spec -- GOTOP.ELF opens on the network tab, refreshes
# from the syscall counters, and flips to procs (the sys_net_stats
# seam shows real calls). GOTOP's network tab is TOP.BIN's N4 view ported:
# interface/DHCP/TCP state plus the byte counters and a 1 Hz rate.
# Mirrors tools/verify-live-n4-top-net.sh (M26 N4, issue #402).

vgate_name live-n4-top-net "GOTOP.ELF network tab live on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-1.txt <<'EOF'
net ip 10.0.0.1
exec GOTOP.ELF
EOF

vgate_file script-2.txt <<'EOF'
procs
syscalls
echo done-top-net
EOF

# M71g (#1566): the chord trigger and the open-id assert moved from the literal
# `id=3` to `id=2`. TOP.BIN printed a HARDCODED `id=3` marker, so the old value
# was never the id the kernel handed out; GOTOP.ELF prints the real one, and
# this boot (no seat, no WM) MEASURED it as 2 (the seatless first window id —
# under a seat the same app gets 2 as the seat's first user window, 3 as its
# second).
#
# Tabs switch via input chords (the app is input-driven); the screen
# capture rides along unasserted-behaviorally (manual-inspection
# evidence, as in legacy) with a PNG-magic snapshot pin so the file
# survives into artifacts/.
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gotop.sh   ->  .build/go/GOTOP.ELF
vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "GOTOP.ELF")
if not os.path.exists(src):
    sys.exit("GOTOP.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-gotop.sh")
shutil.copy(src, os.path.join(share, "GOTOP.ELF"))
print("staged GOTOP.ELF into share (%d bytes)" % os.path.getsize(os.path.join(share, "GOTOP.ELF")))
PY

vgate_run 01 -- --display --input --screen '$RUN_DIR/gpu-screen' --net '$RUN_DIR/cap.bin' --script '$RUN_DIR/script-1.txt' --input-chords 'n,r,p' --input-chords-after 'top: open id=2' --script2 '$RUN_DIR/script-2.txt' --script2-after 'top: tab=procs' --script-expect 'done-top-net' --timeout 60

vgate_assert 01 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert 01 serial-contains 'top: open id=2'
vgate_assert 01 serial-contains 'top: tab=network'
vgate_assert 01 serial-contains 'top: refreshed ok'
vgate_assert 01 serial-contains 'top: tab=procs'
vgate_assert 01 serial-contains 'echo done-top-net'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
# Legacy -E: the sys_net_stats seam shows real calls (slot 62).
if not re.search(r"62 sys_net_stats calls=[1-9]", ser):
    sys.exit("FAIL: no counted sys_net_stats row")
print("top-net seam row ok")
PY
vgate_assert 01 snapshot 'gpu-screen-*' <<'PY'
import sys
data = open(sys.argv[1], 'rb').read()
assert data[:8] == b"\x89PNG\r\n\x1a\n" and len(data) > 8, "screen capture is not a non-empty PNG"
print("top-net screen evidence ok")
PY

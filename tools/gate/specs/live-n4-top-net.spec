# live-n4-top-net.spec -- TOP.BIN opens on the network tab, refreshes
# from the syscall counters, and flips to procs (the sys_net_stats
# seam shows real calls).
# Mirrors tools/verify-live-n4-top-net.sh (M26 N4, issue #402).

vgate_name live-n4-top-net "TOP.BIN network tab live on VZ"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-1.txt <<'EOF'
net ip 10.0.0.1
exec TOP.BIN
EOF

vgate_file script-2.txt <<'EOF'
procs
syscalls
echo done-top-net
EOF

# Tabs switch via input chords (the app is input-driven); the screen
# capture rides along unasserted-behaviorally (manual-inspection
# evidence, as in legacy) with a PNG-magic snapshot pin so the file
# survives into artifacts/.
vgate_run 01 -- --display --input --screen '$RUN_DIR/gpu-screen' --net '$RUN_DIR/cap.bin' --script '$RUN_DIR/script-1.txt' --input-chords 'n,r,p' --input-chords-after 'top: open id=3' --script2 '$RUN_DIR/script-2.txt' --script2-after 'top: tab=procs' --script-expect 'done-top-net' --timeout 60

vgate_assert 01 serial-contains 'net ip: ip=10.0.0.1'
vgate_assert 01 serial-contains 'top: open id=3'
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

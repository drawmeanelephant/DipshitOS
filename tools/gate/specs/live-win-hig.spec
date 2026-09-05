# live-win-hig.spec -- milestone eight card U5: window chrome visible and moves with focus

vgate_name live-win-hig "milestone eight card U5: window chrome visible and moves with focus"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script.txt <<'EOF'
exec WINLOOP.BIN
EOF

vgate_file script2.txt <<'EOF'
dui cycle
dui cycle
echo hig-serial-ok
EOF

vgate_run 01 -- --input --display --screen '$RUN_DIR/screen' --via-virtio --cvc-snap --snapshot-after "hig-serial-ok" --snapshot-out '$RUN_DIR/snap' --script '$RUN_DIR/script.txt' --script2 '$RUN_DIR/script2.txt' --script2-after "winloop: loop ok" --script-expect "hig-serial-ok" --timeout 60

vgate_assert 01 serial-contains 'dui: cycle focused=0'
vgate_assert 01 serial-contains 'dui: cycle focused=2'
vgate_assert 01 serial-contains 'winloop: present ok'
vgate_assert 01 serial-contains 'hig-serial-ok'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 snapshot 'snap-*.raw' <<'PY'
import sys
path = sys.argv[1]
data = open(path, 'rb').read()
assert len(data) == 1280 * 720 * 4, f"unexpected snapshot size {len(data)}"
w = 1280

def px(x, y):
    k = (y * w + x) * 4
    return (data[k+2], data[k+1], data[k]) # R, G, B

def near(c, t, tol):
    return all(abs(c[i] - t[i]) <= tol for i in range(3))

# Ring: theme accent 0x3b82f6 (59, 130, 246)
ring = near(px(65, 65), (59, 130, 246), 25)
# Edge: terminal corner should be terminal bg (16, 20, 24), definitely NOT the ring
edge = not near(px(1, 1), (59, 130, 246), 25)
# Title bar: user title bg 0x1a2b3c (26, 43, 60)
title = near(px(100, 72), (26, 43, 60), 22)

print(f"PIXEL ring={int(ring)} edge_not_ringed={int(edge)} title={int(title)}")
print(f"  ring sample {px(65,65)}  edge sample {px(1,1)}  title sample {px(100,72)}")
sys.exit(0 if (ring and edge and title) else 1)
PY


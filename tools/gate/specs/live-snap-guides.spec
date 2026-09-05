# live-snap-guides.spec -- M37 DQ5 window snap guides (issue #837)

vgate_name live-snap-guides "M37 DQ5 window snap guides"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_allow_rc A 0 1
vgate_allow_rc B 0 1
vgate_allow_rc C 0 1

vgate_file script-base.txt <<'EOF'
wnd start
exec NOTEPAD.BIN
EOF

vgate_file s2-A.txt <<'EOF'
dui
echo done-a
EOF

vgate_file s2-B.txt <<'EOF'
dui
echo done-b
EOF

vgate_file s2-C.txt <<'EOF'
echo done-c
EOF

# --- boot A: near-edge hold -> snap preview outline ---
vgate_run A -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-A' \
    --script '$RUN_DIR/script-base.txt' \
    --script2 '$RUN_DIR/s2-A.txt' --script2-after "wnd: snap-settled" --script2-delay 30 \
    --pointer-virtio "60,64,d;10,300" --pointer-virtio-after "notepad: ready" \
    --snapshot-after "wnd: snap-settled" \
    --script-expect "done-a" --timeout 240

vgate_assert A serial-contains "wnd: snap-preview zone=left x=0 y=0 w=640 h=700"
vgate_assert A serial-absent "[EXC] parking:"

vgate_assert A snapshot 'snap-A-*.raw' <<'PY'
import sys
path = sys.argv[1]
ACC = (0x3b, 0x82, 0xf6)
W, H = 1280, 720
data = open(path, "rb").read()
assert len(data) == W * H * 4, f"size {len(data)}"
def px(x, y):
    k = (y * W + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def check(x, y, want, label):
    got = px(x, y)
    assert got == want, f"{label}: GOT {got} WANT {want}"
def check_not(x, y, ban, label):
    got = px(x, y)
    assert got != ban, f"{label}: GOT banned {got}"

check(638, 100, ACC, "right edge upper")
check(639, 600, ACC, "right edge lower")
check(320, 0, ACC, "top edge")
check(100, 1, ACC, "top edge left")
check(320, 699, ACC, "bottom edge")
check(100, 698, ACC, "bottom edge left")
check(1, 400, ACC, "left edge")
check_not(320, 350, ACC, "interior clean (window content)")
check_not(700, 350, ACC, "outside zone clean (desktop)")
PY

vgate_assert A python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert not re.search(r'wnd: snap$', ser, re.M), "unexpected snap commit in boot A"
p = os.path.join(os.environ["VG_SHARE"], "WINDOWS.SAV")
if os.path.exists(p): os.remove(p)
PY

# --- boot B: release at edge -> snap commits ---
vgate_run B -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-base.txt' \
    --script2 '$RUN_DIR/s2-B.txt' --script2-after "wnd: drop" --script2-delay 8 \
    --pointer-virtio "60,64,d;10,300,u" --pointer-virtio-after "notepad: ready" \
    --script-expect "done-b" --timeout 240

vgate_assert B serial-contains "wnd: snap"
vgate_assert B serial-absent "[EXC] parking:"

vgate_assert B python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
lines = [l for l in ser.splitlines() if "user user rect=" in l]
assert len(lines) >= 1, "no user rect in boot B"
assert "rect=64,138,512," in lines[-1], f"expected rect=64,138,512, in {lines[-1]}"
p = os.path.join(os.environ["VG_SHARE"], "WINDOWS.SAV")
if os.path.exists(p): os.remove(p)
PY

# --- boot C: center hold -> no preview ---
vgate_run C -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-C' \
    --script '$RUN_DIR/script-base.txt' \
    --script2 '$RUN_DIR/s2-C.txt' --script2-after "wnd: drag" --script2-delay 20 \
    --pointer-virtio "60,64,d;500,300" --pointer-virtio-after "notepad: ready" \
    --snapshot-after "wnd: drag" \
    --script-expect "done-c" --timeout 240

vgate_assert C serial-absent "wnd: snap-preview"
vgate_assert C serial-absent "[EXC] parking:"

vgate_assert C snapshot 'snap-C-*.raw' <<'PY'
import sys
path = sys.argv[1]
ACC = (0x3b, 0x82, 0xf6)
W, H = 1280, 720
data = open(path, "rb").read()
assert len(data) == W * H * 4, f"size {len(data)}"
def px(x, y):
    k = (y * W + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def check_not(x, y, ban, label):
    got = px(x, y)
    assert got != ban, f"{label}: GOT banned {got}"

check_not(638, 100, ACC, "right edge clean")
check_not(320, 0, ACC, "top edge clean")
check_not(320, 699, ACC, "bottom edge clean")
PY

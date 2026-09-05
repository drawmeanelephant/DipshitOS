# live-wm4-paint.spec -- M32 WM4 (Lane 1, #707): WM rest policy blends unfocused, focused pure

vgate_name live-wm4-paint "M32 WM4: WM rest policy blends unfocused, focused pure"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-A.txt <<'EOF'
wnd start
exec NOTEPAD.BIN
exec CALC.BIN
EOF

vgate_file s2-A.txt <<'EOF'
dui move 2 700 200
dui
wm
echo wm4-a-go
EOF

vgate_file script-B.txt <<'EOF'
wnd start
exec NOTEPAD.BIN
EOF

vgate_file s2-B.txt <<'EOF'
dui
wm
echo wm4-b-go
EOF

vgate_run A -- --screen '$RUN_DIR/screen' --via-virtio --cvc-snap --snapshot-out '$RUN_DIR/snap-A' --script '$RUN_DIR/script-A.txt' --script2 '$RUN_DIR/s2-A.txt' --script2-after 'calc: ready' --script2-delay 20 --snapshot-after 'wm4-a-go' --script-expect 'wm4-a-go' --timeout 260

vgate_assert A serial-contains 'wnd: rest-alpha=240'
vgate_assert A python <<'PY'
import os, re
ser = open(os.environ["VG_SER"]).read()
assert re.search(r'wm: chrome window id=2 kind=0x[0-9a-f]+ rest=240', ser), "rest alpha id=2 check failed"
assert re.search(r'wm: chrome window id=3 kind=0x[0-9a-f]+ rest=240', ser), "rest alpha id=3 check failed"
PY
vgate_assert A snapshot 'snap-A-*.raw' <<'PY'
import sys, collections
data = open(sys.argv[1], "rb").read()
W, H = 1280, 720
assert len(data) == W * H * 4, f"size {len(data)}"
def px(x, y):
    k = (y * W + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def mode(grid):
    return collections.Counter(grid).most_common(1)[0]
notepad = [px(x, y) for y in range(290, 560, 5) for x in range(720, 1180, 5)]
(m_n, n_n) = mode(notepad)
calc = [px(x, y) for y in range(90, 460, 5) for x in range(70, 540, 5)]
(m_c, n_c) = mode(calc)
print(f"notepad_mode={m_n} calc_mode={m_c} calc_frac={n_c / len(calc):.2f}")
ok = m_n == (23, 31, 37) and m_c == (24, 32, 38) and n_c / len(calc) > 0.5
sys.exit(0 if ok else 1)
PY

vgate_run B -- --screen '$RUN_DIR/screen' --via-virtio --cvc-snap --snapshot-out '$RUN_DIR/snap-B' --script '$RUN_DIR/script-B.txt' --script2 '$RUN_DIR/s2-B.txt' --script2-after 'notepad: ready' --script2-delay 20 --snapshot-after 'wm4-b-go' --script-expect 'wm4-b-go' --timeout 260

vgate_assert B snapshot 'snap-B-*.raw' <<'PY'
import sys, collections
data = open(sys.argv[1], "rb").read()
W, H = 1280, 720
assert len(data) == W * H * 4, f"size {len(data)}"
def px(x, y):
    k = (y * W + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def mode(grid):
    return collections.Counter(grid).most_common(1)[0]
notepad = [px(x, y) for y in range(140, 410, 5) for x in range(84, 560, 5)]
(m_n, n_n) = mode(notepad)
print(f"notepad_mode_focused={m_n} frac={n_n / len(notepad):.2f}")
sys.exit(0 if m_n == (24, 32, 38) and n_n / len(notepad) > 0.5 else 1)
PY

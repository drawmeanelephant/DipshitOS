# live-tabstrip.spec -- M37 DQ2 tab-strip chrome (issue #840)

vgate_name live-tabstrip "M37 DQ2 tab-strip chrome: attached tabs paint visible strip"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-A.txt <<'EOF'
wnd start
exec NOTEPAD.BIN
exec TABHOLD.BIN
EOF

vgate_run A -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-A' \
    --script '$RUN_DIR/script-A.txt' \
    --snapshot-after "tabhold: cycled" \
    --script-expect "tabhold: done" --timeout 240

vgate_assert A serial-contains "wnd: tab-attach child=3 parent=2"
vgate_assert A serial-contains "tabhold: cycled"
vgate_assert A serial-absent "[EXC] parking:"

vgate_assert A snapshot 'snap-A-*.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
W, H = 1280, 720
assert len(data) == W * H * 4, f"snapshot size {len(data)}"
def px(x, y):
    k = (y * W + x) * 4
    return (data[k + 2], data[k + 1], data[k])
X, SY, SW = 56, 72, 512
TROUGH = (0x47, 0x55, 0x69)
CELLBG = (0x1a, 0x2b, 0x3c)
ACCENT = (0x3b, 0x82, 0xf6)
ok = True
divs = sum(1 for y in range(SY, SY + 22, 2) if px(X + 256, y) == TROUGH)
print(f"dividers={divs}")
ok &= divs >= 8
band = sum(1 for x in range(X + 4, X + SW, 4) if px(x, SY + 1) == CELLBG)
print(f"band={band}")
ok &= band >= (SW // 4) - 8
under = sum(1 for x in range(X + 4, X + 240, 2) if px(x, SY + 20) == ACCENT or px(x, SY + 21) == ACCENT)
print(f"underline={under}")
ok &= under >= 80
ink = sum(1 for x in range(X + 4, X + 220, 2) for y in range(SY + 3, SY + 19, 2)
          if px(x, y)[0] > 200 and px(x, y)[1] > 200 and px(x, y)[2] > 200)
print(f"ink={ink}")
ok &= ink >= 20
red = sum(1 for x in range(X + 244, X + 256) for y in range(SY + 7, SY + 18)
          if px(x, y)[0] > 170 and px(x, y)[1] < 120 and px(x, y)[2] < 120)
print(f"close_red={red}")
ok &= red >= 3
print("STRIP_OK" if ok else "STRIP_MISSING")
assert ok, "strip proof failed"
PY

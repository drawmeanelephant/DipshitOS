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

# vgate_assert A serial-contains "wnd: tab-attach child=3 parent=2"
# Census-tolerant form: the attach's child/parent ids depend on window-open
# order. Kernel ids are free-slot order from user_window_id_base=2, and
# NOTEPAD's M42 SX4 open waits on a host theme-sync round trip before
# win_open — so TABHOLD's instant open can land id 2 with NOTEPAD id 3
# (the regression that redded this gate) or the legacy order. WND prints
# `wnd: tab-attach` ONLY on a successful attach, so its existence with
# child != parent is the proof: TABHOLD attached to NOTEPAD, never itself.
vgate_assert A python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"]).read()
m = re.search(r'(?m)^wnd: tab-attach child=(\d+) parent=(\d+)', ser)
if not m:
    print("tab-attach line missing", file=sys.stderr)
    sys.exit(1)
a, b = int(m.group(1)), int(m.group(2))
# The burst census is exactly {2,3}: NOTEPAD + TABHOLD are the only window
# openers (WND opens none), so a valid attach is child!=parent within it.
if not (2 <= a <= 3 and 2 <= b <= 3 and a != b):
    print(f"attach ids not the two-window census: child={a} parent={b}", file=sys.stderr)
    sys.exit(1)
print(f"attach-ok child={a} parent={b}")
PY
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

# live-tabstrip.spec -- M37 DQ2 tab-strip chrome (issue #840)
#
# M71g (#1566): the tab HOST here is GOTOP.ELF (Go, the successor to Zig
# TOP.BIN) —
# the spec's subject is the kernel/WM tab-strip CHROME, which is app-agnostic,
# and under a WM seat the Go client is not a usable host: with NOTE.ELF as the
# tab host the scanout carried NO chrome at all (observed: zero (71,85,105)
# border/trough pixels anywhere), which is undiagnosed — the client's surface
# ends up full-viewport under the WM seat, but that is a hypothesis, not a
# finding. GOTOP.ELF is a tab-aware app that declares TOP's own rect, and
# TABHOLD attaches to it the same way it attached to the notepad (`own_id==2 -> 3`).
#
# GEOMETRY (M66c review, #1495): the pixel scan below is derived from the
# HOST's declaration, and GOTOP declares 40,40 512x384 (user/go/top/main.go),
# not the retired app's 56,56. The first version of this retarget kept X,SY=56,72,
# which put nearly every sample outside TOP's strip — the scan has to follow
# the rect: strip = (host_x .. host_x+host_w), y = host_y + title_bar_h ..
# +tab_bar_height (kernel/src/wnd_core.zig: title_bar_h 16, tab_bar_height 22).

vgate_name live-tabstrip "M37 DQ2 tab-strip chrome: attached tabs paint visible strip"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

# M71g (#1566): the two openers are SPLIT across script stages. Measured on
# the first retarget attempt: as one burst, TABHOLD.BIN (Zig, opens in
# milliseconds) reached the kernel's tab-attach BEFORE the Go client's window
# existed — `wnd: tab-attach child=2 parent=3` landed ahead of
# `open: id=3 owner=2` — and the container then composited nothing at all (the
# frame carried the desktop fill and no client pixels anywhere). Exec'ing
# TABHOLD only after the client's own `top: ready` puts the attach after the
# container exists, which is the order these coordinates were derived from.
vgate_file script-A.txt <<'EOF'
wnd start
exec GOTOP.ELF
EOF

vgate_file script2-A.txt <<'EOF'
exec TABHOLD.BIN
EOF

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

vgate_run A -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-A' \
    --script '$RUN_DIR/script-A.txt' \
    --script2 '$RUN_DIR/script2-A.txt' --script2-after "top: ready" \
    --snapshot-after "tabhold: cycled" \
    --script-expect "tabhold: done" --timeout 240

# vgate_assert A serial-contains "wnd: tab-attach child=3 parent=2"
# Census-tolerant form: the attach's child/parent ids depend on window-open
# order. Kernel ids are free-slot order from user_window_id_base=2, and the
# retired Zig notepad's M42 SX4 open waited on a host theme-sync round trip
# before win_open — that regression could land TABHOLD at id 2 with the text
# client at id 3. Under NOTE.ELF either order is still possible, so the check
# stays census-based: WND prints `wnd: tab-attach` ONLY on a successful
# attach, so its existence with child != parent is the proof: TABHOLD
# attached to the text client, never itself.
vgate_assert A python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"]).read()
m = re.search(r'(?m)^wnd: tab-attach child=(\d+) parent=(\d+)', ser)
if not m:
    print("tab-attach line missing", file=sys.stderr)
    sys.exit(1)
a, b = int(m.group(1)), int(m.group(2))
# The burst census is exactly {2,3}: GOTOP.ELF + TABHOLD are the only window
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
X, SY, SW = 40, 56, 512
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

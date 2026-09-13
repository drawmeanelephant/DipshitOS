# live-doc-tables.spec -- M-web S2: DOC.BIN tables/dl/h4 on-screen (issue #1203)
#
# Dedicated short fixture (oliver's table sits below the fold). One exec per
# boot; settle on a marker the PROGRAM prints.

vgate_name live-doc-tables "M-web S2: DOC.BIN tables and definition lists"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_setup_python <<'PY'
import os, shutil
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
shutil.copy("zig-out/bin/DOC.BIN", share)
shutil.copy("tests/oliver-spike/tables.html", os.path.join(share, "TABLES.HTML"))
PY

vgate_file script-01.txt <<'EOF'
exec DOC.BIN /host/TABLES.HTML
EOF

vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-01' \
    --script '$RUN_DIR/script-01.txt' \
    --snapshot-after "doc: settled" \
    --script-expect "doc: settled" --timeout 120

vgate_assert 01 serial-contains 'doc: open id='
vgate_assert 01 serial-contains 'doc: parse nodes='
vgate_assert 01 serial-contains 'doc: layout blocks='
vgate_assert 01 serial-contains 'doc: probe2 table='
vgate_assert 01 serial-contains 'doc: settled'
vgate_assert 01 serial-contains 'typography: Inter TrueType font loaded'
vgate_assert 01 serial-absent 'doc: error'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 snapshot 'snap-01-*.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
w = 1280
def px(x, y):
    k = (y * w + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def near(c, want, tol=6):
    return all(abs(a - b) <= tol for a, b in zip(c, want))
def ink(c):
    return c[0] > 200 and c[1] > 200 and c[2] > 200
# Native window 40,28 512x384. tables.html is short so the 2x2 table, header
# rule, and dl sit in the client. Equal-width cols split the 492 px content
# box at x=256 inside the window (screen 296).
X, Y, W, H = 40, 28, 512, 384
BG = (0x18, 0x20, 0x26)
SURFACE = (0x22, 0x2d, 0x35)
BORDER = (0x33, 0x41, 0x55)
fails = []
bg = sum(1 for yy in range(Y + 20, Y + H - 20, 2)
         for xx in range(X + 8, X + W - 8, 4)
         if near(px(xx, yy), BG))
if bg < 80:
    fails.append(f"page bg {bg}")
h4 = sum(1 for yy in range(Y + 18, Y + 70)
         for xx in range(X + 10, X + 360)
         if ink(px(xx, yy)))
if h4 < 12:
    fails.append(f"h4 ink {h4}")
# th cells fill theme_surface; the header row sits under the h4.
surf = sum(1 for yy in range(Y + 70, Y + 160, 1)
           for xx in range(X + 10, X + W - 10, 2)
           if near(px(xx, yy), SURFACE, 16))
if surf < 40:
    fails.append(f"th surface {surf}")
left = sum(1 for yy in range(Y + 70, Y + 170, 1)
           for xx in range(X + 14, X + 200)
           if ink(px(xx, yy)))
right = sum(1 for yy in range(Y + 70, Y + 170, 1)
            for xx in range(X + 256, X + 480)
            if ink(px(xx, yy)))
if left < 8:
    fails.append(f"left col ink {left}")
if right < 8:
    fails.append(f"right col ink {right}")
rule = sum(1 for yy in range(Y + 80, Y + 160)
           for xx in range(X + 12, X + W - 12, 2)
           if near(px(xx, yy), BORDER, 12))
if rule < 8:
    fails.append(f"header rule {rule}")
# dd is indented 16 px vs dt. dt "term" sits near the left margin around
# layout y=113 (screen ~157); dd follows at y=133 (screen ~177).
dt_ink = sum(1 for yy in range(Y + 118, Y + 160)
             for xx in range(X + 8, X + 80)
             if ink(px(xx, yy)))
dd_ink = sum(1 for yy in range(Y + 148, Y + 230)
             for xx in range(X + 28, X + 360)
             if ink(px(xx, yy)))
if dt_ink < 2:
    fails.append(f"dt ink {dt_ink}")
if dd_ink < 8:
    fails.append(f"dd ink {dd_ink}")
assert not fails, "DOC-TABLES-FAILS: " + "; ".join(fails)
print("live-doc-tables 01 pixels ok")
PY

# live-doc.spec -- M-web S1: DOC.BIN renders oliver HTML in-guest (issue #1202)
#
# One invocation per boot (the #1197 lesson). Each boot ends on a marker the
# PROGRAM prints (`doc: settled`), never on a script echo.

vgate_name live-doc "M-web S1: DOC.BIN renders oliver HTML in-guest"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_setup_python <<'PY'
import os, shutil
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
shutil.copy("zig-out/bin/DOC.BIN", share)
shutil.copy("tests/oliver-spike/expect.html", os.path.join(share, "PAGE.HTML"))
open(os.path.join(share, "BROKEN.HTML"), "w").write("<p>ok <<<< <em>unclosed\n")
PY

vgate_file script-01.txt <<'EOF'
exec DOC.BIN /host/PAGE.HTML
EOF

vgate_file script-02.txt <<'EOF'
exec DOC.BIN /host/NOPE.HTML
EOF

vgate_file script-03.txt <<'EOF'
exec DOC.BIN /host/BROKEN.HTML
EOF

# --- boot 01: pinned oliver fixture, serial markers + pixel probes ---
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
vgate_assert 01 serial-contains 'doc: probe h1='
vgate_assert 01 serial-contains 'doc: settled'
vgate_assert 01 serial-contains 'typography: Inter TrueType font loaded'
vgate_assert 01 serial-contains 'typography: Fira Code TrueType font loaded'
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
# Native window 40,28 512x384. Quote/pre/hr of the oliver fixture sit below
# the fold (~352 px client); on-screen stand-ins are h1 ink, <em>/<a> accent,
# and inline <code> surface. Serial `doc: probe` lines pin the off-screen y.
X, Y, W, H = 40, 28, 512, 384
BG = (0x18, 0x20, 0x26)
ACCENT = (0x3b, 0x82, 0xf6)
SURFACE = (0x22, 0x2d, 0x35)
fails = []
bg = sum(1 for yy in range(Y + 20, Y + H - 20, 2)
         for xx in range(X + 8, X + W - 8, 4)
         if near(px(xx, yy), BG))
if bg < 200:
    fails.append(f"page bg {bg}")
ink = sum(1 for yy in range(Y + 18, Y + 80)
          for xx in range(X + 10, X + 360)
          if px(xx, yy)[0] > 200 and px(xx, yy)[1] > 200 and px(xx, yy)[2] > 200)
if ink < 20:
    fails.append(f"h1 ink {ink}")
accent = sum(1 for yy in range(Y + 50, Y + H - 24, 2)
             for xx in range(X + 8, X + W - 8, 2)
             if near(px(xx, yy), ACCENT, 24))
if accent < 8:
    fails.append(f"em/link accent {accent}")
surf = sum(1 for yy in range(Y + 50, Y + H - 24, 2)
           for xx in range(X + 8, X + W - 8, 2)
           if near(px(xx, yy), SURFACE, 16))
if surf < 8:
    fails.append(f"code surface {surf}")
assert not fails, "DOC-FAILS: " + "; ".join(fails)
print("live-doc 01 pixels ok")
PY

# --- boot 02: missing file — on-screen error, window stays, settled ---
vgate_run 02 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-02.txt' \
    --script-expect "doc: settled" --timeout 90

vgate_assert 02 serial-contains 'doc: open id='
vgate_assert 02 serial-contains 'doc: error missing'
vgate_assert 02 serial-contains 'doc: settled'
vgate_assert 02 serial-absent '[EXC] parking:'

# --- boot 03: truncated/corrupt page still settles ---
vgate_run 03 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-03.txt' \
    --script-expect "doc: settled" --timeout 90

vgate_assert 03 serial-contains 'doc: open id='
vgate_assert 03 serial-contains 'doc: parse nodes='
vgate_assert 03 serial-contains 'doc: settled'
vgate_assert 03 serial-absent '[EXC] parking:'

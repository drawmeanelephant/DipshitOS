# live-doc-web.spec -- M-web S3–S6: img, click-nav, fetch, publish (issues #1204–#1207)
#
# One spec, four boots (one exec each). S1/S2 stay live-doc / live-doc-tables.

vgate_name live-doc-web "M-web S3–S6: img, nav, fetch, publish"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_setup_python <<'PY'
import os, struct, shutil, subprocess, filecmp
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
shutil.copy("zig-out/bin/DOC.BIN", share)
shutil.copy("tests/oliver-spike/img.html", os.path.join(share, "IMG.HTML"))
shutil.copy("tests/oliver-spike/nav.html", os.path.join(share, "NAV.HTML"))
shutil.copy("tests/oliver-spike/next.html", os.path.join(share, "NEXT.HTML"))

def write_qoi(path, w, h, rgb):
    buf = bytearray(b"qoif")
    buf += struct.pack(">II", w, h)
    buf += bytes([3, 0])
    pix = bytes([0xFE, rgb[0], rgb[1], rgb[2]])
    buf += pix * (w * h)
    buf += bytes([0, 0, 0, 0, 0, 0, 0, 1])
    open(path, "wb").write(buf)

write_qoi(os.path.join(share, "DOT.QOI"), 16, 16, (0xEF, 0x44, 0x44))

pub = os.path.join(rd, "publish")
subprocess.check_call(["bash", "tools/oliver-publish.sh", "tests/oliver-spike", pub])
for name in ("PAGE.HTML", "MANIFEST.TXT", "index.html", "md-fixture.html"):
    src = os.path.join(pub, name)
    if os.path.isfile(src):
        shutil.copy(src, os.path.join(share, name))
assert filecmp.cmp(os.path.join(share, "PAGE.HTML"), "tests/oliver-spike/expect.html", shallow=False)
open(os.path.join(rd, "publish-ok.txt"), "w").write("ok\n")
print("live-doc-web setup: qoi + publish ok")
PY

vgate_file script-img.txt <<'EOF'
exec DOC.BIN /host/IMG.HTML
EOF

vgate_file script-nav.txt <<'EOF'
exec DOC.BIN /host/NAV.HTML
EOF

vgate_file script-fetch.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec DOC.BIN http://10.0.0.2/
EOF

vgate_file script-pub.txt <<'EOF'
exec DOC.BIN /host/PAGE.HTML
EOF

# --- boot 01: S3 <img> QOI blit + missing-src placeholder ---
vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-01' \
    --script '$RUN_DIR/script-img.txt' \
    --snapshot-after "doc: settled" \
    --script-expect "doc: settled" --timeout 120

vgate_assert 01 serial-contains 'doc: open id='
vgate_assert 01 serial-contains 'doc: img'
vgate_assert 01 serial-contains 'doc: settled'
vgate_assert 01 serial-absent 'doc: error'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 snapshot 'snap-01-*.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
w = 1280
def px(x, y):
    k = (y * w + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def near(c, want, tol=10):
    return all(abs(a - b) <= tol for a, b in zip(c, want))
X, Y, W, H = 40, 28, 512, 384
RED = (0xEF, 0x44, 0x44)
SURFACE = (0x22, 0x2d, 0x35)
fails = []
red = sum(1 for yy in range(Y + 40, Y + 160)
          for xx in range(X + 10, X + 140)
          if near(px(xx, yy), RED, 24))
if red < 20:
    fails.append(f"qoi red {red}")
surf = sum(1 for yy in range(Y + 80, Y + 280, 2)
           for xx in range(X + 10, X + 200, 2)
           if near(px(xx, yy), SURFACE, 16))
if surf < 20:
    fails.append(f"img placeholder {surf}")
assert not fails, "DOC-IMG-FAILS: " + "; ".join(fails)
print("live-doc-web 01 img pixels ok")
PY

# --- boot 02: S4 click a local link ---
vgate_run 02 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-02' \
    --script '$RUN_DIR/script-nav.txt' \
    --pointer-virtio "64,58,c" --pointer-virtio-after "doc: settled" \
    --snapshot-after "doc: navigated" \
    --script-expect "doc: navigated" --timeout 120

vgate_assert 02 serial-contains 'doc: settled'
vgate_assert 02 serial-contains 'doc: nav /host/NEXT.HTML'
vgate_assert 02 serial-contains 'doc: navigated'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 snapshot 'snap-02-*.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
w = 1280
def px(x, y):
    k = (y * w + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def ink(c):
    return c[0] > 200 and c[1] > 200 and c[2] > 200
X, Y = 40, 28
n = sum(1 for yy in range(Y + 18, Y + 90)
        for xx in range(X + 10, X + 360)
        if ink(px(xx, yy)))
assert n >= 12, f"next-page h1 ink {n}"
print("live-doc-web 02 nav pixels ok")
PY

# --- boot 03: S5 fetch over the host TCP responder (no public internet) ---
vgate_run 03 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-03' \
    --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 --net-tcp-respond 10.0.0.2:80 \
    --script '$RUN_DIR/script-fetch.txt' \
    --snapshot-after "doc: settled" \
    --script-expect "doc: settled" --timeout 120

vgate_assert 03 serial-contains 'doc: fetch status=200'
vgate_assert 03 serial-contains 'doc: settled'
vgate_assert 03 serial-absent 'doc: error'
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 output-contains "NET-TCP: answered the guest's HTTP request with 200 OK"
vgate_assert 03 snapshot 'snap-03-*.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
w = 1280
def px(x, y):
    k = (y * w + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def ink(c):
    return c[0] > 200 and c[1] > 200 and c[2] > 200
X, Y = 40, 28
n = sum(1 for yy in range(Y + 16, Y + 120)
        for xx in range(X + 8, X + 480)
        if ink(px(xx, yy)))
assert n >= 10, f"fetched body ink {n}"
print("live-doc-web 03 fetch pixels ok")
PY

# --- boot 04: S6 host publish tree, DOC views the pinned oliver bytes ---
vgate_run 04 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-04' \
    --script '$RUN_DIR/script-pub.txt' \
    --snapshot-after "doc: settled" \
    --script-expect "doc: settled" --timeout 120

vgate_assert 04 serial-contains 'doc: parse nodes='
vgate_assert 04 serial-contains 'doc: probe h1='
vgate_assert 04 serial-contains 'doc: settled'
vgate_assert 04 serial-absent 'doc: error'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 snapshot 'snap-04-*.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
w = 1280
def px(x, y):
    k = (y * w + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def ink(c):
    return c[0] > 200 and c[1] > 200 and c[2] > 200
X, Y = 40, 28
n = sum(1 for yy in range(Y + 18, Y + 80)
        for xx in range(X + 10, X + 360)
        if ink(px(xx, yy)))
assert n >= 20, f"published h1 ink {n}"
print("live-doc-web 04 publish pixels ok")
PY

# live-web.spec -- WEB.ELF: the in-guest Go browser (Go app shell + the
# project's own Go HTML renderer, virelai/webrender).
#
# Four boots, one exec each, each ending on a marker the PROGRAM prints
# (never a script echo):
#   01 local page renders (parse/layout markers + scanout pixel probes)
#   02 a pointer click on an in-page link navigates (history + second page)
#   03 http:// fetch over the host TCP responder (no public internet)
#   04 a missing target renders a distinct error page and still settles
#
# HOST PREREQUISITE (fails honestly when missing): .build/go/WEB.ELF must
# exist -- `bash tools/go/build-web.sh browser WEB`.

vgate_name live-web "WEB.ELF: the in-guest Go browser renders, navigates, fetches, and reports errors"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-local.txt <<'EOF'
exec WEB.ELF /host/PAGE.HTML
EOF

vgate_file script-nav.txt <<'EOF'
exec WEB.ELF /host/PAGE.HTML
EOF

vgate_file script-fetch.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec WEB.ELF http://10.0.0.2/
EOF

vgate_file script-missing.txt <<'EOF'
exec WEB.ELF /host/NOPE.HTML
EOF

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "WEB.ELF")
if not os.path.exists(src):
    sys.exit("WEB.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-web.sh browser WEB")
shutil.copy(src, os.path.join(share, "WEB.ELF"))
for src_name, dst_name in (("gate-page.html", "PAGE.HTML"), ("gate-next.html", "NEXT.HTML")):
    shutil.copy(os.path.join("user", "go", "browser", "testdata", src_name),
                os.path.join(share, dst_name))
print("staged WEB.ELF (%d bytes) + PAGE.HTML/NEXT.HTML" %
      os.path.getsize(os.path.join(share, "WEB.ELF")))
PY

# --- boot 01: a local page renders (markers + pixels) --------------------
vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-01' \
    --script '$RUN_DIR/script-local.txt' \
    --snapshot-after "web: settled" \
    --snapshot-after "web: repaint" \
    --script-expect "web: ready" --timeout 120

vgate_assert 01 serial-contains 'web: open id='
vgate_assert 01 serial-contains 'web: parse nodes='
vgate_assert 01 serial-contains 'web: layout blocks='
vgate_assert 01 serial-contains 'web: url /host/PAGE.HTML'
vgate_assert 01 serial-contains 'web: paint items='
vgate_assert 01 serial-contains 'web: settled'
vgate_assert 01 serial-contains 'web: repaint items='
vgate_assert 01 serial-contains 'web: ready'
vgate_assert 01 serial-absent 'web: error'
vgate_assert 01 serial-absent '[EXC] parking:'
vgate_assert 01 snapshot 'snap-01-*.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
w = 1280
X, Y = 40, 28          # the browser window origin on the scanout
def px(x, y):
    k = (y * w + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def near(c, want, tol=6):
    return all(abs(a - b) <= tol for a, b in zip(c, want))
PAGE_BG = (0x18, 0x20, 0x26)
INK = (0xe6, 0xed, 0xf3)
ACCENT = (0x3b, 0x82, 0xf6)
SURFACE = (0x22, 0x2d, 0x35)
CHROME = (0x11, 0x17, 0x1c)
fails = []
content = [(xx, yy) for yy in range(Y + 52, Y + 368, 2) for xx in range(X + 10, X + 500, 3)]
bg = sum(1 for xx, yy in content if near(px(xx, yy), PAGE_BG))
if bg < 3000:
    fails.append(f"page bg {bg}")
ink = sum(1 for xx, yy in content if near(px(xx, yy), INK, 2))
if ink < 200:
    fails.append(f"text ink {ink}")
accent = sum(1 for xx, yy in content if near(px(xx, yy), ACCENT, 8))
if accent < 20:
    fails.append(f"link accent {accent}")
surf = sum(1 for xx, yy in content if near(px(xx, yy), SURFACE, 6))
if surf < 100:
    fails.append(f"pre surface {surf}")
chrome = sum(1 for yy in range(Y + 18, Y + 30) for xx in range(X + 6, X + 500, 4)
             if near(px(xx, yy), CHROME))
if chrome < 100:
    fails.append(f"chrome band {chrome}")
assert not fails, "WEB-FAILS: " + "; ".join(fails)
print("live-web 01 pixels ok")
PY

# --- boot 02: a pointer click on the in-page link replaces the page ------
vgate_run 02 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-02' \
    --script '$RUN_DIR/script-nav.txt' \
    --pointer-virtio "53,82,c" --pointer-virtio-after "web: settled" \
    --snapshot-after "web: settled" \
    --snapshot-after "web: navigated" \
    --script-expect "web: nav-ready" --timeout 120

vgate_assert 02 serial-contains 'web: settled'
vgate_assert 02 serial-contains 'web: ev kind=3'
vgate_assert 02 serial-contains 'web: nav /host/NEXT.HTML'
vgate_assert 02 serial-contains 'web: navigated'
vgate_assert 02 serial-contains 'web: nav-ready'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 snapshot 'snap-02-*.raw' <<'SNAPEOF'
import sys
data = open(sys.argv[1], "rb").read()
w = 1280
X, Y = 40, 28
def px(x, y):
    k = (y * w + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def ink(c):
    return c[0] > 200 and c[1] > 200 and c[2] > 200
SURFACE = (0x22, 0x2d, 0x35)
# NEXT.HTML is a heading plus one short paragraph: it must show ink near the
# top of the content box ...
n = sum(1 for yy in range(Y + 52, Y + 110)
        for xx in range(X + 10, X + 300)
        if ink(px(xx, yy)))
# ... and it must NOT still show PAGE.HTML's monospace block, whose surface
# fill is the discriminator between "navigated" and "old page still on screen".
surf = sum(1 for yy in range(Y + 52, Y + 372, 2)
           for xx in range(X + 10, X + 500, 3)
           if all(abs(a - b) <= 6 for a, b in zip(px(xx, yy), SURFACE)))
fails = []
if n < 20:
    fails.append(f"next-page ink {n}")
if surf != 0:
    fails.append(f"old page's pre block still visible ({surf} surface px)")
assert not fails, "WEB-NAV-FAILS: " + "; ".join(fails)
print(f"live-web 02 nav pixels ok (ink={n}, stale surface={surf})")
SNAPEOF

# --- boot 03: HTTP fetch over the host TCP responder --------------------
vgate_run 03 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-03' \
    --net '$RUN_DIR/cap.bin' --net-arp-respond 10.0.0.2 --net-tcp-respond 10.0.0.2:80 \
    --script '$RUN_DIR/script-fetch.txt' \
    --snapshot-after "web: settled" \
    --snapshot-after "web: repaint" \
    --script-expect "web: ready" --timeout 120

vgate_assert 03 serial-contains 'web: url http://10.0.0.2/'
vgate_assert 03 serial-contains 'web: parse nodes='
vgate_assert 03 serial-contains 'web: paint items='
vgate_assert 03 serial-contains 'web: settled'
vgate_assert 03 serial-contains 'web: repaint items='
vgate_assert 03 serial-contains 'web: ready'
vgate_assert 03 serial-absent 'web: error'
vgate_assert 03 serial-absent 'web: poll err='
vgate_assert 03 serial-absent '[EXC] parking:'
vgate_assert 03 output-contains "NET-TCP: answered the guest's HTTP request with 200 OK"
vgate_assert 03 snapshot 'snap-03-*.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
w = 1280
X, Y = 40, 28
def px(x, y):
    k = (y * w + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def ink(c):
    return c[0] > 200 and c[1] > 200 and c[2] > 200
n = sum(1 for yy in range(Y + 52, Y + 130)
        for xx in range(X + 10, X + 400)
        if ink(px(xx, yy)))
assert n >= 40, f"fetched body ink {n}"
print("live-web 03 fetch pixels ok")
PY

# --- boot 04: a missing target renders an error page, still settles -----
vgate_run 04 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-04' \
    --script '$RUN_DIR/script-missing.txt' \
    --snapshot-after "web: settled" \
    --snapshot-after "web: repaint" \
    --script-expect "web: ready" --timeout 120

vgate_assert 04 serial-contains 'web: open id='
vgate_assert 04 serial-contains 'web: error file'
vgate_assert 04 serial-contains 'web: settled'
vgate_assert 04 serial-contains 'web: repaint items='
vgate_assert 04 serial-contains 'web: ready'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 snapshot 'snap-04-*.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
w = 1280
X, Y = 40, 28
def px(x, y):
    k = (y * w + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def ink(c):
    return c[0] > 200 and c[1] > 200 and c[2] > 200
n = sum(1 for yy in range(Y + 52, Y + 130)
        for xx in range(X + 10, X + 380)
        if ink(px(xx, yy)))
assert n >= 20, f"error page ink {n}"
print("live-web 04 error pixels ok")
PY

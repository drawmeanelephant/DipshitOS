# live-web.spec -- WEB.ELF: the in-guest Go browser (Go app shell + the
# project's own Go HTML renderer, virelai/webrender), plus M67b (#1447)
# GOFETCH.ELF HTTPS in-process (vi.Dial + tls.Dial, ADR 0029).
#
# Boots, one exec each, each ending on a marker the PROGRAM prints
# (never a script echo), plus boot 13 which holds the VM for the M69b
# console-ink re-measure (#1592):
#   01 local page renders (parse/layout markers + scanout pixel probes)
#   02 a pointer click on an in-page link navigates (history + second page)
#   03 http:// fetch over the host TCP responder (no public internet)
#   04 a missing target renders a distinct error page and still settles
#   05 WEB.ELF https to the cleartext :80 responder fails closed (TLS
#      handshake, never a GET; no silent downgrade)
#   12 GOFETCH.ELF https in-process against the runner TLS responder
#      (IP/port/SNI = 10.0.0.2:24533 leaf.example.com). FETCHS.BIN is not
#      exec'd. This boot INHERITS the live-tls13 probe, retired in M71k
#      (#1570): same responder script, same port, same fixture identity.
#      The retired spec grew the probe from "GOFETCH works" to "a guest
#      process reached a real TLS 1.3 peer"; here that is the same act.
#      It also asserted the negotiated suite as a serial marker. On the Go
#      path that is enforced in code rather than echoed: user/go/tls
#      offers exactly one suite (client.go `suiteOffered = 0x1301`) and
#      rejects any other ServerHello choice (client.go:574), pinned by
#      client_test.go -- so a green `gofetch: handshake ok` cannot hide a
#      different suite. No new marker is owed.
#   13 M69b (#1529) claimed kernel console ink in the uncovered scanout
#      of THIS boot (~2.8% at 3 s, ~5.8% at 20 s). M71b measured the
#      default-seat GOSH boot and did not reproduce. Re-measured here
#      (shim; GOTABWM.ELF is not staged): ~5.8% console-green at +3 s
#      and +20 s after web: settled. Two host delays fire kind-4
#      snapshots; the sampler pins that shim band. Seated = go-wm-console-ink.
#
#  14 M71i (#1568) INHERITS the M70d (#1456) fidelity-corpus rung from the
#      retired live-doc-web boot 05: CERN's first-website hub, the corpus's
#      own pinned bytes, laid out from the UA table. No new renderer
#      capability -- the point is that the rung survives its consumer.
#
# M71i (#1568): DOC.BIN and its three specs (live-doc, live-doc-tables,
# live-doc-web) are RETIRED into WEB.ELF, because two HTML painters is the
# dual toolkit ADR 0030 forbids. Nothing was dropped silently: every rung
# those specs pinned is pinned here or in live-web-ttf, by the probe named
# below. Rows marked "vacant at HEAD" are the ones the retired specs held
# alone, so this card is where they move.
#   S1 page render + pixels       boot 01 here; live-web-ttf boot 01
#   S1 typography / faces         live-web-ttf 01 (real faces) vs 03 (grid)
#   S1 missing / malformed page   boot 04 + boot 06/07 here (missing, dns,url)
#   S2 tables + header rule       live-web-ttf boot 02
#   S2 dl/dt/dd                   live-web-ttf boot 04 (vacant at HEAD)
#   S3 <img> decode               live-web-ttf boot 02 (SWATCH quadrants)
#   S3 missing-src placeholder    live-web-ttf boot 04 (vacant at HEAD)
#   S4 click-nav                  boot 02 here
#   S5 http fetch                 boot 03 here
#   S6 oliver-publish page        boot 01 here + go-dogfood boot 02
#   corpus (M70d #1456)           boot 14 here
#
# HOST PREREQUISITE (fails honestly when missing):
#   .build/go/WEB.ELF     -- `bash tools/go/build-web.sh browser WEB`
#   .build/go/GOFETCH.ELF -- `bash tools/go/build-web.sh fetch GOFETCH`

vgate_name live-web "WEB.ELF: the in-guest Go browser renders, navigates, fetches, and reports errors; GOFETCH.ELF https in-process"
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

vgate_file script-https.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec WEB.ELF https://10.0.0.2:80/
EOF

vgate_file script-dns.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec WEB.ELF http://example.com/
EOF

vgate_file script-badurl.txt <<'EOF'
exec WEB.ELF http://
EOF

vgate_file script-hostile.txt <<'EOF'
exec WEB.ELF /host/HOSTILE.HTML
EOF

vgate_file script-store.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec WEB.ELF http://10.0.0.2/
EOF

vgate_file script-offline.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec WEB.ELF http://10.0.0.2/
EOF

vgate_file script-slow.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec WEB.ELF http://10.0.0.2/
EOF

vgate_file script-gofetch.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec GOFETCH.ELF https://10.0.0.2:24533/
EOF

vgate_file script-corpus.txt <<'EOF'
exec WEB.ELF /host/CORPUS.HTML
EOF

vgate_setup_python <<'PY'
# Boot 08 needs a peer that ACCEPTS the connection and never answers: the
# browser must sit in its waiting state so the injected cancel key has a load
# to cancel. A plain silent listener on the host, reached through the runner's
# relay responder, is exactly that peer.
import os, socket, sys, time
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    srv.bind(("127.0.0.1", 45871))
except OSError as exc:
    sys.exit("boot 08: cannot bind the silent peer on 127.0.0.1:45871: %s" % exc)
srv.listen(4)
srv.settimeout(1.0)
pid = os.fork()
if pid == 0:
    # The peer must not inherit the gate's stdio pipes: holding them open
    # keeps the runner's session alive after the gate finishes.
    devnull = os.open(os.devnull, os.O_RDWR)
    os.dup2(devnull, 0)
    os.dup2(devnull, 1)
    os.dup2(devnull, 2)
    conns = []
    deadline = time.time() + 300
    while time.time() < deadline:
        try:
            conn, _ = srv.accept()
            conns.append(conn)   # held open, never written to
        except OSError:
            pass
    os._exit(0)
print("boot 08: silent peer listening on 127.0.0.1:45871 (pid %d)" % pid)
PY

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
src = os.path.join(".build", "go", "WEB.ELF")
if not os.path.exists(src):
    sys.exit("WEB.ELF missing (expected " + src + ") - build it first: "
             "bash tools/go/build-web.sh browser WEB")
shutil.copy(src, os.path.join(share, "WEB.ELF"))
for src_name, dst_name in (("gate-page.html", "PAGE.HTML"), ("gate-next.html", "NEXT.HTML"),
                           ("hostile.html", "HOSTILE.HTML")):
    shutil.copy(os.path.join("user", "go", "browser", "testdata", src_name),
                os.path.join(share, dst_name))
# M71i (#1568): the M70d (#1456) fidelity-corpus page, inherited from the
# retired live-doc-web boot 05 ("one UA-table corpus page the guest can
# open"). It is a real page off the pinned corpus and the only thing that
# keeps that rung asserted IN the guest now that its Zig consumer is gone;
# the host-side golden tests (user/go/webrender/golden_test.go) pin all nine
# corpus pages' layout, but they never boot the VM.
corpus = os.path.join("user", "go", "webrender", "testdata", "corpus",
                      "cern-home.html")
if not os.path.exists(corpus):
    sys.exit("corpus fixture missing at " + corpus)
shutil.copy(corpus, os.path.join(share, "CORPUS.HTML"))
print("staged WEB.ELF (%d bytes) + PAGE.HTML/NEXT.HTML" %
      os.path.getsize(os.path.join(share, "WEB.ELF")))
gofetch = os.path.join(".build", "go", "GOFETCH.ELF")
if not os.path.exists(gofetch):
    sys.exit("GOFETCH.ELF missing (expected " + gofetch + ") - build it first: "
             "bash tools/go/build-web.sh fetch GOFETCH")
shutil.copy(gofetch, os.path.join(share, "GOFETCH.ELF"))
print("staged GOFETCH.ELF (%d bytes)" % os.path.getsize(os.path.join(share, "GOFETCH.ELF")))
PY

vgate_setup_python <<'PY'
# Boot 12: TLS 1.3 responder on the same fixture identity the Go shelf
# vendors (leaf.example.com, AutoClaw test CA). Bound to loopback:24533 and
# reached through the runner's :relay -- the probe retired from live-tls13
# in M71k (#1570); this boot is its coverage. Long deadline because this
# spec has many boots before 12.
import os, subprocess, sys
rd = os.environ["RUN_DIR"]
cfx = os.path.join("user", "src", "lib", "tls", "vectors", "fx")
chain = os.path.join(cfx, "chain-ec.pem")
if not os.path.exists(chain):
    sys.exit("pinned fixture chain missing at %s" % chain)
cmd = [
    sys.executable,
    os.path.join("user", "src", "lib", "tls", "vectors", "tlsresponder.py"),
    "--host", "127.0.0.1", "--port", "24533",
    "--cert", chain, "--key", os.path.join(cfx, "leaf-ec.key"),
    "--body", "live-web-https-ok\n", "--accept", "2", "--timeout", "3600",
]
log = open(os.path.join(rd, "tlsresponder.log"), "wb")
proc = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
print("live-web 12: tlsresponder pid=%d on 127.0.0.1:24533" % proc.pid)
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
vgate_assert 01 serial-contains 'web: budget startup-ms='
vgate_assert 01 serial-contains ' wait-ms='
vgate_assert 01 serial-contains ' render-ms='
vgate_assert 01 serial-contains ' settle-ms='
vgate_assert 01 serial-absent 'web: budget over'
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

# #1586: EVERY boot that launches WEB asserts the absence, not just the old
# 01/03/11. The guest printed `web: budget over startup ...` in all thirteen
# WEB boots for months while only three looked, which is why the red set
# looked load-driven. Measured then: startup=10048ms (7013ms of it vi.WmPeers
# retrying for a WM seat that does not exist on the shim path, 3022ms the four
# faces). After the fix: startup=3029-3054ms, so the absence is true everywhere
# and a real regression trips it in whichever boot it happens. Boot 12 is
# deliberately NOT asserted: it launches GOFETCH, not WEB, and prints no
# `web:` line at all (an absence there could only ever be vacuous).
vgate_assert 02 serial-absent 'web: budget over'
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
vgate_assert 03 serial-contains 'web: budget startup-ms='
vgate_assert 03 serial-absent 'web: budget over'
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

vgate_assert 04 serial-absent 'web: budget over'
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

# --- boot 05: https is TLS, never a cleartext GET -------------------------
# The host TCP responder IS armed for 10.0.0.2:80, so a silent downgrade to
# plain http would print web: fetch and a NET-TCP 200. WEB.ELF instead
# tls.Dials :80; the handshake fails closed on the HTTP peer (not a hang),
# and the GET is never armed.
vgate_run 05 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-05' \
    --net '$RUN_DIR/cap5.bin' --net-arp-respond 10.0.0.2 --net-tcp-respond 10.0.0.2:80 \
    --script '$RUN_DIR/script-https.txt' \
    --snapshot-after "web: settled" \
    --snapshot-after "web: repaint" \
    --script-expect "web: ready" --timeout 120

vgate_assert 05 serial-absent 'web: budget over'
vgate_assert 05 serial-contains 'web: url https://10.0.0.2:80/'
vgate_assert 05 serial-contains 'web: error tls'
vgate_assert 05 serial-contains 'web: ready'
vgate_assert 05 serial-absent 'web: fetch '
vgate_assert 05 serial-absent 'FETCHS.BIN'
vgate_assert 05 serial-absent '[EXC] parking:'
vgate_assert 05 python <<'PY'
import os, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
assert "web: error tls" in ser, "https did not fail closed on TLS"
assert "web: fetch " not in ser, "a request was armed for an https URL"
assert "web: parse nodes=" not in ser, "an https URL produced a rendered page"
assert "GET / HTTP" not in ser, "a cleartext GET was logged"
assert "FETCHS.BIN" not in ser, "FETCHS.BIN was spawned"
print("live-web 05 https fail-closed ok (TLS handshake, no GET, no FETCHS)")
PY

# --- boot 06: a hostname is refused (no resolver), not attempted ---------
vgate_run 06 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-06' \
    --script '$RUN_DIR/script-dns.txt' \
    --snapshot-after "web: settled" \
    --snapshot-after "web: repaint" \
    --script-expect "web: ready" --timeout 120

vgate_assert 06 serial-absent 'web: budget over'
vgate_assert 06 serial-contains 'web: error dns'
vgate_assert 06 serial-contains 'web: ready'
vgate_assert 06 serial-absent 'web: fetch '
vgate_assert 06 serial-absent '[EXC] parking:'

# --- boot 07: a malformed URL is a defined error, not a hang -------------
vgate_run 07 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-07' \
    --script '$RUN_DIR/script-badurl.txt' \
    --snapshot-after "web: settled" \
    --snapshot-after "web: repaint" \
    --script-expect "web: ready" --timeout 120

vgate_assert 07 serial-absent 'web: budget over'
vgate_assert 07 serial-contains 'web: error url'
vgate_assert 07 serial-contains 'web: ready'
vgate_assert 07 serial-absent 'web: fetch '
vgate_assert 07 serial-absent '[EXC] parking:'

# --- boot 08: a load in flight can be stopped (cancel) -------------------
# The guest's request is relayed to the silent host peer (see the first setup
# hook), so the browser is genuinely waiting when the injected `x` arrives:
# the assert requires the cancel, not a fast connection failure.
vgate_run 08 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-08' \
    --net '$RUN_DIR/cap8.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:80:relay --net-tcp-respond-relay 127.0.0.1:45871 \
    --script '$RUN_DIR/script-slow.txt' \
    --input-chords x --input-chords-after "web: fetch " \
    --snapshot-after "web: settled" \
    --snapshot-after "web: repaint" \
    --script-expect "web: ready" --timeout 180

vgate_assert 08 serial-absent 'web: budget over'
vgate_assert 08 serial-absent '[EXC] parking:'
vgate_assert 08 serial-contains 'web: fetch 10.0.0.2/'
vgate_assert 08 python <<'PY'
import os
ser = open(os.environ["VG_SER"], errors="replace").read()
assert "web: fetch 10.0.0.2/" in ser, "the load was never armed"
assert "web: error cancelled" in ser, "the injected cancel key did not stop the load"
assert "web: settled" in ser, "no frame was published after the cancel"
print("live-web 08 cancel ok (a load in flight was stopped by the injected cancel key)")
PY

# --- boot 09: the stores are written, and they land on the host share ----
# Fetch with the responder armed, then save the page. The python assert reads
# the share itself, so this is evidence of a persistent store, not of a
# marker the app printed about itself.
vgate_run 09 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-09' \
    --net '$RUN_DIR/cap9.bin' --net-arp-respond 10.0.0.2 --net-tcp-respond 10.0.0.2:80 \
    --script '$RUN_DIR/script-store.txt' \
    --input-chords s --input-chords-after "web: ready" \
    --snapshot-after "web: repaint" \
    --script-expect "web: download " --timeout 180

vgate_assert 09 serial-absent 'web: budget over'
vgate_assert 09 serial-contains 'web: stores '
vgate_assert 09 serial-contains 'web: cache store '
vgate_assert 09 serial-contains 'web: download '
vgate_assert 09 serial-absent '[EXC] parking:'
vgate_assert 09 python <<'PY'
import glob, os
share = os.environ["VG_SHARE"]
def rows(path):
    with open(path, errors="replace") as fh:
        return [l for l in fh.read().splitlines() if l and not l.startswith("#")]
hist = rows(os.path.join(share, "WEB-HISTORY.TXT"))
assert hist, "WEB-HISTORY.TXT has no data rows"
assert any("http://10.0.0.2/" in r for r in hist), "the visit was not recorded"
idx = rows(os.path.join(share, "WEB-CACHE.TXT"))
assert idx, "WEB-CACHE.TXT has no data rows"
bodies = glob.glob(os.path.join(share, "WEB-C-*.BIN"))
assert bodies, "no cached body file"
size = os.path.getsize(bodies[0])
dl = glob.glob(os.path.join(share, "WEB-DL-*"))
assert dl, "no download file"
dlsize = os.path.getsize(dl[0])
print("live-web 09 stores ok (history rows=%d, cache rows=%d, body=%dB, download=%s %dB)"
      % (len(hist), len(idx), size, os.path.basename(dl[0]), dlsize))
PY

# --- boot 10: the store survives a restart, and serves an offline copy ---
# A second, independent boot with NO responder: the connection cannot be
# answered, so the browser must fall back to what it stored in boot 09 and
# say so. The boot-time inventory is what proves the rows were read back
# from disk.
vgate_run 10 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-10' \
    --net '$RUN_DIR/cap10.bin' --net-arp-respond 10.0.0.2 \
    --script '$RUN_DIR/script-offline.txt' \
    --snapshot-after "web: settled" \
    --snapshot-after "web: repaint" \
    --script-expect "web: ready" --timeout 180

vgate_assert 10 serial-absent 'web: budget over'
vgate_assert 10 serial-contains 'web: offline http://10.0.0.2/'
vgate_assert 10 serial-contains 'web: settled'
vgate_assert 10 serial-absent 'web: error tcp'
vgate_assert 10 serial-absent '[EXC] parking:'
vgate_assert 10 python <<'PY'
import os
ser = open(os.environ["VG_SER"], errors="replace").read()
line = ""
for ln in ser.splitlines():
    if ln.startswith("web: stores "):
        line = ln
        break
assert line, "no store inventory at boot"
fields = dict(f.split("=", 1) for f in line.split()[2:] if "=" in f)
assert int(fields.get("cache", 0)) >= 1, "the cache did not survive the restart: " + line
assert int(fields.get("history", 0)) >= 1, "history did not survive the restart: " + line
assert int(fields.get("downloads", 0)) >= 1, "downloads did not survive the restart: " + line
print("live-web 10 restart-persistence ok (%s)" % line.strip())
PY
vgate_assert 10 snapshot 'snap-10-*.raw' <<'PY'
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
assert n >= 40, f"offline copy body ink {n}"
print(f"live-web 10 offline pixels ok (ink={n})")
PY

# --- boot 11: a hostile page is inert ------------------------------------
# The fixture carries a script whose body would fetch a URL and read a local
# file, an iframe/object/img pointing at the browser's own store files, and
# javascript:/file: links. This browser has no JavaScript and no way for an
# element to act on an attribute, so the page must render as text with no
# request armed, no file read, and no extra syscall path.
vgate_run 11 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-11' \
    --script '$RUN_DIR/script-hostile.txt' \
    --snapshot-after "web: settled" \
    --snapshot-after "web: repaint" \
    --script-expect "web: ready" --timeout 120

vgate_assert 11 serial-contains 'web: parse nodes='
vgate_assert 11 serial-contains 'web: settled'
vgate_assert 11 serial-contains 'web: budget startup-ms='
vgate_assert 11 serial-contains ' wait-ms='
vgate_assert 11 serial-contains ' render-ms='
vgate_assert 11 serial-contains ' settle-ms='
vgate_assert 11 serial-absent 'web: fetch'
vgate_assert 11 serial-absent 'web: error'
vgate_assert 11 serial-absent 'web: download'
vgate_assert 11 serial-absent 'web: budget over'
vgate_assert 11 serial-absent '[EXC] parking:'
vgate_assert 11 snapshot 'snap-11-*.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
w = 1280
X, Y = 40, 28
def px(x, y):
    k = (y * w + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def ink(c):
    return c[0] > 200 and c[1] > 200 and c[2] > 200
n = sum(1 for yy in range(Y + 52, Y + 200)
        for xx in range(X + 10, X + 480)
        if ink(px(xx, yy)))
assert n >= 80, f"hostile page ink {n}"
print(f"live-web 11 hostile-page pixels ok (ink={n})")
PY

# --- boot 12: GOFETCH.ELF https in-process (issue #1447) ------------------
# The host TLS 1.3 fixture peer (setup hook) is relayed at 10.0.0.2:24533.
# GOFETCH dials in-process via tls.Dial; FETCHS.BIN is not exec'd. The
# handshake and GET complete in this process (single goroutine).
# M71k (#1570): FETCHS.BIN no longer exists, so the serial-absent probe
# below can no longer be proven "by a binary that is not built" -- it is
# the identity the retired live-tls13 spec named.
vgate_run 12 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-12' \
    --net '$RUN_DIR/cap12.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:24533:relay --net-tcp-respond-relay 127.0.0.1:24533 \
    --script '$RUN_DIR/script-gofetch.txt' \
    --script-expect "gofetch: ready" --timeout 180

vgate_assert 12 serial-contains 'gofetch: open id='
vgate_assert 12 serial-contains 'gofetch: url https://10.0.0.2:24533/'
vgate_assert 12 serial-contains 'gofetch: dial 10.0.0.2 24533 leaf.example.com'
vgate_assert 12 serial-contains 'gofetch: handshake ok'
vgate_assert 12 serial-contains 'gofetch: request sent'
vgate_assert 12 serial-contains 'live-web-https-ok'
vgate_assert 12 serial-contains 'gofetch: body complete'
vgate_assert 12 serial-contains 'gofetch: ready'
vgate_assert 12 serial-absent 'FETCHS.BIN'
vgate_assert 12 serial-absent 'gofetch: helper'
vgate_assert 12 serial-absent 'gofetch: tcp'
vgate_assert 12 serial-absent 'gofetch: error'
vgate_assert 12 serial-absent 'web: fetch '
vgate_assert 12 serial-absent 'GET / HTTP'
vgate_assert 12 serial-absent 'fatal error: runtime: cannot allocate memory'
vgate_assert 12 serial-absent '[EXC] parking:'
vgate_assert 12 python <<'PY'
import os
ser = open(os.environ["VG_SER"], errors="replace").read()
assert "gofetch: handshake ok" in ser, "in-process TLS handshake did not complete"
assert "live-web-https-ok" in ser, "the fixture body was not read"
assert "FETCHS.BIN" not in ser, "FETCHS.BIN spawn marker present"
assert "gofetch: helper" not in ser, "the Zig TLS helper was exec'd"
assert "gofetch: tcp" not in ser, "Go opened a cleartext TCP socket"
assert "GET / HTTP" not in ser, "a cleartext GET was logged"
print("live-web 12 https in-process ok (GOFETCH tls.Dial, body, no FETCHS)")
PY

# --- boot 13: M69b console-ink re-measure in the web boot (#1592) ----------
# live-web 01-12 are shim-compositing (GOTABWM.ELF is not on the share;
# serial: "wm: autostart gotabwm: GOTABWM.ELF not on the share"). The
# M69b numbers came from this shape. Observed 2026-09-21 on this spec's
# first boot-13 run (macOS 27.2 / arm64, VZ): after web: settled, the
# band below WEB.ELF's 40,28 512x384 window held console-green
# 4747/82792 (5.734%) at +3 s and 4646/82792 (5.612%) at +20 s -- the
# M69b ~5.8% 20 s figure, already at plateau. Kernel fg_rgb = 0x00ff00.
# There is no seat, so paint_scene still blits the full-screen terminal
# and this probe pins that ink. A seated boot is go-wm-console-ink
# (#1561): paint_scene skips the terminal blit while the seat owns the
# layer (M71c) but the present must still flush. Skipping the drain
# outright leaves the pre-seat console frame (measured 1789 green pixels).
vgate_file script-ink-3s.txt <<'EOF'
echo web-ink-3s
EOF

vgate_file script-ink-20s.txt <<'EOF'
echo web-ink-20s
echo web-ink-done
EOF

vgate_run 13 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/ink' \
    --script '$RUN_DIR/script-local.txt' \
    --script2 '$RUN_DIR/script-ink-3s.txt' --script2-after "web: settled" --script2-delay 3 \
    --snapshot-after "web-ink-3s" \
    --script3 '$RUN_DIR/script-ink-20s.txt' --script3-after "web-ink-3s" --script3-delay 17 \
    --snapshot-after "web-ink-20s" \
    --script-expect "web-ink-done" --timeout 180

vgate_assert 13 serial-absent 'web: budget over'
vgate_assert 13 serial-contains 'web: settled'
vgate_assert 13 serial-contains 'web-ink-3s'
vgate_assert 13 serial-contains 'web-ink-20s'
vgate_assert 13 serial-contains 'web-ink-done'
vgate_assert 13 serial-absent '[EXC] parking:'
vgate_assert 13 snapshot 'ink-0.raw' <<'PY'
import os, sys
# First frame (3 s after settled). Shared sampler is below in the python
# assert so both frames are reported together; this check only proves the
# kind-4 stream wrote a 1280x720 BGRX scanout.
data = open(sys.argv[1], "rb").read()
assert len(data) == 1280 * 720 * 4, "3s scanout size %d" % len(data)
print("live-web 13 3s snapshot %d bytes" % len(data))
PY
vgate_assert 13 snapshot 'ink-1.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
assert len(data) == 1280 * 720 * 4, "20s scanout size %d" % len(data)
print("live-web 13 20s snapshot %d bytes" % len(data))
PY
vgate_assert 13 python <<'PY'
import os, sys

W, H = 1280, 720
# WEB.ELF window is 40,28 512x384; sample the band the window cannot cover.
Y0, STEP = 450, 2
PAGE_BG = (0x18, 0x20, 0x26)

def load(name):
    path = os.path.join(os.environ["RUN_DIR"], name)
    data = open(path, "rb").read()
    if len(data) != W * H * 4:
        sys.exit("%s size %d, want %d" % (name, len(data), W * H * 4))
    return data

def px(data, x, y):
    k = (y * W + x) * 4
    return data[k + 2], data[k + 1], data[k]

def near(c, want, tol=6):
    return all(abs(a - b) <= tol for a, b in zip(c, want))

def ink(rgb):
    return max(rgb) >= 100

def console_ink(rgb):
    r, g, b = rgb
    return g > 150 and r < 160 and b < 160

def measure(data, label):
    # Live-capture check: the WEB page fill at the declared window, or any
    # brighter ink there, so a blank/failed stream cannot pass.
    win = 0
    for yy in range(28 + 52, 28 + 200, STEP):
        for xx in range(40 + 10, 40 + 400, STEP):
            rgb = px(data, xx, yy)
            if near(rgb, PAGE_BG) or ink(rgb):
                win += 1
    tot = interior = green = 0
    for yy in range(Y0, H - 8, STEP):
        for xx in range(8, W - 8, STEP):
            rgb = px(data, xx, yy)
            tot += 1
            if ink(rgb):
                interior += 1
                if console_ink(rgb):
                    green += 1
    print("live-web 13 %s: window-page-bg=%d uncovered sampled=%d ink=%d (%.3f%%) console-green=%d (%.3f%%)"
          % (label, win, tot, interior, 100.0 * interior / tot if tot else 0.0,
             green, 100.0 * green / tot if tot else 0.0))
    if win < 200:
        sys.exit("FAIL: %s capture has no WEB window paint -- a blank scanout cannot prove the uncovered region" % label)
    return tot, interior, green

a = measure(load("ink-0.raw"), "3s")
b = measure(load("ink-1.raw"), "20s")
# Shim web boot: the full-screen kernel terminal is the desktop behind WEB.
# Pin the M69b ~5.8% console-green so a blank capture cannot pass and a
# seated paint cannot silently replace this measurement. The seated
# console-green=0 probe is go-wm-console-ink (#1561).
for label, m in (("3s", a), ("20s", b)):
    tot, interior, green = m
    pct = 100.0 * green / tot if tot else 0.0
    if green == 0:
        sys.exit("FAIL: %s uncovered band has 0 console-green -- this shim web boot previously measured ~5.8%% (M69b / #1592)" % label)
    if pct < 2.0 or pct > 12.0:
        sys.exit("FAIL: %s console-green %.3f%% outside the pinned shim band 2-12%% (M69b ~5.8%%)" % (label, pct))
print("live-web 13 console-ink: shim web boot still carries kernel console green in the uncovered band (M69b reproduced; seated probe is go-wm-console-ink)")
PY

# --- boot 14: M70d shard 1 corpus page, on the surviving consumer --------
# M71i (#1568): inherited from the retired live-doc-web boot 05. The fixture
# (CERN's first-website hub) is the corpus's own pinned bytes, and the page is
# readable from the compiled-in UA table alone -- no cascade, no script (ADR
# 0028 D2). The probe asserts a multi-paragraph real page, not a marker: the
# retired boot pinned 16 px of h1 ink, this one pins ink bands and text ink
# inside the client box so a page that failed to lay out cannot pass on its
# own `settled`.
vgate_run 14 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-14' \
    --script '$RUN_DIR/script-corpus.txt' \
    --snapshot-after "web: settled" \
    --snapshot-after "web: repaint" \
    --script-expect "web: ready" --timeout 180

vgate_assert 14 serial-absent 'web: budget over'
vgate_assert 14 serial-contains 'web: url /host/CORPUS.HTML'
vgate_assert 14 serial-contains 'web: parse nodes='
vgate_assert 14 serial-contains 'web: layout blocks='
vgate_assert 14 serial-contains 'web: paint items='
vgate_assert 14 serial-contains 'web: settled'
vgate_assert 14 serial-contains 'web: ready'
vgate_assert 14 serial-absent 'web: error'
vgate_assert 14 serial-absent '[EXC] parking:'
vgate_assert 14 snapshot 'snap-14-0.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
w = 1280
X, Y = 40, 28
CX, CY, CW, CH = 8, 50, 496, 322
def px(x, y):
    k = (y * w + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def near(c, want, tol=6):
    return all(abs(a - b) <= tol for a, b in zip(c, want))
PAGE_BG = (0x18, 0x20, 0x26)
INK = (0xe6, 0xed, 0xf3)
ink = text = 0
rows = []
for yy in range(CY, CY + CH):
    n = 0
    for xx in range(CX, CX + CW):
        c = px(X + xx, Y + yy)
        if not near(c, PAGE_BG, 12):
            n += 1
            ink += 1
        if near(c, INK, 12):
            text += 1
    rows.append(n)
bands = 0
i = 0
while i < len(rows):
    if rows[i] == 0:
        i += 1
        continue
    bands += 1
    while i < len(rows) and rows[i] > 0:
        i += 1
print("live-web 14 corpus: ink=%d text-ink=%d bands=%d" % (ink, text, bands))
fails = []
if ink < 1500:
    fails.append("the corpus page painted only %d px" % ink)
if text < 100:
    fails.append("only %d px of text ink: the page did not lay out as prose" % text)
if bands < 4:
    fails.append("the corpus page produced %d ink bands: a multi-paragraph page was expected" % bands)
assert not fails, "WEB-CORPUS-FAILS: " + "; ".join(fails)
print("live-web 14 ok: the M70d corpus page opens on WEB.ELF")
PY

# go-rss.spec -- the VirelaiOS RSS/Atom reader (RSS.ELF).
#
# Boot 01: the reader launches as a tabapp window on a bound /dev/tty, renders
# the subscriptions and cached articles from /host/RSS.OPML + /host/RSS.CACHE,
# fetches a real RSS 2.0 document relayed from a host HTTP server, repaints on a
# real HID key, and exits cleanly. The capture is the default GOTABWM scanout,
# so the ink proves the frame reached the scanout.
#
# Boot 02: a subscription whose port is closed is opened and must fail LEGIBLY:
# `rss: error`, cached articles still on screen, no crash, no hang.
#
# HOST PREREQUISITE: .build/go/RSS.ELF (`bash tools/go/build-rss.sh`).
#
# The feed server is a real host PROCESS (Popen), not a thread: a thread inside
# the setup hook dies when the hook returns, which leaves the relay with no
# upstream and the guest's connect times out.

vgate_name go-rss "RSS.ELF: the in-guest Go RSS/Atom reader renders, fetches, takes HID keys, and fails legibly"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script1.txt <<'EOF'
net ip 10.0.0.1
net arp 10.0.0.2
exec RSS.ELF
EOF

vgate_file script2.txt <<'EOF'
dui close 2
EOF

vgate_setup_python <<'PY'
import os, shutil, subprocess, sys, time, urllib.request

run = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(run, "share")
os.makedirs(share, exist_ok=True)

elf = os.path.join(".build", "go", "RSS.ELF")
if not os.path.exists(elf):
    sys.exit("RSS.ELF missing (build it first: bash tools/go/build-rss.sh)")
shutil.copy(elf, os.path.join(share, "RSS.ELF"))

PORT = 18099
FEED = "http://10.0.0.2:%d/feed.xml" % PORT

# Subscription 0 is the live feed (relayed from the host server below);
# subscription 1 has a closed port and is the failure case.
opml = """<?xml version="1.0" encoding="UTF-8"?>
<opml version="2.0"><head><title>Virelai RSS</title></head><body>
<outline type="rss" text="Virelai Test Feed" title="Virelai Test Feed" xmlUrl="%s"/>
<outline type="rss" text="Closed Port Feed" title="Closed Port Feed" xmlUrl="http://10.0.0.2:9/feed.xml"/>
</body></opml>
""" % FEED
open(os.path.join(share, "RSS.OPML"), "w").write(opml)

cache = """<?xml version="1.0" encoding="UTF-8"?>
<cache version="1"><feed url="%s">
<article><title>Cached One</title><link>http://10.0.0.2/posts/1</link><date>Mon, 21 Sep 2026 12:00:00 GMT</date><guid>urn:cached:1</guid><summary>Hello from the first post.</summary></article>
</feed></cache>
""" % FEED
open(os.path.join(share, "RSS.CACHE"), "w").write(cache)

src = os.path.join("user", "go", "rss", "feed", "testdata")
srv = os.path.join(run, "feedserver")
os.makedirs(srv, exist_ok=True)
shutil.copy(os.path.join(src, "rss2.xml"), os.path.join(srv, "feed.xml"))
shutil.copy(os.path.join(src, "atom.xml"), os.path.join(srv, "atom.xml"))

proc = subprocess.Popen(
    [sys.executable, "-m", "http.server", str(PORT), "--bind", "127.0.0.1", "--directory", srv],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
for _ in range(60):
    try:
        with urllib.request.urlopen("http://127.0.0.1:%d/feed.xml" % PORT, timeout=0.5) as r:
            if r.status == 200:
                break
    except Exception:
        time.sleep(0.1)
else:
    sys.exit("feed server did not come up on 127.0.0.1:%d" % PORT)

print("go-rss: staged RSS.ELF (%d B) + OPML + CACHE; feed server pid=%d on 127.0.0.1:%d serving %s"
      % (os.path.getsize(elf), proc.pid, PORT, srv))
PY

# Boot 01: open subscription 0 (the live feed) via a real HID Return.
vgate_run 01 -- \
    --screen '$RUN_DIR/rss-screen' \
    --input --via-virtio \
    --net '$RUN_DIR/cap1.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:18099:relay --net-tcp-respond-relay 127.0.0.1:18099 \
    --script '$RUN_DIR/script1.txt' \
    --input-chords return \
    --input-chords-after 'rss: ready' \
    --screenshot-after 'rss: repainted' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'rss: repainted' \
    --script-expect 'rss: close' --timeout 240

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'
vgate_assert 01 serial-contains 'exec: loaded RSS.ELF'
vgate_assert 01 serial-contains 'rss: open id='
vgate_assert 01 serial-contains 'rss: attached'
vgate_assert 01 serial-contains 'rss: storage /host/RSS.OPML'
vgate_assert 01 serial-contains 'rss: loaded feeds=2'
vgate_assert 01 serial-contains 'rss: painted'
vgate_assert 01 serial-contains 'rss: ready'
vgate_assert 01 serial-contains 'rss: fetch http://10.0.0.2:18099/feed.xml'
vgate_assert 01 serial-contains 'rss: got '
vgate_assert 01 serial-contains 'rss: repainted'
vgate_assert 01 serial-contains 'rss: close'
vgate_assert 01 serial-contains 'rss OK'
vgate_assert 01 serial-absent 'exited status=139'
vgate_assert 01 serial-absent 'panic:'

vgate_assert 01 snapshot 'rss-screen-after' <<'PY'
import struct, sys, zlib

d = open(sys.argv[1], "rb").read()
assert d[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG scanout"
pos, idat, w, h, ct = 8, b"", 0, 0, 0
while pos < len(d):
    n, typ = struct.unpack(">I4s", d[pos:pos + 8])
    chunk = d[pos + 8:pos + 8 + n]
    if typ == b"IHDR":
        w, h, depth, ct = struct.unpack(">IIBB", chunk[:10])
    elif typ == b"IDAT":
        idat += chunk
    pos += 12 + n
assert (w, h) == (2560, 1440), "wanted 2560x1440 scanout, got %dx%d" % (w, h)
bpp = 4 if ct == 6 else 3
raw = zlib.decompress(idat)
stride = w * bpp
out = bytearray()
prev = bytearray(stride)
i = 0
for _ in range(h):
    filt = raw[i]; i += 1
    row = bytearray(raw[i:i + stride]); i += stride
    if filt == 1:
        for x in range(bpp, stride):
            row[x] = (row[x] + row[x - bpp]) & 0xff
    elif filt == 2:
        for x in range(stride):
            row[x] = (row[x] + prev[x]) & 0xff
    elif filt == 3:
        for x in range(stride):
            left = row[x - bpp] if x >= bpp else 0
            row[x] = (row[x] + ((left + prev[x]) >> 1)) & 0xff
    elif filt == 4:
        for x in range(stride):
            left = row[x - bpp] if x >= bpp else 0
            up = prev[x]
            ul = prev[x - bpp] if x >= bpp else 0
            p = left + up - ul
            pa, pb, pc = abs(p - left), abs(p - up), abs(p - ul)
            row[x] = (row[x] + (left if pa <= pb and pa <= pc else up if pb <= pc else ul)) & 0xff
    out += row
    prev = row

bright = 0
for y in range(0, h, 4):
    for x in range(0, w, 4):
        k = (y * w + x) * bpp
        if out[k] + out[k + 1] + out[k + 2] > 400:
            bright += 1
print("rss scanout: %dx%d bright=%d" % (w, h, bright))
assert bright > 200, "the reader's ink is absent from the scanout"
PY

# Boot 02: subscription 1 (closed port) is opened; the failure must be legible.
vgate_run 02 -- \
    --screen '$RUN_DIR/rss-screen2' \
    --input --via-virtio \
    --net '$RUN_DIR/cap2.bin' --net-arp-respond 10.0.0.2 \
    --script '$RUN_DIR/script1.txt' \
    --input-chords 'down,return' \
    --input-chords-after 'rss: ready' \
    --screenshot-after 'rss: error' \
    --script-expect 'rss: error' --timeout 240

vgate_assert 02 serial-contains 'rss: fetch http://10.0.0.2:9/feed.xml'
vgate_assert 02 serial-contains 'rss: error'
vgate_assert 02 serial-absent 'exited status=139'
vgate_assert 02 serial-absent 'panic:'

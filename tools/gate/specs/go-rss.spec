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
# upstream and the guest's connect times out. It is not `python -m http.server`:
# /feed.xml answers 301, /rss.xml is chunked, and a Host header without the
# port is refused.

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
import os, shutil, subprocess, sys, time

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

# lastfeed is the URL, the cache key. Boot 01 must print the staged article
# before the live fetch replaces it. A lookup by title finds nothing.
state = """<?xml version="1.0" encoding="UTF-8"?>
<state version="1" lastfeed="%s"></state>
""" % FEED
open(os.path.join(share, "RSS.STATE"), "w").write(state)

src = os.path.join("user", "go", "rss", "feed", "testdata")
srv = os.path.join(run, "feedserver")
os.makedirs(srv, exist_ok=True)
rss_path = os.path.join(srv, "rss.xml")
shutil.copy(os.path.join(src, "rss2.xml"), rss_path)
shutil.copy(os.path.join(src, "atom.xml"), os.path.join(srv, "atom.xml"))

# Not python -m http.server. That server answers Host without a port and
# sends a Content-Length body, so a client that omits :18099, cannot decode
# chunked responses, or does not follow a 301 still fetches this feed.
# /feed.xml is a 301 to /rss.xml. /rss.xml is chunked. Both refuse a Host
# that does not carry the port.
server_py = os.path.join(run, "feed_http.py")
open(server_py, "w").write(r'''
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port = int(sys.argv[1])
rss_path = sys.argv[2]
rss = open(rss_path, "rb").read()

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        self.close_connection = True
        host = self.headers.get("Host", "")
        if (":%d" % port) not in host:
            body = b"host must include port"
            self.send_response(400)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
            return
        path = self.path.split("?", 1)[0]
        if path == "/feed.xml":
            loc = "http://10.0.0.2:%d/rss.xml" % port
            body = b"moved"
            self.send_response(301)
            self.send_header("Location", loc)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
            return
        if path == "/rss.xml":
            self.send_response(200)
            self.send_header("Content-Type", "application/rss+xml")
            self.send_header("Transfer-Encoding", "chunked")
            self.send_header("Connection", "close")
            self.end_headers()
            i = 0
            while i < len(rss):
                part = rss[i:i + 17]
                i += len(part)
                self.wfile.write(("%x\r\n" % len(part)).encode("ascii") + part + b"\r\n")
            self.wfile.write(b"0\r\n\r\n")
            return
        self.send_error(404)

    def log_message(self, fmt, *args):
        return

ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
''')

proc = subprocess.Popen(
    [sys.executable, server_py, str(PORT), rss_path],
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

import http.client
ok = False
last = "not started"
for _ in range(60):
    try:
        c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=0.5)
        c.request("GET", "/feed.xml", headers={"Host": "10.0.0.2:%d" % PORT})
        r = c.getresponse()
        loc = r.getheader("Location") or ""
        r.read()
        c.close()
        if r.status != 301 or (":%d" % PORT) not in loc:
            last = "redirect status=%s location=%s" % (r.status, loc)
            time.sleep(0.1)
            continue
        c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=0.5)
        c.request("GET", "/rss.xml", headers={"Host": "10.0.0.2:%d" % PORT})
        r = c.getresponse()
        body = r.read()
        c.close()
        if r.status != 200 or b"<rss" not in body:
            last = "chunked status=%s len=%d" % (r.status, len(body))
            time.sleep(0.1)
            continue
        c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=0.5)
        c.request("GET", "/rss.xml", headers={"Host": "10.0.0.2"})
        r = c.getresponse()
        r.read()
        c.close()
        if r.status != 400:
            last = "bare host status=%s" % r.status
            time.sleep(0.1)
            continue
        ok = True
        break
    except Exception as e:
        last = str(e)
        time.sleep(0.1)
if not ok:
    sys.exit("feed server did not come up on 127.0.0.1:%d (%s)" % (PORT, last))

print("go-rss: staged RSS.ELF (%d B) + OPML + CACHE + STATE; feed server pid=%d on 127.0.0.1:%d (301 + chunked, Host must carry :%d)"
      % (os.path.getsize(elf), proc.pid, PORT, PORT))
PY

# Boot 01: the staged cache is already on screen (lastfeed is the URL).
# `r` refreshes that feed. Return would open the cached article instead.
vgate_run 01 -- \
    --screen '$RUN_DIR/rss-screen' \
    --input --via-virtio \
    --net '$RUN_DIR/cap1.bin' --net-arp-respond 10.0.0.2 \
    --net-tcp-respond 10.0.0.2:18099:relay --net-tcp-respond-relay 127.0.0.1:18099 \
    --script '$RUN_DIR/script1.txt' \
    --input-chords r \
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
vgate_assert 01 serial-contains 'rss: cache entries=1 first=Cached One'
vgate_assert 01 serial-contains 'rss: painted'
vgate_assert 01 serial-contains 'rss: ready'
vgate_assert 01 serial-contains 'rss: fetch http://10.0.0.2:18099/feed.xml'
vgate_assert 01 serial-contains 'feed: redirect http://10.0.0.2:18099/rss.xml'
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

# SGR 96 is bright cyan, ansi_palette[14] = 0x29b8db
# (kernel/src/driving_award.zig). The reader paints "Virelai RSS" in that
# colour. The capture is a scaled window, so the glyph pixels are blends of
# that cyan toward the terminal background (0x101418): green and blue stay
# near each other and both stay above red. White title text, accent blue
# (0x3b82f6, blue far above green) and the default terminal green do not.
from collections import Counter
buckets = Counter()
cyan = 0
for y in range(0, h, 2):
    for x in range(0, w, 2):
        k = (y * w + x) * bpp
        r, g, b = out[k], out[k + 1], out[k + 2]
        if max(r, g, b) - min(r, g, b) > 24:
            buckets[(r // 32, g // 32, b // 32)] += 1
        if g > 70 and b > 90 and g + 15 > r and b > r + 25 and abs(int(b) - int(g)) < 50 and r < 120:
            cyan += 1
top = ", ".join("%s:%d" % (k, n) for k, n in buckets.most_common(8))
print("rss scanout: %dx%d cyan=%d saturated=%s" % (w, h, cyan, top))
assert cyan >= 30, "Virelai RSS title colour absent from the scanout"
PY

# Boot 02: the cache restore opens on the article list, so Esc returns to
# the subscriptions, Down selects the closed port, Return opens it.
vgate_run 02 -- \
    --screen '$RUN_DIR/rss-screen2' \
    --input --via-virtio \
    --net '$RUN_DIR/cap2.bin' --net-arp-respond 10.0.0.2 \
    --script '$RUN_DIR/script1.txt' \
    --input-chords 'escape,down,return' \
    --input-chords-after 'rss: ready' \
    --screenshot-after 'rss: error' \
    --script-expect 'rss: error' --timeout 240

vgate_assert 02 serial-contains 'rss: fetch http://10.0.0.2:9/feed.xml'
vgate_assert 02 serial-contains 'rss: error'
vgate_assert 02 serial-absent 'exited status=139'
vgate_assert 02 serial-absent 'panic:'

# live-web-ttf.spec -- issue #1346 (class B): Go EL0 paints REAL TrueType.
#
# WEB.ELF is a Go EL0 program over virelai/webrender. Before this card its
# renderer drew the 8x8 integer-scaled bitmap: every advance was 8px, so an h1
# band was a grid rather than a typeface. This gate is what says otherwise, and
# it is written so a silent regression back to the grid FAILS rather than
# merely looking wrong in a screenshot.
#
# Three boots, each proving one thing the other two cannot:
#
#   01  the oliver fixture, faces present. The engine reports measurable facts
#       (per-glyph advances, line heights) and the page's FIRST INKED BAND is
#       measured in pixels: Inter at 13/26px gives an h1 band 20 rows tall
#       spanning 294px, the 8x8 bitmap gives 14 rows and 347px. The probe
#       requires the Inter numbers.
#
#   02  layout depth (ADR 0028 S2-S4) on a page whose table, image and link are
#       all ABOVE the fold: a table header rule, a link underline, and a 32x32
#       QOI image written by this spec's setup hook whose four quadrant colours
#       appear nowhere else on the page. Finding those exact colours is
#       evidence that the image DECODED and painted, not that a box appeared.
#
#   03  the SAME page as 01 with both faces removed from the share over the host
#       file channel (`vf <verb>`, see the script below). The app must fall
#       back, say so on the wire, still paint the page - and produce THE GRID
#       numbers. Boot 03 is the falsification of boot 01: without it, a probe
#       that always passed would look identical. It runs LAST because it
#       mutates the share: the deletion would otherwise be inherited by every
#       later boot (learned by running it second, when boot 03 came up with
#       `web: fonts bitmap8x8 ui=missing mono=missing`).
#
# Why 01 does not probe the table: the oliver fixture lays out 545px tall in a
# 322px content box, so its <table> and <hr> rules sit below the fold (measured
# on the host - the only in-view rules are the two link underlines). Boot 03 is
# where table depth is visible.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   .build/go/WEB.ELF  --  bash tools/go/build-web.sh browser WEB
#
# The faces are seeded by `vgate_share seed` (tools/lib/gate-run.sh), the same
# files the Zig userland loads: /host/INTER.TTF and /host/FIRACODE.TTF.

vgate_name live-web-ttf "issue #1346: WEB.ELF paints real TrueType (Inter) on the oliver fixture, falls back to the 8x8 grid when the face is gone, and renders tables/images/links"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_file script-oliver.txt <<'EOF'
exec WEB.ELF /host/OLIVER.HTML
EOF

# Boot 02 takes the faces away first, through the HOST FILE CHANNEL, not a bare
# verb: the guest shell's `vf` command owns these file ops
# (kernel/src/monitor.zig cmd_vf_rm; the bare verbs only appear in the shell's
# completion table). The first version of this spec typed a bare verb, the
# shell ignored it, the faces were still loaded and the fallback never ran -
# the `vf ls` line below is there so the transcript shows the deletion.
vgate_file script-nofont.txt <<'EOF'
vf rm INTER.TTF
vf rm FIRACODE.TTF
vf ls
exec WEB.ELF /host/OLIVER.HTML
EOF

vgate_file script-depth.txt <<'EOF'
exec WEB.ELF /host/DEPTH.HTML
EOF

vgate_setup_python <<'PY'
# Boot 02's page and its image. The swatch carries four colours that appear
# nowhere else on the page, so the pixel probe can assert the DECODE rather
# than merely "something was painted". QOI_OP_RGB (0xfe) per pixel is the
# simplest legal encoding and keeps this fixture readable by eye.
import os, struct, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
W = H = 32
QUADS = [(0x11, 0x7f, 0x33), (0xd0, 0x33, 0x99), (0x22, 0x66, 0xdd), (0xee, 0xcc, 0x00)]
out = bytearray(b"qoif") + struct.pack(">II", W, H) + bytes([4, 0])
for y in range(H):
    for x in range(W):
        c = QUADS[(y * 2 // H) * 2 + (x * 2 // W)]
        out += bytes([0xfe, c[0], c[1], c[2]])
out += bytes([0, 0, 0, 0, 0, 0, 0, 1])
with open(os.path.join(share, "SWATCH.QOI"), "wb") as fh:
    fh.write(bytes(out))
page = (b"<h4>Depth</h4>"
        b"<table><thead><tr><th>Left</th><th>Right</th></tr></thead>"
        b"<tbody><tr><td>one</td><td>two</td></tr></tbody></table>"
        b"<p>An image:</p><img src=\"SWATCH.QOI\" alt=\"swatch\">"
        b"<p><a href=\"NEXT.HTML\">a link</a></p>")
with open(os.path.join(share, "DEPTH.HTML"), "wb") as fh:
    fh.write(page)
print("boot 02 fixture: SWATCH.QOI %d bytes (%dx%d), DEPTH.HTML %d bytes"
      % (len(out), W, H, len(page)))
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
# The oliver fixture: the pinned HTML this project's own Zig CLI emits, and the
# page ADR 0028 exists to display.
fixture = os.path.join("tests", "oliver-spike", "expect.html")
if not os.path.exists(fixture):
    sys.exit("oliver fixture missing at " + fixture)
shutil.copy(fixture, os.path.join(share, "OLIVER.HTML"))
for face in ("INTER.TTF", "FIRACODE.TTF"):
    p = os.path.join(share, face)
    if not os.path.exists(p):
        sys.exit("gate 01 needs the seeded face " + p)
print("staged WEB.ELF (%d bytes) + OLIVER.HTML + DEPTH.HTML; faces present: %s"
      % (os.path.getsize(os.path.join(share, "WEB.ELF")),
         ", ".join(sorted(f for f in os.listdir(share) if f.endswith(".TTF")))))
PY

# --- boot 01: the oliver fixture, in Inter -------------------------------
vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-01' \
    --script '$RUN_DIR/script-oliver.txt' \
    --snapshot-after "web: settled" \
    --snapshot-after "web: repaint" \
    --script-expect "web: ready" --timeout 120

# The pre-existing WEB.ELF markers must all still be there: this card adds
# typography, it does not change the browser's contract.
vgate_assert 01 serial-contains 'web: open id='
vgate_assert 01 serial-contains 'web: parse nodes='
vgate_assert 01 serial-contains 'web: layout blocks='
vgate_assert 01 serial-contains 'web: url /host/OLIVER.HTML'
vgate_assert 01 serial-contains 'web: paint items='
vgate_assert 01 serial-contains 'web: settled'
vgate_assert 01 serial-contains 'web: repaint items='
vgate_assert 01 serial-contains 'web: ready'
vgate_assert 01 serial-contains 'web: budget startup-ms='
vgate_assert 01 serial-absent 'web: budget over'
vgate_assert 01 serial-absent 'web: error'
vgate_assert 01 serial-absent '[EXC] parking:'

# The face actually loaded, and the engine is the proportional one.
vgate_assert 01 serial-contains 'web: fonts truetype(inter+firacode) ui=truetype mono=truetype'
vgate_assert 01 serial-absent 'web: fonts bitmap8x8'
# The measured facts. On the 8x8 fallback these are 8/8/8 and 10/18; on Inter
# they are 3/13/4 and 18/33. Asserted numerically, not by adjective.
vgate_assert 01 serial-contains 'web: text face=truetype(inter+firacode) proportional=yes'
vgate_assert 01 serial-contains ' body-lineh=18'
vgate_assert 01 serial-contains ' h1-lineh=33'
vgate_assert 01 serial-contains ' mono-lineh=17'
vgate_assert 01 serial-contains ' adv-i=3'
vgate_assert 01 serial-contains ' adv-W=13'
vgate_assert 01 serial-contains ' adv-space=4'
vgate_assert 01 serial-absent 'proportional=no'
vgate_assert 01 serial-absent 'adv-i=8'

# The pixel probe: measure the page's FIRST INKED BAND inside the content box.
# Inter: 20 rows tall, 294px wide. The 8x8 grid: 14 rows, 347px. Both directions
# are asserted, so neither "rendered something" nor "rendered the grid" passes.
vgate_assert 01 snapshot 'snap-01-*.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
w = 1280
X, Y = 40, 28            # the browser window origin on the scanout
CX, CY, CW, CH = 8, 50, 496, 322   # the content box, window-local
def px(x, y):
    k = (y * w + x) * 4
    return (data[k + 2], data[k + 1], data[k])
def near(c, want, tol=6):
    return all(abs(a - b) <= tol for a, b in zip(c, want))
PAGE_BG = (0x18, 0x20, 0x26)
ACCENT  = (0x3b, 0x82, 0xf6)

rows = []
for yy in range(CY, CY + CH):
    n = 0
    for xx in range(CX, CX + CW):
        if not near(px(X + xx, Y + yy), PAGE_BG, 12):
            n += 1
    rows.append(n)
first = -1
for i, n in enumerate(rows):
    if n > 0:
        first = i
        break
assert first >= 0, "the content box painted nothing at all"
last = first
while last < len(rows) and rows[last] > 0:
    last += 1
band_h = last - first
minx, maxx = None, None
for yy in range(CY + first, CY + last):
    for xx in range(CX, CX + CW):
        if not near(px(X + xx, Y + yy), PAGE_BG, 12):
            if minx is None or xx < minx:
                minx = xx
            if maxx is None or xx > maxx:
                maxx = xx
span = maxx - minx + 1
print("live-web-ttf 01: h1 band rows=[%d,%d) height=%d span=%d" % (first, last, band_h, span))

# The fixture's two links must be on screen, in the real face.
accent = 0
for yy in range(CY, CY + CH, 2):
    for xx in range(CX, CX + CW, 3):
        if near(px(X + xx, Y + yy), ACCENT, 8):
            accent += 1
print("live-web-ttf 01: link-accent px=%d" % accent)

fails = []
# An 8x8-grid h1 is 14 rows tall and 347px wide; Inter's is 20 rows and 294px.
if band_h < 17:
    fails.append("h1 band height %d (the 8x8 grid gives 14, Inter gives 20)" % band_h)
if span > 320:
    fails.append("h1 band span %d (the 8x8 grid gives 347, Inter gives 294)" % span)
if span < 200:
    fails.append("h1 band span %d is implausibly narrow" % span)
if accent < 10:
    fails.append("link accent pixels %d" % accent)
assert not fails, "WEB-TTF-FAILS: " + "; ".join(fails)
print("live-web-ttf 01 pixels ok: Inter h1 band, links present")
PY

# --- boot 02: layout depth (table + decoded QOI image + link) -------------
vgate_run 02 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-02' \
    --script '$RUN_DIR/script-depth.txt' \
    --snapshot-after "web: settled" \
    --snapshot-after "web: repaint" \
    --script-expect "web: ready" --timeout 120

vgate_assert 02 serial-contains 'web: url /host/DEPTH.HTML'
vgate_assert 02 serial-contains 'web: parse nodes='
vgate_assert 02 serial-contains 'web: settled'
vgate_assert 02 serial-contains 'web: repaint items='
vgate_assert 02 serial-contains 'web: ready'
vgate_assert 02 serial-contains 'web: fonts truetype(inter+firacode)'
vgate_assert 02 serial-absent 'web: error'
vgate_assert 02 serial-absent '[EXC] parking:'
vgate_assert 02 snapshot 'snap-02-*.raw' <<'PY'
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
RULE = (0x2e, 0x3a, 0x44)
ACCENT = (0x3b, 0x82, 0xf6)
SWATCH = [(0x11, 0x7f, 0x33), (0xd0, 0x33, 0x99), (0x22, 0x66, 0xdd), (0xee, 0xcc, 0x00)]
rule = accent = ink = 0
sw = [0, 0, 0, 0]
for yy in range(CY, CY + CH):
    for xx in range(CX, CX + CW):
        c = px(X + xx, Y + yy)
        if not near(c, PAGE_BG, 12):
            ink += 1
        if near(c, RULE, 6):
            rule += 1
        if near(c, ACCENT, 8):
            accent += 1
        for i, s in enumerate(SWATCH):
            if near(c, s, 2):
                sw[i] += 1
print("live-web-ttf 02: ink=%d table-rule=%d link-accent=%d swatch-quadrants=%s"
      % (ink, rule, accent, sw))
fails = []
if ink < 400:
    fails.append("the page painted only %d px" % ink)
if rule < 3:
    fails.append("table header rule px=%d (tables are ADR 0028 S2)" % rule)
if accent < 5:
    fails.append("link accent px=%d (links are S4)" % accent)
for i, n in enumerate(sw):
    if n < 100:
        fails.append("swatch quadrant %d had %d px: the QOI image did not decode" % (i, n))
assert not fails, "WEB-TTF-DEPTH-FAILS: " + "; ".join(fails)
print("live-web-ttf 02 ok: table rule, link accent, and all four decoded image colours on screen")
PY
# --- boot 03: the faces removed over the host file channel ----------------
vgate_run 03 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --snapshot-out '$RUN_DIR/snap-03' \
    --script '$RUN_DIR/script-nofont.txt' \
    --snapshot-after "web: settled" \
    --snapshot-after "web: repaint" \
    --script-expect "web: ready" --timeout 120

# The removal is proved by the app itself: it opened both share paths and found
# nothing, so its own report is `ui=missing mono=missing`. The transcript also
# echoes the removal commands, which is why the evidence is the engine report
# rather than a substring check on the listing.
# The fallback is announced, not hidden.
vgate_assert 03 serial-contains 'web: fonts bitmap8x8 ui=missing mono=missing'
vgate_assert 03 serial-contains 'web: text face=bitmap8x8 proportional=no'
vgate_assert 03 serial-contains ' adv-i=8'
vgate_assert 03 serial-contains ' adv-W=8'
vgate_assert 03 serial-contains ' h1-lineh=18'
vgate_assert 03 serial-absent 'proportional=yes'
# And the page still renders end to end: a missing font costs typography, never
# the page (this is the "never a silent blank page" rule, live).
vgate_assert 03 serial-contains 'web: parse nodes='
vgate_assert 03 serial-contains 'web: settled'
vgate_assert 03 serial-contains 'web: repaint items='
vgate_assert 03 serial-contains 'web: ready'
vgate_assert 03 serial-absent 'web: error'
vgate_assert 03 serial-absent '[EXC] parking:'

# The falsification: the SAME probe must now report the grid's numbers. If this
# boot passed boot 01's thresholds, boot 01's probe would be vacuous.
vgate_assert 03 snapshot 'snap-03-*.raw' <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
w = 1280
X, Y = 40, 28
CX, CY, CW, CH = 8, 50, 496, 322
def px(x, y):
    k = (y * w + x) * 4
    return (data[k + 2], data[k + 1], data[k])
PAGE_BG = (0x18, 0x20, 0x26)
def near(c, want, tol=6):
    return all(abs(a - b) <= tol for a, b in zip(c, want))
rows = []
for yy in range(CY, CY + CH):
    n = 0
    for xx in range(CX, CX + CW):
        if not near(px(X + xx, Y + yy), PAGE_BG, 12):
            n += 1
    rows.append(n)
first = -1
for i, n in enumerate(rows):
    if n > 0:
        first = i
        break
assert first >= 0, "the fallback painted nothing: a missing font blanked the page"
last = first
while last < len(rows) and rows[last] > 0:
    last += 1
band_h = last - first
minx, maxx = None, None
for yy in range(CY + first, CY + last):
    for xx in range(CX, CX + CW):
        if not near(px(X + xx, Y + yy), PAGE_BG, 12):
            if minx is None or xx < minx:
                minx = xx
            if maxx is None or xx > maxx:
                maxx = xx
span = maxx - minx + 1
print("live-web-ttf 03: fallback h1 band height=%d span=%d" % (band_h, span))
fails = []
if band_h > 16:
    fails.append("fallback band height %d is not the 8x8 grid's 14" % band_h)
if span < 335:
    fails.append("fallback band span %d is not the 8x8 grid's 347 (the probe would be vacuous)" % span)
if span > 360:
    fails.append("fallback band span %d is wider than the grid can produce" % span)
assert not fails, "WEB-TTF-FALLBACK-FAILS: " + "; ".join(fails)
print("live-web-ttf 03 ok: faces gone -> grid metrics, page still painted")
PY


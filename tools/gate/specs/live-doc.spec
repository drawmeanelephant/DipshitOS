# live-doc.spec -- M-web S1: DOC.BIN renders oliver HTML in-guest (issue #1202)
#
# One invocation per boot (the #1197 lesson). Each boot ends on a marker the
# PROGRAM prints (`doc: settled`), never on a script echo.
#
# M69d2 (#1536): boots 01 and 04 are the two halves of one claim about
# <strong>/<em>. DOC publishes its typography as FACTS — which faces loaded,
# the ink each weight paints, and how many pixels the Bold mask DISAGREES with
# the 1-px strike the old fallback drew — because Inter matches advances across
# weights, so nothing about width can tell the weights apart. Boot 01 asserts
# the real faces (a Regular-only build fails there by design, card D2); boot 04
# removes INTERB/INTERI from the share after boot 03 and asserts the probe
# reports the fallback instead (`diff=0`, bold ink == strike ink) and the page
# still settles. Without boot 04 a `diff>0` in boot 01 could be measuring
# nothing.

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
# M69d2 (#1536): the real Bold/Italic faces, and the numbers that separate them
# from the synthetic emphasis this path used to draw. The relations live in the
# python assert below; these two lines are the faces themselves.
vgate_assert 01 serial-contains 'typography: Inter Bold TrueType font loaded'
vgate_assert 01 serial-contains 'typography: Inter Italic TrueType font loaded'
vgate_assert 01 serial-absent 'typography: Inter Italic absent'
vgate_assert 01 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
faces = re.search(r"typography: faces ui=(\d) bold=(\d) italic=(\d) mono=(\d)", ser)
if not faces:
    sys.exit("FAIL: DOC published no `typography: faces` line")
ui_f, bold_f, ital_f, mono_f = (int(x) for x in faces.groups())
if not (ui_f and mono_f):
    sys.exit("FAIL: ui/mono faces missing: " + faces.group(0))
# Card D2: Regular-only must NOT pass. The Bold face is what retires the 1-px
# double strike, so its absence is a failed card, not a silent fallback.
if not bold_f:
    sys.exit("FAIL: no Bold face -- <strong> is the synthetic double strike (D2)")
# The share stages INTERI.TTF (image/fonts, M69d #1531), so its absence here is
# a staging failure rather than a design choice.
if not ital_f:
    sys.exit("FAIL: no Italic face though the share stages INTERI.TTF")
ink = {int(m[0]): tuple(int(x) for x in m[1:])
       for m in re.findall(r"typography: ink n@(\d+) regular=(\d+) bold=(\d+) strike=(\d+) diff=(\d+)", ser)}
for want in (14, 24):
    if want not in ink:
        sys.exit("FAIL: DOC published no `typography: ink` line at %d px" % want)
# Card D2's real question, at both sizes.
for size, (reg, bold, strike, diff) in sorted(ink.items()):
    if bold <= reg:
        sys.exit("FAIL: at %d px bold ink %d <= regular %d -- the weight is not "
                 "reaching the face" % (size, bold, reg))
    # The claim as a number: the Bold face's mask is NOT the strike that doubles
    # Regular. A regular-only build publishes diff=0 (boot 04 proves it).
    if diff <= 0:
        sys.exit("FAIL: at %d px the Bold mask agrees with the 1-px strike everywhere "
                 "(diff=%d): this IS the double-strike story" % (size, diff))
# 14 px is DOC's body size and the awkward one: the old strike lands within a
# couple of pixels of the real face there, so the weights are also held apart at
# a heading size, where they separate by tens of pixels.
if ink[24][1] <= ink[24][2]:
    sys.exit("FAIL: at 24 px the Bold face (%d ink px) is not heavier than the "
             "strike that doubles Regular (%d)" % (ink[24][1], ink[24][2]))
skew = re.search(r"typography: skew l@(\d+) roman=(-?\d+) italic=(-?\d+)", ser)
if not skew:
    sys.exit("FAIL: DOC published no `typography: skew` line")
sz, roman, italic = (int(x) for x in skew.groups())
# A leaning stem's ink centre moves LEFT as it descends (negative); an upright
# one is ~0. Both are the SAME glyph, so this is about the lean, not the shape.
if not (abs(roman) <= 8):
    sys.exit("FAIL: Roman 'l' is not upright: skew=%d sixteenths" % roman)
if not (italic < roman - 8):
    sys.exit("FAIL: Italic 'l' is not leaning: skew=%d vs Roman %d sixteenths" % (italic, roman))
print("typography: 14 px bold %d > regular %d, mask differs from the strike in %d px; "
      "24 px bold %d > strike %d (diff %d); Italic 'l' leans %d/16 px vs Roman %d"
      % (ink[14][1], ink[14][0], ink[14][3], ink[24][1], ink[24][2], ink[24][3],
         italic, roman))
PY
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

# --- M69d2 (#1536) negative control: the fallback, asserted as itself ---
#
# Runs AFTER the three boots that need the real faces, and it is what makes
# boot 01's `diff>0` mean something: with Bold gone the probe has to report the
# strike honestly (bold ink == strike ink, diff == 0, Italic absent) while the
# page still renders and still settles. A probe that could not tell the two
# apart would pass both boots and prove neither.
vgate_assert 03 python <<'PY'
import os
share = os.environ.get("VG_SHARE") or os.path.join(os.environ["RUN_DIR"], "share")
for name in ("INTERB.TTF", "INTERI.TTF"):
    p = os.path.join(share, name)
    if os.path.exists(p):
        os.remove(p)
        print("negative control: removed %s from the share for boot 04" % name)
PY

vgate_run 04 -- \
    --screen '$RUN_DIR/screen' \
    --via-virtio --cvc-snap \
    --script '$RUN_DIR/script-01.txt' \
    --script-expect "doc: settled" --timeout 120

vgate_assert 04 serial-contains 'typography: Inter TrueType font loaded'
vgate_assert 04 serial-absent 'typography: Inter Bold TrueType font loaded'
vgate_assert 04 serial-absent 'typography: Inter Italic TrueType font loaded'
vgate_assert 04 serial-contains 'typography: Inter Italic absent, em keeps accent'
vgate_assert 04 serial-contains 'doc: layout blocks='
vgate_assert 04 serial-contains 'doc: settled'
vgate_assert 04 serial-absent 'doc: error'
vgate_assert 04 serial-absent '[EXC] parking:'
vgate_assert 04 serial-absent 'exited status=139'
vgate_assert 04 python <<'PY'
import os, re, sys
ser = open(os.environ["VG_SER"], errors="replace").read()
faces = re.search(r"typography: faces ui=(\d) bold=(\d) italic=(\d) mono=(\d)", ser)
if not faces:
    sys.exit("FAIL: no `typography: faces` line without the weight faces")
ui_f, bold_f, ital_f, mono_f = (int(x) for x in faces.groups())
if bold_f or ital_f or not (ui_f and mono_f):
    sys.exit("FAIL: the probe did not report the faces it actually has: " + faces.group(0))
ink = {int(m[0]): tuple(int(x) for x in m[1:])
       for m in re.findall(r"typography: ink n@(\d+) regular=(\d+) bold=(\d+) strike=(\d+) diff=(\d+)", ser)}
if len(ink) < 2:
    sys.exit("FAIL: no `typography: ink` lines without the weight faces")
for size, (reg, bold, strike, diff) in sorted(ink.items()):
    if bold != strike:
        sys.exit("FAIL: at %d px the bold number must BE the strike with no Bold face: "
                 "bold=%d strike=%d" % (size, bold, strike))
    if diff != 0:
        sys.exit("FAIL: at %d px the fallback's mask must equal the strike's (diff=%d)"
                 % (size, diff))
    if bold <= reg:
        sys.exit("FAIL: even the fallback has to be heavier than Regular: %d vs %d"
                 % (bold, reg))
print("fallback: bold==strike ink at 14 px (%d) and 24 px (%d), diff 0 both -- the same "
      "probe that reads the real face reads the double strike" % (ink[14][1], ink[24][1]))
PY

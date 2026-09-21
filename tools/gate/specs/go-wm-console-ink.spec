# go-wm-console-ink.spec -- M71b (#1561) class-B gate: while the default Go
# seat owns the scanout, the region no window covers is the SEAT's chrome --
# not kernel console ink.
#
# docs/testing.md has carried this as an explicitly unasserted observation
# since M69b (#1529): "kernel console text (`ks worker advances=…`) is on the
# scanout wherever no window covers it, growing with how long the boot has run
# (~2.8% of sampled pixels at 3 s, ~5.8% at 20 s in the web boot; none in the
# hero boot). The M69a beat asserts serial markers, so neither is visible to
# it."  M71a (#1560) proved the first half of that paragraph stale; this spec
# closes the gap for the second half, in the direction the card's D1 states:
# **seat paint is the source of truth for uncovered pixels**.
#
# MEASUREMENT (2026-09-21, first run of this spec on current main, macOS 27.2
# / arm64, VZ): in a default-Go-seat boot with a GOSH tab OPEN (so the seat is
# in its rail-only paint mode, user/go/gotabwm/seat.go: only `tab.Count() == 0`
# paints the full scanout) and the kernel printing its own console output while
# the seat was registered (`tasks worker advances=1600` reaches the serial log
# AFTER `gotabwm: registered`), the captured frame's uncovered region held
#
#     sampled=614400  ink=6702 (1.091%)  green-family=0 (0.000%)
#
# and every one of those 6702 "ink" pixels was the capture's own 6-pixel edge
# border (x 0..5 and 2554..2559, full height) -- the interior was uniform
# background.  So the M69b console-leak observation does NOT reproduce here;
# the kernel console's ink (kernel/src/text.zig `fg_rgb = 0x00ff00`) does not
# reach the seat's pixels today.  This spec asserts that invariant so a
# regression -- or a configuration where it does not hold -- fails loudly.
#
# What this gate therefore holds, and what it does not:
#   * HOLDS: with the default seat live and a tab hosted, every pixel the seat
#     does not cover is the seat's own background fill, and the kernel's
#     terminal-family ink is absent from it.  The rail band is asserted
#     NON-empty first, so a blank/failed capture cannot pass by being empty.
#   * DOES NOT (yet) hold: the same question in the WEB boot, which is where
#     the M69b numbers (3 s / 20 s, ~2.8% / ~5.8%) were measured.  That boot
#     is live-web.spec (12 runs) and was not re-measured here; the card names
#     it as the remaining configuration, and this probe is the instrument for
#     it.
#   * The kernel-side paths that *could* put ink there are still ungated --
#     shell.zig:3894 `road_pops.drain()` and main.zig:77 `rp_text_present`
#     both call driving_award.composite() with no `wm_server.registered()`
#     check, unlike the clock composite two lines later (shell.zig:3904).
#     Today the seat's own paint wins anyway; that is what this gate pins.
#
# One boot, one capture: seat the DEFAULT Go WM (no `wm` setting), host
# GOSH.ELF in a tab, drive kernel console output through the monitor (`tasks`
# prints the per-task advances= report on mon.console -> the Road Pops tee),
# and capture right after the script's own closing marker.
#
# HOST PREREQUISITE (fails the gate honestly when missing):
#   bash tools/go/build-gotabwm.sh   ->  .build/go/GOTABWM.ELF
#   bash tools/go/build-gosh.sh      ->  .build/go/GOSH.ELF

vgate_name go-wm-console-ink "M71b (#1561): a seated scanout carries the seat's chrome, not kernel console ink"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE

vgate_setup_python <<'PY'
import os, shutil, sys
rd = os.environ["RUN_DIR"]
share = os.environ.get("VG_SHARE") or os.path.join(rd, "share")
for name in ("GOTABWM.ELF", "GOSH.ELF"):
    src = os.path.join(".build", "go", name)
    if not os.path.exists(src):
        sys.exit(name + " missing (expected " + src + ") - build it first: "
                 "bash tools/go/build-gotabwm.sh / build-gosh.sh")
    shutil.copy(src, os.path.join(share, name))
    print("staged %s into share (%d bytes)" % (name, os.path.getsize(src)))
# The DEFAULT seat is the compiled default; a persisted `wm` setting would
# test the setting instead of the flip (the go-wm-default boot-01 rule).
if os.path.exists(os.path.join(share, "SETTINGS.TXT")):
    sys.exit("SETTINGS.TXT present in the seed share; this boot must run on "
             "the compiled default seat")
PY

# Stage 1: seat the default Go desktop and host GOSH.ELF in a tab.
vgate_file script.txt <<'EOF'
exec GOSH.ELF
EOF

# Stage 2: the tab is open (GOSH's own prompt is up), so the seat is in its
# rail-only paint mode. Now make the KERNEL print console output through the
# tee -- `tasks` is the monitor's per-task advances= report -- and close with a
# script-owned marker that both ends the run and triggers the capture.
vgate_file script2.txt <<'EOF'
tasks
echo rx-console-ink-probe
EOF

vgate_run 01 -- \
    --screen '$RUN_DIR/screen' \
    --script '$RUN_DIR/script.txt' \
    --script-after 'gotabwm: holding seat' \
    --script2 '$RUN_DIR/script2.txt' \
    --script2-after 'gosh: prompt' \
    --script-expect 'rx-console-ink-probe' \
    --screenshot-after 'rx-console-ink-probe' --timeout 240

# The precondition: the seat really is up and owning the scanout.
vgate_assert 01 serial-contains 'wm: autostart gotabwm'
vgate_assert 01 serial-contains 'gotabwm: registered'
vgate_assert 01 serial-contains 'gotabwm: scanout'
vgate_assert 01 serial-contains 'gotabwm: draw'
vgate_assert 01 serial-contains 'gotabwm: present'
# A tab is hosted, so the seat paints only its rail band.
vgate_assert 01 serial-contains 'gotabwm: tab open id='
vgate_assert 01 serial-contains 'gosh: prompt'
# The kernel printed its OWN console output while the seat owned the scanout:
# the per-task advances report comes from the monitor, i.e. through the tee.
vgate_assert 01 serial-contains 'tasks '
vgate_assert 01 serial-contains 'advances='
vgate_assert 01 serial-contains 'rx-console-ink-probe'
vgate_assert 01 serial-absent '[EXC] parking:'

# The measurement, asserted.  The capture is a 2x-scaled window capture, so
# the scanout's own edge is not the window's edge: sample the interior only
# (a 12-pixel margin) and ignore the capture's own border.
vgate_assert 01 snapshot 'screen-*' <<'PY'
import sys, zlib, struct
path = sys.argv[1]
d = open(path, 'rb').read()
assert d[:8] == b'\x89PNG\r\n\x1a\n', "not a PNG"
pos = 8; idat = b''; w = h = ct = 0
while pos < len(d):
    ln, typ = struct.unpack('>I4s', d[pos:pos+8])
    data = d[pos+8:pos+8+ln]
    if typ == b'IHDR':
        w, h, bd, ct = struct.unpack('>IIBB', data[:10])
    elif typ == b'IDAT':
        idat += data
    pos += 12 + ln
raw = zlib.decompress(idat)
bpp = 4 if ct == 6 else 3
stride = w * bpp
out = bytearray(); prev = bytearray(stride); i = 0
for y in range(h):
    f = raw[i]; i += 1
    line = bytearray(raw[i:i+stride]); i += stride
    if f == 1:
        for x in range(bpp, stride): line[x] = (line[x] + line[x-bpp]) & 0xff
    elif f == 2:
        for x in range(stride): line[x] = (line[x] + prev[x]) & 0xff
    elif f == 3:
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0
            line[x] = (line[x] + ((a + prev[x]) >> 1)) & 0xff
    elif f == 4:
        for x in range(stride):
            a = line[x-bpp] if x >= bpp else 0
            b = prev[x]; c = prev[x-bpp] if x >= bpp else 0
            p = a + b - c
            pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
            pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
            line[x] = (line[x] + pr) & 0xff
    out += line
    prev = line

def px(x, y):
    k = (y * w + x) * bpp
    return out[k], out[k+1], out[k+2]

def ink(rgb):
    return max(rgb) >= 100  # the seat's fill is dark; anything brighter is ink

def console_ink(rgb):
    # kernel/src/text.zig fg_rgb = 0x00ff00, observed through the host
    # pipeline as a green family (live-roadpops.spec uses the same test).
    r, g, b = rgb
    return g > 150 and r < 160 and b < 160

MARGIN = 12
STEP = 2

# 1. The capture is live: the seat's rail band (its top strip) is NOT empty.
rail_ink = rail_tot = 0
for y in range(MARGIN, h // 8, STEP):
    for x in range(MARGIN, w - MARGIN, STEP):
        rail_tot += 1
        if ink(px(x, y)):
            rail_ink += 1
print("rail band: sampled=%d ink=%d (%.3f%%)" % (rail_tot, rail_ink, 100.0*rail_ink/rail_tot))
if rail_ink == 0:
    sys.exit("FAIL: the rail band is empty -- the seat painted nothing, so an "
             "empty uncovered region would prove nothing")

# 2. The uncovered region: no window covers it, so it is the seat's chrome.
tot = interior = green = 0
for y in range(h // 3, h - MARGIN, STEP):
    for x in range(MARGIN, w - MARGIN, STEP):
        rgb = px(x, y)
        tot += 1
        if ink(rgb):
            interior += 1
            if console_ink(rgb):
                green += 1
print("uncovered region: sampled=%d ink=%d (%.3f%%) console-green=%d (%.3f%%)"
      % (tot, interior, 100.0*interior/tot, green, 100.0*green/tot))
if green:
    sys.exit("FAIL: %d console-ink pixels on the scanout the seat owns -- the "
             "kernel's console is painting into pixels no window covers "
             "(M71b #1561; see the kernel paths named in this spec's header)" % green)
if interior:
    sys.exit("FAIL: %d non-background pixels in the region no window covers -- "
             "expected the seat's own blank-desktop fill to own every pixel "
             "there (M71b #1561 D1)" % interior)
print("PASS: the seat owns every uncovered pixel and no kernel console ink is on the scanout")
PY

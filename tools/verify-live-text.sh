#!/usr/bin/env bash
#
# verify-live-text.sh -- claim 3194 (milestone six, card G2) class-B gate:
# FRAMEBUFFER TEXT observed end to end on real VZ — the machine now boots
# to WORDS on the screen, painted by kernel/src/text.zig (the fixed BSS
# 8x8 bitmap font) on top of G1's virtio-gpu framebuffer.
#
# Mechanism: the runner's `--display`/`--screenshot` flag (OFF by default —
# the default VM is untouched) attaches ONE VZVirtioGraphicsDeviceConfiguration
# with a 1280x720 scanout. The guest boots, G1's virtio_gpu.zig sets up the
# transport + framebuffer (DID 0x1050, virtio-gpu 1.2 display_info, B8G8R8X8
# resource, post-exit re-arm — all claim-6053 observations), and G2's
# text.zig paints the SAME banner + prompt the serial log carries:
#   "DipshitOS - AArch64 firmware-assisted kernel monitor"
#   "DipshitOS: terminal loop, meet the monitor."
#   "Type 'help' before touching anything expensive."
#   "dipshit> "
# (fg 0x00ff00 over bg 0x101418), then G1's transfer/flush pushes it to the
# scanout.
#
# Phase 1 (shared-seam serial evidence): assert the transport report lines
# (pre-rearm st=00 — the claim-time reset-at-ExitBootServices observation),
# "text: boot banner presented", the `text` command's report
# (rows=90 cols=160 cell=8x8 cur=3,9 lines=4 fg/bg), and that the serial
# transcript still carries the banner lines themselves — the machine STILL
# boots to a terminal on serial.
# Phase 2 (the pixel proof — the milestone's headline): the host decodes the
# captured PNG (2560x1440 — the view's retina backing for the 1280x720
# window) and asserts the frame shows TEXT, not the G1 solid fill and not
# black:
#   (a) the banner region (the top ~4 glyph rows) contains BOTH foreground
#       pixels (green family — the observed color-managed shift of
#       0x00ff00 -> ~(117,251,76)) AND dark background pixels (0x101418),
#       with the background dominant (glyphs are sparse) — the frame is no
#       longer monochrome;
#   (b) a region far below the text is background — the rest of the screen
#       is the dark fill, not garbage.
# Honest bound (the G1 gate's precedent): byte-exact glyph shapes are
# asserted in the class A mock (the golden-glyph canvas tests in text.zig);
# the LIVE pixels are color-managed + retina-scaled, so the live assertion
# is "text is visible in the expected region with the expected color
# family", not per-glyph equality.
#
# Honesty: the runner exits 0 when the scripted run completes; the gate
# asserts every transcript line AND decodes the PNG itself (no pixel
# assertions hidden in the runner). Evidence under artifacts/: live-text-*
# (runner output, serial copies, the report) + gpu-screen-*s.png (the
# captures).
#
# Class B — Apple silicon + VZ only; boots real VMs. A green CI badge
# proves class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-text.sh
#
# Evidence: artifacts/live-text-gate.txt (full output),
# artifacts/live-text-report.txt (per-phase detail).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-text-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

REPORT="artifacts/live-text-report.txt"
RUNNER="host/vm-runner/.build/release/VMRunner"

echo "=== verify-live-text: claim 3194 — framebuffer text (BSS 8x8 font, banner painted on G1's scanout, first words on the screen) ==="

# 1. Build the runner + the disk image (the kernel carries text.zig).
echo
echo "[1/3] building the runner + disk image"
swift build --package-path host/vm-runner --configuration release >/dev/null 2>&1
# The other live gates' convention: the fresh binary needs the
# com.apple.security.virtualization entitlement before it can boot a VM.
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner
zig build >/dev/null 2>&1
zig build image >/dev/null 2>&1

# 2. The scripted boot: the `text` command reports the layer AFTER the
# boot banner painted it (the banner itself is the painted evidence).
SCRIPT="artifacts/live-text-script.txt"
printf 'text\n' > "$SCRIPT"
rm -f artifacts/vm-serial.log artifacts/gpu-screen-*.png "$REPORT"

echo
echo "[2/3] live VZ run (scripted)"
set +e
"$RUNNER" artifacts/disk.img artifacts/vm-serial.log \
    --screen artifacts/gpu-screen --script "$SCRIPT" \
    --expect "text: boot banner presented" --timeout 30 \
    > artifacts/live-text-run.txt 2>&1
RC=$?
set -e
echo "runner exit: $RC"
echo "--- runner output (text/gpu lines) ---"
grep -E "gpu:|text:|SUCCESS|FAILURE" artifacts/live-text-run.txt | head -40
if [ "$RC" -ne 0 ]; then
    echo "FAIL: runner did not complete successfully (exit $RC)"
    exit 1
fi

# 3. Assertions.
echo
echo "[3/3] asserting the serial transcript + the captured pixels"

fail() { echo "FAIL: $1"; exit 1; }

# Phase 0 — the evidence path: the capture must be the COMPOSITED WINDOW
# (ScreenCaptureKit), not the cacheDisplay offscreen render. The SCK
# switch (2026-08-12) exists so the gate's pixel evidence is
# pixel-identical to the live `--display` window; the runner prints which
# path produced each capture. Require the SCK line and forbid the
# fallback line — a single fallback capture means the decoded PNG is not
# what the operator sees.
grep -q "capture path: ScreenCaptureKit" artifacts/live-text-run.txt \
    || fail "pixel evidence did not come from ScreenCaptureKit (composited window) — Screen Recording permission missing or the SCK path broke"
if grep -q "capture path: cacheDisplay fallback" artifacts/live-text-run.txt; then
    fail "some captures fell back to cacheDisplay (offscreen render) — every capture must be the composited window"
fi

# Phase 1 — the shared-seam serial evidence (the machine still boots to a
# terminal on serial AND paints the same words on the screen).
grep -q "gpu: pre-rearm st=00" artifacts/vm-serial.log || fail "missing pre-rearm st=00 (the claim-time reset-at-ExitBootServices observation)"
grep -q "text: boot banner presented" artifacts/vm-serial.log || fail "boot banner was not presented to the framebuffer"
# Since G3 (Road Pops), the echoed session + replies land in the text
# ring, so the report's cur/lines are session-dependent (it even reflects
# its own output progress mid-print) — the STABLE parts are the region,
# the cell, and the fg/bg colors, which is what G2 proves.
grep -q "text: rows=90 cols=160 cell=8x8" artifacts/vm-serial.log || fail "the text report does not show the 90x160 region with 8x8 cells"
grep -q "text: rows=90 cols=160 cell=8x8 .*fg=0x000000000000ff00 bg=0x0000000000101418" artifacts/vm-serial.log || fail "the text report does not show the G2 fg/bg colors"
grep -q "DipshitOS - AArch64 firmware-assisted kernel monitor" artifacts/vm-serial.log || fail "serial transcript lost the banner (shared-seam regression)"
grep -q "dipshit> " artifacts/vm-serial.log || fail "serial transcript lost the prompt (shared-seam regression)"

# Phase 2 — the pixel proof: decode the captured PNG and assert TEXT.
# The runner writes `--screen <base>` captures as <base>-Ns (no extension).
LATEST="$(ls -t artifacts/gpu-screen-*s 2>/dev/null | head -1 || true)"
if [ -z "$LATEST" ]; then
    fail "no gpu-screen PNG captured"
fi
echo "decoding $LATEST"
python3 - "$LATEST" <<'EOF'
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
    return out[k], out[k+1], out[k+2]  # r, g, b

def is_fg(rgb):
    r, g, b = rgb
    return g > 150 and r < 160 and b < 160  # the observed shift of 0x00ff00

def is_bg(rgb):
    return max(rgb) < 100  # 0x101418 stays dark through the pipeline

# Region A — the banner: the top 4 glyph rows (8px cells) + margin, and the
# banner's column span (the longest line is ~54 chars -> ~432px at 8px/char;
# sample generously to 1024px).
fg = bg = 0; total = 0
for y in range(0, 48, 4):
    for x in range(0, 1024, 4):
        rgb = px(x, y)
        total += 1
        if is_fg(rgb): fg += 1
        elif is_bg(rgb): bg += 1
fg_frac = fg / total if total else 0
bg_frac = bg / total if total else 0
print(f"banner region: sampled={total} fg={fg} ({fg_frac:.3f}) bg={bg} ({bg_frac:.3f})")
if fg_frac < 0.01:
    sys.exit("FAIL: no foreground (green-family) pixels in the banner region — no text painted")
if bg_frac < 0.5:
    sys.exit("FAIL: the banner region is not background-dominated — the frame looks like a solid fill, not text")
if fg_frac > 0.5:
    sys.exit("FAIL: the banner region is mostly foreground — implausible for sparse 8x8 glyphs")

# Region B — far below the text (bottom of the frame): must be the dark
# background fill, proving the rest of the screen is not garbage/solid.
dbg = 0; dtotal = 0
for y in range(h - 96, h, 8):
    for x in range(0, w, 16):
        rgb = px(x, y)
        dtotal += 1
        if is_bg(rgb): dbg += 1
dbg_frac = dbg / dtotal if dtotal else 0
print(f"lower region: sampled={dtotal} bg={dbg} ({dbg_frac:.3f})")
if dbg_frac < 0.9:
    sys.exit("FAIL: the region below the text is not the background fill")

print("PASS: the captured frame shows text (foreground glyphs over the dark background) in the banner region")
EOF
if [ $? -ne 0 ]; then
    fail "captured framebuffer does not show text (black, solid fill, or garbage)"
fi

echo
echo "=== verify-live-text: PASS (the machine boots to words on the screen — banner on serial AND on the framebuffer) ==="
echo "evidence: artifacts/live-text-run.txt, artifacts/vm-serial.log, artifacts/gpu-screen-*.png" | tee "$REPORT"

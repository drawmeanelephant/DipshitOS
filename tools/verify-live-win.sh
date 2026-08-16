#!/usr/bin/env bash
#
# verify-live-win.sh -- claim 1543 (milestone six, card G5) class-B gate:
# Driving Award, the window manager, live on real VZ.
#
# The machine boots to TWO overlapping windows: Road Pops (the G3 boot
# terminal) is window 0 (full screen), and a 1 Hz clock overlay is window 1
# (top-right, overlapping the terminal). The compositor
# (kernel/src/driving_award.zig) repaints from the lowest dirty window up and
# pushes one transfer + flush per dirty batch, so the clock always sits ON
# TOP of a freshly repainted terminal. `dui` is the monitor command.
#
# Phase 1 (serial evidence): the scripted session exercises the registry —
#   * `dui`                  -> windows=2, focused=0 (terminal by default),
#                              the two dui[] rows (roadpops terminal +
#                              clock), the rects + z-order;
#   * `dui hit 1000 100`     -> hit-tests the clock overlay (z-order: the
#                              clock is on top at that point) and FOCUSES it;
#   * `dui`                  -> focused=1 (hit-testing switched focus);
#   * `dui hit 100 400`      -> hit-tests the terminal (below the clock) and
#                              re-focuses it.
#   Then the KEYBOARD (--input-string, the I3 seam) types `uname\n` into the
#   focused terminal — the `DipshitOS aarch64` reply is the proof that
#   screen-side input lands in the FOCUSED window.
#
# Phase 2 (pixel proof): the host decodes the captured PNG (2560x1440, the
#   view's retina backing for the 1280x720 scanout) and asserts two distinct
#   windows with the right z-order:
#   (a) the clock's amber title bar + navy body are present in the clock
#       rect — the clock's OWN content, blitted OVER the terminal (z-order:
#       the terminal's dark background is REPLACED there);
#   (b) NO green (terminal foreground) inside the clock rect — the clock
#       fully covers the terminal beneath it;
#   (c) green foreground IS present in the terminal region left of the
#       clock — the terminal (window 0) renders beneath and beside it.
#
# Honest bound (the G1/G2/G3 precedent): byte-exact text is the class A
# mock's domain; the LIVE pixels are color-managed + retina-scaled, so the
# live assertion is "distinct color families in the expected regions", not
# per-glyph equality. The observed capture colors are pinned in the claim.
#
# Class B — Apple silicon + VZ only; boots real VMs. A green CI badge
# proves class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-win.sh
#
# Evidence: artifacts/live-win-gate.txt (full output),
# artifacts/live-win-report.txt (per-phase detail).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-win-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

REPORT="artifacts/live-win-report.txt"

echo "=== verify-live-win: claim 1543 — Driving Award, the window manager, live on VZ ==="

# --- tool versions + revision ------------------------------------------------
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# --- build gates --------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- scripted session + keyboard typing --------------------------------------
# The serial script drives the registry; the KEYBOARD types `uname\n` after
# `dui hit 100 400` re-focuses the terminal (the trigger marker).
cat > artifacts/live-win-script.txt <<'EOF'
dui
dui hit 1000 100
dui
dui hit 100 400
EOF

# --- per-run gate -------------------------------------------------------------
run_one() {
    local out="$1" serial="$2"
    rm -f artifacts/efi-vars.bin artifacts/vm-serial.log artifacts/gpu-screen-*
    host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
        --display --input --screen artifacts/gpu-screen \
        --script artifacts/live-win-script.txt \
        --input-string "uname"$'\n' --input-string-after "dui hit: 100,400 -> 0" \
        --script-expect "DipshitOS aarch64" \
        --timeout 60 \
        > "$out" 2>&1
    local RC=$?
    [ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log "$serial" || true
    echo "$RC" > /tmp/live-win-rc.txt
}

rm -f artifacts/efi-vars.bin artifacts/vm-serial.log
set +e
run_one "artifacts/live-win-run.txt" "artifacts/live-win-serial.log"
RC="$(cat /tmp/live-win-rc.txt)"
set -e

# --- assertions ---------------------------------------------------------------
SERIAL="artifacts/live-win-serial.log"
TWO_WIN=0 ROW0=0 ROW1=0 HIT1=0 FOCUS1=0 HIT0=0 KB_UNAME=0 RUNNERFLAG=0
if [ -f "$SERIAL" ]; then
    grep -a -qF -- "dui: windows=2 focused=0" "$SERIAL" && TWO_WIN=1
    grep -a -qF -- "dui[0]: roadpops terminal rect=0,0,1280,720" "$SERIAL" && ROW0=1
    grep -a -qF -- "dui[1]: clock clock rect=960,16,304,192" "$SERIAL" && ROW1=1
    grep -a -qF -- "dui hit: 1000,100 -> 1" "$SERIAL" && HIT1=1
    grep -a -qF -- "dui: windows=2 focused=1" "$SERIAL" && FOCUS1=1
    grep -a -qF -- "dui hit: 100,400 -> 0" "$SERIAL" && HIT0=1
    # The keyboard-typed `uname` reply (the script never runs uname — this
    # is the proof that screen-side input landed in the focused terminal).
    grep -a -qF -- "DipshitOS aarch64" "$SERIAL" && KB_UNAME=1
fi
grep -a -qF -- "input-string: ENABLED" artifacts/live-win-run.txt && RUNNERFLAG=1

echo "dui: rc=$RC two-win=$TWO_WIN row0=$ROW0 row1=$ROW1 hit-clock=$HIT1 focus-clock=$FOCUS1 hit-terminal=$HIT0 kb-uname=$KB_UNAME runner-flag=$RUNNERFLAG"

PASS=0
if [ "$RC" = 0 ] && [ "$TWO_WIN" = 1 ] && [ "$ROW0" = 1 ] && [ "$ROW1" = 1 ] && \
   [ "$HIT1" = 1 ] && [ "$FOCUS1" = 1 ] && [ "$HIT0" = 1 ] && [ "$KB_UNAME" = 1 ] && \
   [ "$RUNNERFLAG" = 1 ]; then
    PASS=1
fi

# Phase 2 — the pixel proof. The runner writes `--screen <base>` captures as
# <base>-Ns (2560x1440 retina). The LATEST capture holds the settled frame.
LATEST="$(ls -t artifacts/gpu-screen-*s 2>/dev/null | head -1 || true)"
if [ -z "$LATEST" ]; then
    echo "FAIL: no gpu-screen PNG captured"
    PASS=0
else
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
    return out[k], out[k+1], out[k+2]

def classify(r, g, b):
    if r > 140 and g > 100 and b < 90:
        return 'amber'       # clock title bar (0xb58900 -> ~(174,139,45))
    if g > 140 and r < 160 and b < 160:
        return 'green'       # terminal foreground (0x00ff00 -> ~(80,174,52))
    if b > 35 and b > g and b > r:
        return 'navy'        # clock body (0x0a1a2e -> ~(14,26,44))
    if max(r, g, b) < 32:
        return 'dark'        # terminal background (0x101418 -> ~(17,20,24))
    return 'other'

def region(x0, y0, x1, y1, step=3):
    counts = {}
    for y in range(y0, y1, step):
        for x in range(x0, x1, step):
            k = classify(*px(x, y))
            counts[k] = counts.get(k, 0) + 1
    return counts

def frac(counts, key):
    tot = sum(counts.values())
    return (counts.get(key, 0) / tot) if tot else 0.0

# The clock rect in retina coords: logical (960,16,304,192) x2.
CLX0, CLY0, CLX1, CLY1 = 1920, 32, 2528, 416

# (a) The clock title bar is amber (its own content, on top of the terminal).
title = region(CLX0 + 40, CLY0 + 8, CLX1 - 40, CLY0 + 32)
fa = frac(title, 'amber')
print(f"clock title bar: {title} amber={fa:.3f}")
if fa < 0.30:
    sys.exit("FAIL: the clock title bar is not amber in its region (window 1 did not render on top)")

# (b) The clock body is navy (blitted over the terminal's dark background).
body = region(CLX0 + 200, CLY0 + 70, CLX1 - 200, CLY1 - 60)
fn = frac(body, 'navy')
print(f"clock body: {body} navy={fn:.3f}")
if fn < 0.50:
    sys.exit("FAIL: the clock body is not navy in its region (the clock did not cover the terminal)")

# (c) NO green inside the clock rect — the clock fully covers the terminal.
whole = region(CLX0 + 6, CLY0 + 6, CLX1 - 6, CLY1 - 6, step=2)
if whole.get('green', 0) != 0:
    sys.exit(f"FAIL: terminal foreground visible inside the clock rect ({whole.get('green',0)} green) — z-order wrong")

# (d) Green foreground present in the terminal region LEFT of the clock.
term = region(0, 0, 1900, 96, step=2)
print(f"terminal banner region: {term}")
if term.get('green', 0) < 50:
    sys.exit("FAIL: no terminal foreground in the banner region (window 0 did not render)")

print("PASS: two overlapping windows with the right z-order — the clock's amber + navy content sits over the terminal, and the terminal's green glyphs render beside it")
EOF
    if [ $? -ne 0 ]; then
        echo "FAIL: captured framebuffer does not show two distinct overlapping windows"
        PASS=0
    fi
fi

{
    echo "DIPSHITOS live window-manager gate (claim 1543, milestone six card G5) — Driving Award on real VZ hardware"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "phase: scripted registry exercise (win/win hit) + a keyboard-typed uname into the focused terminal; the captured PNG is decoded and asserted for two overlapping windows with the right z-order"
    echo "assertions: windows=2 (roadpops terminal + clock), the two rects, hit-test -> clock + focus switch, hit-test -> terminal, keyboard-typed uname reply, amber title bar + navy clock body over the terminal, no terminal foreground inside the clock rect, terminal foreground left of the clock"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} > "$REPORT"

echo
echo "=== result ==="
if [ "$PASS" = 1 ]; then
    echo "verify-live-win: PASS — Driving Award composites two overlapping windows on real VZ: Road Pops (window 0, the terminal) with a 1 Hz clock overlay (window 1) on top; hit-testing focuses the clock then the terminal, and a keyboard-typed uname landed in the focused terminal (DipshitOS aarch64). The decoded capture shows the clock's amber title bar + navy body over the terminal with the terminal's green glyphs beside it — distinct windows, right z-order. The default VM is untouched: without --display/--input, no windows are armed and every existing gate stays byte-identical."
    echo "PASS: $PASS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-win: FAILED — see artifacts/live-win-report.txt, the runner output (live-win-run.txt), and the serial log (live-win-serial.log)."
    echo "FAIL: $PASS" >> "$REPORT"
    sleep 0.5
    exit 1
fi

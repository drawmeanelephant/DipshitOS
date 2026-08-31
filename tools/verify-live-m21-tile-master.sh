#!/usr/bin/env bash
#
# verify-live-m21-tile-master.sh -- claim 8777 (milestone twenty-one, cards
# W1 tiling + W2 master-detail) class-B gate: the M21 tiling surface, live
# on real VZ.
#
# The Ctrl+T / Ctrl+M chord entries cannot be typed through the serial
# script path, so the gate drives the SAME driving_award.zig functions
# (`toggle_tiling` / `swap_master`) through the new EL1h monitor halves
# `dui tile <n>` / `dui master` — the established `dui move`/`dui raise`
# precedent — with the real chord wiring asserted by code inspection
# (kernel/src/input.zig pending-flag seam -> kernel/src/shell.zig:3326-3347
# consumers) and host-tested there.
#
# M21DEMO.BIN (`user/src/m21demo.zig`, the THIRTY-EIGHTH ESP user program)
# puts two distinctively-colored windows on screen and yield-loops forever:
#   A (id 2): dark-blue 0x1a2b3c background + red 0xff0000 block, local (8,8)
#   B (id 3): black 0x000000 background + cyan 0x00ffff block, local (8,8)
#
# Phases (TWO live runs):
#   * run A (W1): `dui tile 2` + `dui tile 3` + `dui`. Serial proof: the
#     tile markers and the registry rows rect=24,0,837,700 (master-left,
#     667 per mille of the 1256 px usable width = 837) and rect=861,0,419,700
#     (detail-right). Pixel proof (marker capture on the tiled report line):
#     A's red block at its tiled origin (24,0), B's cyan block at (861,0),
#     dark-blue body dominant in A's content strip, black body dominant in
#     B's strip.
#   * run B (W2): same, then `dui master` + `dui`. Serial proof: side flips
#     to right and BOTH rects move (A detail-left 24,0,419,700; B
#     master-right 443,0,837,700). Pixel proof: cyan now at B's NEW master
#     origin (443,0) and GONE from the old detail spot, red unchanged at
#     A's left edge.
#
# Honest bound (the G6 precedent): byte-exact pixels are the class A mock's
# domain; LIVE pixels are color-managed + retina-scaled (2560x1440 for the
# 1280x720 scanout), so the assertion is "distinct color families in the
# expected regions". The back-buffer source clamp (claim 8777) keeps each
# window's content in its tile's top-left 512x384 corner; every pixel
# target sits inside that strip.
#
# Run isolation (#523 item 2): private stacked disk + EFI vars + serial log
# + screen captures under $RUN_DIR; VIRELAI_GATE_SUFFIX/_KEEP_RUN supported.
#
# Class B — Apple silicon + VZ only; boots real VMs. A green CI badge proves
# class A only and says nothing about this gate.
#
# Usage:
#   bash tools/verify-live-m21-tile-master.sh
#
# Evidence: artifacts/live-m21-tile-gate.txt (full output),
# artifacts/live-m21-tile-report.txt (per-phase detail),
# artifacts/live-m21-tile-run{A,B}-{run.txt,serial.log,after.png}.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-m21-tile-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="artifacts/live-m21-tile-report.txt"

echo "=== verify-live-m21-tile-master: claim 8777 — W1 tiling + W2 master swap, live on VZ ==="

# --- tool versions + revision ------------------------------------------------
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# --- build gates -------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig user/src/*.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
gate_begin live-m21-tile
echo "run dir: $RUN_DIR"

cat > "$RUN_DIR/script1.txt" <<'EOF'
exec M21DEMO.BIN
EOF
cat > "$RUN_DIR/script2a.txt" <<'EOF'
dui tile 2
dui tile 3
dui
EOF
cat > "$RUN_DIR/script2b.txt" <<'EOF'
dui tile 2
dui tile 3
dui
dui master
dui
EOF

# The marker captures fire on the EARLY tile/master lines; the run-expect
# is the LATE 20 s heartbeat. scriptPoll checks --script-expect BEFORE
# --screenshot-after on each poll and finishes the run on a match, so the
# expect text must appear in a LATER poll than the capture marker or the
# capture never fires (observed 2026-08-25, claim 8777).
MARK_A='dui tile: id=3 mode=on master=2 stack=3'
MARK_B='dui master: side=right master=3 stack=2'
EXPECT='timer heartbeat ticks=20 irq=20 poll=0'

# Boots the private WRITABLE copy (not an overlay): the timed screen
# captures need main-like boot pacing; overlays shift guest timing so the
# marker captures land on stale frames (the verify-live-win-move precedent).

# --- one gated run ------------------------------------------------------------
run_one() {
    local tag="$1" script2="$2" final="$3"
    local out serial screenbase
    out="$(art "live-m21-tile-run$tag-run.txt")"
    serial="$(art "live-m21-tile-run$tag-serial.log")"
    screenbase="$RUN_DIR/gpu-screen-$tag"
    cp -f "$ROOT/artifacts/disk.img" "$RUN_DIR/disk-base.img"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log" "$screenbase"-*
    set +e
    host/vm-runner/.build/release/VMRunner "$RUN_DIR/disk-base.img" \
        --serial "$RUN_DIR/vm-serial.log" \
        --display --screen "$screenbase" \
        --screenshot-after "$final" \
        --script "$RUN_DIR/script1.txt" \
        --script2 "$script2" --script2-after "m21demo: loop ok" \
        --script-expect "$EXPECT" \
        --timeout 90 \
        > "$out" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$serial" || true
    [ -f "$screenbase-after" ] && cp "$screenbase-after" "$(art "live-m21-tile-run$tag-after.png")" || true
    for f in "$screenbase"-*s; do
        [ -f "$f" ] && cp "$f" "$(art "live-m21-tile-run$tag-$(basename "$f")")" || true
    done
    echo "$RC" > "$RUN_DIR/rc-$tag.txt"
}

set +e
run_one A "$RUN_DIR/script2a.txt" "$MARK_A"
run_one B "$RUN_DIR/script2b.txt" "$MARK_B"
set -e

# --- assertions ----------------------------------------------------------------
check_run() {
    # $1 tag — sets RUN_<tag> to 1 iff all serial markers are present.
    local tag="$1" serial
    serial="$(art "live-m21-tile-run$tag-serial.log")"
    local OK=1
    if [ ! -f "$serial" ]; then
        echo "run$tag: NO SERIAL LOG"
        eval "RUN_$tag=0"
        return 0
    fi
    # M21DEMO.BIN's EL0 markers.
    grep -a -q -F -- "m21demo: open-a id=2" "$serial" || OK=0
    grep -a -q -F -- "m21demo: fill-a ok" "$serial" || OK=0
    grep -a -q -F -- "m21demo: present-a ok" "$serial" || OK=0
    grep -a -q -F -- "m21demo: open-b id=3" "$serial" || OK=0
    grep -a -q -F -- "m21demo: fill-b ok" "$serial" || OK=0
    grep -a -q -F -- "m21demo: present-b ok" "$serial" || OK=0
    grep -a -q -F -- "m21demo: loop ok" "$serial" || OK=0
    # The EL1h tile halves (W1): window A becomes master, B joins as stack.
    grep -a -q -F -- "dui tile: id=2 mode=on master=2" "$serial" || OK=0
    grep -a -q -F -- "dui tile: id=3 mode=on master=2 stack=3" "$serial" || OK=0
    if [ "$tag" = "A" ]; then
        # W1 pre-swap geometry: master-left 837 px, detail-right 419 px.
        grep -a -q -F -- "dui: tiling=on master=2 stack=3 side=left" "$serial" || OK=0
        grep -a -E -q 'dui\[[0-9]+\]: user user rect=24,0,837,700 ' "$serial" || OK=0
        grep -a -E -q 'dui\[[0-9]+\]: user user rect=861,0,419,700 ' "$serial" || OK=0
    else
        # W2 post-swap geometry: sides flipped, BOTH rects moved.
        grep -a -q -F -- "dui master: side=right master=3 stack=2" "$serial" || OK=0
        grep -a -q -F -- "dui: tiling=on master=3 stack=2 side=right" "$serial" || OK=0
        grep -a -E -q 'dui\[[0-9]+\]: user user rect=24,0,419,700 ' "$serial" || OK=0
        grep -a -E -q 'dui\[[0-9]+\]: user user rect=443,0,837,700 ' "$serial" || OK=0
        # The pre-swap state was also observed on the way through.
        grep -a -q -F -- "dui: tiling=on master=2 stack=3 side=left" "$serial" || OK=0
    fi
    eval "RUN_$tag=$OK"
}

RUN_A=0 RUN_B=0
check_run A
check_run B

RC_A="$(cat "$RUN_DIR/rc-A.txt" 2>/dev/null || echo 1)"
RC_B="$(cat "$RUN_DIR/rc-B.txt" 2>/dev/null || echo 1)"

echo "tile-master: rcA=$RC_A rcB=$RC_B runA=$RUN_A runB=$RUN_B"

PASS=1
[ "$RC_A" = 0 ] || PASS=0
[ "$RC_B" = 0 ] || PASS=0
[ "$RUN_A" = 1 ] || PASS=0
[ "$RUN_B" = 1 ] || PASS=0

# --- pixel proofs ---------------------------------------------------------------
decode_capture() {
    # $1 png path, $2 phase (A = tiled split, B = swapped)
    python3 - "$1" "$2" <<'PYEOF'
import sys, zlib, struct
path, phase = sys.argv[1], sys.argv[2]
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
    if r > 200 and g > 200 and b > 200:
        return 'white'
    if (g > 50 and b > 50 and g > r + 15 and b > r + 15) or (g > 160 and b > 160 and r < 170):
        return 'cyan'
    if (r > 50 and r > g + 15 and r > b + 15) or (r > 140 and g < 130 and b < 130):
        return 'red'
    if (b > r + 5 and b > g + 5 and max(r, g, b) < 130) or (b > 30 and b > r and b > g):
        return 'darkblue'
    if g > 140 and r < 160 and b < 160:
        return 'green'
    return 'other'

def region(x0, y0, x1, y1, step=4):
    counts = {}
    for y in range(y0, y1, step):
        for x in range(x0, x1, step):
            k = classify(*px(x, y))
            counts[k] = counts.get(k, 0) + 1
    return counts

def frac(counts, key):
    tot = sum(counts.values())
    return (counts.get(key, 0) / tot) if tot else 0.0

# All coords RETINA (logical x2). Content strips (the clamped blit):
#   A content: logical (24..536)x(0..384)  -> retina (48..1072)x(0..768)
#   B content (detail): logical (861..1280)x(0..384) -> retina (1722..2560)x(0..768)
#   B content (master-right): logical (443..955)x(0..384) -> retina (886..1910)x(0..768)

if phase == 'A':
    # A master-left at (24,0): red block center local (32,32).
    red = classify(*px(80, 64))
    print(f"A red@master-origin: {red}")
    if red != 'red':
        sys.exit(f"FAIL: A's red block not at the tiled master origin ({red})")
    # B detail-right at (861,0): cyan block center local (32,32).
    cyan = classify(*px(1750, 64))
    print(f"A cyan@detail-origin: {cyan}")
    if cyan != 'cyan':
        sys.exit(f"FAIL: B's cyan block not at the tiled detail origin ({cyan})")
    # A's dark-blue body dominates its content strip below the blocks.
    body_a = region(60, 180, 1050, 740)
    fa = frac(body_a, 'darkblue')
    print(f"A body: {body_a} darkblue={fa:.3f}")
    if fa < 0.60:
        sys.exit("FAIL: A's tiled master content is not dark-blue dominant")
    # B's black body dominates its content strip below the blocks.
    body_b = region(1740, 180, 2540, 740)
    fb = frac(body_b, 'other')
    print(f"B body: {body_b} other(black)={fb:.3f}")
    if fb < 0.60:
        sys.exit("FAIL: B's tiled detail content is not black dominant")
    print("PASS(A): two tiled windows split the screen — A master-left (24,0,837,700) with its red-on-darkblue content, B detail-right (861,0,419,700) with its cyan-on-black content")
else:
    # After `dui master`: B moved to master-right (443,0); A stays at the
    # left edge but narrows to the 419 px detail.
    red = classify(*px(80, 64))
    print(f"B red@left-edge: {red}")
    if red != 'red':
        sys.exit(f"FAIL: A's red block missing from the detail-left origin ({red})")
    cyan_new = classify(*px(914, 64))
    print(f"B cyan@new-master-origin: {cyan_new}")
    if cyan_new != 'cyan':
        sys.exit(f"FAIL: B's cyan block not at the SWAPPED master origin (443,0) ({cyan_new})")
    cyan_old = classify(*px(1750, 64))
    print(f"B cyan@old-detail-spot: {cyan_old}")
    if cyan_old == 'cyan':
        sys.exit("FAIL: B's cyan block still at the OLD detail spot (861,0) — the swap did not land")
    # No cyan anywhere in the old detail strip.
    old_strip = region(1900, 160, 2540, 740)
    if old_strip.get('cyan', 0):
        sys.exit(f"FAIL: cyan still present in the old detail strip ({old_strip})")
    # B's black body dominates its NEW content strip.
    body_b = region(900, 180, 1890, 740)
    fbb = frac(body_b, 'other')
    print(f"B body(new): {body_b} other(black)={fbb:.3f}")
    if fbb < 0.60:
        sys.exit("FAIL: B's swapped master content is not black dominant")
    # A's dark-blue body still dominates its (now narrower) content strip.
    body_a = region(60, 180, 1050, 740)
    fa = frac(body_a, 'darkblue')
    print(f"A body: {body_a} darkblue={fa:.3f}")
    if fa < 0.60:
        sys.exit("FAIL: A's detail-left content is not dark-blue dominant")
    print("PASS(B): master/detail SWAPPED — B carries the 2/3 master rect on the right (443,0,837,700) with its cyan block at the new origin, A holds the 1/3 detail on the left (24,0,419,700)")

PYEOF
    return $?
}

CAPTURE_A="$(art live-m21-tile-runA-after.png)"
if [ -f "$CAPTURE_A" ]; then
    echo "decoding $CAPTURE_A (W1 tiled split)"
    if ! decode_capture "$CAPTURE_A" A; then
        echo "FAIL: run-A capture does not show the tiled split"
        PASS=0
    fi
else
    echo "FAIL: no marker capture for run A ($CAPTURE_A)"
    PASS=0
fi

CAPTURE_B="$(art live-m21-tile-runB-after.png)"
if [ -f "$CAPTURE_B" ]; then
    echo "decoding $CAPTURE_B (W2 swapped)"
    if ! decode_capture "$CAPTURE_B" B; then
        echo "FAIL: run-B capture does not show the swapped layout"
        PASS=0
    fi
else
    echo "FAIL: no marker capture for run B ($CAPTURE_B)"
    PASS=0
fi

{
    echo "VIRELAIOS M21 W1/W2 tiling + master-detail gate (claim 8777) — compositor geometry + paint, live on VZ hardware"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "phase: exec M21DEMO.BIN (two colored user windows), then EL1h halves — run A: dui tile 2 + dui tile 3 + dui; run B: + dui master + dui; marker-driven capture decoded per run"
    echo "assertions: m21demo open/fill/present/loop markers for both windows; dui tile: id=2 mode=on master=2 + dui tile: id=3 mode=on master=2 stack=3; run A registry rows rect=24,0,837,700 (master-left) + rect=861,0,419,700 (detail-right) + dui: tiling=on master=2 stack=3 side=left; run B adds dui master: side=right master=3 stack=2 + rows rect=24,0,419,700 + rect=443,0,837,700 + tiling=on master=3 stack=2 side=right; run-A capture shows red@ (112,64) + cyan@(1786,64) + darkblue-dominant master strip + black-dominant detail strip; run-B capture shows cyan MOVED to (950,64) and gone from (1786,64)"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} > "$REPORT"

echo
echo "=== result ==="
if [ "$PASS" = 1 ]; then
    echo "verify-live-m21-tile-master: PASS — M21DEMO.BIN put two owned user windows on the scanout from EL0 (A dark-blue+red id=2, B black+cyan id=3), the EL1h halves drove the same functions as the Ctrl+T/Ctrl+M chords (toggle_tiling/swap_master), and BOTH runs prove the layout on real pixels: run A (W1) — two tiled windows split the usable area master-left 24,0,837,700 / detail-right 861,0,419,700 (667:333 per mille of 1256 px, registry-asserted AND pixel-asserted); run B (W2) — dui master flipped the side and BOTH rects moved (A 24,0,419,700 detail-left, B 443,0,837,700 master-right) with B's cyan block observed at the NEW origin and gone from the old spot. The tiled blit source clamp (claim 8777) held: every tile paints its content inside the top-left 512x384 corner, no OOB."
    echo "PASS: $PASS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-m21-tile-master: FAILED — see artifacts/live-m21-tile-report.txt, the runner outputs (live-m21-tile-run{A,B}-run.txt), the serial logs (live-m21-tile-run{A,B}-serial.log), and the captures (live-m21-tile-run{A,B}-after.png)."
    echo "FAIL: $PASS" >> "$REPORT"
    sleep 0.5
    exit 1
fi

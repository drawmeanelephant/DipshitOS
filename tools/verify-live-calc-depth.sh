#!/usr/bin/env bash
#
# verify-live-calc-depth.sh -- milestone-twenty-four depth gate (claims
# 4354 sweep): the K2–K16 cards whose march rows were "✅ code / live gate
# pending", driven end to end on real VZ.
#
# Mechanism: boots the production image (SPIKE build, custom-virtio INPUT
# queue), execs CALC.BIN from the monitor, waits for `calc: ready`, then
# drives the GUI through the claim 9588 virtio channels and asserts the
# app's serial markers:
#
#   --input-chords (after "calc: ready") — one ordered burst:
#     K16 stats    ctrl-s 1 2 3 return escape        -> stats-on/ok/off
#     K13 dates    ctrl-d "2026-01-01 - 2026-01-10" enter escape
#                                                   -> date-open/ok/close
#     K12 settings ctrl-, escape                     -> cfg-open/close
#     K14 rand     r                                -> rand
#     K2  memory   5 s m ctrl-2                     -> (store/recall) mem-slot
#     K3  units    ctrl-u ctrl-u                    -> conv-on/off
#     K10 clipboard ctrl-c                          -> clip-copy
#
#   --pointer-virtio (after "calc: clip-copy") — one ordered click burst
#   (window-local conversion happens in driving_award):
#     K4  constants PI (336,162)                    -> display "3" (no marker;
#                                                     proven by screenshot)
#     K7  trig     DEG/RAD (267,344) x2             -> deg-mode/rad-mode
#     K6  sci      SCI (84,318) x2                  -> sci-on/off
#     K9  expr     EXPR (145,318) x2                -> expr-on/off
#
#   --screenshot-after "calc: deg-mode" — display shows "3" after the PI
#   click (pixel proof for K4).
#
#   --script2 (after "calc: expr-off", the LAST pointer marker) — `echo
#   calc-depth-live-ok` at the SHELL (script2 writes to the monitor console;
#   the chord/pointer channels reach the focused CALC window, so the success
#   marker cannot ride them). Firing on the last marker -- not a timer -- is
#   essential: the chord burst alone is ~22 s (88 strokes x 0.25 s) and the
#   pointer burst ~52 s (21 msgs x 2.5 s), so a timer-based marker stops the
#   VM mid-input (observed: script2 fired at heartbeat ticks=25 while the
#   tail chords were still in flight).
#
# Stats note: the comma-separated chord list cannot express a literal `,`
# (it IS the token separator), so the live stats proof types a single
# value ("123"); the multi-sample parse_list path is host-tested
# (calc/stats.zig 3/3).
#
# Run isolation (#523 item 2 / issue #528, claim 5069): private stacked
# disk + EFI vars + serial log under $RUN_DIR.
#
# Class B -- Apple silicon + VZ only; boots a real VM.
#
# Usage:
#   bash tools/verify-live-calc-depth.sh             # BOOTS boots (default 1)
#   BOOTS=2 bash tools/verify-live-calc-depth.sh
#
# Evidence saved under artifacts/: live-calc-depth-gate.txt,
# live-calc-depth-report.txt, live-calc-depth-run-<NN>.txt,
# live-calc-depth-serial-<NN>.log, gpu-screen-after.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-calc-depth-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

BOOTS="${BOOTS:-1}"
REPORT="$(art live-calc-depth-report.txt)"

echo "=== verify-live-calc-depth: M24 K2-K16 depth sweep on VZ, $BOOTS boot(s) ==="

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"

# --- build gates ------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig user/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation ------------------------------------------------------
gate_begin live-calc-depth
echo "run dir: $RUN_DIR"
SCRIPT="$RUN_DIR/script.txt"

cat > "$SCRIPT" <<'EOF'
exec CALC.BIN
EOF

# The K16 stats bar opens on ctrl-s and consumes keys until escape; K13's
# date bar the same; K12's settings bar the same. The burst is ordered so
# each bar is opened, fed, and closed before the next card's keys land.
CHORDS="ctrl-s,1,comma,2,comma,3,return,escape,ctrl-d,2,0,2,6,-,0,1,-,0,1,space,-,space,2,0,2,6,-,0,1,-,1,0,return,escape,ctrl-comma,escape,r,5,s,m,ctrl-2,ctrl-u,ctrl-u,ctrl-c"

# Pointer clicks in guest-framebuffer pixels (window-local conversion is
# driving_award's). PI first so the screenshot-after "calc: deg-mode"
# captures the display already showing the inserted constant.
PTR="336,162,c;267,344,c;267,344,c;84,318,c;84,318,c;145,318,c;145,318,c"

cat > "$RUN_DIR/script2.txt" <<'EOF'
echo calc-depth-live-ok
EOF

run_one() {
    local tag="$1"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log"
    rm -f "$RUN_DIR"/gpu-screen-*
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --display --screen "$RUN_DIR/gpu-screen" \
        --via-virtio \
        --script "$SCRIPT" \
        --input-chords "$CHORDS" \
        --input-chords-after "calc: ready" \
        --pointer-virtio "$PTR" \
        --pointer-virtio-after "calc: clip-copy" \
        --screenshot-after "calc: deg-mode" \
        --script2 "$RUN_DIR/script2.txt" \
        --script2-after "calc: expr-off" \
        --script-expect "calc-depth-live-ok" \
        --timeout 180 \
        > "$(art live-calc-depth-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-calc-depth-serial-$tag.log)" || true
    cp "$RUN_DIR"/gpu-screen-* artifacts/ 2>/dev/null || true
    local SER="$(art live-calc-depth-serial-$tag.log)"

    local BANNER=0 READY=0 STATS_ON=0 STATS_OK=0 STATS_OFF=0 DATE_OPEN=0 DATE_OK=0 DATE_CLOSE=0
    local CFG_OPEN=0 CFG_CLOSE=0 RAND=0 MEM_SLOT=0 CONV_ON=0 CONV_OFF=0 CLIP=0
    local DEG=0 RAD=0 SCI_ON=0 SCI_OFF=0 EXPR_ON=0 EXPR_OFF=0 DONE=0 PIX=0
    if [ -f "$SER" ]; then
        grep -qF -- "DipshitOS kernel has seized control." "$SER" && BANNER=1
        grep -qF -- "calc: ready" "$SER" && READY=1
        grep -qF -- "calc: stats-on" "$SER" && STATS_ON=1
        grep -qF -- "calc: stats-ok" "$SER" && STATS_OK=1
        grep -qF -- "calc: stats-off" "$SER" && STATS_OFF=1
        grep -qF -- "calc: date-open" "$SER" && DATE_OPEN=1
        grep -qF -- "calc: date-ok" "$SER" && DATE_OK=1
        grep -qF -- "calc: date-close" "$SER" && DATE_CLOSE=1
        grep -qF -- "calc: cfg-open" "$SER" && CFG_OPEN=1
        grep -qF -- "calc: cfg-close" "$SER" && CFG_CLOSE=1
        grep -qF -- "calc: rand" "$SER" && RAND=1
        grep -qF -- "calc: mem-slot" "$SER" && MEM_SLOT=1
        grep -qF -- "calc: conv-on" "$SER" && CONV_ON=1
        grep -qF -- "calc: conv-off" "$SER" && CONV_OFF=1
        grep -qF -- "calc: clip-copy" "$SER" && CLIP=1
        grep -qF -- "calc: deg-mode" "$SER" && DEG=1
        grep -qF -- "calc: rad-mode" "$SER" && RAD=1
        grep -qF -- "calc: sci-on" "$SER" && SCI_ON=1
        grep -qF -- "calc: sci-off" "$SER" && SCI_OFF=1
        grep -qF -- "calc: expr-on" "$SER" && EXPR_ON=1
        grep -qF -- "calc: expr-off" "$SER" && EXPR_OFF=1
        grep -qF -- "calc-depth-live-ok" "$SER" && DONE=1
    fi

    # K4 pixel proof: the display (window-local 8,72,496,28 -> global
    # 56,120..552,148 -> 2x 112,240..1104,296) shows "3" after the PI
    # click. The display text is RIGHT-ALIGNED, so the constant lands in
    # the last ~64 guest px of the rect (2x x 990..1104) — a single 8x8
    # digit yields only ~15 near-white samples there (observed live), so
    # sample that right-aligned region rather than the whole band.
    local SHOT="artifacts/gpu-screen-after${SUFFIX}"
    if [ -f "$SHOT" ]; then
        if python3 - "$SHOT" <<'PYEOF'
import sys, zlib, struct
d = open(sys.argv[1], 'rb').read()
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
# CALC window at (48,48); display rect local (8,72,496,28) -> global
# (56,120)-(552,148) -> 2x retina (112,240)-(1104,296). The display text
# is right-aligned, so the inserted constant "3" renders in the far-right
# of the rect — sample 2x x 990..1104 for near-white glyph pixels.
white = 0
for y in range(240, 300, 2):
    for x in range(990, 1104, 3):
        r, g, b = px(x, y)
        if min(r, g, b) > 160:
            white += 1
print("white-glyph samples in CALC display (right-aligned region): %d" % white)
if white < 10:
    print("ERROR: too few white glyph pixels — display did not render the constant")
    sys.exit(1)
PYEOF
        then PIX=1
        fi
    fi

    {
        echo "$tag: rc=$RC banner=$BANNER ready=$READY stats($STATS_ON/$STATS_OK/$STATS_OFF) date($DATE_OPEN/$DATE_OK/$DATE_CLOSE) cfg($CFG_OPEN/$CFG_CLOSE) rand=$RAND mem=$MEM_SLOT conv($CONV_ON/$CONV_OFF) clip=$CLIP deg($DEG/$RAD) sci($SCI_ON/$SCI_OFF) expr($EXPR_ON/$EXPR_OFF) k4-pixels=$PIX done=$DONE"
    } >> "$REPORT"
    echo "$tag rc=$RC banner=$BANNER ready=$READY stats($STATS_ON/$STATS_OK/$STATS_OFF) date($DATE_OPEN/$DATE_OK/$DATE_CLOSE) cfg($CFG_OPEN/$CFG_CLOSE) rand=$RAND mem=$MEM_SLOT conv($CONV_ON/$CONV_OFF) clip=$CLIP deg($DEG/$RAD) sci($SCI_ON/$SCI_OFF) expr($EXPR_ON/$EXPR_OFF) k4-pixels=$PIX done=$DONE"
    [ "$RC" = 0 ] && [ "$BANNER" = 1 ] && [ "$READY" = 1 ] && \
        [ "$STATS_ON" = 1 ] && [ "$STATS_OK" = 1 ] && [ "$STATS_OFF" = 1 ] && \
        [ "$DATE_OPEN" = 1 ] && [ "$DATE_OK" = 1 ] && [ "$DATE_CLOSE" = 1 ] && \
        [ "$CFG_OPEN" = 1 ] && [ "$CFG_CLOSE" = 1 ] && [ "$RAND" = 1 ] && [ "$MEM_SLOT" = 1 ] && \
        [ "$CONV_ON" = 1 ] && [ "$CONV_OFF" = 1 ] && [ "$CLIP" = 1 ] && \
        [ "$DEG" = 1 ] && [ "$RAD" = 1 ] && [ "$SCI_ON" = 1 ] && [ "$SCI_OFF" = 1 ] && \
        [ "$EXPR_ON" = 1 ] && [ "$EXPR_OFF" = 1 ] && [ "$PIX" = 1 ] && [ "$DONE" = 1 ]
}

: > "$REPORT"
{
    echo "DIPSHITOS live-calc-depth gate (M24 K2-K16) -- depth sweep on VZ"
    echo "revision: $REVISION branch=$BRANCH boots=$BOOTS dirty-files=$DIRTY"
    echo "chords: $CHORDS"
    echo "pointer: $PTR"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} >> "$REPORT"

PASS=0
n=0
while [ "$n" -lt "$BOOTS" ]; do
    n=$((n + 1))
    echo
    echo "=== live-calc-depth boot $n ==="
    if run_one "$(printf "%02d" "$n")"; then
        PASS=$((PASS + 1))
    fi
done

echo
echo "=== result ==="
if [ "$PASS" = "$BOOTS" ]; then
    echo "verify-live-calc-depth: PASS -- K2/K3/K4/K6/K7/K9/K10/K12/K13/K14/K16 markers observed ($PASS/$BOOTS boot(s))."
    echo "PASS: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-calc-depth: FAILED -- $PASS/$BOOTS boot(s) passed; see artifacts/live-calc-depth-report.txt"
    echo "FAIL: $PASS/$BOOTS" >> "$REPORT"
    sleep 0.5
    exit 1
fi

#!/usr/bin/env bash
#
# verify-live-chrome.sh -- milestone-twenty card U4 class-B gate
# (march-m20 "Improved window chrome", Lane C issue #319, claim 8961).
#
# What is proven: the M20-U9 chrome paint contract, MEASURED from the
# guest's own scanout (claim-0680 kind-4 snapshot over custom-virtio
# queue 4 — byte-exact raw BGRX; no ScreenCaptureKit, no TCC permission,
# no activation wall):
#
#   NOTEPAD.BIN opens its user window at the fixed rect (56,56) 512x384;
#   driving_award.zig paints chrome_border_w=2 border, user_title_h=16
#   title band (bg 0x1a2b3c), a centered white label, and the red
#   close glyph (0xef4444 'x') at the title bar's top-right.
#
#   boot A (focused): the white focus ring (0xffffff, 3px) wraps the
#          window edge; title label + close glyph present.
#   boot B (unfocused via `dui focus 0`): the exact chrome is measurable
#          edge-to-edge — left/right/bottom border columns/rows exactly
#          2px of 0x0c1826, rows Y..Y+15 the title band with label ink,
#          client area the app's own background (0x182026), red close
#          glyph inside the top-right box.
#
#   Behavioral tail (boot B): after both snapshots, the custom-virtio
#   pointer channel (claim 9367) CLICKS the close glyph — the window
#   manager closes notepad (`notepad: win_close` over serial): the title
#   strip is behaviorally live chrome, not paint alone.
#
# Class B — Apple silicon + VZ only.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-chrome-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-chrome-report.txt)"

echo "=== verify-live-chrome: M20 U4 — window chrome metrics + close click on VZ ==="

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null | sed 's|agent/||;s|/|-|g' || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

gate_begin live-chrome
gate_seed_share
echo "run dir: $RUN_DIR"

run_boot() {
    # $1 = tag; remaining args passed through to VMRunner.
    local tag="$1"; shift
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial-$tag.log" "$RUN_DIR"/snap-$tag-*.raw
    set +e
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial-$tag.log" \
        --screen "$RUN_DIR/screen" \
        --via-virtio --cvc-snap \
        --snapshot-out "$RUN_DIR/snap-$tag" "$@" \
        > "$(art live-chrome-run-$tag.txt)" 2>&1
    local RC=$?
    set -e
    [ -f "$RUN_DIR/vm-serial-$tag.log" ] && cp "$RUN_DIR/vm-serial-$tag.log" "$(art live-chrome-serial-$tag.log)" || true
    echo "$tag: runner rc=$RC"
    return "$RC"
}

snap_file() {
    local f
    f="$(ls "$RUN_DIR"/snap-$1-*.raw 2>/dev/null | head -1 || true)"
    [ -n "$f" ] || { echo "FAIL: no snapshot streamed in boot $1"; return 1; }
    cp "$f" "$(art live-chrome-snap-$1.raw)"
    printf '%s' "$f"
}

# --- boot A: FOCUSED window chrome (ring + title + close glyph) ---------------
echo "--- boot A: focused chrome (focus ring + title bar + close glyph) ---"
printf 'exec NOTEPAD.BIN\n' > "$RUN_DIR/script-A.txt"
printf 'echo chrome-a\n' > "$RUN_DIR/s2-A.txt"
printf 'echo done-a\n' > "$RUN_DIR/s3-A.txt"
set +e
run_boot A \
    --script "$RUN_DIR/script-A.txt" \
    --script2 "$RUN_DIR/s2-A.txt" --script2-after "notepad: ready" --script2-delay 15 \
    --script3 "$RUN_DIR/s3-A.txt" --script3-after "chrome-a" --script3-delay 25 \
    --snapshot-after "chrome-a" \
    --script-expect "done-a" --timeout 150
RC_A=$?
set -e
A_OK=0
if [ "$RC_A" = 0 ]; then
    SNAP_A="$(snap_file A || true)"
    if [ -n "$SNAP_A" ] && python3 - "$SNAP_A" <<'PYEOF'
import sys
data = open(sys.argv[1], "rb").read()
w = 1280
def px(x, y):
    k = (y * w + x) * 4
    return (data[k + 2], data[k + 1], data[k])
X, Y, W, H = 56, 56, 512, 384
ok = True
# Focus ring on the focused window's edge. M21 W9 (claim 2621) restyled
# the original white D4 ring into a 3px ACCENT border (0x3b82f6).
for dy in (0, 1, 2):
    n = sum(1 for dx in range(8, W - 8, 16) if px(X + dx, Y + dy) == (59, 130, 246))
    ok &= n >= (W - 16) // 16 - 2
print("ring_top_ok" if ok else "RING_MISSING")
# Title label ink: white pixels somewhere inside the title band (y+3..y+15).
ink = sum(1 for x in range(X + 20, X + W - 40, 2) for y in range(Y + 3, Y + 16)
          if px(x, y)[0] > 200 and px(x, y)[1] > 200 and px(x, y)[2] > 200)
print("label_ink=%d" % ink)
# Close glyph: red pixels inside the title-right box.
red = sum(1 for x in range(X + W - 15, X + W - 5) for y in range(Y + 3, Y + 13)
          if px(x, y)[0] > 170 and px(x, y)[1] < 120 and px(x, y)[2] < 120)
print("close_red=%d" % red)
sys.exit(0 if ok and ink >= 30 and red >= 6 else 1)
PYEOF
    then A_OK=1
    fi
fi

# --- boot B: UNFOCUSED chrome measured edge-to-edge ---------------------------
# OBSERVED (claim 8961 bring-up): the kind-4 snapshot streams the LIVE
# framebuffer over ~113 chunks, so any pointer interaction scheduled
# alongside the stream corrupts the measured frame. Chrome metrics and
# the behavioral close-click therefore get SEPARATE boots.
echo "--- boot B: unfocused chrome metrics ---"
printf 'exec NOTEPAD.BIN\n' > "$RUN_DIR/script-B.txt"
printf 'dui focus 0\necho chrome-b\n' > "$RUN_DIR/s2-B.txt"
printf 'echo done-b\n' > "$RUN_DIR/s3-B.txt"
set +e
run_boot B \
    --script "$RUN_DIR/script-B.txt" \
    --script2 "$RUN_DIR/s2-B.txt" --script2-after "notepad: ready" --script2-delay 15 \
    --script3 "$RUN_DIR/s3-B.txt" --script3-after "chrome-b" --script3-delay 30 \
    --snapshot-after "chrome-b" \
    --script-expect "done-b" --timeout 150
RC_B=$?
set -e
B_OK=0
if [ "$RC_B" = 0 ]; then
    SNAP_B="$(snap_file B || true)"
    if [ -n "$SNAP_B" ] && python3 - "$SNAP_B" <<'PYEOF'
import sys
data = open(sys.argv[1], "rb").read()
w = 1280
def px(x, y):
    k = (y * w + x) * 4
    return (data[k + 2], data[k + 1], data[k])
BORDER = (0x47, 0x55, 0x69)     # user_border_unfocused() dark theme (M21 W9)
TITLE  = (0x1a, 0x2b, 0x3c)     # user_title_bg()
CLIENT = (0x18, 0x20, 0x26)     # ui.COLOR_BG (dark theme)
X, Y, W, H = 56, 56, 512, 384
fails = []
def near(c, want, tol=6):
    return all(abs(a - b) <= tol for a, b in zip(c, want))
# Left/right border columns: EXACTLY 2px for the full height below the title.
for xx in (X, X + 1, X + W - 2, X + W - 1):
    good = sum(1 for yy in range(Y + 20, Y + H - 6, 24) if near(px(xx, yy), BORDER))
    need = len(range(Y + 20, Y + H - 6, 24))
    if good < need - 1: fails.append(f"border col {xx-X}: {good}/{need}")
# Border is only TWO px: the third column is NOT border color.
third_bad = sum(1 for yy in range(Y + 20, Y + H - 6, 24) if near(px(X + 2, yy), BORDER))
if third_bad > 2: fails.append(f"border thicker than 2px ({third_bad} hits at col+2)")
# Bottom border rows: exactly two.
for yy in (Y + H - 2, Y + H - 1):
    good = sum(1 for xx in range(X + 8, X + W - 8, 32) if near(px(xx, yy), BORDER))
    need = len(range(X + 8, X + W - 8, 32))
    if good < need - 1: fails.append(f"border row {yy-Y}: {good}/{need}")
# Title band: rows Y..Y+15 dominated by title bg outside the centered label.
band = tot = 0
for yy in range(Y + 2, Y + 16):
    for xx in range(X + 4, X + W - 40, 3):
        tot += 1
        if near(px(xx, yy), TITLE): band += 1
if band < int(tot * 0.55): fails.append(f"title band bg {band}/{tot}")
# Label ink (white) present in the band.
ink = sum(1 for xx in range(X + 20, X + W - 40, 2) for yy in range(Y + 2, Y + 16)
          if px(xx, yy) == (255, 255, 255))
if ink < 30: fails.append(f"title label ink {ink}")
# Client interior (right of the editor surface, below the tool row) is the
# app background, NOT title/border color.
cl = sum(1 for xx in range(X + 420, X + 504, 4) for yy in range(Y + 300, Y + 372, 4)
         if near(px(xx, yy), CLIENT))
if cl < 100: fails.append(f"client bg {cl}")
# Close glyph red pixels.
red = sum(1 for xx in range(X + W - 15, X + W - 5) for yy in range(Y + 3, Y + 13)
          if px(xx, yy)[0] > 170 and px(xx, yy)[1] < 120 and px(xx, yy)[2] < 120)
if red < 6: fails.append(f"close glyph red {red}")
if fails:
    print("CHROME-FAILS:", "; ".join(fails)); sys.exit(1)
print("CHROME-METRICS-OK")
PYEOF
    then B_OK=1
    fi
fi

# --- boot C: behavioral close-click on the title-bar close glyph ---------------
echo "--- boot C: pointer click on the close glyph closes the window ---"
printf 'exec NOTEPAD.BIN\n' > "$RUN_DIR/script-C.txt"
set +e
run_boot C \
    --script "$RUN_DIR/script-C.txt" \
    --pointer-virtio "320,360,c;558,64,c" --pointer-virtio-after "notepad: ready" \
    --script-expect "notepad: win_close" --timeout 150
RC_C=$?
set -e
C_OK=0
[ "$RC_C" = 0 ] && grep -a -qF "PTR-CV-SEQ" "$(art live-chrome-run-C.txt)" && C_OK=1

PASS=$((A_OK + B_OK + C_OK))
echo "$REVISION branch=$BRANCH" > "$REPORT"
echo "bootA(focused ring/title/close)=$A_OK bootB(unfocused metrics)=$B_OK bootC(close click)=$C_OK" >> "$REPORT"

if [ "$PASS" = 3 ]; then
    echo "verify-live-chrome: PASS (2px border, 16px title band, label, close glyph, ring, close-click)"
    exit 0
fi
echo "verify-live-chrome: FAIL ($PASS/3 boots)"
exit 1

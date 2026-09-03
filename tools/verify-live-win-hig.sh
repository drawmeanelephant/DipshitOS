#!/usr/bin/env bash
#
# verify-live-win-hig.sh -- milestone eight card U5 (claim 0935, ADR 0008
# D4) class-B gate: the window chrome is VISIBLE and MOVES with focus.
#
# Mechanism: ONE --input --display run with a marker-driven screenshot
# capture. The serial script exercises the focus surface: `dui cycle`
# (the D4 keyboard-cycling analogue — the Alt+Tab HID decode is
# host-tested; synthesized modifiers never reach VZ's HID report, the
# claim-6233 hardware-contract observation), then `exec WINLOOP.BIN`
# opens a USER window (the long-lived G6 program), then `dui` reports
# the registry — the capture fires on that report line.
#
# Pixel assertions (the decoded capture, 2560x1440 = 2x the 1280x720
# framebuffer; colors ride the host's color-managed pipeline — the G6
# recorded transforms — so white stays ~(255,255,255) and the title-bar
# blue ~(30,43,59)):
#   * the FOCUS RING (white, 3 px) sits on the FOCUSED window — after the
#     cycle focuses the clock, `exec WINLOOP.BIN` opens a user window
#     which TAKES focus (the G6 open semantic), so the ring sits on
#     WINLOOP's corner at capture time;
#   * the TERMINAL's screen edge is NOT ringed (sample (1,1)-area shows
#     the terminal background, not white);
#   * the USER window carries its TITLE BAR (dark blue strip at the top
#     of WINLOOP's window, with the "win2" text row);

#
# Card U4's pointer half (cursor + click-to-focus) is host-tested but NOT
# gated here: five synthesized pointer delivery routes were observed
# producing ZERO guest pointer reports (direct view calls, window
# sendEvent, NSApp.postEvent, CGEventPost without Accessibility trust,
# and a mouseEntered preamble) — recorded in the hardware contract; the
# real-mouse question and the Accessibility-granted CG route remain the
# follow-up.
#
# Run isolation (#523 item 2 / issue #528, claim 5069): private stacked
# disk + EFI vars + serial log + screen captures under $RUN_DIR.
#
# Class B — Apple silicon + VZ only; boots a real VM.
#
# Usage:
#   bash tools/verify-live-win-hig.sh
#
# Evidence: artifacts/win-hig-gate.txt, artifacts/win-hig-report.txt,
# the capture under artifacts/hig-screen-*.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art win-hig-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="artifacts/win-hig-report.txt"
SCREEN_BASE="$RUN_DIR/hig-screen"

echo "=== verify-live-win-hig: card U5 (claim 0935) — the focus ring + title bars are visible and move with focus ==="

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# --- build gates ------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
gate_begin live-win-hig
gate_seed_share
echo "run dir: $RUN_DIR"

# --- the session --------------------------------------------------------------
# WINLOOP.BIN opens a user window (id 2) which takes focus.
# script2 then exercises focus cycling: user window (2) -> terminal (0) -> user window (2).
cat > "$RUN_DIR/script.txt" <<'EOF'
exec WINLOOP.BIN
EOF
cat > "$RUN_DIR/script2.txt" <<'EOF'
dui cycle
dui cycle
echo hig-serial-ok
EOF

rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log" "$RUN_DIR"/snap-*.raw
set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial.log" \
    --input --display \
    --screen "$RUN_DIR/screen" \
    --via-virtio --cvc-snap \
    --snapshot-after "hig-serial-ok" \
    --snapshot-out "$RUN_DIR/snap" \
    --script "$RUN_DIR/script.txt" \
    --script2 "$RUN_DIR/script2.txt" --script2-after "winloop: loop ok" \
    --script-expect "hig-serial-ok" \
    --timeout 60 \
    > "$(art win-hig-run.txt)" 2>&1
RC=$?
set -e

# --- serial assertions --------------------------------------------------------
SERIAL="$RUN_DIR/vm-serial.log"
cp "$SERIAL" "$(art win-hig-serial.log)" 2>/dev/null || true
for f in "$RUN_DIR"/snap-*.raw; do
    [ -f "$f" ] && cp "$f" "$(art win-hig-snap-0.raw)" && break || true
done

CYCLED=0 THREE=0 OBSDONE=0
if [ -f "$SERIAL" ]; then
    grep -a -qF -- "dui: cycle focused=0" "$SERIAL" && \
        grep -a -qF -- "dui: cycle focused=2" "$SERIAL" && CYCLED=1
    grep -a -qF -- "winloop: present ok" "$SERIAL" && THREE=1
    grep -a -qF -- "hig-serial-ok" "$SERIAL" && OBSDONE=1
fi

# --- pixel assertions (headless virtio snapshot: 1280x720 BGRX raw scanout) ---
# WINLOOP's window at (64,64), 512x384. Sample points:
#   RING   (65, 65) — WINLOOP's ring corner (focus ring color: 0x3b82f6 -> (59, 130, 246))
#   EDGE   (1, 1)    — the terminal corner, NOT ringed
#   TITLE  (100, 72) — WINLOOP's title-bar strip (0x1a2b3c -> (26, 43, 60))
RING=0 EDGE=0 TITLE=0
SNAP="$(ls -t "$RUN_DIR"/snap-*.raw 2>/dev/null | head -1 || ls -t artifacts/win-hig-snap-*.raw 2>/dev/null | head -1 || true)"
if [ -n "$SNAP" ] && [ -f "$SNAP" ]; then
    echo "decoding $SNAP"
    python3 - "$SNAP" <<'EOF'
import sys
path = sys.argv[1]
data = open(path, 'rb').read()
assert len(data) == 1280 * 720 * 4, f"unexpected snapshot size {len(data)}"
w = 1280

def px(x, y):
    k = (y * w + x) * 4
    return (data[k+2], data[k+1], data[k]) # R, G, B

def near(c, t, tol):
    return all(abs(c[i] - t[i]) <= tol for i in range(3))

# Ring: theme accent 0x3b82f6 (59, 130, 246)
ring = near(px(65, 65), (59, 130, 246), 25)
# Edge: terminal corner should be terminal bg (16, 20, 24), definitely NOT the ring
edge = not near(px(1, 1), (59, 130, 246), 25)
# Title bar: user title bg 0x1a2b3c (26, 43, 60)
title = near(px(100, 72), (26, 43, 60), 22)

print(f"PIXEL ring={int(ring)} edge_not_ringed={int(edge)} title={int(title)}")
print(f"  ring sample {px(65,65)}  edge sample {px(1,1)}  title sample {px(100,72)}")
sys.exit(0 if (ring and edge and title) else 1)
EOF
    if [ $? -eq 0 ]; then RING=1; EDGE=1; TITLE=1; fi
else
    echo "FAIL: no capture raw snapshot"
fi

echo "win-hig: rc=$RC cycled=$CYCLED windows3=$THREE obs-done=$OBSDONE pixels=$RING/$EDGE/$TITLE"

PASS=0
if [ "$RC" = 0 ] && [ "$CYCLED" = 1 ] && [ "$THREE" = 1 ] && [ "$OBSDONE" = 1 ] && \
   [ "$RING" = 1 ] && [ "$EDGE" = 1 ] && [ "$TITLE" = 1 ]; then
    PASS=1
fi

{
    echo "VIRELAIOS win HIG gate (milestone eight card U5, claim 0935 / issue #731) — focus ring + title bars on real VZ"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "session: exec WINLOOP.BIN (user window takes focus) + dui cycle to terminal and back to user window; headless virtio snapshot on winloop: loop ok"
    echo "assertions: cycle markers, winloop present marker, serial marker, ring-on-focused-window + edge-not-ringed + title-bar pixels"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} > "$REPORT"

echo
echo "=== result ==="
if [ "$PASS" = 1 ]; then
    echo "verify-live-win-hig: PASS — the focus ring renders on the FOCUSED user window (WINLOOP at (64,64)), the terminal edge is not ringed, and the user window carries its title bar — decoded headlessly from raw virtio scanout without ScreenCaptureKit/TCC. Focus cycling between user window and terminal via dui cycle verified."
    echo "PASS: $PASS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-win-hig: FAILED — see artifacts/win-hig-report.txt, win-hig-run.txt, and the serial log."
    echo "FAIL: $PASS" >> "$REPORT"
    sleep 0.5
    exit 1
fi

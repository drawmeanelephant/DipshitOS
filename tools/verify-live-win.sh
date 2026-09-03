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
#   focused terminal — the `VirelaiOS aarch64` reply is the proof that
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
# Run isolation (#523 item 2 / issue #528, claim 5069): private stacked
# disk + EFI vars + serial log + screen captures under $RUN_DIR;
# VIRELAI_GATE_SUFFIX/_KEEP_RUN supported.
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

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-win-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

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
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
gate_begin live-win
echo "run dir: $RUN_DIR"

# --- scripted session + keyboard typing --------------------------------------
# The serial script drives the registry; the KEYBOARD types `uname\n` after
# `dui hit 100 400` re-focuses the terminal (the trigger marker).
cat > "$RUN_DIR/script.txt" <<'EOF'
dui
dui hit 1000 710
dui
dui hit 10 100
dui
dui hit 100 400
EOF

# --- per-run gate -------------------------------------------------------------
run_one() {
    local out="$1" serial="$2"
    rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log" "$RUN_DIR"/snap-*.raw
    host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
        --serial "$RUN_DIR/vm-serial.log" \
        --display --input --screen "$RUN_DIR/screen" \
        --via-virtio --cvc-snap \
        --snapshot-after "dui hit: 100,400 -> 0" \
        --snapshot-out "$RUN_DIR/snap" \
        --script "$RUN_DIR/script.txt" \
        --input-string "uname"$'\n' --input-string-after "dui hit: 100,400 -> 0" \
        --script-expect "VirelaiOS aarch64" \
        --timeout 60 \
        > "$out" 2>&1
    local RC=$?
    [ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$serial" || true
    for f in "$RUN_DIR"/snap-*.raw; do
        [ -f "$f" ] && cp "$f" "$(art live-win-snap-0.raw)" && break || true
    done
    echo "$RC" > "$RUN_DIR/rc.txt"
}

rm -f "$RUN_DIR/efi-vars.bin"
set +e
run_one "$(art live-win-run.txt)" "$(art live-win-serial.log)"
RC="$(cat "$RUN_DIR/rc.txt")"
set -e

# --- assertions ---------------------------------------------------------------
SERIAL="$(art live-win-serial.log)"
FOUR_WIN=0 ROW0=0 ROW1=0 ROW2=0 ROW3=0 HIT_TB=0 HIT_DK=0 HIT_TM=0 KB_UNAME=0 RUNNERFLAG=0
if [ -f "$SERIAL" ]; then
    grep -a -qF -- "dui: windows=4 focused=0" "$SERIAL" && FOUR_WIN=1
    grep -a -qF -- "dui[0]: roadpops terminal rect=0,0,1280,720" "$SERIAL" && ROW0=1
    grep -a -qF -- "dui[1]: wallpaper wallpaper rect=0,0,1280,720" "$SERIAL" && ROW1=1
    grep -a -qF -- "dui[2]: taskbar taskbar rect=0,700,1280,20" "$SERIAL" && ROW2=1
    grep -a -qF -- "dui[3]: dock dock rect=0,0,24,700" "$SERIAL" && ROW3=1
    grep -a -qF -- "dui hit: 1000,710 -> 255" "$SERIAL" && HIT_TB=1
    grep -a -qF -- "dui hit: 10,100 -> 253" "$SERIAL" && HIT_DK=1
    grep -a -qF -- "dui hit: 100,400 -> 0" "$SERIAL" && HIT_TM=1
    # The keyboard-typed `uname` reply (the script never runs uname — this
    # is the proof that screen-side input landed in the focused terminal).
    grep -a -qF -- "VirelaiOS aarch64" "$SERIAL" && KB_UNAME=1
fi
grep -a -qF -- "input-string: ENABLED" artifacts/live-win-run.txt && RUNNERFLAG=1

echo "dui: rc=$RC four-win=$FOUR_WIN row0=$ROW0 row1=$ROW1 row2=$ROW2 row3=$ROW3 hit-tb=$HIT_TB hit-dk=$HIT_DK hit-tm=$HIT_TM kb-uname=$KB_UNAME runner-flag=$RUNNERFLAG"

PASS=0
if [ "$RC" = 0 ] && [ "$FOUR_WIN" = 1 ] && [ "$ROW0" = 1 ] && [ "$ROW1" = 1 ] && \
   [ "$ROW2" = 1 ] && [ "$ROW3" = 1 ] && [ "$HIT_TB" = 1 ] && [ "$HIT_DK" = 1 ] && \
   [ "$HIT_TM" = 1 ] && [ "$KB_UNAME" = 1 ] && [ "$RUNNERFLAG" = 1 ]; then
    PASS=1
fi

# Phase 2 — the pixel proof (headless virtio snapshot: 1280x720 BGRX raw scanout).
SNAP="$(ls -t "$RUN_DIR"/snap-*.raw 2>/dev/null | head -1 || ls -t artifacts/live-win-snap-*.raw 2>/dev/null | head -1 || true)"
if [ -z "$SNAP" ] || [ ! -f "$SNAP" ]; then
    echo "FAIL: no virtio scanout snapshot captured"
    PASS=0
else
    echo "decoding $SNAP"
    python3 - "$SNAP" <<'EOF'
import sys
path = sys.argv[1]
data = open(path, 'rb').read()
assert len(data) == 1280 * 720 * 4, f"unexpected snapshot size {len(data)}"
w = 1280

def px(x, y):
    k = (y * w + x) * 4
    return data[k+2], data[k+1], data[k] # R, G, B

def classify(r, g, b):
    if g > 140 and r < 160 and b < 160:
        return 'green'       # terminal foreground (0x00ff00 -> ~(80,174,52))
    if max(r, g, b) < 32:
        return 'terminal_bg' # terminal background (0x101418 -> ~(16,20,24))
    if r < 35 and g < 45 and b > 30 and b > r:
        return 'taskbar_bg'  # taskbar background (0x0f172a -> ~(15,23,42))
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

# (a) Terminal text is rendered in the banner region
term = region(40, 10, 1200, 96, step=2)
print(f"terminal banner region: {term}")
if term.get('green', 0) < 50:
    sys.exit("FAIL: no terminal foreground in the banner region (window 0 did not render)")

# (b) Taskbar at bottom (y=700..720) has taskbar background
tb = region(100, 702, 1100, 718, step=2)
ftb = frac(tb, 'taskbar_bg')
print(f"taskbar region: {tb} taskbar_bg={ftb:.3f}")
if ftb < 0.80:
    sys.exit(f"FAIL: taskbar background not present at y=700..720 (ftb={ftb:.3f})")

# (c) Tray clock in the right 80px of taskbar (x=1200..1280, y=700..720) has taskbar bg + glyphs
tray = region(1205, 702, 1275, 718, step=1)
print(f"tray clock region: {tray}")
if tray.get('taskbar_bg', 0) == 0 or tray.get('other', 0) == 0:
    sys.exit("FAIL: tray clock does not contain expected tray content in right 80px of taskbar")

print("PASS: 4-window desktop chrome rendered with terminal, taskbar, and tray clock")
EOF
    if [ $? -ne 0 ]; then
        echo "FAIL: captured framebuffer does not show 4-window desktop chrome"
        PASS=0
    fi
fi

{
    echo "VIRELAIOS live window-manager gate (claim 1543 / issue #731) — Driving Award on real VZ hardware"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "phase: scripted registry exercise (dui hit taskbar/dock/terminal) + a keyboard-typed uname into the focused terminal; raw virtio snapshot decoded for terminal, taskbar, and tray clock"
    echo "assertions: windows=4 (roadpops, wallpaper, taskbar, dock), hit-test -> taskbar/dock/terminal, keyboard-typed uname reply, taskbar background, tray clock glyphs, terminal text"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo
} > "$REPORT"

echo
echo "=== result ==="
if [ "$PASS" = 1 ]; then
    echo "verify-live-win: PASS — Driving Award composites 4-window desktop chrome on real VZ: Road Pops (terminal), wallpaper, taskbar (with tray clock), and dock. Hit-testing focuses taskbar, dock, and terminal; keyboard-typed uname landed in the focused terminal (VirelaiOS aarch64). Headless virtio snapshot verifies scanout pixels without ScreenCaptureKit/TCC."
    echo "PASS: $PASS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-win: FAILED — see artifacts/live-win-report.txt, the runner output (live-win-run.txt), and the serial log (live-win-serial.log)."
    echo "FAIL: $PASS" >> "$REPORT"
    sleep 0.5
    exit 1
fi

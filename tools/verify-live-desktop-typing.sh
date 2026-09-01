#!/usr/bin/env bash
#
# verify-live-desktop-typing.sh -- issue #563 class-B regression gate:
# keyboard input reaches a GUI app launched by DESKTOP.BIN through the
# EL0 exec seam (sys_exec, slot 28).
#
# Issue #563 reported "virtio INPUT queue stops polling after desktop
# launches a GUI app". Root cause (claim 1382, 2026-08-26): the guest's
# input path is healthy — poll_input() keeps draining and focus hands to
# the launched app — but the issue's repro typed the ENTIRE launch+letters
# chord list as ONE untimed burst after "desktop: menu ready". The letters
# were drained by the shell idle loop WHILE sys_exec was still in flight
# (before the app's window existed), so they were routed to the still-
# focused launcher (DESKTOP) and consumed there. Gates that launch from
# the desktop must therefore phase their injection: launch chords after
# the menu marker, then typing chords after the app's ready marker.
#
# This gate proves the fixed pattern end to end on real VZ hardware:
#   1. exec DESKTOP.BIN, wait for "desktop: menu ready"
#   2. inject 10 down-arrows + return (launch EDIT.BIN, manifest index 10)
#   3. wait for "edit: ready" (the app's window exists and holds focus)
#   4. type a,b,c,d,e over the custom-virtio INPUT queue (claim 9588)
#      gated on its own marker: --input-string ... --input-string-after
#   5. assert the letters reached the app:
#        - `input` report events=16 (11 launch + 5 typed KEY_DOWNs decoded)
#        - `dui` shows EDIT's window focused (focused=3, owner=2)
#        - screenshot: white glyph pixels in EDIT's text area (the letters
#          were RENDERED, not just routed)
#
# Run isolation (#523 item 2 / issue #528, claim 5069): private stacked
# disk + EFI vars + serial log under $RUN_DIR.
#
# Class B — Apple silicon + VZ only; boots a real VM (SPIKE runner,
# --via-virtio).
#
# Usage:
#   bash tools/verify-live-desktop-typing.sh
#
# Evidence under artifacts/: live-desktop-typing-*.
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-desktop-typing-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-desktop-typing-report.txt)"

echo "=== verify-live-desktop-typing: issue #563 — keys reach a desktop-launched GUI app on VZ ==="

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# --- build gates ------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig user/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation ------------------------------------------------------
gate_begin live-desktop-typing
gate_seed_share
echo "run dir: $RUN_DIR"

cat > "$RUN_DIR/script.txt" <<'EOF'
exec DESKTOP.BIN
EOF

# Timing (heartbeat ticks are a fixed 1 Hz cadence, unlike wall-clock
# sleeps): the letters drain + render at the shell-idle-pass cadence
# (~1.3 reports/s through the 8-buffer virtio pool), finishing by ~tick 24.
# Capture at tick 30 (pixels must show the rendered letters) and sweep at
# tick 35 — the screenshot marker must precede the expect marker or the
# runner's expect-check finishes the VM before the capture fires.
cat > "$RUN_DIR/script2.txt" <<'EOF'
procs
dui
input
tasks
echo desktop-typing-sweep-done
EOF

rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log"
rm -f "$RUN_DIR"/gpu-screen-*

set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial.log" \
    --display --screen "$RUN_DIR/gpu-screen" \
    --via-virtio \
    --script "$RUN_DIR/script.txt" \
    --input-chords "down,down,down,down,down,down,down,down,down,down,return" \
    --input-chords-after "desktop: menu ready" \
    --input-string "abcde" \
    --input-string-after "edit: ready" \
    --script2 "$RUN_DIR/script2.txt" \
    --script2-after "timer heartbeat ticks=35" \
    --screenshot-after "timer heartbeat ticks=30" \
    --script-expect "desktop-typing-sweep-done" \
    --timeout 150 > "$(art live-desktop-typing-run.txt)" 2>&1
RC=$?
set -e

[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-desktop-typing-serial.log)" || true
cp "$RUN_DIR"/gpu-screen-* artifacts/ 2>/dev/null || true
SER="$(art live-desktop-typing-serial.log)"

echo "VMRunner exit code: $RC"
if [ $RC -ne 0 ]; then
    echo "ERROR: VMRunner failed with return code $RC"
    cat "$(art live-desktop-typing-run.txt)"
    exit 1
fi

# --- serial assertions ------------------------------------------------------
PASS=1
fail() { echo "ERROR: $1"; PASS=0; }

grep -q "desktop: menu ready" "$SER" || fail "desktop: menu ready missing"
grep -q "desktop: launch EDIT.BIN pid=2" "$SER" || fail "desktop: launch EDIT.BIN missing"
[ "$(grep -a -c "desktop: select app" "$SER")" -ge 10 ] || fail "fewer than 10 select-app markers"
grep -q "edit: ready" "$SER" || fail "edit: ready missing"

# All 11 launch chords + 5 typed letters reached decode_keyboard_report.
grep -a -q "input: armed=0 fifo=0/64 dropped=0 events=16" "$SER" || {
    echo "--- input report observed: ---"
    grep -a "input:" "$SER" | tail -3 || true
    fail "input events != 16 (letters did not reach the decode path)"
}

# EDIT (pid 2, window id 3) is focused at sweep time.
grep -q "dui: windows=6 focused=3" "$SER" || fail "dui focus != 3 (EDIT not focused)"
grep -a -q 'dui\[[0-9]*\]: user user rect=64,48,512,384' "$SER" || fail "EDIT window rect missing from dui"
grep -a -q "owner=2" "$SER" || fail "EDIT window owner=2 missing from dui"

# --- pixel proof: the letters were RENDERED in EDIT's text area ------------
# EDIT window logical (64,48,512,384) -> retina (128,96,1024,768) at the
# 2x ScreenCaptureKit scale. The gutter's line numbers occupy retina
# x ~120..127; the first text row's glyphs were OBSERVED (claim 1382, run
# evidence) at retina x 194..266, y 169..182 — five clusters ~16 px apart
# ('a'..'e'). The gate samples a generous band around that row, PAST the
# gutter (x >= 180), so only typed-text pixels (not line numbers) count.
SHOT="$(art gpu-screen-after 2>/dev/null || true)"
[ -f "$SHOT" ] || SHOT="artifacts/gpu-screen-after${SUFFIX}"
if [ ! -f "$SHOT" ]; then
    echo "ERROR: no gpu-screen-after capture found"
    PASS=0
else
    python3 - "$SHOT" <<'PYEOF'
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

# Retina band around the observed first-text-row glyphs.
white = 0
for y in range(155, 235, 2):
    for x in range(180, 430, 2):
        r, g, b = px(x, y)
        if min(r, g, b) > 170:
            white += 1
print("white-glyph samples in EDIT text region: %d" % white)
if white < 50:
    print("ERROR: too few white glyph pixels — the letters were not rendered")
    sys.exit(1)
PYEOF
    [ $? -eq 0 ] || fail "EDIT text-area pixel proof failed"
fi

# --- report -----------------------------------------------------------------
cat > "$REPORT" <<EOF
=== Issue #563 Desktop-Launched GUI App Input Regression Gate ===
Revision: $REVISION ($BRANCH)
Status: $([ $PASS -eq 1 ] && echo "PASS (1/1 on Apple Virtualization.framework)" || echo "FAIL")

Verified End to End:
- DESKTOP.BIN launched from the monitor; menu ready.
- 10 injected down-arrows moved the launcher selection (10 select-app markers).
- Return launched EDIT.BIN through the EL0 exec seam (sys_exec slot 28).
- After 'edit: ready', 5 letters were injected over the custom-virtio
  INPUT queue (claim 9588) and reached the focused app:
  - input report events=16 (all 5 post-launch KEY_DOWNs decoded)
  - dui focused=3, EDIT's window owner=2
  - screenshot: white glyph pixels in EDIT's text region

Serial Output Highlights:
$(grep -a -E '(desktop: (menu ready|launch|select app)|edit: ready|input:|dui: windows)' "$SER" | tail -20 || true)
EOF

echo "verify-live-desktop-typing: $([ $PASS -eq 1 ] && echo PASS — desktop-launched GUI app receives and renders keyboard input on VZ || echo FAIL)"
[ $PASS -eq 1 ]
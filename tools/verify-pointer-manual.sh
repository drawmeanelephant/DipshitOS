#!/usr/bin/env bash
#
# verify-pointer-manual.sh -- milestone eight card U4 (claim 4993, ADR 0008
# D4) class-C gate: a REAL mouse over the --display window moves focus under
# the pointer_tick path.
#
# WHY CLASS C: the five synthesized pointer delivery routes (claim 4993,
# hardware-contract) each produced ptr-reports=0 in the guest -- VZ's view
# does NOT translate programmatically-posted mouse NSEvents into HID reports
# for the VZUSBScreenCoordinatePointingDevice. Only a REAL mouse moved by a
# human over the VZVirtualMachineView can produce the reports. So this gate
# cannot be automated and cannot run in CI; it needs a human at the mouse.
#
# Mechanism: ONE --input --display run with a generous --timeout. A setup
# script (over serial) opens WINLOOP.BIN (a long-lived user window) and
# reports the registry, so there are three windows to click between: the
# terminal (0), the clock (1), and WINLOOP (2). The human then:
#   1. moves the REAL mouse over the VM window -- the magenta cursor
#      (0xff00ff) appears and follows the pointer;
#   2. clicks the clock window, then WINLOOP, then the terminal -- each
#      click hit-tests the topmost window and prints `dui: pointer focus=<id>`;
#   3. types `input` (real keyboard over the VZ USB HID path) so the report
#      shows ptr-reports>0;
#   4. types `echo pointer-gate-done` -- the runner's --expect fires and the
#      run ends cleanly.
#
# Assertions (the guest's own serial evidence):
#   * >=2 DISTINCT `dui: pointer focus=<id>` lines -- a real click moved
#     focus between windows (D4's headline);
#   * `ptr-reports=<N>` with N>0 -- a REAL pointer report reached the guest
#     (the exact evidence the synthesized routes failed to produce);
#   * the magenta cursor pixel in the marker-driven capture -- the cursor
#     actually rendered on the scanout;
#   * the `pointer-gate-done` completion marker + runner exit 0.
#
# Class C -- Apple silicon + VZ only; a human at the mouse is REQUIRED.
# Not in CI (ci=no); not automatable.
#
# Usage:
#   bash tools/verify-pointer-manual.sh
#
# Evidence: artifacts/pointer-manual-gate.txt,
# artifacts/pointer-manual-report.txt, artifacts/pointer-screen-after.png.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/pointer-manual-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

REPORT="artifacts/pointer-manual-report.txt"
SCREEN_BASE="artifacts/pointer-screen"

echo "=== verify-pointer-manual: card U4 (claim 4993) -- a REAL mouse moves focus over VZ (class C) ==="

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# --- build gates ------------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- the human's instructions (printed BEFORE the VM boots) -----------------
cat <<'EOF'

>>>>>>>>>> REAL-MOUSE POINTER GATE -- PLEASE READ <<<<<<<<<<

A VM window titled with the Road Pops framebuffer will open (1280x720).
On the upper-left of the screen there is the clock window (amber title
bar) and, once the setup script runs, a second window (WINLOOP, the dark
blue blocks). Do this, in order:

  1. Move your REAL mouse over the VM window. A MAGENTA cursor should
     appear under the pointer and follow it.
  2. CLICK the clock window (upper area). The terminal should print:
         dui: pointer focus=1
  3. CLICK the WINLOOP window (the blue-blocks window). It should print:
         dui: pointer focus=2
  4. CLICK the terminal background (anywhere below the windows):
         dui: pointer focus=0
  5. In the VM window, TYPE:  input   then press Enter. Confirm the line
     ends in  ptr-reports=<N>  with N > 0  (a real report arrived).
  6. TYPE:  echo pointer-gate-done   then press Enter. This ends the run.

If the cursor does not follow your mouse, or no `dui: pointer focus=`
line appears on a click, that is the negative result -- let the timeout
expire and the gate will FAIL honestly.

EOF

# --- the session ------------------------------------------------------------
cat > artifacts/pointer-manual-script.txt <<'EOF'
dui
exec WINLOOP.BIN
dui
echo pointer-manual-ready
EOF

rm -f artifacts/efi-vars.bin artifacts/vm-serial.log "$SCREEN_BASE"*
set +e
host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
    --input --display \
    --script artifacts/pointer-manual-script.txt \
    --screen "$SCREEN_BASE" --screenshot-after "pointer-gate-done" \
    --expect "pointer-gate-done" \
    --timeout 240 \
    > artifacts/pointer-manual-run.txt 2>&1
RC=$?
set -e

# --- serial assertions --------------------------------------------------------
SERIAL="artifacts/vm-serial.log"
READY=0 FOCUS_LINES=0 DISTINCT_FOCUS=0 PTR_REPORTS=0 PTR_GT0=0 DONE=0
if [ -f "$SERIAL" ]; then
    grep -a -qF -- "pointer-manual-ready" "$SERIAL" && READY=1
    # Distinct focus ids: the D4 "click moves focus BETWEEN windows" proof.
    FOCUS_LINES=$(grep -a -c "dui: pointer focus=" "$SERIAL" || true)
    DISTINCT_FOCUS=$(grep -a -o "dui: pointer focus=[0-9]*" "$SERIAL" | sort -u | wc -l | tr -d ' ' || true)
    # A real pointer report (the synthesized routes all produced 0).
    PTR_REPORTS=$(grep -a -o "ptr-reports=[0-9]*" "$SERIAL" | tail -1 | cut -d= -f2 || true)
    PTR_REPORTS=${PTR_REPORTS:-0}
    if [ "$PTR_REPORTS" -gt 0 ] 2>/dev/null; then PTR_GT0=1; fi
    grep -a -qF -- "pointer-gate-done" "$SERIAL" && DONE=1
fi

# --- pixel assertion: the magenta cursor rendered ---------------------------
CURSOR=0
CAP="$(ls -t "$SCREEN_BASE"-after.png 2>/dev/null | head -1 || true)"
if [ -n "$CAP" ]; then
    echo "decoding $CAP"
    python3 - "$CAP" <<'EOF'
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

# The cursor is magenta (0xff00ff): R and B high, G low. Calibrated live
# (a `screen fill ff00ff` marker capture): magenta renders as ~(234,51,247)
# through the host's color-managed pipeline, so look for the FAMILY
# (R and B both clearly above G) rather than the exact triple. No other
# on-screen element matches -- terminal fg is green, the clock title bar is
# amber, and WINLOOP's blocks are red/cyan/white (red has low B, cyan has
# high G) -- so a magenta-family pixel is the cursor unambiguously.
found = 0
for y in range(0, h, 2):
    for x in range(0, w, 2):
        o = y * stride + x * bpp
        r, g, b = out[o], out[o+1], out[o+2]
        if r > 140 and b > 140 and g < 110 and r - g > 60 and b - g > 60:
            found += 1
print(f"CURSOR_PIXEL magenta_family_samples={found}")
sys.exit(0 if found > 0 else 1)
EOF
    CURSOR=$?
    if grep -a -q "magenta_family_samples=[1-9]" "$GATE_LOG"; then CURSOR=1; fi
else
    echo "note: no marker capture PNG (the run may have ended before pointer-gate-done)"
fi

echo "pointer-manual: rc=$RC ready=$READY focus-lines=$FOCUS_LINES distinct=$DISTINCT_FOCUS ptr-reports=$PTR_REPORTS done=$DONE cursor=$CURSOR"

PASS=0
if [ "$RC" = 0 ] && [ "$READY" = 1 ] && [ "$DISTINCT_FOCUS" -ge 2 ] && \
   [ "$PTR_GT0" = 1 ] && [ "$DONE" = 1 ] && [ "$CURSOR" = 1 ]; then
    PASS=1
fi

{
    echo "VIRELAIOS manual pointer-focus gate (milestone eight card U4, claim 4993) -- a REAL mouse moves focus under pointer_tick, on real VZ (class C)"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "session: setup opens WINLOOP.BIN; the HUMAN moves a real mouse and clicks clock -> WINLOOP -> terminal, types input, then echo pointer-gate-done"
    echo "assertions: ready marker, >=2 distinct focus lines, ptr-reports>0, the magenta cursor pixel, the done marker + runner exit 0"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} > "$REPORT"

echo
echo "=== result ==="
if [ "$PASS" = 1 ]; then
    echo "verify-pointer-manual: PASS -- a REAL mouse click moved focus between windows (>=2 distinct win: pointer focus lines), a real pointer report reached the guest (ptr-reports=$PTR_REPORTS), and the magenta cursor rendered on the scanout -- the claim-4993 live-seam blocker is RESOLVED for the real-mouse path."
    echo "PASS: $PASS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-pointer-manual: FAILED -- see artifacts/pointer-manual-report.txt, pointer-manual-run.txt, and the serial log. If a human did not move a real mouse this is the expected negative result."
    echo "FAIL: $PASS" >> "$REPORT"
    sleep 0.5
    exit 1
fi

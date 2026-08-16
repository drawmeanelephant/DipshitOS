#!/usr/bin/env bash
#
# verify-live-pointer-cg.sh -- milestone eight card U4 (claim 4993) CG
# follow-on (claim 3692) class-B gate: the CGEventPost pointer route drives
# pointer reports + click-to-focus, GATED on Accessibility trust.
#
# WHY THIS EXISTS: the four in-process synthesized routes (direct view
# calls, window sendEvent, NSApp.postEvent, a mouseEntered preamble) each
# produced ptr-reports=0 -- VZ's view does not translate them. Route 5,
# CGEventPost at the HID tap, was ALSO 0, but silently: it was dropped
# because the terminal lacks Accessibility trust. The runner now reports
# that honestly (`PTR-TRUST: untrusted`) instead of silently dropping.
#
# This gate is class B *once the one-time human grant exists*: it self-
# gates on trust. WITHOUT trust it FAILS with the exact grant steps (the
# grant is a System Settings action, not something a gate can automate).
# WITH trust, the synthesized CG pointer seam drives the guest end to end,
# so the gate is fully automatable -- the class-C real-mouse gate
# (tools/verify-pointer-manual.sh, claim 9015) remains for the no-trust
# path, and this one supersedes it once trust is granted.
#
# Mechanism (trusted path): ONE --input --display run. The setup script
# opens WINLOOP.BIN (three windows); the runner's --pointer seam posts the
# click sequence over route "cg" at the HID tap in GLOBAL screen coords,
# exactly like a physical mouse. The gate asserts the guest's own serial
# evidence: >=2 distinct `dui: pointer focus=<id>` lines (a synthesized
# click moved focus between windows), `ptr-reports>0`, the magenta cursor
# pixel in the marker capture, and the done marker + exit 0.
#
# Class B -- Apple silicon + VZ; the Accessibility grant is a one-time
# per-machine precondition (like Screen Recording for the screenshot
# gates). Not in CI (ci=no; the grant is machine-local).
#
# Usage:
#   bash tools/verify-live-pointer-cg.sh
#   bash tools/verify-live-pointer-cg.sh --request-trust   # prompt System Settings first
#
# Evidence: artifacts/pointer-cg-gate.txt,
# artifacts/pointer-cg-report.txt, artifacts/pointer-cg-screen-after.png.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

REQUEST_TRUST=0
[ "${1:-}" = "--request-trust" ] && REQUEST_TRUST=1

GATE_LOG="artifacts/pointer-cg-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

REPORT="artifacts/pointer-cg-report.txt"
SCREEN_BASE="artifacts/pointer-cg-screen"

echo "=== verify-live-pointer-cg: card U4 (claim 4993) CG follow-on (claim 3692) -- the CGEventPost route, gated on Accessibility trust ==="

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

# --- Accessibility trust preflight -----------------------------------------
# The CG HID-tap post is silently dropped without Accessibility for the
# responsible process (the terminal). Report the truth; a gate cannot
# grant TCC. CGPreflightPostEventAccess is the precise check (posting, not
# listening).
cat > /tmp/dipshitos-trust-probe.swift <<'EOF'
import ApplicationServices
import CoreGraphics
print(CGPreflightPostEventAccess() && AXIsProcessTrusted() ? "1" : "0")
EOF
TRUST="$(swift /tmp/dipshitos-trust-probe.swift 2>/dev/null | tail -1 || echo 0)"
rm -f /tmp/dipshitos-trust-probe.swift
TRUST="${TRUST:-0}"
echo "accessibility-trust: post=$TRUST"

if [ "$TRUST" != "1" ]; then
    cat <<'EOF'

FAIL: the CG pointer route needs Accessibility trust, which the terminal
does NOT currently hold. Grant it ONCE (a human action), then re-run:

  1. System Settings -> Privacy & Security -> Accessibility
  2. enable your terminal (Terminal.app / iTerm2 / VS Code / the process
     running this script), or add it if absent
  3. re-run:  bash tools/verify-live-pointer-cg.sh

Or run with  --request-trust  to have the runner prompt the system:

  bash tools/verify-live-pointer-cg.sh --request-trust

Until then the honest result is the class-C real-mouse gate:
  bash tools/verify-pointer-manual.sh

EOF
    {
        echo "DIPSHITOS pointer CG gate (milestone eight card U4, claim 4993 follow-on, claim 3692) -- TRUST PRECONDITION NOT MET"
        echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
        echo "accessibility-trust: $TRUST (the CG HID-tap post is dropped without it)"
        echo "action: grant Accessibility to the terminal in System Settings, then re-run (or use --request-trust)"
        echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } > "$REPORT"
    echo
    echo "=== result ==="
    echo "verify-live-pointer-cg: FAILED (trust precondition) -- Accessibility is not granted to the terminal; see the grant steps above."
    echo "TRUST: $TRUST" >> "$REPORT"
    sleep 0.5
    exit 1
fi

# --- the session ------------------------------------------------------------
cat > artifacts/pointer-cg-script.txt <<'EOF'
dui
exec WINLOOP.BIN
dui
echo pointer-cg-ready
EOF

# The pointer sequence clicks the clock (window 1, upper area), then
# WINLOOP (window 2, upper-left), then the terminal (window 0, below) --
# three distinct focus moves. Coordinates are guest pixels (y from top).
PTR_SEQ="960,100;960,100,c;200,150;200,150,c;640,600;640,600,c"

EXTRA=()
[ "$REQUEST_TRUST" = 1 ] && EXTRA=(--pointer-request-trust)

rm -f artifacts/efi-vars.bin artifacts/vm-serial.log "$SCREEN_BASE"*
set +e
host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
    --input --display \
    --script artifacts/pointer-cg-script.txt \
    --screen "$SCREEN_BASE" --screenshot-after "pointer-cg-done" \
    --pointer "$PTR_SEQ" --pointer-after "winloop: present ok" --pointer-route cg \
    "${EXTRA[@]}" \
    --expect "pointer-cg-done" \
    --timeout 240 \
    > artifacts/pointer-cg-run.txt 2>&1
RC=$?
set -e

# --- serial assertions --------------------------------------------------------
SERIAL="artifacts/vm-serial.log"
READY=0 FOCUS_LINES=0 DISTINCT_FOCUS=0 PTR_REPORTS=0 PTR_GT0=0 DONE=0 UNTRUSTED=0
if [ -f "$SERIAL" ]; then
    grep -a -qF -- "pointer-cg-ready" "$SERIAL" && READY=1
    FOCUS_LINES=$(grep -a -c "dui: pointer focus=" "$SERIAL" || true)
    DISTINCT_FOCUS=$(grep -a -o "dui: pointer focus=[0-9]*" "$SERIAL" | sort -u | wc -l | tr -d ' ')
    PTR_REPORTS=$(grep -a -o "ptr-reports=[0-9]*" "$SERIAL" | tail -1 | cut -d= -f2 || true)
    PTR_REPORTS=${PTR_REPORTS:-0}
    if [ "$PTR_REPORTS" -gt 0 ] 2>/dev/null; then PTR_GT0=1; fi
    grep -a -qF -- "pointer-cg-done" "$SERIAL" && DONE=1
fi
grep -a -qF -- "PTR-TRUST: untrusted" artifacts/pointer-cg-run.txt && UNTRUSTED=1

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

# Magenta cursor (0xff00ff -> ~(234,51,247) through the color pipeline,
# claim 9015's calibration): R and B both clearly above G, the family no
# other on-screen element matches.
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
    echo "note: no marker capture PNG"
fi

echo "pointer-cg: rc=$RC ready=$READY focus-lines=$FOCUS_LINES distinct=$DISTINCT_FOCUS ptr-reports=$PTR_REPORTS done=$DONE cursor=$CURSOR untrusted=$UNTRUSTED"

PASS=0
if [ "$RC" = 0 ] && [ "$READY" = 1 ] && [ "$DISTINCT_FOCUS" -ge 2 ] && \
   [ "$PTR_GT0" = 1 ] && [ "$DONE" = 1 ] && [ "$CURSOR" = 1 ] && [ "$UNTRUSTED" = 0 ]; then
    PASS=1
fi

{
    echo "DIPSHITOS pointer CG gate (milestone eight card U4, claim 4993 follow-on, claim 3692) -- the CGEventPost route drives pointer reports + focus, on real VZ (class B)"
    echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"
    echo "accessibility-trust: $TRUST"
    echo "session: setup opens WINLOOP.BIN; the --pointer seam posts clock -> WINLOOP -> terminal clicks over route cg (global HID tap); input + echo pointer-cg-done end the run"
    echo "assertions: ready marker, >=2 distinct focus lines, ptr-reports>0, the magenta cursor pixel, no PTR-TRUST untrusted, the done marker + exit 0"
    echo "date: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} > "$REPORT"

echo
echo "=== result ==="
if [ "$PASS" = 1 ]; then
    echo "verify-live-pointer-cg: PASS -- the CGEventPost route (with Accessibility trust) drove synthesized clicks that moved focus between windows (>=2 distinct focus lines) and produced ptr-reports=$PTR_REPORTS, with the magenta cursor rendered -- U4's pointer proof is upgraded to class B."
    echo "PASS: $PASS" >> "$REPORT"
    sleep 0.5
    exit 0
else
    echo "verify-live-pointer-cg: FAILED -- see artifacts/pointer-cg-report.txt, pointer-cg-run.txt, and the serial log."
    echo "FAIL: $PASS" >> "$REPORT"
    sleep 0.5
    exit 1
fi

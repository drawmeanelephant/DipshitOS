#!/usr/bin/env bash
#
# verify-live-clipboard.sh -- claim 2611 (Milestone 14, Card S1) class-B
# gate: the shared clipboard seam (ADR 0007 slots 38/39) verified on real
# Apple silicon Virtualization.framework hardware.
#
# CLIPTEST.BIN drives the seam from EL0:
#   set "hello" -> get "hello" (byte-exact) -> truncated get "hel"
#   (non-consuming) -> still "hello" -> over-long set truncates at 512 ->
#   zero-length set clears -> empty get -> EFAULT on both directions.
# The syscalls report proves slots 38/39 were each called the exact number
# of times.
#
# Usage:
#   bash tools/verify-live-clipboard.sh
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-clipboard-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

REPORT="artifacts/live-clipboard-report.txt"

echo "=== verify-live-clipboard: claim 2611 — Milestone 14 S1 on VZ ==="

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
echo "revision: $REVISION branch=$BRANCH"

# Build all binaries and disk image
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

cat > artifacts/live-clipboard-script.txt <<'EOF'
exec CLIPTEST.BIN
EOF

cat > artifacts/live-clipboard-script2.txt <<'EOF'
echo done-clipboard
syscalls
EOF

STATIC_EXIT_LINE="tasks user-el0 exited status=7"

echo "--- Phase 1: Running CLIPTEST.BIN on VZ ---"
rm -f artifacts/efi-vars.bin
rm -f artifacts/vm-serial.log artifacts/gpu-screen-*

set +e
host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
    --script artifacts/live-clipboard-script.txt \
    --script-after "$STATIC_EXIT_LINE" \
    --script2 artifacts/live-clipboard-script2.txt \
    --script2-after "clip: done" \
    --script-expect "done-clipboard" \
    --timeout 60 > artifacts/live-clipboard-run.txt 2>&1
RC=$?
set -e

[ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log artifacts/live-clipboard-serial.log || true

echo "VMRunner exit code: $RC"
if [ $RC -ne 0 ]; then
    echo "ERROR: VMRunner failed with return code $RC"
    cat artifacts/live-clipboard-run.txt
    exit 1
fi

echo "--- Phase 2: Verifying CLIPTEST.BIN Markers ---"

grep -q "clip: set 5" artifacts/live-clipboard-serial.log || {
    echo "ERROR: clip: set 5 marker missing from serial log"
    exit 1
}
echo "CLIP.SET: OK"

grep -q "clip: got hello" artifacts/live-clipboard-serial.log || {
    echo "ERROR: clip: got hello marker missing from serial log"
    exit 1
}
echo "CLIP.GET: OK"

grep -q "clip: trunc hel" artifacts/live-clipboard-serial.log || {
    echo "ERROR: clip: trunc hel marker missing from serial log"
    exit 1
}
echo "CLIP.TRUNC: OK"

grep -q "clip: still hello" artifacts/live-clipboard-serial.log || {
    echo "ERROR: clip: still hello marker missing from serial log"
    exit 1
}
echo "CLIP.NONCONSUMING: OK"

grep -q "clip: cap 512" artifacts/live-clipboard-serial.log || {
    echo "ERROR: clip: cap 512 marker missing from serial log"
    exit 1
}
echo "CLIP.CAP: OK"

grep -q "clip: cleared" artifacts/live-clipboard-serial.log || {
    echo "ERROR: clip: cleared marker missing from serial log"
    exit 1
}
grep -q "clip: empty" artifacts/live-clipboard-serial.log || {
    echo "ERROR: clip: empty marker missing from serial log"
    exit 1
}
echo "CLIP.CLEAR: OK"

grep -q "clip: set efault" artifacts/live-clipboard-serial.log || {
    echo "ERROR: clip: set efault marker missing from serial log"
    exit 1
}
grep -q "clip: get efault" artifacts/live-clipboard-serial.log || {
    echo "ERROR: clip: get efault marker missing from serial log"
    exit 1
}
echo "CLIP.EFAULT: OK"

# The two new slots were called the exact number of times (set x4: hello +
# truncating set + zero-length clear + EFAULT; get x5: byte-exact + trunc +
# still + empty + EFAULT).
grep -q "38 sys_clipboard_set calls=4" artifacts/live-clipboard-serial.log || {
    echo "ERROR: sys_clipboard_set call count missing from syscalls report"
    exit 1
}
grep -q "39 sys_clipboard_get calls=5" artifacts/live-clipboard-serial.log || {
    echo "ERROR: sys_clipboard_get call count missing from syscalls report"
    exit 1
}
echo "SYS_CLIPBOARD_SET/GET: OK"

grep -q "tasks user-exec exited status=0" artifacts/live-clipboard-serial.log || {
    echo "ERROR: CLIPTEST.BIN exit status 0 missing from serial log"
    exit 1
}
grep -q "tasks user-exec reaped" artifacts/live-clipboard-serial.log || {
    echo "ERROR: CLIPTEST.BIN reap missing from serial log"
    exit 1
}
echo "CLIP.LIFECYCLE: OK"

grep -q "done-clipboard" artifacts/live-clipboard-serial.log || {
    echo "ERROR: final sweep marker missing from serial log"
    exit 1
}

cat > "$REPORT" <<EOF
=== Milestone 14 S1 Live Gate Report ===
Revision: $REVISION ($BRANCH)
Status: PASS (1/1 on Apple Virtualization.framework)

Verified Components:
- sys_clipboard_set (slot 38): set, truncating set, clear, EFAULT
- sys_clipboard_get (slot 39): byte-exact get, truncated get (non-consuming),
  empty get, EFAULT
- The one bounded kernel clipboard buffer (512 B BSS, no heap)
- CLIPTEST.BIN exit status 0 through the real lifecycle

Serial Output Highlights:
$(grep -E 'clip:|sys_clipboard_(set|get)|user-exec' artifacts/live-clipboard-serial.log || true)
EOF

echo "verify-live-clipboard: PASS — clipboard set/get verified on VZ."

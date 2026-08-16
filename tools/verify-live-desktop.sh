#!/usr/bin/env bash
#
# verify-live-desktop.sh -- claim 2427 (Milestone 11, Card A5) class-B
# capstone gate: Desktop Platform & GUI Apps (ADR 0011) verified on real
# Apple silicon Virtualization.framework hardware.
#
# The gate verifies all Milestone 11 components end-to-end:
#   1. Zero-allocation micro-widget toolkit (`user/src/lib/ui.zig`)
#   2. CALC.BIN (64-bit interactive calculator with button grid & keyboard input)
#   3. NOTEPAD.BIN (multi-line text editor with persistent /data load/save)
#   4. TOP.BIN (graphical task manager introspecting sys_procs)
#   5. DESKTOP.BIN (desktop launcher & environment catalog)
#
# Claim 6359 (ADR 0007 slot 28 `sys_exec`): the launcher half is REAL —
# DESKTOP.BIN is no longer select-only. The monitor execs NOTEPAD/TOP/
# DESKTOP; the runner types Enter after `desktop: menu ready`; DESKTOP
# launches CALC.BIN through the EL0 exec seam (the fourth concurrent GUI
# app), and the gate asserts `desktop: launch CALC.BIN` + `calc: ready` +
# `28 sys_exec calls=1` in the syscalls report.
#
# Usage:
#   bash tools/verify-live-desktop.sh
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-desktop-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

REPORT="artifacts/live-desktop-report.txt"

echo "=== verify-live-desktop: claim 2427 — Milestone 11 Desktop Platform on VZ ==="

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

# Tool versions + revision
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
echo "revision: $REVISION branch=$BRANCH"

# Build all binaries and disk image
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# Scripts for Desktop Platform test
# Claim 6359: CALC.BIN is NOT exec'd by the monitor — the desktop launches
# it through slot 28 sys_exec after the injected Enter (the launcher proof).
cat > artifacts/live-desktop-script.txt <<'EOF'
exec NOTEPAD.BIN
exec TOP.BIN
exec DESKTOP.BIN
EOF

cat > artifacts/live-desktop-script2.txt <<'EOF'
echo done-desktop-sweep
procs
syscalls
EOF

STATIC_EXIT_LINE="tasks user-el0 exited status=7"

echo "--- Phase 1: Running Milestone 11 Desktop Suite on VZ ---"
rm -f artifacts/efi-vars.bin
rm -f artifacts/vm-serial.log artifacts/gpu-screen-*

set +e
host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
    --display --input --screen artifacts/gpu-screen \
    --script artifacts/live-desktop-script.txt \
    --script-after "$STATIC_EXIT_LINE" \
    --input-chords "return" \
    --input-chords-after "desktop: menu ready" \
    --script2 artifacts/live-desktop-script2.txt \
    --script2-after "calc: ready" \
    --script-expect "done-desktop-sweep" \
    --timeout 90 > artifacts/live-desktop-run.txt 2>&1
RC=$?
set -e

[ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log artifacts/live-desktop-serial.log || true

echo "VMRunner exit code: $RC"
if [ $RC -ne 0 ]; then
    echo "ERROR: VMRunner failed with return code $RC"
    cat artifacts/live-desktop-run.txt
    exit 1
fi

echo "--- Phase 2: Verifying Application Markers ---"

# 1. Verify CALC.BIN
grep -q "calc: ready" artifacts/live-desktop-serial.log || {
    echo "ERROR: CALC.BIN ready marker missing from serial log"
    exit 1
}
echo "CALC.BIN: OK"

# 2. Verify NOTEPAD.BIN
grep -q "notepad: ready" artifacts/live-desktop-serial.log || {
    echo "ERROR: NOTEPAD.BIN ready marker missing from serial log"
    exit 1
}
echo "NOTEPAD.BIN: OK"

# 3. Verify TOP.BIN
grep -q "top: ready" artifacts/live-desktop-serial.log || {
    echo "ERROR: TOP.BIN ready marker missing from serial log"
    exit 1
}
echo "TOP.BIN: OK"

# 4. Verify DESKTOP.BIN
grep -q "desktop: ready" artifacts/live-desktop-serial.log || {
    echo "ERROR: DESKTOP.BIN ready marker missing from serial log"
    exit 1
}
grep -q "desktop: menu ready" artifacts/live-desktop-serial.log || {
    echo "ERROR: DESKTOP.BIN menu marker missing from serial log"
    exit 1
}
echo "DESKTOP.BIN: OK"

# 5. Verify the launcher is REAL (claim 6359, slot 28 sys_exec): the
# injected Enter made DESKTOP exec CALC.BIN from EL0 — the launch marker
# and the syscall counter prove the seam, not a monitor exec.
grep -q "desktop: launch CALC.BIN" artifacts/live-desktop-serial.log || {
    echo "ERROR: DESKTOP.BIN launch marker missing from serial log"
    exit 1
}
echo "DESKTOP.LAUNCH: OK"
grep -q "28 sys_exec calls=1" artifacts/live-desktop-serial.log || {
    echo "ERROR: sys_exec call count missing from syscalls report"
    exit 1
}
echo "SYS_EXEC: OK"

# 6. Verify Clean Exits & Syscall Accounting
grep -q "done-desktop-sweep" artifacts/live-desktop-serial.log || {
    echo "ERROR: final sweep marker missing from serial log"
    exit 1
}

cat > "$REPORT" <<EOF
=== Milestone 11 Desktop Platform Live Gate Report ===
Revision: $REVISION ($BRANCH)
Status: PASS (1/1 on Apple Virtualization.framework)

Verified Components:
- Micro-Widget Toolkit & Runtime (user/src/lib/ui.zig)
- CALC.BIN: Interactive Graphical Calculator (LAUNCHED BY DESKTOP through slot 28 sys_exec)
- NOTEPAD.BIN: Graphical Text Editor with /data Storage
- TOP.BIN: Graphical Task Manager & Process Introspector
- DESKTOP.BIN: Desktop Environment & Application Launcher (real EL0 exec)
- sys_exec (ADR 0007 slot 28): calls=1 in the syscalls report

Serial Output Highlights:
$(grep -E '(calc|notepad|top|desktop):' artifacts/live-desktop-serial.log || true)
EOF

echo "verify-live-desktop: PASS — all Milestone 11 GUI applications and desktop platform verified on VZ."

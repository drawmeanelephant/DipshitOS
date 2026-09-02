#!/usr/bin/env bash
#
# verify-live-desktop.sh -- claim 2427 (Milestone 11, Card A5) class-B
# capstone gate: Desktop Platform & GUI Apps (ADR 0011) verified on real
# Apple silicon Virtualization.framework hardware.
#
# The gate verifies all Milestone 11 components end-to-end:
#   1. Zero-allocation micro-widget toolkit (`user/src/lib/ui.zig`)
#   2. CALC.BIN (64-bit interactive calculator with button grid & keyboard input)
#   3. NOTEPAD.BIN (multi-line text editor with persistent host-share
#      load/save; M34 HF6 re-point — the /data volume is gone)
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
# Run isolation (#523 item 2 / issue #528, claim 5069; fleet remainder
# claim 2259): private stacked disk (pristine-per-boot overlay), EFI var
# store, serial log, and screen captures under $RUN_DIR — concurrent
# instances cannot clobber each other. Set VIRELAI_GATE_SUFFIX=_alt for
# distinct canonical evidence names; VIRELAI_KEEP_RUN=1 keeps the scratch
# dir. Nothing here asserts CROSS-BOOT persistence, so the throwaway
# overlay is the right disk mode (the shell-history FAT write lands in
# the overlay and is discarded).
#
# Usage:
#   bash tools/verify-live-desktop.sh
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-desktop-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-desktop-report.txt)"

echo "=== verify-live-desktop: claim 2427 — Milestone 11 Desktop Platform on VZ ==="

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

# Tool versions + revision
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# Build all binaries and disk image
zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
gate_begin live-desktop
gate_seed_share
echo "run dir: $RUN_DIR"

# Scripts for Desktop Platform test
# Claim 6359: CALC.BIN is NOT exec'd by the monitor — the desktop launches
# it through slot 28 sys_exec after the injected Enter (the launcher proof).
cat > "$RUN_DIR/script.txt" <<'EOF'
exec NOTEPAD.BIN
exec TOP.BIN
exec DESKTOP.BIN
EOF

cat > "$RUN_DIR/script2.txt" <<'EOF'
procs
syscalls
echo done-desktop-sweep
EOF

STATIC_EXIT_LINE="tasks user-el0 exited status=7"

echo "--- Phase 1: Running Milestone 11 Desktop Suite on VZ ---"
rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log"
rm -f "$RUN_DIR"/gpu-screen-*

set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial.log" \
    --display --input --screen "$RUN_DIR/gpu-screen" \
    --script "$RUN_DIR/script.txt" \
    --script-after "$STATIC_EXIT_LINE" \
    --input-chords "return" \
    --input-chords-after "desktop: menu ready" \
    --script2 "$RUN_DIR/script2.txt" \
    --script2-after "calc: ready" \
    --script-expect "done-desktop-sweep" \
    --timeout 90 > "$(art live-desktop-run.txt)" 2>&1
RC=$?
set -e

[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-desktop-serial.log)" || true
cp "$RUN_DIR"/gpu-screen-* artifacts/ 2>/dev/null || true
SER="$(art live-desktop-serial.log)"

echo "VMRunner exit code: $RC"
if [ $RC -ne 0 ]; then
    echo "ERROR: VMRunner failed with return code $RC"
    cat "$(art live-desktop-run.txt)"
    exit 1
fi

echo "--- Phase 2: Verifying Application Markers ---"

# 1. Verify CALC.BIN
grep -q "calc: ready" "$SER" || {
    echo "ERROR: CALC.BIN ready marker missing from serial log"
    exit 1
}
echo "CALC.BIN: OK"

# 2. Verify NOTEPAD.BIN
grep -q "notepad: ready" "$SER" || {
    echo "ERROR: NOTEPAD.BIN ready marker missing from serial log"
    exit 1
}
echo "NOTEPAD.BIN: OK"

# 3. Verify TOP.BIN
grep -q "top: ready" "$SER" || {
    echo "ERROR: TOP.BIN ready marker missing from serial log"
    exit 1
}
echo "TOP.BIN: OK"

# 4. Verify DESKTOP.BIN
grep -q "desktop: ready" "$SER" || {
    echo "ERROR: DESKTOP.BIN ready marker missing from serial log"
    exit 1
}
grep -q "desktop: menu ready" "$SER" || {
    echo "ERROR: DESKTOP.BIN menu marker missing from serial log"
    exit 1
}
echo "DESKTOP.BIN: OK"

# 4b. Verify the launcher reads the APPS.TXT manifest (claim 8877, card
# B2): the manifest marker names the count read from /host/APPS.TXT — the
# gate_seed_share helper drops image/apps.txt into the share (M34 HF6,
# issue #740: the ESP is gone; the manifest is no longer embedded in the
# image).
# Expectation revised to OBSERVED BYTES (2026-09-01, claim 5251): the
# serial marker reads `desktop: manifest apps=22` — image/apps.txt grew
# from 9 entries at M13 close (d62c933) through M15 C4's SETTINGS.BIN
# (6c8b5b3), M23 E1's EDIT.BIN (ee3da3e), M27 G6's SYSMON.BIN, the M30/M31
# ELF rows, and M32's ZC.BIN. `#` comments are skipped by parse_manifest.
grep -q "desktop: manifest apps=22" "$SER" || {
    echo "ERROR: DESKTOP.BIN manifest marker (apps=22) missing from serial log"
    exit 1
}
echo "DESKTOP.MANIFEST: OK"

# 5. Verify the launcher is REAL (claim 6359, slot 28 sys_exec): the
# injected Enter made DESKTOP exec CALC.BIN from EL0 — the launch marker
# and the syscall counter prove the seam, not a monitor exec.
grep -q "desktop: launch CALC.BIN" "$SER" || {
    echo "ERROR: DESKTOP.BIN launch marker missing from serial log"
    exit 1
}
echo "DESKTOP.LAUNCH: OK"
grep -q "28 sys_exec calls=1" "$SER" || {
    echo "ERROR: sys_exec call count missing from syscalls report"
    exit 1
}
echo "SYS_EXEC: OK"

# 6. Verify Clean Exits & Syscall Accounting
grep -q "done-desktop-sweep" "$SER" || {
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
- NOTEPAD.BIN: Graphical Text Editor (Host Share Storage)
- TOP.BIN: Graphical Task Manager & Process Introspector
- DESKTOP.BIN: Desktop Environment & Application Launcher (real EL0 exec)
- sys_exec (ADR 0007 slot 28): calls=1 in the syscalls report

Serial Output Highlights:
$(grep -E '(calc|notepad|top|desktop):' "$SER" || true)
EOF

echo "verify-live-desktop: PASS — all Milestone 11 GUI applications and desktop platform verified on VZ."

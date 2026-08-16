#!/usr/bin/env bash
#
# verify-live-file-browser.sh -- claim 4046 (Milestone 13, Card B4) class-B
# capstone gate: desktop composition, verified on real Apple silicon
# Virtualization.framework hardware.
#
# The gate proves the full B4 arc end-to-end from EL0, composing B2's
# manifest-driven launcher with B3's FILE.BIN:
#   1. DESKTOP.BIN boots and reads its menu from /esp/APPS.TXT — 9 entries,
#      FILE.BIN included (the manifest, not the hardcoded fallback).
#   2. The runner navigates the manifest menu to FILE.BIN and presses Enter;
#      DESKTOP launches it through the M11 sys_exec seam (slot 28).
#   3. FILE.BIN opens its own window (auto-focused), lists `/data/` via
#      sys_dir_list (slot 27), and the runner's second Enter opens the
#      selected README.TXT read-only via sys_file_open/read (slots 23/24).
#   4. The syscalls report proves the seam: sys_exec once, sys_dir_list once,
#      and file_open/file_read twice each (desktop manifest + FILE.BIN read).
#
# Delete/rename (B1, slots 34-37) are proven separately by
# tools/verify-live-fs-mutation.sh; this gate keeps the read-only browser
# arc deterministic.
#
# Usage:
#   bash tools/verify-live-file-browser.sh
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-file-browser-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

REPORT="artifacts/live-file-browser-report.txt"

echo "=== verify-live-file-browser: claim 4046 — Milestone 13 B4 desktop composition on VZ ==="

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

# Boot the desktop only; FILE.BIN is launched from EL0 by the desktop, never
# exec'd by the monitor (the composition proof).
cat > artifacts/live-file-browser-script.txt <<'EOF'
exec DESKTOP.BIN
EOF

cat > artifacts/live-file-browser-script2.txt <<'EOF'
echo done-file-sweep
syscalls
EOF

STATIC_EXIT_LINE="tasks user-el0 exited status=7"

# Eight Down arrows walk the 9-entry manifest menu from CALC.BIN (index 0)
# to FILE.BIN (index 8); the first Return launches it, the second Return
# (arriving once FILE.BIN's window is focused) opens README.TXT.
CHORDS="down,down,down,down,down,down,down,down,return,return"

echo "--- Phase 1: Running desktop composition (DESKTOP -> FILE.BIN) on VZ ---"
rm -f artifacts/efi-vars.bin
rm -f artifacts/vm-serial.log artifacts/gpu-screen-*

set +e
host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
    --display --input --screen artifacts/gpu-screen \
    --script artifacts/live-file-browser-script.txt \
    --script-after "$STATIC_EXIT_LINE" \
    --input-chords "$CHORDS" \
    --input-chords-after "desktop: menu ready" \
    --input-chords-delay 2.0 \
    --script2 artifacts/live-file-browser-script2.txt \
    --script2-after "file: view README.TXT" \
    --script-expect "done-file-sweep" \
    --timeout 90 > artifacts/live-file-browser-run.txt 2>&1
RC=$?
set -e

[ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log artifacts/live-file-browser-serial.log || true

echo "VMRunner exit code: $RC"
if [ $RC -ne 0 ]; then
    echo "ERROR: VMRunner failed with return code $RC"
    cat artifacts/live-file-browser-run.txt
    exit 1
fi

echo "--- Phase 2: Verifying the composition arc ---"

# 1. The desktop menu came from the manifest (9 entries, FILE.BIN included),
#    not the hardcoded fallback (claim 8877 + B4).
grep -q "desktop: manifest apps=9" artifacts/live-file-browser-serial.log || {
    echo "ERROR: desktop manifest marker (apps=9) missing from serial log"
    exit 1
}
echo "DESKTOP.MANIFEST: OK"

# 2. The desktop launched FILE.BIN through the EL0 exec seam (claim 6359).
grep -q "desktop: launch FILE.BIN" artifacts/live-file-browser-serial.log || {
    echo "ERROR: desktop launch FILE.BIN marker missing from serial log"
    exit 1
}
echo "DESKTOP.LAUNCH: OK"
grep -q "28 sys_exec calls=1" artifacts/live-file-browser-serial.log || {
    echo "ERROR: sys_exec call count missing from syscalls report"
    exit 1
}
echo "SYS_EXEC: OK"

# 3. FILE.BIN opened its window and browsed /data (claim 4742).
grep -q "file: ready" artifacts/live-file-browser-serial.log || {
    echo "ERROR: FILE.BIN ready marker missing from serial log"
    exit 1
}
echo "FILE.READY: OK"
grep -q "file: listing 2 entries" artifacts/live-file-browser-serial.log || {
    echo "ERROR: FILE.BIN listing marker (2 entries) missing from serial log"
    exit 1
}
echo "FILE.LIST: OK"
grep -q "27 sys_dir_list calls=1" artifacts/live-file-browser-serial.log || {
    echo "ERROR: sys_dir_list call count missing from syscalls report"
    exit 1
}
echo "SYS_DIR_LIST: OK"

# 4. The second Enter opened README.TXT read-only (the browse arc).
grep -q "file: open README.TXT" artifacts/live-file-browser-serial.log || {
    echo "ERROR: FILE.BIN open marker missing from serial log"
    exit 1
}
echo "FILE.OPEN: OK"
grep -q "file: view README.TXT" artifacts/live-file-browser-serial.log || {
    echo "ERROR: FILE.BIN view marker missing from serial log"
    exit 1
}
echo "FILE.VIEW: OK"

# 5. File seam accounting: two opens/reads — the desktop's manifest read
#    plus FILE.BIN's README.TXT read.
grep -q "23 sys_file_open calls=2" artifacts/live-file-browser-serial.log || {
    echo "ERROR: sys_file_open call count (calls=2) missing from syscalls report"
    exit 1
}
echo "SYS_FILE_OPEN: OK"
grep -q "24 sys_file_read calls=2" artifacts/live-file-browser-serial.log || {
    echo "ERROR: sys_file_read call count (calls=2) missing from syscalls report"
    exit 1
}
echo "SYS_FILE_READ: OK"

# 6. Clean sweep marker.
grep -q "done-file-sweep" artifacts/live-file-browser-serial.log || {
    echo "ERROR: final sweep marker missing from serial log"
    exit 1
}

cat > "$REPORT" <<EOF
=== Milestone 13 B4 Desktop Composition Live Gate Report ===
Revision: $REVISION ($BRANCH)
Status: PASS (1/1 on Apple Virtualization.framework)

Verified Components:
- DESKTOP.BIN: manifest-driven launcher (9 apps incl FILE.BIN, claim 8877)
- sys_exec (ADR 0007 slot 28): DESKTOP launches FILE.BIN from EL0
- FILE.BIN: lists /data and opens README.TXT read-only (claim 4742)
- sys_dir_list (slot 27) / sys_file_open+read (slots 23/24)

Serial Output Highlights:
$(grep -E 'desktop:|file:|sys_(exec|dir_list|file_open|file_read)' artifacts/live-file-browser-serial.log || true)
EOF

echo "verify-live-file-browser: PASS — DESKTOP.BIN launches FILE.BIN from the manifest menu and it browses /data on VZ."

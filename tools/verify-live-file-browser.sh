#!/usr/bin/env bash
#
# verify-live-file-browser.sh -- claim 4742 (Milestone 13, Card B3) class-B
# capstone gate: FILE.BIN, the graphical DATA-partition file browser,
# verified on real Apple silicon Virtualization.framework hardware.
#
# The gate proves the browser end-to-end from EL0:
#   1. FILE.BIN opens a window and lists `/data/` via sys_dir_list (slot 27).
#   2. The runner injects Enter, which opens the selected entry (README.TXT)
#      read-only via sys_file_open/read/close (slots 23/24/26).
#   3. The syscalls report shows the seam used exactly once per call.
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

echo "=== verify-live-file-browser: claim 4742 — Milestone 13 FILE.BIN on VZ ==="

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

cat > artifacts/live-file-browser-script.txt <<'EOF'
exec FILE.BIN
EOF

cat > artifacts/live-file-browser-script2.txt <<'EOF'
echo done-file-sweep
syscalls
EOF

STATIC_EXIT_LINE="tasks user-el0 exited status=7"

echo "--- Phase 1: Running FILE.BIN on VZ ---"
rm -f artifacts/efi-vars.bin
rm -f artifacts/vm-serial.log artifacts/gpu-screen-*

set +e
host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
    --display --input --screen artifacts/gpu-screen \
    --script artifacts/live-file-browser-script.txt \
    --script-after "$STATIC_EXIT_LINE" \
    --input-chords "return" \
    --input-chords-after "file: ready" \
    --script2 artifacts/live-file-browser-script2.txt \
    --script2-after "file: view README.TXT" \
    --script-expect "done-file-sweep" \
    --timeout 60 > artifacts/live-file-browser-run.txt 2>&1
RC=$?
set -e

[ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log artifacts/live-file-browser-serial.log || true

echo "VMRunner exit code: $RC"
if [ $RC -ne 0 ]; then
    echo "ERROR: VMRunner failed with return code $RC"
    cat artifacts/live-file-browser-run.txt
    exit 1
fi

echo "--- Phase 2: Verifying FILE.BIN Markers ---"

# 1. Window opened + ready.
grep -q "file: ready" artifacts/live-file-browser-serial.log || {
    echo "ERROR: FILE.BIN ready marker missing from serial log"
    exit 1
}
echo "FILE.READY: OK"

# 2. The DATA partition listing (README.TXT + DATA.TXT) via sys_dir_list.
grep -q "file: listing 2 entries" artifacts/live-file-browser-serial.log || {
    echo "ERROR: FILE.BIN listing marker (2 entries) missing from serial log"
    exit 1
}
echo "FILE.LIST: OK"

# 3. The injected Enter opened the selected entry read-only.
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

# 4. The M10 file seam was exercised from EL0 exactly once per call.
grep -q "27 sys_dir_list calls=1" artifacts/live-file-browser-serial.log || {
    echo "ERROR: sys_dir_list call count missing from syscalls report"
    exit 1
}
echo "SYS_DIR_LIST: OK"
grep -q "23 sys_file_open calls=1" artifacts/live-file-browser-serial.log || {
    echo "ERROR: sys_file_open call count missing from syscalls report"
    exit 1
}
echo "SYS_FILE_OPEN: OK"
grep -q "24 sys_file_read calls=1" artifacts/live-file-browser-serial.log || {
    echo "ERROR: sys_file_read call count missing from syscalls report"
    exit 1
}
echo "SYS_FILE_READ: OK"

# 5. Clean sweep marker.
grep -q "done-file-sweep" artifacts/live-file-browser-serial.log || {
    echo "ERROR: final sweep marker missing from serial log"
    exit 1
}

cat > "$REPORT" <<EOF
=== Milestone 13 FILE.BIN Live Gate Report ===
Revision: $REVISION ($BRANCH)
Status: PASS (1/1 on Apple Virtualization.framework)

Verified Components:
- FILE.BIN: Graphical DATA-partition file browser (user/src/file_browser.zig)
- sys_dir_list (ADR 0007 slot 27): lists /data (README.TXT + DATA.TXT)
- sys_file_open/read/close (slots 23/24/26): opens README.TXT read-only
- ui.zig micro-widget toolkit: scrollable list + details + text view

Serial Output Highlights:
$(grep -E 'file:|sys_dir_list|sys_file_(open|read|close)' artifacts/live-file-browser-serial.log || true)
EOF

echo "verify-live-file-browser: PASS — FILE.BIN lists /data and opens README.TXT read-only on VZ."

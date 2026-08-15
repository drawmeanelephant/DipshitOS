#!/usr/bin/env bash
#
# verify-live-user-fs.sh -- claim 0510 (milestone 10 card F4) class-B gate:
# userland storage ABI and utilities (SAVETEXT.BIN, TYPE.BIN, DIR.BIN) verified
# on real Apple silicon Virtualization.framework hardware.
#
# The gate performs a multi-boot persistent round-trip:
#   1. Boot A (fresh disk image):
#      - Runs `exec SAVETEXT.BIN` from the shell.
#      - SAVETEXT.BIN opens `/data/hello.txt` via sys_file_open (slot 23),
#        writes 34-byte persistent payload via sys_file_write (slot 25),
#        closes via sys_file_close (slot 26), and outputs:
#        "savetext: wrote /data/hello.txt\n"
#      - Asserts process exit status 0.
#   2. Boot B (reboot VM against the same disk image):
#      - Runs `exec TYPE.BIN` and `exec DIR.BIN` from the shell.
#      - TYPE.BIN opens `/data/hello.txt` with MODE_READ (slot 23),
#        reads contents via sys_file_read (slot 24), echoes payload to console,
#        outputs "type: success\n", and exits with status 0.
#      - DIR.BIN enumerates `/data` directory entries via sys_dir_list (slot 27),
#        outputs directory listings, outputs "dir: success\n", and exits with status 0.
#
# Usage:
#   bash tools/verify-live-user-fs.sh
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-user-fs-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

REPORT="artifacts/live-user-fs-report.txt"

echo "=== verify-live-user-fs: claim 0510 — userland storage ABI & utilities on VZ hardware ==="

# Tool versions + revision
zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
echo "revision: $REVISION branch=$BRANCH"

# Build all binaries and disk image
zig build
/bin/bash image/make-image.sh
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# Scripts for Boot A and Boot B
cat > artifacts/live-user-fs-script-A.txt <<'EOF'
exec SAVETEXT.BIN
echo done-savetext
procs
EOF

cat > artifacts/live-user-fs-script-B.txt <<'EOF'
exec TYPE.BIN
exec DIR.BIN
echo done-fs-read
procs
EOF

STATIC_EXIT_LINE="tasks user-el0 exited status=7"

# Phase 1: Boot A — Write persistent file from EL0
echo "--- Phase 1: Boot A (SAVETEXT.BIN) ---"
rm -f artifacts/efi-vars.bin
rm -f artifacts/vm-serial.log
set +e
host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
    --script artifacts/live-user-fs-script-A.txt \
    --script-after "$STATIC_EXIT_LINE" \
    --script-expect "procs SAVETEXT.BIN exited status=0" \
    --timeout 40 > artifacts/live-user-fs-run-A.txt 2>&1
RC_A=$?
set -e
[ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log artifacts/live-user-fs-serial-A.log || true

if [ $RC_A -ne 0 ]; then
    echo "ERROR: Boot A failed with return code $RC_A"
    exit 1
fi

grep -q "savetext: wrote /data/hello.txt" artifacts/live-user-fs-serial-A.log || {
    echo "ERROR: SAVETEXT.BIN write marker missing from serial log"
    exit 1
}
grep -q "procs SAVETEXT.BIN exited status=0" artifacts/live-user-fs-serial-A.log || {
    echo "ERROR: SAVETEXT.BIN exit status 0 missing from serial log"
    exit 1
}
echo "Boot A passed: SAVETEXT.BIN wrote persistent data and exited cleanly."

# Phase 2: Boot B — Reboot and verify persistence via TYPE.BIN and DIR.BIN
echo "--- Phase 2: Boot B (TYPE.BIN + DIR.BIN persistence verification) ---"
rm -f artifacts/vm-serial.log
set +e
host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
    --script artifacts/live-user-fs-script-B.txt \
    --script-after "$STATIC_EXIT_LINE" \
    --script-expect "procs DIR.BIN exited status=0" \
    --timeout 40 > artifacts/live-user-fs-run-B.txt 2>&1
RC_B=$?
set -e
[ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log artifacts/live-user-fs-serial-B.log || true

if [ $RC_B -ne 0 ]; then
    echo "ERROR: Boot B failed with return code $RC_B"
    exit 1
fi

grep -q "type: read Hello from DipshitOS EL0 Storage!" artifacts/live-user-fs-serial-B.log || {
    echo "ERROR: TYPE.BIN read payload missing or incorrect"
    exit 1
}
grep -q "type: success" artifacts/live-user-fs-serial-B.log || {
    echo "ERROR: TYPE.BIN success marker missing from serial log"
    exit 1
}
grep -q "procs TYPE.BIN exited status=0" artifacts/live-user-fs-serial-B.log || {
    echo "ERROR: TYPE.BIN exit status 0 missing from serial log"
    exit 1
}

grep -q "dir: listing /data" artifacts/live-user-fs-serial-B.log || {
    echo "ERROR: DIR.BIN listing marker missing from serial log"
    exit 1
}
grep -q "HELLO.TXT" artifacts/live-user-fs-serial-B.log || {
    echo "ERROR: HELLO.TXT missing from DIR.BIN directory enumeration"
    exit 1
}
grep -q "dir: success" artifacts/live-user-fs-serial-B.log || {
    echo "ERROR: DIR.BIN success marker missing from serial log"
    exit 1
}
grep -q "procs DIR.BIN exited status=0" artifacts/live-user-fs-serial-B.log || {
    echo "ERROR: DIR.BIN exit status 0 missing from serial log"
    exit 1
}

echo "Boot B passed: TYPE.BIN and DIR.BIN verified persistent data across reboot."

# Summary report
cat > "$REPORT" <<EOF
=== Milestone 10 Capstone Gate Report (Claim 0510) ===
Date: $(date -u '+%Y-%m-%d %H:%M:%SZ')
Revision: $REVISION
Branch: $BRANCH
Boot A (SAVETEXT.BIN): PASSED (wrote /data/hello.txt, status=0)
Boot B (TYPE.BIN): PASSED (read persistent data across reboot, status=0)
Boot B (DIR.BIN): PASSED (enumerated /data entries including HELLO.TXT, status=0)
Result: SUCCESS (all assertions verified on Apple silicon VZ hardware)
EOF

cat "$REPORT"
echo "=== verify-live-user-fs: SUCCESS ==="

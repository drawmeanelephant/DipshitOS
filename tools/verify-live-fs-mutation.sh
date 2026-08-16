#!/usr/bin/env bash
#
# verify-live-fs-mutation.sh -- claim 5801 (Milestone 13, Card B1) class-B
# gate: the mutating filesystem seam (ADR 0007 slots 34-37) verified on real
# Apple silicon Virtualization.framework hardware.
#
# FSTEST.BIN drives the seam from EL0 against the DATA partition:
#   create + write -> truncate to 5 -> read back "hello" -> rename ->
#   free-space query -> delete -> prove the file is gone.
# The syscalls report proves slots 34-37 were each called exactly once.
#
# Usage:
#   bash tools/verify-live-fs-mutation.sh
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-fs-mutation-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

REPORT="artifacts/live-fs-mutation-report.txt"

echo "=== verify-live-fs-mutation: claim 5801 — Milestone 13 B1 on VZ ==="

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

cat > artifacts/live-fs-mutation-script.txt <<'EOF'
exec FSTEST.BIN
EOF

cat > artifacts/live-fs-mutation-script2.txt <<'EOF'
echo done-fs-mutation
syscalls
EOF

STATIC_EXIT_LINE="tasks user-el0 exited status=7"

echo "--- Phase 1: Running FSTEST.BIN on VZ ---"
rm -f artifacts/efi-vars.bin
rm -f artifacts/vm-serial.log artifacts/gpu-screen-*

set +e
host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
    --script artifacts/live-fs-mutation-script.txt \
    --script-after "$STATIC_EXIT_LINE" \
    --script2 artifacts/live-fs-mutation-script2.txt \
    --script2-after "fstest: done" \
    --script-expect "done-fs-mutation" \
    --timeout 60 > artifacts/live-fs-mutation-run.txt 2>&1
RC=$?
set -e

[ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log artifacts/live-fs-mutation-serial.log || true

echo "VMRunner exit code: $RC"
if [ $RC -ne 0 ]; then
    echo "ERROR: VMRunner failed with return code $RC"
    cat artifacts/live-fs-mutation-run.txt
    exit 1
fi

echo "--- Phase 2: Verifying FSTEST.BIN Markers ---"

grep -q "fstest: wrote" artifacts/live-fs-mutation-serial.log || {
    echo "ERROR: fstest write marker missing from serial log"
    exit 1
}
echo "FS.WRITE: OK"

grep -q "fstest: truncate ok" artifacts/live-fs-mutation-serial.log || {
    echo "ERROR: fstest truncate marker missing from serial log"
    exit 1
}
echo "FS.TRUNCATE: OK"

grep -q "fstest: shrunk=5 hello" artifacts/live-fs-mutation-serial.log || {
    echo "ERROR: fstest shrink read-back marker missing from serial log"
    exit 1
}
echo "FS.SHRUNK: OK"

grep -q "fstest: rename ok" artifacts/live-fs-mutation-serial.log || {
    echo "ERROR: fstest rename marker missing from serial log"
    exit 1
}
echo "FS.RENAME: OK"

grep -q "fstest: free=" artifacts/live-fs-mutation-serial.log || {
    echo "ERROR: fstest free-space marker missing from serial log"
    exit 1
}
echo "FS.FREE: OK"

grep -q "fstest: delete ok" artifacts/live-fs-mutation-serial.log || {
    echo "ERROR: fstest delete marker missing from serial log"
    exit 1
}
grep -q "fstest: deleted-gone" artifacts/live-fs-mutation-serial.log || {
    echo "ERROR: fstest deleted-gone marker missing from serial log"
    exit 1
}
echo "FS.DELETE: OK"

# The four new slots were each called exactly once.
grep -q "34 sys_file_delete calls=1" artifacts/live-fs-mutation-serial.log || {
    echo "ERROR: sys_file_delete call count missing from syscalls report"
    exit 1
}
grep -q "35 sys_file_rename calls=1" artifacts/live-fs-mutation-serial.log || {
    echo "ERROR: sys_file_rename call count missing from syscalls report"
    exit 1
}
grep -q "36 sys_file_truncate calls=1" artifacts/live-fs-mutation-serial.log || {
    echo "ERROR: sys_file_truncate call count missing from syscalls report"
    exit 1
}
grep -q "37 sys_file_free calls=1" artifacts/live-fs-mutation-serial.log || {
    echo "ERROR: sys_file_free call count missing from syscalls report"
    exit 1
}
echo "SYS_FILE_DELETE/RENAME/TRUNCATE/FREE: OK"

grep -q "done-fs-mutation" artifacts/live-fs-mutation-serial.log || {
    echo "ERROR: final sweep marker missing from serial log"
    exit 1
}

cat > "$REPORT" <<EOF
=== Milestone 13 B1 Live Gate Report ===
Revision: $REVISION ($BRANCH)
Status: PASS (1/1 on Apple Virtualization.framework)

Verified Components:
- sys_file_delete (slot 34): deletes /data/b1renamed.txt, then proves it is gone
- sys_file_rename (slot 35): /data/b1test.txt -> /data/b1renamed.txt
- sys_file_truncate (slot 36): resizes to 5 bytes; read-back "hello"
- sys_file_free (slot 37): free-space query on the DATA volume
- All four slots calls=1 in the syscalls report

Serial Output Highlights:
$(grep -E 'fstest:|sys_file_(delete|rename|truncate|free)' artifacts/live-fs-mutation-serial.log || true)
EOF

echo "verify-live-fs-mutation: PASS — delete/rename/truncate/free verified on VZ."

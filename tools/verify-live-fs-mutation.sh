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

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

# Run isolation (#523 item 2 / issue #528; fleet remainder claim 2259):
# private stacked disk (pristine-per-boot overlay), EFI var store, serial
# log, and scripts under $RUN_DIR. The mutation walk is SELF-CLEANING
# within its single boot (FSTEST.BIN deletes what it creates), nothing
# asserts cross-boot persistence, so the throwaway overlay absorbs the
# writes. Set DIPSHIT_GATE_SUFFIX=_alt for distinct canonical evidence
# names; DIPSHIT_KEEP_RUN=1 keeps the scratch dir.

GATE_LOG="$(art live-fs-mutation-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-fs-mutation-report.txt)"
echo "=== verify-live-fs-mutation: claim 5801 — Milestone 13 B1 on VZ ==="

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

# Build all binaries and disk image
zig build
zig build image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# --- per-run isolation -------------------------------------------------------
gate_begin live-fs-mutation
echo "run dir: $RUN_DIR"

cat > "$RUN_DIR/script.txt" <<'EOF'
exec FSTEST.BIN
EOF

# Order matters (fleet remainder claim 2259): syscalls FIRST, success
# echo LAST — the runner exits on the echo, and an echo-first order can
# truncate the report before the slot-count lines print.
cat > "$RUN_DIR/script2.txt" <<'EOF'
syscalls
echo done-fs-mutation
EOF

STATIC_EXIT_LINE="tasks user-el0 exited status=7"

echo "--- Phase 1: Running FSTEST.BIN on VZ ---"
rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log"

set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial.log" \
    --script "$RUN_DIR/script.txt" \
    --script-after "$STATIC_EXIT_LINE" \
    --script2 "$RUN_DIR/script2.txt" \
    --script2-after "fstest: done" \
    --script-expect "done-fs-mutation" \
    --timeout 60 > "$(art live-fs-mutation-run.txt)" 2>&1
RC=$?
set -e

[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-fs-mutation-serial.log)" || true
SER="$(art live-fs-mutation-serial.log)"

echo "VMRunner exit code: $RC"
if [ $RC -ne 0 ]; then
    echo "ERROR: VMRunner failed with return code $RC"
    cat "$(art live-fs-mutation-run.txt)"
    exit 1
fi

echo "--- Phase 2: Verifying FSTEST.BIN Markers ---"

grep -q "fstest: wrote" "$SER" || {
    echo "ERROR: fstest write marker missing from serial log"
    exit 1
}
echo "FS.WRITE: OK"

grep -q "fstest: truncate ok" "$SER" || {
    echo "ERROR: fstest truncate marker missing from serial log"
    exit 1
}
echo "FS.TRUNCATE: OK"

grep -q "fstest: shrunk=5 hello" "$SER" || {
    echo "ERROR: fstest shrink read-back marker missing from serial log"
    exit 1
}
echo "FS.SHRUNK: OK"

grep -q "fstest: rename ok" "$SER" || {
    echo "ERROR: fstest rename marker missing from serial log"
    exit 1
}
echo "FS.RENAME: OK"

grep -q "fstest: free=" "$SER" || {
    echo "ERROR: fstest free-space marker missing from serial log"
    exit 1
}
echo "FS.FREE: OK"

grep -q "fstest: delete ok" "$SER" || {
    echo "ERROR: fstest delete marker missing from serial log"
    exit 1
}
grep -q "fstest: deleted-gone" "$SER" || {
    echo "ERROR: fstest deleted-gone marker missing from serial log"
    exit 1
}
echo "FS.DELETE: OK"

# The four new slots were each called exactly once.
grep -q "34 sys_file_delete calls=1" "$SER" || {
    echo "ERROR: sys_file_delete call count missing from syscalls report"
    exit 1
}
grep -q "35 sys_file_rename calls=1" "$SER" || {
    echo "ERROR: sys_file_rename call count missing from syscalls report"
    exit 1
}
grep -q "36 sys_file_truncate calls=1" "$SER" || {
    echo "ERROR: sys_file_truncate call count missing from syscalls report"
    exit 1
}
grep -q "37 sys_file_free calls=1" "$SER" || {
    echo "ERROR: sys_file_free call count missing from syscalls report"
    exit 1
}
echo "SYS_FILE_DELETE/RENAME/TRUNCATE/FREE: OK"

grep -q "done-fs-mutation" "$SER" || {
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

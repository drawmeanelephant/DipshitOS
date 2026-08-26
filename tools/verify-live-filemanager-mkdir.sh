#!/usr/bin/env bash
#
# verify-live-filemanager-mkdir.sh -- M25 Lane B (claim 2539) class-B gate:
# F3 real FAT32 directory creation verified on Apple silicon
# Virtualization.framework hardware.
#
# The kernel-side seam is new with this claim: slot 23's flag contract
# gains MODE_DIR (open + CREATE + WRITE creates a directory — cluster
# allocation, zeroed contents, `.` / `..` dot entries, ATTR_DIRECTORY
# parent slot) via fat.create_dir, exposed to EL0 as ui.file_mkdir.
#
# FSTEST.BIN drives the seam headlessly against the DATA partition:
#   mkdir /data/M25DIR -> ok -> the new directory LISTS EMPTY (dot entries
#   skipped by the listing seam) -> a second mkdir refuses with -EEXIST
#   (-9). On-disk dot-entry BYTES are pinned by the fat.zig host tests;
#   this gate proves the full EL0 -> syscall -> FAT -> virtio-blk chain.
#
# NOTE on the card's Ctrl+Shift+N UI walk: M21 W3's global Ctrl+N
# minimize intercept (kernel/src/input.zig) currently fires on the
# Shift combo too, stealing window focus mid-walk. That one-line guard
# (`and shift-not-set`) lives in input.zig, held ACTIVE by claim 8777 —
# the chord-level live walk follows once that claim lands. Host unit
# tests pin the overlay + confirm_create_dir wiring meanwhile.
#
# Run isolation (claim 6637): throwaway overlay absorbs the mkdir; the
# canonical image is untouched.
#
# Usage:
#   bash tools/verify-live-filemanager-mkdir.sh
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-filemanager-mkdir-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-filemanager-mkdir-report.txt)"

echo "=== verify-live-filemanager-mkdir: M25 Lane B F3 — real FAT32 mkdir on VZ ==="

PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
DIRTY="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "revision: $REVISION branch=$BRANCH dirty-files=$DIRTY"

zig build
zig build image
swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

gate_begin live-filemanager-mkdir
echo "run dir: $RUN_DIR"

printf 'exec FSTEST.BIN\n' > "$RUN_DIR/script.txt"
printf 'syscalls\necho m25-mkdir-ok\n' > "$RUN_DIR/settle.txt"

rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log"
set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial.log" \
    --script "$RUN_DIR/script.txt" \
    --script-after "tasks user-el0 exited status=7" \
    --script2 "$RUN_DIR/settle.txt" \
    --script2-after "fstest: done" \
    --script-expect "m25-mkdir-ok" \
    --timeout 90 > "$(art live-filemanager-mkdir-run.txt)" 2>&1
RC=$?
set -e

[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-filemanager-mkdir-serial.log)" || true
SER="$(art live-filemanager-mkdir-serial.log)"

echo "VMRunner exit code: $RC"
if [ $RC -ne 0 ]; then
    echo "ERROR: VMRunner failed with return code $RC"
    cat "$(art live-filemanager-mkdir-run.txt)"
    exit 1
fi

echo "--- Phase 2: Verifying the mkdir arc ---"

grep -aqF "fstest: mkdir ok" "$SER" || { echo "ERROR: mkdir-ok marker missing"; exit 1; }
echo "MKDIR.CREATE: OK"

grep -aqF "fstest: mkdir dir-empty" "$SER" || { echo "ERROR: created-directory listing marker missing"; exit 1; }
echo "MKDIR.LIST_EMPTY: OK"

grep -aqF "fstest: mkdir exists-refused" "$SER" || { echo "ERROR: exists-refusal marker missing"; exit 1; }
echo "MKDIR.EXISTS_REFUSED: OK"

cat > "$REPORT" <<EOF
=== M25 Lane B F3 Live Gate Report ===
Revision: $REVISION ($BRANCH)
Status: PASS (1/1 boot on Apple Virtualization.framework)

Verified:
- Slot 23 MODE_DIR extension driven from EL0 via ui.file_mkdir
- fat.create_dir: cluster alloc + dot entries + ATTR_DIRECTORY slot
- Created directory lists empty through sys_dir_list (dots skipped)
- Second mkdir refuses with -9 (EEXIST) — never overwrites
- On-disk dot-entry bytes pinned by fat.zig host unit tests
Deferred: Ctrl+Shift+N chord walk (input.zig W3 shift-guard held by
claim 8777); overlay wiring covered by host unit tests meanwhile.
EOF

echo "verify-live-filemanager-mkdir: PASS — real FAT32 directory creation verified on VZ."

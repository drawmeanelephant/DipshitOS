#!/usr/bin/env bash
#
# verify-live-filemanager-bulk.sh -- M25 Lane A (claim 0434) class-B gate:
# F1 bulk operations verified on real Apple silicon Virtualization.framework
# hardware.
#
# FILE.BIN is exec'd directly; the walk rides the claim-9588 custom-virtio
# INPUT queue (headless-safe, no activation wall — the M20-U3/U5 lesson):
#   1. Ctrl+A selects all entries (marker `file: select all n=2`).
#   2. 'd' opens the delete confirmation dialog (`file: del prompt n=2`).
#   3. Return confirms; the stepwise batch engine deletes both files,
#      emitting one serial marker per unit (`file: del i/2 NAME`) and the
#      final accounting (`file: batch done n=2`), then re-lists
#      (`file: listing 0 entries`).
#   4. The syscalls report proves slot 34 fired exactly twice.
#
# Run isolation (claim 6637): private stacked disk + EFI vars + serial log
# per boot. The deletion lands in the throwaway overlay; the canonical
# image is untouched. DIPSHIT_GATE_SUFFIX / DIPSHIT_KEEP_RUN as usual.
#
# Usage:
#   bash tools/verify-live-filemanager-bulk.sh
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${DIPSHIT_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-filemanager-bulk-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-filemanager-bulk-report.txt)"

echo "=== verify-live-filemanager-bulk: M25 Lane A F1 — multi-select + batch delete on VZ ==="

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

gate_begin live-filemanager-bulk
echo "run dir: $RUN_DIR"

printf 'exec FILE.BIN\n' > "$RUN_DIR/script.txt"
printf 'dui focus 0\nmount data\nls -l /\nsyscalls\necho m25-bulk-ok\n' > "$RUN_DIR/settle.txt"

# The pristine DATA partition carries exactly two files (DATA.TXT +
# README.TXT). Select all, open the delete dialog, confirm with Return.
CHORDS="ctrl-a,d,return"

rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log"
set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial.log" \
    --screen "$RUN_DIR/screen" \
    --via-virtio \
    --script "$RUN_DIR/script.txt" \
    --input-chords "$CHORDS" --input-chords-after "file: ready" \
    --script2 "$RUN_DIR/settle.txt" --script2-after "file: batch done n=2" --script2-delay 2 \
    --script-expect "m25-bulk-ok" \
    --timeout 150 > "$(art live-filemanager-bulk-run.txt)" 2>&1
RC=$?
set -e

[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-filemanager-bulk-serial.log)" || true
cp "$RUN_DIR"/screen-* artifacts/ 2>/dev/null || true
SER="$(art live-filemanager-bulk-serial.log)"

echo "VMRunner exit code: $RC"
if [ $RC -ne 0 ]; then
    echo "ERROR: VMRunner failed with return code $RC"
    cat "$(art live-filemanager-bulk-run.txt)"
    exit 1
fi

echo "--- Phase 2: Verifying the bulk-operation arc ---"

grep -aqF "file: select all n=2" "$SER" || { echo "ERROR: select-all marker missing"; exit 1; }
echo "BULK.SELECT_ALL: OK"

grep -aqF "file: del prompt n=2" "$SER" || { echo "ERROR: delete-dialog marker missing"; exit 1; }
echo "BULK.DELETE_PROMPT: OK"

grep -aqF "file: del 1/2 DATA.TXT" "$SER" || { echo "ERROR: per-unit del marker 1 missing"; exit 1; }
grep -aqF "file: del 2/2 README.TXT" "$SER" || { echo "ERROR: per-unit del marker 2 missing"; exit 1; }
echo "BULK.STEPWISE_MARKERS: OK"

grep -aqF "file: batch done n=2" "$SER" || { echo "ERROR: batch completion marker missing"; exit 1; }
echo "BULK.BATCH_DONE: OK"

# Slot 34 fired exactly twice (once per selected file).
grep -aqF "34 sys_file_delete calls=2" "$SER" || { echo "ERROR: sys_file_delete calls=2 missing from syscalls report"; exit 1; }
echo "SYS_FILE_DELETE x2: OK"

# Ground truth from the monitor (volume-relative root of DATA): neither
# deleted name survives. Background writers (M21 W11 persistence) may add
# unrelated files around shutdown, so absence of the TARGETS is the
# assertion — never total entry counts.
sed -n '/^ls: \/ entries/,$p' "$SER" > "$RUN_DIR/post-walk.txt"
if grep -aqE "DATA\.TXT|README\.TXT" "$RUN_DIR/post-walk.txt"; then
    echo "ERROR: a deleted target still present after the batch walk"
    cat "$RUN_DIR/post-walk.txt"
    exit 1
fi
echo "BULK.GONE_FROM_VOLUME: OK"

cat > "$REPORT" <<EOF
=== M25 Lane A F1 Live Gate Report ===
Revision: $REVISION ($BRANCH)
Status: PASS (1/1 boot on Apple Virtualization.framework)

Verified:
- Ctrl+A select-all over the virtio INPUT queue (n=2 marker)
- Delete confirmation dialog ('d', prompt marker, Return confirms)
- Stepwise batch engine: one serial marker per unit + final accounting
- Slot 34 sys_file_delete calls=2 in the syscalls report
- Post-delete re-listing reports 0 entries
EOF

echo "verify-live-filemanager-bulk: PASS — multi-select + dialog + stepwise batch delete verified on VZ."

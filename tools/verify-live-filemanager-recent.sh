#!/usr/bin/env bash
#
# verify-live-filemanager-recent.sh -- M25 Lane B (claim 2539) class-B gate:
# F5 recent-files ring (persist + virtual RECENT entry) on Apple silicon
# Virtualization.framework hardware.
#
#   1. Return opens the selected DATA.TXT; open_selected records the full
#      path and PERSISTS the ring to /host/RECENT.SAV — M34 HF5 (issue
#      #739): FILE.BIN's root + recent ring live in the --cvc-file share
#      (`file: recent saved n=1`).
#   2. Escape re-lists; the virtual RECENT entry is injected as the pinned
#      first row (`file: listing 3 entries ... recent=virtual`).
#   3. Return enters the RECENT pseudo-listing (`file: recent open n=1`)
#      whose rows are the stored FULL paths.
#   4. Return opens the selected row — `file: open /host/DATA.TXT` proves
#      the pseudo-listing resolves stored paths directly, and the dedup
#      move-to-front keeps the ring at n=1.
#
# Run isolation (claim 6637): the .recent write lands in the throwaway
# overlay; cross-boot persistence is pinned by host unit tests + the FAT
# write path already live-gated (M13 B1).
#
# Usage:
#   bash tools/verify-live-filemanager-recent.sh
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-filemanager-recent-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-filemanager-recent-report.txt)"

echo "=== verify-live-filemanager-recent: M25 Lane B F5 — recent ring on VZ ==="

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

gate_begin live-filemanager-recent
gate_seed_share
echo "run dir: $RUN_DIR"

# M34 HF5 (issue #739): the share is FILE.BIN's root — seed the byte-known
# DATA.TXT fixture (same bytes as image/mkfat32.py build_data_volume) so
# the open/recent arc has an entry to select.
SHARE="$RUN_DIR/share"
mkdir -p "$SHARE"
printf '%s\n' 'general data volume contents: 1234567890' > "$SHARE/DATA.TXT"

printf 'exec FILE.BIN\n' > "$RUN_DIR/script.txt"
printf 'dui focus 0\nsyscalls\necho m25-recent-ok\n' > "$RUN_DIR/settle.txt"

CHORDS="return,escape,return,return"

rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log"
set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial.log" \
    --screen "$RUN_DIR/screen" \
    --via-virtio \
    --script "$RUN_DIR/script.txt" \
    --input-chords "$CHORDS" --input-chords-after "file: ready" \
    --script2 "$RUN_DIR/settle.txt" --script2-after "file: open /host/DATA.TXT" --script2-delay 2 \
    --script-expect "m25-recent-ok" \
    --timeout 150 > "$(art live-filemanager-recent-run.txt)" 2>&1
RC=$?
set -e

[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-filemanager-recent-serial.log)" || true
cp "$RUN_DIR"/screen-* artifacts/ 2>/dev/null || true
SER="$(art live-filemanager-recent-serial.log)"

echo "VMRunner exit code: $RC"
if [ $RC -ne 0 ]; then {
    echo "ERROR: VMRunner failed with return code $RC"
    cat "$(art live-filemanager-recent-run.txt)"
    exit 1
} fi

echo "--- Phase 2: Verifying the recent-files arc ---"

grep -aqF "file: recent saved n=1" "$SER" || { echo "ERROR: recent-persist marker missing"; exit 1; }
echo "RECENT.PERSIST: OK"

grep -aqF "recent=virtual" "$SER" || { echo "ERROR: virtual RECENT injection marker missing"; exit 1; }
echo "RECENT.VIRTUAL_ENTRY: OK"

grep -aqF "file: recent open n=1" "$SER" || { echo "ERROR: pseudo-listing marker missing"; exit 1; }
echo "RECENT.PSEUDO_LISTING: OK"

grep -aqF "file: open /host/DATA.TXT" "$SER" || { echo "ERROR: stored-path open marker missing"; exit 1; }
echo "RECENT.STORED_PATH_OPEN: OK"

# M34 HF5 (issue #739): the persisted ring must exist ON THE HOST DISK.
grep -aqF "/host/DATA.TXT" "$SHARE/RECENT.SAV" 2>/dev/null || { echo "ERROR: RECENT.SAV missing the stored path on the host share"; exit 1; }
echo "RECENT.HOST_DISK: OK"

cat > "$REPORT" <<EOF
=== M25 Lane B F5 Live Gate Report ===
Revision: $REVISION ($BRANCH)
Status: PASS (1/1 boot on Apple Virtualization.framework)

Verified:
- add_recent persists the ring to /host/RECENT.SAV via slot 23/25 (HF5 share)
- Virtual RECENT entry injected + pinned at the root listing
- RECENT pseudo-listing opens from the keyboard and lists stored paths
- Opening a stored path views it directly (full-path resolution)
- Host disk: RECENT.SAV on the --cvc-file share carries /host/DATA.TXT
EOF

echo "verify-live-filemanager-recent: PASS — recent persist + virtual entry verified on VZ."

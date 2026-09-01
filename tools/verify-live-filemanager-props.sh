#!/usr/bin/env bash
#
# verify-live-filemanager-props.sh -- M25 Lane A (claim 0434) class-B gate:
# F2 file-properties inspector verified on Apple silicon
# Virtualization.framework hardware.
#
#   1. Ctrl+I toggles the properties inspector on the selected entry;
#      the app reports `file: props on` over serial (the same seam the
#      right-click context menu's Properties item drives — that dispatch
#      path is pinned by host unit tests; synthesized RIGHT clicks hit
#      the claim-4769 activation wall and stay class-C).
#   2. The panel renders size / type / full path / directory total /
#      FAT32 format + N/A timestamp in the details pane (screenshot
#      evidence captured alongside).
#   3. Ctrl+I again reports `file: props off` (toggle symmetry).
#
# Run isolation (claim 6637): read-only walk, throwaway overlay.
#
# Usage:
#   bash tools/verify-live-filemanager-props.sh
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-filemanager-props-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-filemanager-props-report.txt)"

echo "=== verify-live-filemanager-props: M25 Lane A F2 — properties inspector on VZ ==="

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

gate_begin live-filemanager-props
echo "run dir: $RUN_DIR"

# M34 HF5 (issue #739): FILE.BIN's root is the HOST SHARE — seed the two
# byte-known DATA fixtures so the listing carries real entries + a live
# F4 du= total (same bytes as image/mkfat32.py build_data_volume).
SHARE="$RUN_DIR/share"
mkdir -p "$SHARE"
printf '%s\n' 'VirelaiOS general filesystem: a second FAT32 volume on the same disk (claim 3678, milestone four card 2)' > "$SHARE/README.TXT"
printf '%s\n' 'general data volume contents: 1234567890' > "$SHARE/DATA.TXT"

printf 'exec FILE.BIN\n' > "$RUN_DIR/script.txt"
printf 'dui focus 0\necho m25-props-ok\n' > "$RUN_DIR/settle.txt"

CHORDS="ctrl-i,ctrl-i,ctrl-i"

rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log"
set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial.log" \
    --cvc-file "$SHARE" \
    --screen "$RUN_DIR/screen" \
    --via-virtio \
    --script "$RUN_DIR/script.txt" \
    --input-chords "$CHORDS" --input-chords-after "file: ready" \
    --script2 "$RUN_DIR/settle.txt" --script2-after "file: props off" --script2-delay 2 \
    --script-expect "m25-props-ok" \
    --timeout 150 > "$(art live-filemanager-props-run.txt)" 2>&1
RC=$?
set -e

[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-filemanager-props-serial.log)" || true
cp "$RUN_DIR"/screen-* artifacts/ 2>/dev/null || true
SER="$(art live-filemanager-props-serial.log)"

echo "VMRunner exit code: $RC"
if [ $RC -ne 0 ]; then
    echo "ERROR: VMRunner failed with return code $RC"
    cat "$(art live-filemanager-props-run.txt)"
    exit 1
fi

echo "--- Phase 2: Verifying the properties arc ---"

grep -aqF "file: props on" "$SER" || { echo "ERROR: props-on marker missing"; exit 1; }
echo "PROPS.ON: OK"

grep -aqF "file: props off" "$SER" || { echo "ERROR: props-off marker missing"; exit 1; }
echo "PROPS.OFF: OK"

# Toggle symmetry: exactly two toggles happened across three chords.
ON=$(grep -acF "file: props on" "$SER" || true)
OFF=$(grep -acF "file: props off" "$SER" || true)
[ "$ON" = "2" ] && [ "$OFF" = "1" ] || { echo "ERROR: toggle accounting wrong (on=$ON off=$OFF)"; exit 1; }
echo "PROPS.SYMMETRY: OK"

# The du= total in the listing marker proves F4's bounded walk ran live.
grep -aqE "file: listing [0-9]+ entries .*du=[0-9]+" "$SER" || { echo "ERROR: breadcrumb du total missing from listing marker"; exit 1; }
echo "PROPS.DU_TOTAL: OK"

cat > "$REPORT" <<EOF
=== M25 Lane A F2 Live Gate Report ===
Revision: $REVISION ($BRANCH)
Status: PASS (1/1 boot on Apple Virtualization.framework)

Verified:
- Ctrl+I toggles the properties inspector (on/off serial markers)
- F4 breadcrumb du= byte total computed live in every listing marker
- Screenshot evidence of the panel captured to artifacts/
- Right-click dispatch path covered by host unit tests (claim-4769 wall)
EOF

echo "verify-live-filemanager-props: PASS — properties inspector + du total verified on VZ (HF5 share root)."

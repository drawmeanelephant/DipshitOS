#!/usr/bin/env bash
#
# verify-live-filemanager-du.sh -- M25 (claim 4379) class-B gate:
# F4 disk usage (`du`) command verified on Apple silicon
# Virtualization.framework hardware.
#
# Drives the `du` command from the monitor:
#   1. `du /` walks the root directory recursively across subdirectories.
#   2. `du /EFI` measures the `/EFI` subtree.
#   3. Asserts exact reported shape `du: <path> <bytes> bytes (dirs=<n>)`.
#
# Usage:
#   bash tools/verify-live-filemanager-du.sh
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

source tools/lib/gate-run.sh

SUFFIX="${VIRELAI_GATE_SUFFIX:-}"
art() { printf 'artifacts/%s%s' "$1" "$SUFFIX"; }

GATE_LOG="$(art live-filemanager-du-gate.txt)"
exec > >(tee "$GATE_LOG") 2>&1
trap 'gate_end 2>/dev/null || true; sleep 0.5' EXIT

REPORT="$(art live-filemanager-du-report.txt)"

echo "=== verify-live-filemanager-du: M25 F4 — recursive disk usage on VZ ==="

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

gate_begin live-filemanager-du
echo "run dir: $RUN_DIR"

printf 'du /\ndu /EFI\necho m25-du-ok\n' > "$RUN_DIR/script.txt"

rm -f "$RUN_DIR/efi-vars.bin" "$RUN_DIR/vm-serial.log"
set +e
host/vm-runner/.build/release/VMRunner "${GATE_RUNNER_ARGS[@]}" \
    --serial "$RUN_DIR/vm-serial.log" \
    --script "$RUN_DIR/script.txt" \
    --script-expect "m25-du-ok" \
    --timeout 90 > "$(art live-filemanager-du-run.txt)" 2>&1
RC=$?
set -e

[ -f "$RUN_DIR/vm-serial.log" ] && cp "$RUN_DIR/vm-serial.log" "$(art live-filemanager-du-serial.log)" || true
SER="$(art live-filemanager-du-serial.log)"

echo "VMRunner exit code: $RC"
if [ $RC -ne 0 ]; then
    echo "ERROR: VMRunner failed with return code $RC"
    cat "$(art live-filemanager-du-run.txt)"
    exit 1
fi

echo "--- Phase 2: Verifying the du output ---"

grep -aqE "du: / [1-9][0-9]* bytes \(dirs=[0-9]+\)" "$SER" || { echo "ERROR: du / output missing or zero bytes"; exit 1; }
echo "DU.ROOT: OK"

grep -aqE "du: /EFI [1-9][0-9]* bytes \(dirs=[0-9]+\)" "$SER" || { echo "ERROR: du /EFI output missing or zero bytes"; exit 1; }
echo "DU.EFI: OK"

cat > "$REPORT" <<EOF
=== M25 F4 Live Gate Report ===
Revision: $REVISION ($BRANCH)
Status: PASS (1/1 boot on Apple Virtualization.framework)

Verified:
- Monitor \`du\` command runs fat.dir_size_recursive correctly
- Root tree and /EFI subtree measured with non-zero byte totals
- Live output matches contract: du: <path> <bytes> bytes (dirs=<n>)
EOF

echo "verify-live-filemanager-du: PASS — recursive disk usage verified on VZ."

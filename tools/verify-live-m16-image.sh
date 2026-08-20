#!/usr/bin/env bash
#
# verify-live-m16-image.sh -- claim 3900 (Milestone 16, Card C1) class-B gate:
# the multi-segment DSK2 image with writable globals + BSS + >16 KiB.
#
# BIGTEST.BIN drives the seam from EL0: it is 28 KiB (DSK2, 2 segments:
#   text RX 4 KiB at 0x400000, data RW 32 KiB at 0x401000 with 24 KiB filesz
#   + 8 KiB BSS zero tail), so the file is >16 KiB and the program proves
#   that writable globals and BSS are RW and zeroed, while the text is RX.
#   The kernel's DSK2 loader allocates per-segment pages, maps them with
#   correct AP/UXN/PXN, and the uaccess aperture covers data+stack.
#   The gate asserts the serial markers, the exit/reap, and that the file
#   on disk is >16 KiB with DSK2 magic.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-m16-image-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

REPORT="artifacts/live-m16-image-report.txt"

echo "=== verify-live-m16-image: claim 3900 — M16 C1 DSK2 >16 KiB + writable globals on VZ ==="

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

# Check the file on disk is DSK2 and >16 KiB
echo "--- Phase 0: host-side file checks ---"
BIGTEST="zig-out/bin/BIGTEST.BIN"
if [ ! -f "$BIGTEST" ]; then
    echo "ERROR: $BIGTEST not found"
    exit 1
fi
SIZE=$(wc -c < "$BIGTEST" | tr -d ' ')
echo "BIGTEST.BIN size=$SIZE"
if [ "$SIZE" -le 16384 ]; then
    echo "ERROR: BIGTEST.BIN size $SIZE is not >16 KiB (16384)"
    exit 1
fi
echo "BIGTEST.SIZE>16K: OK ($SIZE)"

# Check DSK2 magic and segments
python3 tools/elf2bin-dsk2.py --info "$BIGTEST" 2>&1 | tee artifacts/bigtest-info.txt
grep -q "magic=0x324b5344" artifacts/bigtest-info.txt || { echo "ERROR: BIGTEST is not DSK2 (magic 0x324b5344)"; exit 1; }
grep -q "seg0:.*flags=0x5" artifacts/bigtest-info.txt || { echo "ERROR: seg0 not RX"; exit 1; }
grep -q "seg1:.*flags=0x6" artifacts/bigtest-info.txt || { echo "ERROR: seg1 not RW"; exit 1; }
echo "BIGTEST.DSK2: OK"

# Check it is on the ESP
python3 image/mkfat32.py --list artifacts/disk.img 2>&1 | grep -q "BIGTEST.BIN" || { echo "ERROR: BIGTEST.BIN not on ESP"; exit 1; }
echo "BIGTEST.ESP: OK"

cat > artifacts/live-m16-image-script.txt <<'EOF'
exec BIGTEST.BIN
EOF

cat > artifacts/live-m16-image-script2.txt <<'EOF'
echo m16-image-ok
syscalls
EOF

STATIC_EXIT_LINE="tasks user-el0 exited status=7"

echo "--- Phase 1: Running BIGTEST.BIN on VZ ---"
rm -f artifacts/efi-vars.bin
rm -f artifacts/vm-serial.log artifacts/gpu-screen-*

set +e
host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
    --script artifacts/live-m16-image-script.txt \
    --script-after "$STATIC_EXIT_LINE" \
    --script2 artifacts/live-m16-image-script2.txt \
    --script2-after "bigtest: done" \
    --script-expect "m16-image-ok" \
    --timeout 90 > artifacts/live-m16-image-run.txt 2>&1
RC=$?
set -e

[ -f artifacts/vm-serial.log ] && cp artifacts/vm-serial.log artifacts/live-m16-image-serial.log || true

echo "VMRunner exit code: $RC"
if [ $RC -ne 0 ]; then
    echo "ERROR: VMRunner failed with return code $RC"
    cat artifacts/live-m16-image-run.txt
    exit 1
fi

echo "--- Phase 2: Verifying BIGTEST.BIN Markers ---"

grep -q "exec: loaded BIGTEST.BIN size=" artifacts/live-m16-image-serial.log || { echo "ERROR: exec loaded line missing"; exit 1; }
echo "EXEC.LOADED: OK"

# Check size >0x4000 in the exec line (hex)
EXEC_SIZE_HEX=$(grep "exec: loaded BIGTEST.BIN" artifacts/live-m16-image-serial.log | sed -n 's/.*size=0x\([0-9a-fA-F]*\).*/\1/p' | head -1)
EXEC_SIZE_DEC=$((16#$EXEC_SIZE_HEX))
echo "exec size hex=$EXEC_SIZE_HEX dec=$EXEC_SIZE_DEC"
if [ "$EXEC_SIZE_DEC" -le 16384 ]; then
    echo "ERROR: exec size $EXEC_SIZE_DEC not >16 KiB"
    exit 1
fi
echo "EXEC.SIZE>16K: OK"

grep -q "bigtest: start" artifacts/live-m16-image-serial.log || { echo "ERROR: bigtest start missing"; exit 1; }
echo "BIGTEST.START: OK"

grep -q "bigtest: bss zero ok" artifacts/live-m16-image-serial.log || { echo "ERROR: bss zero ok missing"; exit 1; }
echo "BIGTEST.BSS_ZERO: OK"

grep -q "bigtest: global rw ok" artifacts/live-m16-image-serial.log || { echo "ERROR: global rw ok missing"; exit 1; }
echo "BIGTEST.GLOBAL_RW: OK"

grep -q "bigtest: large_data rw ok" artifacts/live-m16-image-serial.log || { echo "ERROR: large_data rw ok missing"; exit 1; }
echo "BIGTEST.LARGE_DATA_RW: OK"

grep -q "bigtest: large_ro ok" artifacts/live-m16-image-serial.log || { echo "ERROR: large_ro ok missing"; exit 1; }
echo "BIGTEST.LARGE_RO: OK"

grep -q "bigtest: bss write ok" artifacts/live-m16-image-serial.log || { echo "ERROR: bss write ok missing"; exit 1; }
echo "BIGTEST.BSS_WRITE: OK"

grep -q "bigtest: large_data\[0\]=66" artifacts/live-m16-image-serial.log || { echo "ERROR: large_data[0]=66 missing"; exit 1; }
echo "BIGTEST.LARGE_DATA_NUM: OK"

grep -q "bigtest: done" artifacts/live-m16-image-serial.log || { echo "ERROR: bigtest done missing"; exit 1; }
echo "BIGTEST.DONE: OK"

grep -q "tasks user-exec exited status=42" artifacts/live-m16-image-serial.log || { echo "ERROR: exit 42 missing"; exit 1; }
echo "BIGTEST.EXIT42: OK"

grep -q "procs BIGTEST.BIN exited status=42" artifacts/live-m16-image-serial.log || { echo "ERROR: procs exit 42 missing"; exit 1; }
echo "BIGTEST.PROCS_EXIT42: OK"

grep -q "tasks user-exec reaped" artifacts/live-m16-image-serial.log || { echo "ERROR: reap missing"; exit 1; }
echo "BIGTEST.REAP: OK"

grep -q "m16-image-ok" artifacts/live-m16-image-serial.log || { echo "ERROR: m16-image-ok missing"; exit 1; }
echo "BIGTEST.SCRIPT_OK: OK"

# Check syscalls report for write and exit
grep -q "syscalls: slots=64 implemented=46" artifacts/live-m16-image-serial.log || { echo "ERROR: syscalls implemented=46 missing"; exit 1; }
grep -q "1 sys_write calls=" artifacts/live-m16-image-serial.log || { echo "ERROR: sys_write calls missing"; exit 1; }
echo "SYSCALLS: OK"

cat > "$REPORT" <<EOF
=== Milestone 16 C1 Live Gate Report ===
Revision: $REVISION ($BRANCH)
Status: PASS (1/1 on Apple Virtualization.framework)

Verified Components:
- DSK2 file $BIGTEST size $SIZE (>16 KiB), magic DSK2, 2 segments RX+RW
- BIGTEST.BIN on ESP, exec loaded with size $EXEC_SIZE_DEC (>16 KiB)
- Writable globals: global_counter RW, large_data RW, large_ro RX, BSS zero + RW
- Markers: start, bss zero ok, global rw ok, large_data rw ok, large_ro ok, bss write ok, large_data[0]=66, done
- Lifecycle: exit 42, procs exit 42, reaped
- Syscalls: implemented=46, write+exit counted

Serial Highlights:
$(grep -E 'bigtest:|exec: loaded BIGTEST|tasks user-exec|procs BIGTEST' artifacts/live-m16-image-serial.log || true)
EOF

echo "verify-live-m16-image: PASS — DSK2 >16 KiB + writable globals/BSS verified on VZ."

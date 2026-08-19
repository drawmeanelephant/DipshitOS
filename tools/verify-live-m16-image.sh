#!/usr/bin/env bash
#
# verify-live-m16-image.sh -- claim 3805 (Milestone 16, Card C1) class-B gate:
# the SEGMENTED DSK3 user image format verified on real Apple silicon
# Virtualization.framework hardware.
#
# GLOBALS.BIN is the first segmented image: a read-only W^X text region
# (28 KiB — past the OLD 16 KiB exec bound, wishlist 15), a writable
# `.data` global, and a zero-filled 4 KiB `.bss` global (the M15 JINGLE
# finding reversed: EL0 writable globals exist now). The program reads its
# `.data` initial value, writes it back, reads+writes `.bss`, and reads its
# `.rodata` blob; only when all five checks pass does it print
# `globals: data bss ok` and exit 42.
#
# The gate asserts the kernel's OWN page accounting is exact: the exec reply
# reports size=0x7000 (28 KiB of text) and data=0x1010 datapages=2 (4112
# bytes of data+bss over 2 pages), matching what elf2bin emitted.
#
# Usage:
#   bash tools/verify-live-m16-image.sh
#

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/live-m16-image-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

REPORT="artifacts/live-m16-image-report.txt"

echo "=== verify-live-m16-image: claim 3805 — Milestone 16 C1 on VZ ==="

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

cat > artifacts/live-m16-image-script.txt <<'EOF'
exec GLOBALS.BIN
EOF

cat > artifacts/live-m16-image-script2.txt <<'EOF'
echo m16-image-live-ok
EOF

# The boot payload's exit line frees the pool slot the exec lands in.
STATIC_EXIT_LINE="tasks user-el0 exited status=7"

echo "--- Phase 1: Running GLOBALS.BIN on VZ ---"
rm -f artifacts/efi-vars.bin
rm -f artifacts/vm-serial.log artifacts/gpu-screen-*

set +e
host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
    --script artifacts/live-m16-image-script.txt \
    --script-after "$STATIC_EXIT_LINE" \
    --script2 artifacts/live-m16-image-script2.txt \
    --script2-after "globals: data bss ok" \
    --script-expect "m16-image-live-ok" \
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

echo "--- Phase 2: Verifying GLOBALS.BIN Markers ---"

# The exec reply: the 28 KiB text region proves the lifted load bound (the
# OLD 16 KiB bound would have refused this image).
grep -q "exec: loaded GLOBALS.BIN size=0x0000000000007000" artifacts/live-m16-image-serial.log || {
    echo "ERROR: exec reply missing the 28 KiB text size (size=0x7000)"
    grep -E "exec: loaded GLOBALS.BIN" artifacts/live-m16-image-serial.log || true
    exit 1
}
echo "IMAGE.SIZE_28K: OK"

# The kernel's own page accounting: 4112 bytes of data+bss over 2 pages.
grep -q "data=0x0000000000001010 datapages=2" artifacts/live-m16-image-serial.log || {
    echo "ERROR: data segment page accounting missing (expected data=0x1010 datapages=2)"
    grep -E "exec: loaded GLOBALS.BIN" artifacts/live-m16-image-serial.log || true
    exit 1
}
echo "IMAGE.DATA_PAGES: OK"

grep -q "globals: data bss ok" artifacts/live-m16-image-serial.log || {
    echo "ERROR: GLOBALS.BIN success marker missing from serial log"
    exit 1
}
echo "GLOBALS.DATA_BSS: OK"

grep -q "tasks user-exec exited status=42" artifacts/live-m16-image-serial.log || {
    echo "ERROR: GLOBALS.BIN exit status=42 line missing from serial log"
    exit 1
}
echo "GLOBALS.EXIT42: OK"

grep -q "m16-image-live-ok" artifacts/live-m16-image-serial.log || {
    echo "ERROR: final sweep marker missing from serial log"
    exit 1
}

cat > "$REPORT" <<EOF
=== Milestone 16 C1 Live Gate Report ===
Revision: $REVISION ($BRANCH)
Status: PASS (1/1 on Apple Virtualization.framework)

Verified Components:
- The segmented DSK3 loader (elf2bin --segments + exec second path) loaded
  GLOBALS.BIN: 28 KiB of read-only W^X text (> the old 16 KiB bound, wishlist
  15 reversed)
- Writable .data + zero-filled .bss globals worked from EL0 (the M15 JINGLE
  finding reversed): read init value, write/read data, read/write bss, read
  the 24 KiB .rodata blob
- Kernel page accounting exact: size=0x7000 text, data=0x1010 datapages=2
- The program exited status 42

Serial Output Highlights:
$(grep -E 'exec: loaded GLOBALS.BIN|globals:|user-exec exited' artifacts/live-m16-image-serial.log || true)
EOF

echo "verify-live-m16-image: PASS — segmented image + writable globals verified on VZ."

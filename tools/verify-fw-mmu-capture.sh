#!/usr/bin/env bash
#
# verify-fw-mmu-capture.sh -- claim 0021 gate: capture the firmware's MMU
# state and the virtio BAR-window's firmware mapping BEFORE ExitBootServices,
# and diff against the kernel's planned identity-map values.
#
# Mechanism: builds the kernel with -Dfw-mmu-capture=true (default off; the
# default build is byte-identical), boots it once in a VZ VM with a fresh
# variable store, and extracts the ASCII variable `DipshitMmu` from
# artifacts/efi-vars.bin. The captured lines record the firmware's
# SCTLR/TCR/MAIR/TTBR0/TTBR1/ID_AA64MMFR0, a bounded walk of the firmware's
# TTBR0 tables for the virtio BAR0 window (0x100010000 — the claim-0020
# post-switch hang target) and a RAM control address, and the kernel's
# planned MAIR/TCR/TTBR0/BAR-descriptor values.
#
# This feeds claim 0022's "reconstruct exactly what is OBSERVED" step and
# supersedes claim 0010's missing raw register artifact (only quoted values
# survive in this checkout). Diagnostic only — no production change, does not
# pass the claim-0002 serial gate.
#
# Usage: bash tools/verify-fw-mmu-capture.sh
# Evidence saved under artifacts/: fw-mmu-capture-gate.txt (full output),
# fw-mmu-capture-run.txt (runner output), fw-mmu-capture-efi-vars.bin (the
# store), fw-mmu-capture-lines.txt (the captured MMU lines), vm-serial.log.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GATE_LOG="artifacts/fw-mmu-capture-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
trap 'sleep 0.5' EXIT

echo "=== verify-fw-mmu-capture: claim 0021 — firmware MMU state + virtio BAR-window mapping ==="

zig version; swift --version 2>&1 | head -1; sw_vers
REVISION="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
echo "revision: $REVISION branch=$BRANCH build=-Dfw-mmu-capture=true"

zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
zig build
zig build -Dfw-mmu-capture=true
zig build -Dfw-mmu-capture=true image
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

rm -f artifacts/efi-vars.bin
set +e
host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
    --dump-marker artifacts/fw-mmu-marker.txt --timeout 25 \
    > artifacts/fw-mmu-capture-run.txt 2>&1
RUNNER_RC=$?
set -e
cp artifacts/efi-vars.bin artifacts/fw-mmu-capture-efi-vars.bin

echo
echo "=== captured MMU lines (strings of the EFI variable store) ==="
strings artifacts/fw-mmu-capture-efi-vars.bin | grep -E '^(MMU |SEL )' > artifacts/fw-mmu-capture-lines.txt || true
cat artifacts/fw-mmu-capture-lines.txt

echo
echo "=== assertions ==="
FAIL=0
for needle in \
    'MMU SCTLR=' \
    'MMU TCR=' \
    'MMU MAIR=' \
    'MMU TTBR0=' \
    'MMU TTBR1=' \
    'MMU IDAA64MMFR0=' \
    'MMU WALK BAR va=' \
    'MMU WALK RAM va=' \
    'MMU KERNEL-PLAN'; do
    if grep -qF "$needle" artifacts/fw-mmu-capture-lines.txt; then
        echo "  PASS: $needle"
    else
        echo "  FAIL: $needle missing"
        FAIL=1
    fi
done

if [ "$FAIL" = 1 ]; then
    echo
    echo "verify-fw-mmu-capture: FAILED — the capture is incomplete; see artifacts/fw-mmu-capture-lines.txt"
    sleep 0.5
    exit 1
fi
echo
echo "verify-fw-mmu-capture: PASS — firmware MMU state + BAR-window walk captured (diagnostic only)"
echo "  Compare 'MMU WALK BAR ... A=...' against 'MMU KERNEL-PLAN ... BAR=...|0x403 (Device 4K page, MAIR A0=0x00)'."
sleep 0.5
exit 0

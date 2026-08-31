#!/usr/bin/env bash
#
# verify-preexit-tx.sh -- claim 0017 diagnostic gate: can the CURRENT
# virtio-pci console TX a known string while Boot Services and the firmware
# address space are still active?
#
# Background (claims 0013/0016): the VZ serial attachment is a modern
# virtio-pci console (bus 0 D5, VID 0x1af4 DID 0x1043) whose transport arms
# completely PRE-EXIT (features, queue 1, DRIVER_OK) but whose POST-EXIT
# access hangs on VZ (the first banner TX dies in the first flush;
# vm-serial.log stays 0 B). This gate isolates WHICH side the failure is on:
#
#   * A. PRE-EXIT TX WORKS: the same device/queue/notify communicates while
#     Boot Services + firmware address space are active (the fixed string
#     appears in vm-serial.log), so the residual failure is somewhere
#     across ExitBootServices/MMU/post-exit access.
#   * B. PRE-EXIT TX DOES NOT WORK: the fixed string never appears; the
#     NVRAM ladder bracket names where the flush died, and the transport is
#     not yet proven -- the post-exit transition cannot be blamed.
#   * STILL INDETERMINATE: no bracket and no bytes (transport never armed).
#
# Mechanism: build with -Dpreexit-tx=true (a fixed line
# "VIRELAIOS PREEXIT VIRTIO TX" is TX'd through the SAME virtio transport
# -- same device, BAR, capability decoding, negotiated features, TX queue,
# desc/avail/used rings, 16-bit notify -- before ExitBootServices), boot in
# a VZ VM, and check vm-serial.log for the exact string while reading the
# NVRAM marker ladder bracket (M2_PEXT! ... M2_TXST!/M2_TXNT!/M2_TXPL! ...
# M2_PEXD!) for the death site.
#
# The serial channel IS the gate here (the diagnostic line, pre-exit); the
# marker ladder is the bracketing evidence. Run on Apple silicon only (VZ
# VM). Diagnostic only: the post-exit banner TX (claim 0002) is untouched;
# a pre-exit hit does NOT pass the VZ serial gate.
#
# Usage: bash tools/verify-preexit-tx.sh
# Evidence saved under artifacts/: preexit-tx-gate.txt (this script's full
# output), preexit-tx-run.txt (runner output), preexit-marker-dump.txt (the
# ladder), vm-serial.log (the diagnostic line), efi-vars.bin (the store),
# plus the loader evidence via the disk image.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# Save the script's complete output under artifacts/ (bash 3.2-compatible).
GATE_LOG="artifacts/preexit-tx-gate.txt"
exec > >(tee "$GATE_LOG") 2>&1
# Let the tee drain on every exit path so the gate log is complete.
trap 'sleep 0.5' EXIT

echo "=== verify-preexit-tx: claim 0017 — pre-exit virtio-pci TX diagnostic ==="

# --- tool versions (record which Zig/Swift/macOS you ran on) ---------------
zig version; swift --version 2>&1 | head -1; sw_vers

# --- formatting gate ---------------------------------------------------------
zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig

# --- build gates (kernel built with the pre-exit TX experiment enabled) ------
zig build -Dpreexit-tx=true
zig build -Dpreexit-tx=true image

# --- Swift runner build ---------------------------------------------------------
swift build --package-path host/vm-runner --configuration release
codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner

# Fresh variable store so the ladder bracket is exactly this run's writes
# (the store is append-per-write and survives across runs otherwise).
rm -f artifacts/efi-vars.bin

# --- THE GATE: boot the VM, capture vm-serial.log + the ladder bracket -------
set +e
host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log \
    --dump-marker artifacts/preexit-marker-dump.txt --timeout 25 \
    --expect "VIRELAIOS PREEXIT VIRTIO TX" \
    > artifacts/preexit-tx-run.txt 2>&1
RUNNER_RC=$?
set -e
cat artifacts/preexit-tx-run.txt

echo
echo "=== marker ladder (artifacts/preexit-marker-dump.txt) ==="
[ -f artifacts/preexit-marker-dump.txt ] || { echo "ERROR: no marker dump produced" >&2; exit 1; }
cat artifacts/preexit-marker-dump.txt

echo
echo "=== vm-serial.log (artifacts/vm-serial.log) ==="
[ -f artifacts/vm-serial.log ] || { echo "ERROR: no vm-serial.log produced" >&2; exit 1; }
cat artifacts/vm-serial.log

# --- loader evidence (preserved, exactly like the other gates) ----------------
echo
echo "=== loader evidence on the ESP (preserved) ==="
BOOTED_TXT="$(python3 image/mkfat32.py --cat-file /BOOTED.TXT artifacts/disk.img 2>/dev/null || true)"
printf '%s\n' "$BOOTED_TXT"
echo
echo "=== loader trace: /LOADER.TXT on the ESP ==="
LOADER_TXT="$(python3 image/mkfat32.py --cat-file /LOADER.TXT artifacts/disk.img 2>/dev/null || true)"
printf '%s\n' "$LOADER_TXT"

# --- interpretation -------------------------------------------------------------
if grep -qF -- "VIRELAIOS PREEXIT VIRTIO TX" artifacts/vm-serial.log; then
    echo
    echo "VERDICT: A. PRE-EXIT TX WORKS -- OBSERVED (the exact diagnostic string reached vm-serial.log while Boot Services and the firmware address space were still active)"
    echo "  The same device/BAR/features/queue/desc-avail-used/notify communicate pre-exit; the residual failure is somewhere across ExitBootServices/MMU/post-exit access."
    echo "verify-preexit-tx: PASS (diagnostic -- does NOT pass the claim-0002 VZ serial gate; post-exit TX untouched)"
    sleep 0.5  # let the tee drain before exit
    exit 0
fi

# Not observed: name the bracket stage for interpretation B / indeterminate.
# The pre-exit bracket is the subsequence M2_PEXT!/M2_TXST!/M2_TXNT!/
# M2_TXPL!/M2_PEXD! in the ladder. (TXST/TXNT/TXPL also fire post-exit in
# the banner flush, so the subsequence may repeat; the FIRST run is the
# pre-exit experiment.)
BRACKET=()
while IFS= read -r line; do
    BRACKET+=("$line")
done < <(grep -E '^MARKER-GATE: M2_(PEXT|TXST|TXNT|TXPL|PEXD)!' artifacts/preexit-tx-run.txt || true)
if [ "${#BRACKET[@]}" -eq 0 ]; then
    echo
    echo "=== pre-exit TX bracket (first occurrences in ladder order) ==="
    echo "  (none — the experiment never ran: the transport was not armed pre-exit, or the kernel died earlier)"
    echo
    echo "VERDICT: STILL INDETERMINATE -- no pre-exit-TX bracket marker AND no serial bytes (transport never armed pre-exit, or the kernel died before the experiment)"
    echo "  The transport implementation is not proven by this run, but there is also no evidence of a pre-exit flush attempt; re-run for a clean boot."
    echo "verify-preexit-tx: FAILED (diagnostic -- indeterminate; evidence kept under artifacts/)"
    sleep 0.5
    exit 1
fi
B_LAST="${BRACKET[${#BRACKET[@]}-1]#MARKER-GATE: }"

echo
echo "=== pre-exit TX bracket (first occurrences in ladder order) ==="
for line in "${BRACKET[@]}"; do
    echo "  $line"
done
echo
echo "VERDICT: B. PRE-EXIT TX DOES NOT WORK -- OBSERVED FAILING/HANGING (the exact string never reached vm-serial.log)"
echo "  Last bracket stage: $B_LAST"
case "$B_LAST" in
    M2_PEXT!*) echo "  -> the flush hung BEFORE descriptor publication (no M2_TXST!): the ring/status-read path stalled pre-exit." ;;
    M2_TXST!*) echo "  -> descriptor/avail posted (M2_TXST!) but the notify was never issued (no M2_TXNT!): stalled at the device-status read or the notify write." ;;
    M2_TXNT!*) echo "  -> notify issued (M2_TXNT!) but the used ring never completed (no M2_TXPL!): the device did not consume the buffer pre-exit." ;;
    M2_TXPL!*) echo "  -> flush returned (M2_TXPL!/M2_PEXD!) but no bytes reached vm-serial.log: the device dropped the buffer or the host attachment never delivered it." ;;
    *) echo "  -> the transport never reached the experiment (not armed pre-exit): transport implementation not proven; the post-exit transition cannot be blamed." ;;
esac
echo "verify-preexit-tx: FAILED (diagnostic -- transport not proven pre-exit; evidence kept under artifacts/)"
sleep 0.5
exit 1

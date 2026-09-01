#!/usr/bin/env bash
#
# make-image.sh -- build the bootable FAT32+GPT boot disk image for VirelaiOS.
#
# Usage: make-image.sh [EFI_BINARY] [IMAGE_PATH] [KERNEL_BINARY]
# Defaults: zig-out/bin/BOOTAA64.EFI   artifacts/disk.img   zig-out/bin/KERNEL.BIN
#
# M34 HF6 (issue #740): the image is a BOOT VOLUME ONLY. It embeds exactly
# two files — EFI/BOOT/BOOTAA64.EFI and KERNEL.BIN — parsed by Apple's
# firmware pre-exit. The embedded-app machinery, the DATA partition, and
# the guest FAT driver are all gone: applications live in the macOS host
# share (runner flag --cvc-file <host-dir>; see the `gate_seed_share`
# helper in tools/lib/gate-run.sh). Raw image size is pinned at the FAT32
# cluster-count floor (~34 MiB, mostly zeros; content ~1.5 MiB).
#
# The image is written to IMAGE.tmp and atomically renamed into place, so
# a concurrent reader (another gate attaching artifacts/disk.img as its
# read-only overlay base) always sees a complete image.
#
# Uses image/mkfat32.py (pure Python 3, stdlib only), so it needs no root,
# no mtools, and no loopback devices. Safe to rerun: the image is rebuilt
# from scratch every time. Fails loudly if a required tool or a compiled
# artifact is missing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

EFI_BIN="${1:-$ROOT_DIR/zig-out/bin/BOOTAA64.EFI}"
IMAGE="${2:-$ROOT_DIR/artifacts/disk.img}"
KERNEL_BIN="${3:-$ROOT_DIR/zig-out/bin/KERNEL.BIN}"
SIZE_MB="${VIRELAIOS_IMAGE_SIZE_MB:-0}"

cd "$ROOT_DIR"

fail() { echo "make-image: ERROR: $*" >&2; exit 1; }

# 1. Required tools.
command -v python3 >/dev/null 2>&1 || fail "python3 is required to build the disk image."

# 2. Compiled artifacts.
[ -f "$EFI_BIN" ] || fail "compiled EFI application not found at '$EFI_BIN' -- run 'zig build' first."
if [ "$(head -c 2 "$EFI_BIN")" != "MZ" ]; then
    fail "'$EFI_BIN' does not look like a PE/COFF image (missing MZ header)."
fi
[ -f "$KERNEL_BIN" ] || fail "kernel image not found at '$KERNEL_BIN' -- run 'zig build' first (it produces zig-out/bin/KERNEL.BIN)."
if [ "$(head -c 4 "$KERNEL_BIN")" != "DSK1" ]; then
    fail "'$KERNEL_BIN' does not start with the 'DSK1' kernel-image magic -- run 'zig build' first."
fi

# 3. Builder script.
[ -f "$SCRIPT_DIR/mkfat32.py" ] || fail "missing $SCRIPT_DIR/mkfat32.py."

# 4. Rebuild the image from scratch (safe to rerun), atomically.
mkdir -p "$(dirname "$IMAGE")"
rm -f "$IMAGE.tmp"
echo "make-image: building FAT32+GPT boot image '$IMAGE' (${SIZE_MB:-FAT32-floor} MiB)..."

python3 "$SCRIPT_DIR/mkfat32.py" --size-mb "${SIZE_MB:-0}" "$IMAGE.tmp" "$EFI_BIN" "$KERNEL_BIN" \
    || fail "image creation failed (see output above)."
mv -f "$IMAGE.tmp" "$IMAGE"

# 5. Self-verify by listing the image we just wrote.
echo "make-image: verifying image contents..."
LISTING="$(python3 "$SCRIPT_DIR/mkfat32.py" --list "$IMAGE")" \
    || fail "image verification failed."
printf '%s\n' "$LISTING"
printf '%s\n' "$LISTING" | grep -q 'KERNEL.BIN' || fail "KERNEL.BIN missing from the image listing"
printf '%s\n' "$LISTING" | grep -q 'BOOTAA64.EFI' || fail "BOOTAA64.EFI missing from the image listing"

echo "make-image: done."

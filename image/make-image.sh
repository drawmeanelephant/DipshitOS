#!/usr/bin/env bash
#
# make-image.sh -- build the bootable FAT32+GPT boot disk image for DipshitOS.
#
# Usage: make-image.sh [EFI_BINARY] [IMAGE_PATH] [KERNEL_BINARY]
# Defaults: zig-out/bin/BOOTAA64.EFI   artifacts/disk.img
#           zig-out/bin/KERNEL.BIN
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
SIZE_MB="${DIPSHITOS_IMAGE_SIZE_MB:-64}"

cd "$ROOT_DIR"

fail() { echo "make-image: ERROR: $*" >&2; exit 1; }

# 1. Required tools.
command -v python3 >/dev/null 2>&1 || fail "python3 is required to build the disk image."

# 2. Compiled artifacts.
[ -f "$EFI_BIN" ] || fail "compiled EFI application not found at '$EFI_BIN' -- run 'zig build' first."
if [ "$(head -c 2 "$EFI_BIN")" != "MZ" ]; then
    fail "'$EFI_BIN' does not look like a PE/COFF image (missing MZ header)."
fi
if [ -f "$KERNEL_BIN" ]; then
    if [ "$(head -c 4 "$KERNEL_BIN")" != "DSK1" ]; then
        fail "'$KERNEL_BIN' does not start with the 'DSK1' kernel-image magic -- run 'zig build' first."
    fi
else
    fail "kernel image not found at '$KERNEL_BIN' -- run 'zig build' first (it produces zig-out/bin/KERNEL.BIN)."
fi

# 3. Builder script.
[ -f "$SCRIPT_DIR/mkfat32.py" ] || fail "missing $SCRIPT_DIR/mkfat32.py."

# 4. Rebuild the image from scratch (safe to rerun).
mkdir -p "$(dirname "$IMAGE")"
rm -f "$IMAGE"
echo "make-image: building FAT32+GPT image '$IMAGE' (${SIZE_MB} MiB)..."
python3 "$SCRIPT_DIR/mkfat32.py" --size-mb "$SIZE_MB" "$IMAGE" "$EFI_BIN" "$KERNEL_BIN" \
    || fail "image creation failed (see output above)."

# 5. Self-verify by listing the image we just wrote.
echo "make-image: verifying image contents..."
python3 "$SCRIPT_DIR/mkfat32.py" --list "$IMAGE" \
    || fail "image verification failed."

echo "make-image: done."

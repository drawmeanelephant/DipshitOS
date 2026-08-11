#!/usr/bin/env bash
#
# make-image.sh -- build the bootable FAT32+GPT boot disk image for DipshitOS.
#
# Usage: make-image.sh [EFI_BINARY] [IMAGE_PATH] [KERNEL_BINARY] [USER_BINARY] [COUNTER_BINARY] [PEER_BINARY] [STATUS43_BINARY]
# Defaults: zig-out/bin/BOOTAA64.EFI   artifacts/disk.img
#           zig-out/bin/KERNEL.BIN     zig-out/bin/USER.BIN
#           zig-out/bin/COUNTER.BIN    zig-out/bin/PEER.BIN
#           zig-out/bin/STATUS43.BIN
#
# USER.BIN (the milestone-three ESP user program, claim 6783), COUNTER.BIN
# (the milestone-four follow-on 2 never-exiting user program, claim 4613),
# PEER.BIN (the follow-on 3 card 3f IPC peer, claim 5965) and STATUS43.BIN
# (the follow-on 4 card 4c wait-gate target, claim 9946) are embedded at the
# volume root when present; the kernel's `exec` monitor command loads them by
# name from the ESP and enters them at EL0.
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
USER_BIN="${4:-$ROOT_DIR/zig-out/bin/USER.BIN}"
COUNTER_BIN="${5:-$ROOT_DIR/zig-out/bin/COUNTER.BIN}"
PEER_BIN="${6:-$ROOT_DIR/zig-out/bin/PEER.BIN}"
STATUS43_BIN="${7:-$ROOT_DIR/zig-out/bin/STATUS43.BIN}"
SIZE_MB="${DIPSHITOS_IMAGE_SIZE_MB:-128}"

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
USER_ARGS=()
if [ -f "$USER_BIN" ]; then
    if [ "$(head -c 4 "$USER_BIN")" != "DSK1" ]; then
        fail "'$USER_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/USER.BIN)."
    fi
    USER_ARGS+=("$USER_BIN")
fi
COUNTER_ARGS=()
if [ -f "$COUNTER_BIN" ]; then
    if [ "$(head -c 4 "$COUNTER_BIN")" != "DSK1" ]; then
        fail "'$COUNTER_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/COUNTER.BIN)."
    fi
    COUNTER_ARGS+=("$COUNTER_BIN")
fi
PEER_ARGS=()
if [ -f "$PEER_BIN" ]; then
    if [ "$(head -c 4 "$PEER_BIN")" != "DSK1" ]; then
        fail "'$PEER_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/PEER.BIN)."
    fi
    PEER_ARGS+=("$PEER_BIN")
fi
STATUS43_ARGS=()
if [ -f "$STATUS43_BIN" ]; then
    if [ "$(head -c 4 "$STATUS43_BIN")" != "DSK1" ]; then
        fail "'$STATUS43_BIN' does not start with the 'DSK1' image magic -- run 'zig build' first (it produces zig-out/bin/STATUS43.BIN)."
    fi
    STATUS43_ARGS+=("$STATUS43_BIN")
fi

# 3. Builder script.
[ -f "$SCRIPT_DIR/mkfat32.py" ] || fail "missing $SCRIPT_DIR/mkfat32.py."

# 4. Rebuild the image from scratch (safe to rerun).
mkdir -p "$(dirname "$IMAGE")"
rm -f "$IMAGE"
echo "make-image: building FAT32+GPT image '$IMAGE' (${SIZE_MB} MiB)..."
python3 "$SCRIPT_DIR/mkfat32.py" --size-mb "$SIZE_MB" "$IMAGE" "$EFI_BIN" "$KERNEL_BIN" "${USER_ARGS[@]}" "${COUNTER_ARGS[@]}" "${PEER_ARGS[@]}" "${STATUS43_ARGS[@]}" \
    || fail "image creation failed (see output above)."

# 5. Self-verify by listing the image we just wrote. The embed is asserted:
# the ESP must carry KERNEL.BIN, USER.BIN, COUNTER.BIN (claim 4613),
# PEER.BIN (claim 5965), and STATUS43.BIN (claim 9946).
echo "make-image: verifying image contents..."
LISTING="$(python3 "$SCRIPT_DIR/mkfat32.py" --list "$IMAGE")" \
    || fail "image verification failed."
printf '%s\n' "$LISTING"
printf '%s\n' "$LISTING" | grep -q 'KERNEL.BIN' || fail "KERNEL.BIN missing from the image listing"
printf '%s\n' "$LISTING" | grep -q 'USER.BIN' || fail "USER.BIN missing from the image listing"
printf '%s\n' "$LISTING" | grep -q 'COUNTER.BIN' || fail "COUNTER.BIN missing from the image listing"
printf '%s\n' "$LISTING" | grep -q 'PEER.BIN' || fail "PEER.BIN missing from the image listing"
printf '%s\n' "$LISTING" | grep -q 'STATUS43.BIN' || fail "STATUS43.BIN missing from the image listing"

echo "make-image: done."

#!/usr/bin/env bash
#
# inspect.sh -- report useful facts about the generated EFI binary and the
# boot disk image. Uses whichever inspection tools are installed (file,
# llvm-objdump, llvm-readobj, objdump, nm, our python FAT/GPT lister, mtools)
# and degrades gracefully when optional tools are unavailable.
#
# Usage: inspect.sh [EFI_BINARY] [IMAGE_PATH]

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

EFI_BIN="${1:-$ROOT_DIR/zig-out/bin/BOOTAA64.EFI}"
IMAGE="${2:-$ROOT_DIR/artifacts/disk.img}"

missing() { printf '  (tool not available: %s)\n' "$*"; }

find_objdump() {
    if command -v llvm-objdump >/dev/null 2>&1; then
        echo "$(command -v llvm-objdump)"
    elif xcrun --find llvm-objdump >/dev/null 2>&1; then
        xcrun --find llvm-objdump
    elif command -v objdump >/dev/null 2>&1; then
        echo "$(command -v objdump)"
    fi
}

printf '=== EFI binary: %s ===\n' "$EFI_BIN"
if [ -f "$EFI_BIN" ]; then
    if command -v file >/dev/null 2>&1; then
        file "$EFI_BIN"
    else
        missing file
    fi

    OBJDUMP="$(find_objdump)"
    if [ -n "$OBJDUMP" ]; then
        printf -- '-- %s -f (file header) --\n' "$(basename "$OBJDUMP")"
        "$OBJDUMP" -f "$EFI_BIN" 2>&1 || true
        printf -- '-- %s --private-headers (PE/COFF) --\n' "$(basename "$OBJDUMP")"
        "$OBJDUMP" --private-headers "$EFI_BIN" 2>&1 | head -70 || true
        printf -- '-- %s -h (sections) --\n' "$(basename "$OBJDUMP")"
        "$OBJDUMP" -h "$EFI_BIN" 2>&1 | head -40 || true
        printf -- '-- %s -d (first 24 lines of disassembly) --\n' "$(basename "$OBJDUMP")"
        "$OBJDUMP" -d "$EFI_BIN" 2>&1 | head -24 || true
    else
        missing "llvm-objdump/objdump"
    fi

    if command -v llvm-readobj >/dev/null 2>&1; then
        printf -- '-- llvm-readobj --coff-headers --\n'
        llvm-readobj --coff-headers "$EFI_BIN" 2>&1 | head -70 || true
    elif xcrun --find llvm-readobj >/dev/null 2>&1; then
        printf -- '-- llvm-readobj --coff-headers --\n'
        xcrun llvm-readobj --coff-headers "$EFI_BIN" 2>&1 | head -70 || true
    else
        missing "llvm-readobj"
    fi

    printf -- '-- symbols of interest --\n'
    if command -v nm >/dev/null 2>&1; then
        nm "$EFI_BIN" 2>&1 | grep -iE 'efi|main|start' | head -10 || true
    else
        missing nm
    fi
else
    printf 'EFI binary not found. Run "zig build" first.\n'
fi

printf '\n=== Disk image: %s ===\n' "$IMAGE"
if [ -f "$IMAGE" ]; then
    if command -v file >/dev/null 2>&1; then
        file "$IMAGE"
    else
        missing file
    fi
    if command -v python3 >/dev/null 2>&1 && [ -f "$ROOT_DIR/image/mkfat32.py" ]; then
        printf -- '-- FAT/GPT listing (python) --\n'
        python3 "$ROOT_DIR/image/mkfat32.py" --list "$IMAGE" 2>&1 || true
    else
        missing "python3 + image/mkfat32.py"
    fi
    if command -v mdir >/dev/null 2>&1; then
        printf -- '-- mtools listing --\n'
        mdir -i "$IMAGE" ::/EFI/BOOT 2>&1 || true
    else
        missing mdir
    fi
else
    printf 'Disk image not found. Run "zig build image" first.\n'
fi

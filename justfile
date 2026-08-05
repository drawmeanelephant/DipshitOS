# DipshitOS milestone-zero command aliases.
# Requires: just (https://github.com/casey/just)
# All recipes simply delegate to the Zig build system.

set shell := ["bash", "-c"]

default: build

# Compile the AArch64 UEFI application (zig build)
build:
    zig build

# Create the FAT32+GPT boot disk image (zig build image)
image:
    zig build image

# Boot with the Swift Virtualization.framework runner (zig build run)
run:
    zig build run

# Boot with QEMU, if installed (zig build run-qemu)
run-qemu:
    zig build run-qemu

# Inspect the EFI binary and disk image (zig build inspect)
inspect:
    zig build inspect

# Regenerate artifacts/context.md (zig build context)
context:
    zig build context

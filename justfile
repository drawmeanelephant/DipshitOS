# DipshitOS command aliases.
# Requires: just (https://github.com/casey/just)
# All recipes simply delegate to the Zig build system.

set shell := ["bash", "-c"]

default: build

# Compile the AArch64 UEFI application and kernel image (zig build)
build:
    zig build

# Extract the flat kernel image zig-out/bin/KERNEL.BIN (zig build kernel)
kernel:
    zig build kernel

# Create the FAT32+GPT boot disk image (zig build image)
image:
    zig build image

# Boot with the Swift Virtualization.framework runner (zig build run)
run:
    zig build run

# Inspect the EFI binary and disk image (zig build inspect)
inspect:
    zig build inspect

# Regenerate artifacts/context.md (zig build context)
context:
    zig build context

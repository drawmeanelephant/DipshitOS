# DipshitOS command aliases.
# Requires: just (https://github.com/casey/just)
# All recipes simply delegate to the Zig build system.

set shell := ["bash", "-c"]

default: build

# Compile the AArch64 UEFI application and kernel image (zig build)
build:
    zig build

# Run the M1.5 kernel monitor module unit tests (zig test per module; skips modules not yet landed)
test:
    bash tools/verify-unit-tests.sh

# Run the automated dipshit> transcript test — mock console, no VM (M1.5 march step 19)
test-console:
    zig build test-console

# Boot the VM and save the host-side NVRAM marker ladder (ADR 0004 D4 fallback, `zig build marker`)
marker:
    zig build marker

# Verify the ADR 0004 D4 fixed-memory-marker fallback gate (boots a VZ VM; Apple silicon only)
verify-marker:
    bash tools/verify-marker.sh

# Boot the -Dnvram-console=true image and reconstruct the post-exit NVRAM console stream (zig build nvram-console; claim 0015)
nvram-console:
    zig build nvram-console

# Verify the claim-0015 NVRAM console gate (post-exit console bytes via the NVRAM channel; boots a VZ VM; Apple silicon only)
verify-nvram-console:
    bash tools/verify-nvram-console.sh

# Extract the flat kernel image zig-out/bin/KERNEL.BIN (zig build kernel)
kernel:
    zig build kernel

# Create the FAT32+GPT boot disk image (zig build image)
image:
    zig build image

# Boot with the Swift Virtualization.framework runner (zig build run)
run:
    zig build run

# Boot an interactive host serial console (zig build console)
console:
    zig build console

# Inspect the EFI binary and disk image (zig build inspect)
inspect:
    zig build inspect

# Regenerate artifacts/context.md (zig build context)
context:
    zig build context

# Local Git-aware context engine — tools/ragshit (ragshit index/query/bundle/doctor ...)
ragshit *ARGS:
    python3 tools/ragshit/ragshit {{ARGS}}

# Run the build-gate verification sequence from docs/testing.md (no VM)
verify:
    zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
    bash tools/verify-unit-tests.sh
    zig build test-console
    zig build
    zig build image
    zig build inspect
    swift build --package-path host/vm-runner
    zig build context
    bash tools/verify-coordination.sh

# Verify the multiagent coordination surface (claims/logs files + generated indexes)
verify-coordination:
    bash tools/verify-coordination.sh

# Regenerate the claim/log index tables from the files (run after creating a claim or branch log)
refresh-indexes:
    bash tools/status/refresh-indexes.sh

# Verify the pre-exit failure path (boots a VZ VM; Apple silicon only)
verify-bad-handoff:
    bash tools/verify-bad-handoff.sh

# Verify the M1.5 host-side interactive serial plumbing (boots VZ VMs; Apple silicon only)
verify-host-console:
    bash tools/verify-host-console.sh

# Git-aware change-impact reviewer context (ragshit impact)
impact *ARGS:
    python3 tools/ragshit/ragshit impact {{ARGS}}

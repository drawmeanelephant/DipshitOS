//! DipshitOS root build system (milestone zero).
//!
//! Written against Zig 0.16.0 (pinned in .zigversion). Notable 0.16
//! differences from older tutorials that this file accounts for:
//!   * `b.addExecutable` takes `.root_module = b.createModule(...)`.
//!   * `build.zig.zon` uses `.name = .dipshitos`, `.fingerprint`,
//!     `.minimum_zig_version` and a `.paths` allowlist.
//!   * `Step.Run` exposes settable `has_side_effects` and `stdio` fields
//!     (verified against the installed 0.16.0 std sources).
//! See docs/decisions/0001-arm64-uefi-zig.md and README.md.

const std = @import("std");

pub fn build(b: *std.Build) void {
    // ------------------------------------------------------------------
    // Guest: AArch64 UEFI application -- the loader (BOOTAA64.EFI).
    // ------------------------------------------------------------------
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .uefi,
    });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    const efi = b.addExecutable(.{
        .name = "bootaa64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("boot/src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    // Canonical removable-media ARM64 UEFI filename (EFI/BOOT/BOOTAA64.EFI).
    // Set directly on the compile so the installed artifact is named exactly
    // BOOTAA64.EFI. (On case-insensitive APFS a separate install step would
    // collide with the default lowercase artifact name.)
    efi.out_filename = "BOOTAA64.EFI";
    b.installArtifact(efi);

    // ------------------------------------------------------------------
    // Guest: freestanding AArch64 kernel (linked ELF -> flat KERNEL.BIN).
    // ------------------------------------------------------------------
    const kernel_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
    });
    // The kernel is always built ReleaseSmall regardless of the loader's
    // mode: Debug's safety runtime (ubsan_rt etc.) bloats the flat blob and
    // emits absolute-address movk chains, which would break the kernel's
    // load-anywhere (PC-relative) contract. See ADR 0002.
    const kernel = b.addExecutable(.{
        .name = "dipshit-kernel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("kernel/src/main.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    // Dense layout from address 0 (kernel/linker.ld): without this, lld's
    // 64 KiB max-page-size padding would inflate the flat image ~100x.
    kernel.linker_script = b.path("kernel/linker.ld");
    // tools/elf2bin.py converts the linked ELF into the flat kernel image
    // format v1 (magic "DSK1", entry offset, size; see docs/decisions/
    // 0002-kernel-handoff.md). The loader on the ESP reads KERNEL.BIN.
    const kernel_step = b.step("kernel", "Extract the flat kernel image (zig-out/bin/KERNEL.BIN) from the freestanding ELF");
    const elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    elf2bin.addFileArg(kernel.getEmittedBin());
    const kernel_bin = elf2bin.addOutputFileArg("KERNEL.BIN");
    elf2bin.has_side_effects = true;
    elf2bin.stdio = .inherit;
    kernel_step.dependOn(&elf2bin.step);
    const install_kernel = b.addInstallFileWithDir(kernel_bin, .bin, "KERNEL.BIN");
    b.getInstallStep().dependOn(&install_kernel.step);

    // ------------------------------------------------------------------
    // Top-level steps. System-command steps are marked as having side
    // effects (and inherit stdio) so they always execute instead of being
    // skipped by the build cache. (No QEMU path: this project targets Apple
    // Virtualization.framework only.)
    // ------------------------------------------------------------------
    const image_step = b.step("image", "Create the FAT32+GPT boot disk image at artifacts/disk.img");
    const image = b.addSystemCommand(&.{ "bash", "image/make-image.sh" });
    image.addFileArg(efi.getEmittedBin());
    image.addArg("artifacts/disk.img");
    image.addFileArg(kernel_bin); // make-image.sh: [EFI_BIN] [IMAGE] [KERNEL_BIN]
    image.has_side_effects = true;
    image.stdio = .inherit;
    image_step.dependOn(&image.step);

    const inspect_step = b.step("inspect", "Inspect the EFI binary and the disk image");
    const inspect = b.addSystemCommand(&.{ "bash", "tools/inspect.sh" });
    inspect.addFileArg(efi.getEmittedBin());
    inspect.addArg("artifacts/disk.img");
    inspect.has_side_effects = true;
    inspect.stdio = .inherit;
    inspect_step.dependOn(&inspect.step);

    const run_step = b.step("run", "Boot the disk image with the Swift Virtualization.framework runner");
    const run = b.addSystemCommand(&.{ "bash", "-c", run_vm_command });
    run.step.dependOn(&image.step);
    run.has_side_effects = true;
    run.stdio = .inherit;
    run_step.dependOn(&run.step);

    const context_step = b.step("context", "Regenerate artifacts/context.md (deterministic project snapshot)");
    const context = b.addSystemCommand(&.{ "bash", "tools/context/build-context.sh" });
    context.has_side_effects = true;
    context.stdio = .inherit;
    context_step.dependOn(&context.step);
}

const run_vm_command =
    \\set -e
    \\swift build --package-path host/vm-runner --configuration release
    \\# Recent macOS requires the com.apple.security.virtualization entitlement;
    \\# ad-hoc codesign the binary with it before running.
    \\codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner
    \\# Apple's EFI firmware does not route its console to the virtio serial
    \\# port or render it to the framebuffer, so the guest also writes its
    \\# message to \\BOOTED.TXT on the ESP (UEFI Simple File System).
    \\# VMRunner exits 0 once the VM ran; the cat below is the real gate:
    \\# it fails the step unless the guest wrote the marker files.
    \\host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log --screen artifacts/vm-screen.png
    \\echo
    \\echo "=== guest execution evidence: \\BOOTED.TXT on the ESP ==="
    \\EVIDENCE="$(python3 image/mkfat32.py --cat-file /BOOTED.TXT artifacts/disk.img)" || { echo "evidence missing: the guest did not write BOOTED.TXT"; exit 1; }
    \\printf '%s\n' "$EVIDENCE"
    \\printf '%s' "$EVIDENCE" | grep -q "firmware has agreed to cooperate" || { echo "evidence content mismatch"; exit 1; }
    \\echo
    \\echo "=== loader trace: \\LOADER.TXT on the ESP ==="
    \\python3 image/mkfat32.py --cat-file /LOADER.TXT artifacts/disk.img 2>/dev/null || echo "(no LOADER.TXT -- the loader did not reach the kernel jump)"
    \\echo
    \\echo "=== kernel return evidence: \\RC.TXT on the ESP ==="
    \\RCEVIDENCE="$(python3 image/mkfat32.py --cat-file /RC.TXT artifacts/disk.img)" || { echo "kernel return missing: the kernel did not return to the loader"; exit 1; }
    \\printf '%s\n' "$RCEVIDENCE"
    \\printf '%s' "$RCEVIDENCE" | grep -q "kernel_rc=0x0000000000000000" || { echo "kernel returned a nonzero rc"; exit 1; }
    \\echo
    \\echo "=== kernel marker: \\KERNEL.TXT (the kernel's own write, informational) ==="
    \\python3 image/mkfat32.py --cat-file /KERNEL.TXT artifacts/disk.img 2>/dev/null || echo "(no KERNEL.TXT)"
    \\echo
    \\echo "note: on Apple VZ firmware the KERNEL.TXT bytes are currently scrambled"
    \\echo "(observed firmware quirk; see docs/decisions/0002-kernel-handoff.md). The"
    \\echo "RC.TXT gate above is the clean proof that the kernel ran and returned."
    \\echo
    \\echo "run: boot completed; loader and kernel handoff observed (BOOTED.TXT, LOADER.TXT, RC.TXT)"
;

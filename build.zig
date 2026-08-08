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
    const bad_handoff = b.option(bool, "bad-handoff", "Corrupt handoff v2 magic for the pre-exit failure-path test") orelse false;
    const boot_options = b.addOptions();
    boot_options.addOption(bool, "bad_handoff", bad_handoff);

    const efi = b.addExecutable(.{
        .name = "bootaa64",
        .root_module = b.createModule(.{
            .root_source_file = b.path("boot/src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    efi.root_module.addOptions("build_options", boot_options);
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
    // Claim 0015: `-Dnvram-console` diverts console TX through the NVRAM
    // variable channel (post-exit access to the virtio transport hangs on
    // VZ — claim 0013), so the kernel can produce host-observable console
    // bytes after the MMU switch. Default off: the virtio TX path is
    // unchanged.
    const nvram_console = b.option(bool, "nvram-console", "Route kernel console TX through the NVRAM variable channel instead of the MMIO serial transport (claim 0015; for the VZ post-exit evidence gate)") orelse false;
    // Claim 0017: `-Dpreexit-tx` transmits a fixed diagnostic line
    // ("DIPSHITOS PREEXIT VIRTIO TX") through the virtio-pci console
    // transport BEFORE ExitBootServices, while Boot Services and the
    // firmware address space are still active — using the same device, BAR,
    // rings and notify mechanism as the post-exit path. Default off: the
    // post-exit TX path and every existing gate are byte-identical.
    const preexit_tx = b.option(bool, "preexit-tx", "Transmit 'DIPSHITOS PREEXIT VIRTIO TX' through the virtio-pci transport before ExitBootServices (claim 0017 diagnostic)") orelse false;
    // Claim 0018: `-Dtx-diag` replaces the flush's coarse TXST/TXNT/TXPL
    // markers with ten ordered per-stage NVRAM markers around each
    // potentially fatal operation of the first post-exit virtio TX, and
    // removes the large post-exit probe-tail SetVariable + logging-only
    // status dump from the flush. Default off: the default build's flush is
    // byte-identical.
    const tx_diag = b.option(bool, "tx-diag", "Bisect the post-exit virtio TX failure with per-stage NVRAM markers (claim 0018 diagnostic)") orelse false;
    const kernel_options = b.addOptions();
    kernel_options.addOption(bool, "nvram_console", nvram_console);
    kernel_options.addOption(bool, "preexit_tx", preexit_tx);
    kernel_options.addOption(bool, "tx_diag", tx_diag);
    const kernel = b.addExecutable(.{
        .name = "dipshit-kernel",
        .root_module = b.createModule(.{
            .root_source_file = b.path("kernel/src/main.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    kernel.root_module.addOptions("build_options", kernel_options);
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

    const failure_step = b.step("bad-handoff", "Build a deliberately corrupted handoff image for the pre-exit failure-path test");
    const failure_image = b.addSystemCommand(&.{ "bash", "image/make-image.sh" });
    failure_image.addFileArg(efi.getEmittedBin());
    failure_image.addArg("artifacts/bad-handoff.img");
    failure_image.addFileArg(kernel_bin);
    failure_image.has_side_effects = true;
    failure_image.stdio = .inherit;
    failure_step.dependOn(&failure_image.step);

    const run_step = b.step("run", "Boot the disk image with the Swift Virtualization.framework runner");
    const run = b.addSystemCommand(&.{ "bash", "-c", run_vm_command });
    run.step.dependOn(&image.step);
    run.has_side_effects = true;
    run.stdio = .inherit;
    run_step.dependOn(&run.step);

    const console_step = b.step("console", "Boot the disk image and open an interactive host serial console (M1.5 host plumbing)");
    const console = b.addSystemCommand(&.{ "bash", "-c", console_vm_command });
    console.step.dependOn(&image.step);
    console.has_side_effects = true;
    console.stdio = .inherit;
    console_step.dependOn(&console.step);

    const context_step = b.step("context", "Regenerate artifacts/context.md (deterministic project snapshot)");
    const context = b.addSystemCommand(&.{ "bash", "tools/context/build-context.sh" });
    context.has_side_effects = true;
    context.stdio = .inherit;
    context_step.dependOn(&context.step);

    // ADR 0004 D4 fixed-memory-marker fallback (status.md gate work item 3):
    // boot the VM and save the host-side NVRAM marker ladder (the kernel
    // persists each takeover stage as the EFI variable `DipshitM2`, which
    // runtime SetVariable keeps alive past ExitBootServices on VZ). The gate
    // here is the marker channel, not the serial channel: the runner exits 0
    // iff an M2_* marker was found. The hard gate lives in
    // tools/verify-marker.sh (`just verify-marker`).
    const marker_step = b.step("marker", "Boot the disk image and save the host-side kernel marker dump (ADR 0004 D4 fixed-memory-marker fallback)");
    const marker = b.addSystemCommand(&.{ "bash", "-c", marker_vm_command });
    marker.step.dependOn(&image.step);
    marker.has_side_effects = true;
    marker.stdio = .inherit;
    marker_step.dependOn(&marker.step);

    // M1.5 march step 19: automated transcript test. No VM, no live RX —
    // the shell's mock-fed e2e test asserts the exact `dipshit>` transcript
    // in-test and emits the captured bytes to artifacts/, which this gate
    // diffs byte-for-byte against the canonical fixture
    // tests/transcript-console.txt. The live vm-serial.log assertion stays
    // gated on the VZ serial gate (claim 0002).
    const test_console_step = b.step("test-console", "Run the automated 'dipshit>' transcript test (M1.5 march step 19; mock console, no VM)");
    const test_console = b.addSystemCommand(&.{ "bash", "tools/verify-transcript.sh" });
    test_console.has_side_effects = true;
    test_console.stdio = .inherit;
    test_console_step.dependOn(&test_console.step);

    // Claim 0015: NVRAM console channel. `zig build nvram-console` rebuilds
    // the image with `-Dnvram-console=true` and boots it, reconstructing
    // the post-exit console stream from the EFI variable store. The hard
    // gate with substring assertions lives in tools/verify-nvram-console.sh
    // (`just verify-nvram-console`). Apple silicon only (VZ VM).
    const nvram_console_step = b.step("nvram-console", "Boot the -Dnvram-console=true image and reconstruct the post-exit NVRAM console stream (claim 0015)");
    const nvram_console_run = b.addSystemCommand(&.{ "bash", "-c", nvram_console_vm_command });
    nvram_console_run.has_side_effects = true;
    nvram_console_run.stdio = .inherit;
    nvram_console_step.dependOn(&nvram_console_run.step);

    // Claim 0017: pre-exit virtio-pci TX diagnostic. `zig build preexit-tx`
    // rebuilds the image with -Dpreexit-tx=true and boots it, checking
    // whether the fixed line reaches vm-serial.log while the host saves the
    // NVRAM ladder bracket. The hard gate with the full assertions lives in
    // tools/verify-preexit-tx.sh (`just verify-preexit-tx`). Apple silicon
    // only (VZ VM).
    const preexit_tx_step = b.step("preexit-tx", "Boot the -Dpreexit-tx=true image and check whether the pre-exit virtio TX reaches vm-serial.log (claim 0017 diagnostic)");
    const preexit_tx_run = b.addSystemCommand(&.{ "bash", "-c", preexit_tx_vm_command });
    preexit_tx_run.has_side_effects = true;
    preexit_tx_run.stdio = .inherit;
    preexit_tx_step.dependOn(&preexit_tx_run.step);

    // Claim 0018: post-exit virtio TX bisect. `zig build tx-diag` boots the
    // -Dtx-diag=true image once and saves the per-stage marker ladder; the
    // determinism gate (N identical boots, per-boot ladders + serial logs +
    // revision) lives in tools/verify-tx-diag.sh (`just verify-tx-diag`).
    // Apple silicon only (VZ VM).
    const tx_diag_step = b.step("tx-diag", "Boot the -Dtx-diag=true image and save the per-stage post-exit TX marker ladder (claim 0018 diagnostic)");
    const tx_diag_run = b.addSystemCommand(&.{ "bash", "-c", tx_diag_vm_command });
    tx_diag_run.has_side_effects = true;
    tx_diag_run.stdio = .inherit;
    tx_diag_step.dependOn(&tx_diag_run.step);
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
    \\# The runner waits for the kernel's terminal marker. It accepts the
    \\# serial banner and marker as the milestone-two success signal.
    \\host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log --screen artifacts/vm-screen.png --expect "DipshitOS kernel has seized control." --terminal-marker "kernel terminal state"
    \\echo
    \\echo "=== guest execution evidence: \\BOOTED.TXT on the ESP ==="
    \\EVIDENCE="$(python3 image/mkfat32.py --cat-file /BOOTED.TXT artifacts/disk.img)" || { echo "evidence missing: the guest did not write BOOTED.TXT"; exit 1; }
    \\printf '%s\n' "$EVIDENCE"
    \\printf '%s' "$EVIDENCE" | grep -q "firmware has agreed to cooperate" || { echo "evidence content mismatch"; exit 1; }
    \\echo
    \\echo "=== loader trace: \\LOADER.TXT on the ESP ==="
    \\python3 image/mkfat32.py --cat-file /LOADER.TXT artifacts/disk.img 2>/dev/null || echo "(no LOADER.TXT -- the loader did not reach the kernel jump)"
    \\echo
    \\echo "=== milestone-two serial evidence ==="
    \\SERIAL="$(cat artifacts/vm-serial.log)" || { echo "serial log missing"; exit 1; }
    \\printf '%s\n' "$SERIAL"
    \\printf '%s' "$SERIAL" | grep -q "DipshitOS kernel has seized control." || { echo "kernel banner missing from vm-serial.log"; exit 1; }
    \\printf '%s' "$SERIAL" | grep -q "memory-map descriptors=0x" || { echo "kernel memory-map print missing from vm-serial.log"; exit 1; }
    \\printf '%s' "$SERIAL" | grep -q "kernel terminal state" || { echo "kernel terminal state missing from vm-serial.log"; exit 1; }
    \\echo "run: milestone-two takeover observed (serial banner, memory-map view, terminal state)"
;

// M1.5 host plumbing: `zig build console` boots the image and opens an
// interactive host console. stdin is inherited so keystrokes reach the
// runner; the runner forwards them to the serial attachment (guest RX is a
// separate milestone slice). `zig build run` above keeps the deterministic
// evidence-gated behavior.
const console_vm_command =
    \\set -e
    \\swift build --package-path host/vm-runner --configuration release
    \\codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner
    \\host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log --console
    \\echo
    \\echo "console session ended."
;

// ADR 0004 D4 fixed-memory-marker fallback (status.md gate work item 3):
// `zig build marker` boots the image, saves artifacts/marker-dump.txt (the
// host-side NVRAM marker ladder — the working form of the fallback; the
// memory-scan form is impossible on VZ because guest RAM is not host-mapped),
// and exits with the runner's code (0 iff an M2_* marker was found).
// `tools/verify-marker.sh` is the hard gate that also asserts the dump and
// saves the evidence.
const marker_vm_command =
    \\set -e
    \\swift build --package-path host/vm-runner --configuration release
    \\# Recent macOS requires the com.apple.security.virtualization entitlement;
    \\# ad-hoc codesign the binary with it before running.
    \\codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner
    \\# Fresh variable store so the dump is exactly this run's ladder (the
    \\# store is append-per-write and survives across runs otherwise).
    \\rm -f artifacts/efi-vars.bin
    \\set +e
    \\host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log --dump-marker artifacts/marker-dump.txt --timeout 25 --expect "DipshitOS kernel has seized control." --terminal-marker "kernel terminal state"
    \\RUNNER_RC=$?
    \\set -e
    \\echo
    \\echo "=== marker dump (artifacts/marker-dump.txt) ==="
    \\cat artifacts/marker-dump.txt 2>/dev/null || true
    \\echo
    \\echo "=== loader trace: \\LOADER.TXT on the ESP ==="
    \\python3 image/mkfat32.py --cat-file /LOADER.TXT artifacts/disk.img 2>/dev/null || echo "(no LOADER.TXT -- the loader did not reach the kernel jump)"
    \\exit $RUNNER_RC
;

// Claim 0017: pre-exit virtio-pci TX diagnostic. Rebuilds the kernel +
// image with -Dpreexit-tx=true (a fixed line is TX'd through the virtio-pci
// transport BEFORE ExitBootServices), boots it, and reports whether the
// exact string reached vm-serial.log while saving the NVRAM ladder bracket
// (M2_PEXT!/M2_TXST!/M2_TXNT!/M2_TXPL!/M2_PEXD!). The hard gate lives in
// tools/verify-preexit-tx.sh.
// Claim 0018: post-exit virtio TX bisect. Rebuilds the kernel + image with
// -Dtx-diag=true (the flush writes ten ordered per-stage NVRAM markers;
// see the claim file for the interpretation table), boots it once, and
// saves the ladder. The determinism gate is tools/verify-tx-diag.sh.
const tx_diag_vm_command =
    \\set -e
    \\zig build -Dtx-diag=true image
    \\swift build --package-path host/vm-runner --configuration release
    \\# Recent macOS requires the com.apple.security.virtualization entitlement;
    \\# ad-hoc codesign the binary with it before running.
    \\codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner
    \\# Fresh variable store so the ladder is exactly this run's writes.
    \\rm -f artifacts/efi-vars.bin
    \\set +e
    \\host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log --dump-marker artifacts/tx-diag-marker-dump.txt --timeout 25
    \\RUNNER_RC=$?
    \\set -e
    \\echo
    \\echo "=== marker ladder (artifacts/tx-diag-marker-dump.txt) ==="
    \\cat artifacts/tx-diag-marker-dump.txt 2>/dev/null || true
    \\echo
    \\echo "=== vm-serial.log (artifacts/vm-serial.log) ==="
    \\cat artifacts/vm-serial.log 2>/dev/null || true
    \\exit $RUNNER_RC
;

const preexit_tx_vm_command =
    \\set -e
    \\zig build -Dpreexit-tx=true image
    \\swift build --package-path host/vm-runner --configuration release
    \\# Recent macOS requires the com.apple.security.virtualization entitlement;
    \\# ad-hoc codesign the binary with it before running.
    \\codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner
    \\# Fresh variable store so the ladder bracket is exactly this run's writes.
    \\rm -f artifacts/efi-vars.bin
    \\set +e
    \\host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log --dump-marker artifacts/preexit-marker-dump.txt --timeout 25 --expect "DIPSHITOS PREEXIT VIRTIO TX"
    \\RUNNER_RC=$?
    \\set -e
    \\echo
    \\echo "=== marker ladder (artifacts/preexit-marker-dump.txt) ==="
    \\cat artifacts/preexit-marker-dump.txt 2>/dev/null || true
    \\echo
    \\echo "=== vm-serial.log (artifacts/vm-serial.log) ==="
    \\cat artifacts/vm-serial.log 2>/dev/null || true
    \\echo
    \\if grep -qF -- "DIPSHITOS PREEXIT VIRTIO TX" artifacts/vm-serial.log; then
    \\  echo "PREEXIT-TX: OBSERVED in vm-serial.log (interpretation A — pre-exit TX works; the residual failure is across ExitBootServices/MMU/post-exit)"
    \\  exit 0
    \\else
    \\  echo "PREEXIT-TX: NOT OBSERVED in vm-serial.log (interpretation B / indeterminate — see the marker bracket in artifacts/preexit-marker-dump.txt)"
    \\  exit 1
    \\fi
;

// Claim 0015: NVRAM console channel. The kernel is rebuilt with
// -Dnvram-console=true (its console TX then rides the NVRAM variable
// channel instead of the hanging virtio transport), the image is rebuilt,
// and the runner reconstructs the console stream from efi-vars.bin. The
// hard gate (substring assertions + saved evidence) lives in
// tools/verify-nvram-console.sh.
const nvram_console_vm_command =
    \\set -e
    \\# Claim 0015: rebuild the kernel + image with console TX routed through
    \\# the NVRAM variable channel (post-exit virtio transport access hangs
    \\# on VZ — claim 0013).
    \\zig build -Dnvram-console=true image
    \\swift build --package-path host/vm-runner --configuration release
    \\codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner
    \\rm -f artifacts/efi-vars.bin
    \\set +e
    \\host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-serial.log --nvram-console artifacts/nvram-console.log --timeout 25
    \\RUNNER_RC=$?
    \\set -e
    \\echo
    \\echo "=== nvram console stream (artifacts/nvram-console.log) ==="
    \\cat artifacts/nvram-console.log 2>/dev/null || true
    \\echo
    \\echo "=== loader trace: \\LOADER.TXT on the ESP ==="
    \\python3 image/mkfat32.py --cat-file /LOADER.TXT artifacts/disk.img 2>/dev/null || echo "(no LOADER.TXT -- the loader did not reach the kernel jump)"
    \\exit $RUNNER_RC
;

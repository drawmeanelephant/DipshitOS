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
    // Claim 0020: TX-transition matrix phases. Each is default off; a
    // diagnostic build enables EXACTLY ONE phase, which runs a single
    // controlled TX attempt at its named location (A pre-ExitBootServices,
    // B immediately post-ExitBootServices on the firmware translation,
    // C immediately after the identity-map install, D at the normal final
    // location). Same payload + same transport + same flush in every phase.
    // Default builds stay byte-identical.
    const tx_transition_a = b.option(bool, "tx-transition-a", "Phase A: one virtio TX attempt before ExitBootServices (claim 0020 diagnostic)") orelse false;
    const tx_transition_b = b.option(bool, "tx-transition-b", "Phase B: one virtio TX attempt immediately after ExitBootServices, before DipshitOS page tables (claim 0020 diagnostic)") orelse false;
    const tx_transition_c = b.option(bool, "tx-transition-c", "Phase C: one virtio TX attempt immediately after the identity-map install, before unrelated work (claim 0020 diagnostic)") orelse false;
    const tx_transition_d = b.option(bool, "tx-transition-d", "Phase D: one virtio TX attempt at the normal final location (claim 0020 diagnostic)") orelse false;
    // Claim 0021: firmware MMU-state capture. `-Dfw-mmu-capture` records the
    // firmware's live SCTLR/TCR/MAIR/TTBR0/TTBR1 + a bounded walk of the
    // firmware TTBR0 tables for the virtio BAR0 window and a RAM control
    // address, plus the kernel's planned values, persisted pre-exit as the
    // ASCII variable `DipshitMmu` for a host-side firmware-vs-kernel diff.
    // Default off: the default build is byte-identical.
    const fw_mmu_capture = b.option(bool, "fw-mmu-capture", "Capture firmware MMU registers + a virtio BAR-window table walk pre-exit, persisted to NVRAM (claim 0021 diagnostic)") orelse false;
    // Claim 3475: `-Dprobe-var` persists the claim-0013 probe dump (the raw
    // declared-MMIO-window / config-table / ACPI evidence) as the chunked
    // `DipshitP0..N` variables. Default OFF: the serial log carries the
    // probe records, and VZ's variable store is append-per-write, so the
    // ~32 KiB persist per boot starved the store and left no room for the
    // ESP file window's `write` (claim 3475; claim 0015 already gated the
    // persist off in nvram-console builds for the same starvation).
    const probe_var = b.option(bool, "probe-var", "Persist the claim-0013 probe dump as DipshitP* NVRAM variables (diagnostic; default off — the serial log carries the probe records, and the persist starves the variable store)") orelse false;
    // Claim 1517: production T0SZ is 16 (correct start level for the built
    // L0-rooted hierarchy). `-Dt0sz25` selects the legacy 25 (W=39, walk
    // starts at level 1 — the claim-6460/7896 start-level mismatch that
    // made every fresh post-switch walk fault on VZ) for class-D A/B
    // regression. ONLY T0SZ changes: same tables, same TTBR0 root, same
    // MAIR/attributes/blanket/BAR window; the TLBI at the switch is
    // unconditional production behavior (claim 1517). Default off: default
    // builds are the production T0SZ=16 + TLBI kernel.
    const t0sz25 = b.option(bool, "t0sz25", "Diagnostic: install_identity_map programs T0SZ=25 (legacy start level, W=39 — the claim-6460/7896 start-level mismatch) instead of production 16 (claim 1517; default off)") orelse false;
    // Claim 7896: `-Dwalk-probe` runs a post-switch cold-address probe
    // battery, each probe bracketed by an NVRAM marker, to test whether the
    // installed tables resolve under the programmed T0SZ and to NAME the
    // first address whose walk (or MMIO read) does not return. Runs after
    // install_identity_map (which now always ends with the full TLBI,
    // claim 1517) before the claim-0020 phase-C experiment. Default off: the
    // module is linker-eliminated from default builds (byte-identical).
    const walk_probe = b.option(bool, "walk-probe", "Diagnostic: post-switch walk-validity probe battery with per-probe NVRAM markers (claim 7896; default off)") orelse false;
    const kernel_options = b.addOptions();
    kernel_options.addOption(bool, "nvram_console", nvram_console);
    kernel_options.addOption(bool, "probe_var", probe_var);
    kernel_options.addOption(bool, "preexit_tx", preexit_tx);
    kernel_options.addOption(bool, "tx_diag", tx_diag);
    kernel_options.addOption(bool, "tx_transition_a", tx_transition_a);
    kernel_options.addOption(bool, "tx_transition_b", tx_transition_b);
    kernel_options.addOption(bool, "tx_transition_c", tx_transition_c);
    kernel_options.addOption(bool, "tx_transition_d", tx_transition_d);
    kernel_options.addOption(bool, "fw_mmu_capture", fw_mmu_capture);
    kernel_options.addOption(bool, "t0sz25", t0sz25);
    kernel_options.addOption(bool, "walk_probe", walk_probe);
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
    const kernel_step = b.step("kernel", "Extract the flat kernel image (zig-out/bin/KERNEL.BIN) from the freestanding ELF (class A tooling, no VM)");
    const elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    elf2bin.addFileArg(kernel.getEmittedBin());
    const kernel_bin = elf2bin.addOutputFileArg("KERNEL.BIN");
    elf2bin.has_side_effects = true;
    elf2bin.stdio = .inherit;
    kernel_step.dependOn(&elf2bin.step);
    const install_kernel = b.addInstallFileWithDir(kernel_bin, .bin, "KERNEL.BIN");
    b.getInstallStep().dependOn(&install_kernel.step);

    // ------------------------------------------------------------------
    // Guest: ESP user program (milestone-three card 6, claim 6783) — a
    // small freestanding AArch64 flat image (USER.BIN, same DSK1 format as
    // KERNEL.BIN) that the kernel's `exec` monitor command loads from the
    // ESP and enters at EL0. Built into the same freestanding target and
    // embedded on the ESP by the image builder.
    // ------------------------------------------------------------------
    const user = b.addExecutable(.{
        .name = "user-hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/main.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    user.linker_script = b.path("user/linker.ld");
    const user_step = b.step("user", "Build the ESP user program (zig-out/bin/USER.BIN; class A tooling, no VM)");
    const user_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    user_elf2bin.addFileArg(user.getEmittedBin());
    const user_bin = user_elf2bin.addOutputFileArg("USER.BIN");
    user_elf2bin.has_side_effects = true;
    user_elf2bin.stdio = .inherit;
    user_step.dependOn(&user_elf2bin.step);
    const install_user = b.addInstallFileWithDir(user_bin, .bin, "USER.BIN");
    b.getInstallStep().dependOn(&install_user.step);

    // ------------------------------------------------------------------
    // Guest: second ESP user program (milestone-four follow-on 2, claim
    // 4613) — the never-exiting COUNTER.BIN. Same freestanding target,
    // linker script, elf2bin conversion, and ESP embedding as USER.BIN;
    // the kernel's `exec COUNTER.BIN` monitor command loads it by name.
    // It loops forever writing a DISTINCT marker (sys_write + sys_yield
    // only, no sys_exit), so the live long-lived gate can tell the two
    // programs apart in the serial log while one occupies its pool slot
    // permanently.
    // ------------------------------------------------------------------
    const counter = b.addExecutable(.{
        .name = "user-counter",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/counter.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    counter.linker_script = b.path("user/linker.ld");
    const counter_step = b.step("counter", "Build the second ESP user program (zig-out/bin/COUNTER.BIN; class A tooling, no VM)");
    const counter_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    counter_elf2bin.addFileArg(counter.getEmittedBin());
    const counter_bin = counter_elf2bin.addOutputFileArg("COUNTER.BIN");
    counter_elf2bin.has_side_effects = true;
    counter_elf2bin.stdio = .inherit;
    counter_step.dependOn(&counter_elf2bin.step);
    const install_counter = b.addInstallFileWithDir(counter_bin, .bin, "COUNTER.BIN");
    b.getInstallStep().dependOn(&install_counter.step);

    // ------------------------------------------------------------------
    // Guest: third ESP user program (milestone-four follow-on 3, card
    // 3f — claim 5965) — the IPC peer PEER.BIN. Same freestanding target,
    // linker script, elf2bin conversion, and ESP embedding as USER.BIN /
    // COUNTER.BIN; the kernel's `exec PEER.BIN` monitor command loads it
    // by name. It never exits: it recv-loops through sys_ipc_recv (slot
    // 6) and echoes each received message verbatim ("peer: got N"), so
    // the live IPC gate can show COUNTER.BIN's sends and PEER.BIN's
    // echoes interleaving across the whole serial log — the strongest
    // proof of two live processes communicating.
    // ------------------------------------------------------------------
    const peer = b.addExecutable(.{
        .name = "user-peer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/peer.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    peer.linker_script = b.path("user/linker.ld");
    const peer_step = b.step("peer", "Build the third ESP user program (zig-out/bin/PEER.BIN; class A tooling, no VM)");
    const peer_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    peer_elf2bin.addFileArg(peer.getEmittedBin());
    const peer_bin = peer_elf2bin.addOutputFileArg("PEER.BIN");
    peer_elf2bin.has_side_effects = true;
    peer_elf2bin.stdio = .inherit;
    peer_step.dependOn(&peer_elf2bin.step);
    const install_peer = b.addInstallFileWithDir(peer_bin, .bin, "PEER.BIN");
    b.getInstallStep().dependOn(&install_peer.step);

    // ------------------------------------------------------------------
    // Guest: fourth ESP user program (milestone-four follow-on 4, card
    // 4c — claim 9946) — the short third program STATUS43.BIN. Same
    // freestanding target, linker script, elf2bin conversion, and ESP
    // embedding as USER.BIN / COUNTER.BIN / PEER.BIN; the kernel's
    // `exec STATUS43.BIN` monitor command loads it by name. It prints its
    // alive marker, sleeps `sleep_ticks` scheduler ticks (slot 4) so the
    // observer deterministically blocks on it, then exits with status 43
    // (slot 3) — the target in the exit-status-propagation live gate.
    // ------------------------------------------------------------------
    const status43 = b.addExecutable(.{
        .name = "user-status43",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/status43.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    status43.linker_script = b.path("user/linker.ld");
    const status43_step = b.step("status43", "Build the fourth ESP user program (zig-out/bin/STATUS43.BIN; class A tooling, no VM)");
    const status43_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    status43_elf2bin.addFileArg(status43.getEmittedBin());
    const status43_bin = status43_elf2bin.addOutputFileArg("STATUS43.BIN");
    status43_elf2bin.has_side_effects = true;
    status43_elf2bin.stdio = .inherit;
    status43_step.dependOn(&status43_elf2bin.step);
    const install_status43 = b.addInstallFileWithDir(status43_bin, .bin, "STATUS43.BIN");
    b.getInstallStep().dependOn(&install_status43.step);

    // ------------------------------------------------------------------
    // Guest: fifth ESP user program (milestone five, card N6 — claim
    // 1384) — the UDP syscall proof UDP.BIN. Same freestanding target,
    // linker script, elf2bin conversion, and ESP embedding as USER.BIN /
    // COUNTER.BIN / PEER.BIN / STATUS43.BIN; the kernel's `exec UDP.BIN`
    // monitor command loads it by name. It binds port 7000 through the
    // new sys_udp_listen (slot 9), loopback-sends and round-trips to the
    // host through sys_udp_send (slot 10) + sys_udp_recv (slot 11),
    // prints its markers, and exits with status 17 — the live gate's
    // first network-syscall proof from EL0.
    // ------------------------------------------------------------------
    const udp = b.addExecutable(.{
        .name = "user-udp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/udp.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    udp.linker_script = b.path("user/linker.ld");
    const udp_step = b.step("udp", "Build the fifth ESP user program (zig-out/bin/UDP.BIN; class A tooling, no VM)");
    const udp_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    udp_elf2bin.addFileArg(udp.getEmittedBin());
    const udp_bin = udp_elf2bin.addOutputFileArg("UDP.BIN");
    udp_elf2bin.has_side_effects = true;
    udp_elf2bin.stdio = .inherit;
    udp_step.dependOn(&udp_elf2bin.step);
    const install_udp = b.addInstallFileWithDir(udp_bin, .bin, "UDP.BIN");
    b.getInstallStep().dependOn(&install_udp.step);

    // ------------------------------------------------------------------
    // Guest: sixth ESP user program (milestone six, card G6 — claim 0487) —
    // the draw/window syscall proof WIN.BIN. Same freestanding target,
    // linker script, elf2bin conversion, and ESP embedding as the other
    // user programs; the kernel's `exec WIN.BIN` monitor command loads it
    // by name. It opens a user window through sys_win_open (slot 12),
    // fills it through sys_win_fill (slot 13), presents it through
    // sys_win_present (slot 14), and exits 87 — the first EL0 graphics
    // proof.
    // ------------------------------------------------------------------
    const win = b.addExecutable(.{
        .name = "user-win",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/win.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    win.linker_script = b.path("user/linker.ld");
    const win_step = b.step("win", "Build the sixth ESP user program (zig-out/bin/WIN.BIN; class A tooling, no VM)");
    const win_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    win_elf2bin.addFileArg(win.getEmittedBin());
    const win_bin = win_elf2bin.addOutputFileArg("WIN.BIN");
    win_elf2bin.has_side_effects = true;
    win_elf2bin.stdio = .inherit;
    win_step.dependOn(&win_elf2bin.step);
    const install_win = b.addInstallFileWithDir(win_bin, .bin, "WIN.BIN");
    b.getInstallStep().dependOn(&install_win.step);

    // ------------------------------------------------------------------
    // Guest: seventh ESP user program (milestone six, card G6 teardown
    // follow-on — claim 0487) — the draw/window RELEASE proof WINCLOSE.BIN.
    // Same freestanding target, linker script, elf2bin conversion, and ESP
    // embedding as the other user programs; the kernel's
    // `exec WINCLOSE.BIN` monitor command loads it by name. It opens a user
    // window through sys_win_open (slot 12), fills it (slot 13), presents
    // it (slot 14), then CLOSES it through sys_win_close (slot 15) and
    // exits 88 — the EL0 release proof (the window does not persist; the
    // freed id is re-openable).
    // ------------------------------------------------------------------
    const winclose = b.addExecutable(.{
        .name = "user-winclose",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/winclose.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    winclose.linker_script = b.path("user/linker.ld");
    const winclose_step = b.step("winclose", "Build the seventh ESP user program (zig-out/bin/WINCLOSE.BIN; class A tooling, no VM)");
    const winclose_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    winclose_elf2bin.addFileArg(winclose.getEmittedBin());
    const winclose_bin = winclose_elf2bin.addOutputFileArg("WINCLOSE.BIN");
    winclose_elf2bin.has_side_effects = true;
    winclose_elf2bin.stdio = .inherit;
    winclose_step.dependOn(&winclose_elf2bin.step);
    const install_winclose = b.addInstallFileWithDir(winclose_bin, .bin, "WINCLOSE.BIN");
    b.getInstallStep().dependOn(&install_winclose.step);

    // ------------------------------------------------------------------
    // Guest: eighth ESP user program (milestone six, card G6 per-process-
    // ownership follow-on — claim 0487) — the PERSISTENT window proof
    // WINLOOP.BIN. Same freestanding target, linker script, elf2bin
    // conversion, and ESP embedding as the other user programs; the kernel's
    // `exec WINLOOP.BIN` monitor command loads it by name. It opens a user
    // window (slot 12), fills it (slot 13), presents it (slot 14), then
    // yield-loops FOREVER (slot 2) so the window stays on the scanout for
    // the live gate's decoded-capture phase (WIN.BIN exits and its window
    // auto-closes before a capture can see it).
    // ------------------------------------------------------------------
    const winloop = b.addExecutable(.{
        .name = "user-winloop",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/winloop.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    winloop.linker_script = b.path("user/linker.ld");
    const winloop_step = b.step("winloop", "Build the eighth ESP user program (zig-out/bin/WINLOOP.BIN; class A tooling, no VM)");
    const winloop_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    winloop_elf2bin.addFileArg(winloop.getEmittedBin());
    const winloop_bin = winloop_elf2bin.addOutputFileArg("WINLOOP.BIN");
    winloop_elf2bin.has_side_effects = true;
    winloop_elf2bin.stdio = .inherit;
    winloop_step.dependOn(&winloop_elf2bin.step);
    const install_winloop = b.addInstallFileWithDir(winloop_bin, .bin, "WINLOOP.BIN");
    b.getInstallStep().dependOn(&install_winloop.step);

    // ------------------------------------------------------------------
    // Guest: ninth ESP user program (milestone six, card G6 move/raise
    // follow-on — claim 0487) — the MOVE/RESTACK proof WINMOVE.BIN. Same
    // freestanding target, linker script, elf2bin conversion, and ESP
    // embedding as the other user programs; the kernel's
    // `exec WINMOVE.BIN` monitor command loads it by name. It opens a user
    // window (slot 12), fills it (slot 13), presents it (slot 14), moves it
    // twice (slot 16 — the second move clamps to the scanout corner) and
    // raises it (slot 17), then yield-loops FOREVER (slot 2) so the moved
    // window stays on the scanout for the live gate's decoded-capture
    // phase (the window's own colors at the NEW position).
    // ------------------------------------------------------------------
    const winmove = b.addExecutable(.{
        .name = "user-winmove",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/winmove.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    winmove.linker_script = b.path("user/linker.ld");
    const winmove_step = b.step("winmove", "Build the ninth ESP user program (zig-out/bin/WINMOVE.BIN; class A tooling, no VM)");
    const winmove_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    winmove_elf2bin.addFileArg(winmove.getEmittedBin());
    const winmove_bin = winmove_elf2bin.addOutputFileArg("WINMOVE.BIN");
    winmove_elf2bin.has_side_effects = true;
    winmove_elf2bin.stdio = .inherit;
    winmove_step.dependOn(&winmove_elf2bin.step);
    const install_winmove = b.addInstallFileWithDir(winmove_bin, .bin, "WINMOVE.BIN");
    b.getInstallStep().dependOn(&install_winmove.step);

    // ------------------------------------------------------------------
    // Guest: tenth ESP user program (milestone nine, card E6 capstone gate —
    // claim 9328) — the interactive event user application KEYTEST.BIN.
    // Opens a window, waits for application events via sys_wait_event
    // (slot 22), updates window contents in response to keyboard and pointer
    // events, and exits with status 99.
    // ------------------------------------------------------------------
    const keytest = b.addExecutable(.{
        .name = "user-keytest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/keytest.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    keytest.linker_script = b.path("user/linker.ld");
    const keytest_step = b.step("keytest", "Build the tenth ESP user program (zig-out/bin/KEYTEST.BIN; class A tooling, no VM)");
    const keytest_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    keytest_elf2bin.addFileArg(keytest.getEmittedBin());
    const keytest_bin = keytest_elf2bin.addOutputFileArg("KEYTEST.BIN");
    keytest_elf2bin.has_side_effects = true;
    keytest_elf2bin.stdio = .inherit;
    keytest_step.dependOn(&keytest_elf2bin.step);
    const install_keytest = b.addInstallFileWithDir(keytest_bin, .bin, "KEYTEST.BIN");
    b.getInstallStep().dependOn(&install_keytest.step);

    // ------------------------------------------------------------------
    // Guest: eleventh ESP user program (milestone ten, card F4 — claim 0510)
    // SAVETEXT.BIN. Writes data to /data/hello.txt via file syscalls.
    // ------------------------------------------------------------------
    const savetext = b.addExecutable(.{
        .name = "user-savetext",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/savetext.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    savetext.linker_script = b.path("user/linker.ld");
    const savetext_step = b.step("savetext", "Build the eleventh ESP user program (zig-out/bin/SAVETEXT.BIN)");
    const savetext_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    savetext_elf2bin.addFileArg(savetext.getEmittedBin());
    const savetext_bin = savetext_elf2bin.addOutputFileArg("SAVETEXT.BIN");
    savetext_elf2bin.has_side_effects = true;
    savetext_elf2bin.stdio = .inherit;
    savetext_step.dependOn(&savetext_elf2bin.step);
    const install_savetext = b.addInstallFileWithDir(savetext_bin, .bin, "SAVETEXT.BIN");
    b.getInstallStep().dependOn(&install_savetext.step);

    // ------------------------------------------------------------------
    // Guest: twelfth ESP user program (milestone ten, card F4 — claim 0510)
    // TYPE.BIN. Reads data from /data/hello.txt via file syscalls.
    // ------------------------------------------------------------------
    const type_prog = b.addExecutable(.{
        .name = "user-type",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/type.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    type_prog.linker_script = b.path("user/linker.ld");
    const type_step = b.step("type", "Build the twelfth ESP user program (zig-out/bin/TYPE.BIN)");
    const type_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    type_elf2bin.addFileArg(type_prog.getEmittedBin());
    const type_bin = type_elf2bin.addOutputFileArg("TYPE.BIN");
    type_elf2bin.has_side_effects = true;
    type_elf2bin.stdio = .inherit;
    type_step.dependOn(&type_elf2bin.step);
    const install_type = b.addInstallFileWithDir(type_bin, .bin, "TYPE.BIN");
    b.getInstallStep().dependOn(&install_type.step);

    // ------------------------------------------------------------------
    // Guest: thirteenth ESP user program (milestone ten, card F4 — claim 0510)
    // DIR.BIN. Enumerates directory entries via sys_dir_list.
    // ------------------------------------------------------------------
    const dir_prog = b.addExecutable(.{
        .name = "user-dir",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/dir.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    dir_prog.linker_script = b.path("user/linker.ld");
    const dir_step = b.step("dir", "Build the thirteenth ESP user program (zig-out/bin/DIR.BIN)");
    const dir_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    dir_elf2bin.addFileArg(dir_prog.getEmittedBin());
    const dir_bin = dir_elf2bin.addOutputFileArg("DIR.BIN");
    dir_elf2bin.has_side_effects = true;
    dir_elf2bin.stdio = .inherit;
    dir_step.dependOn(&dir_elf2bin.step);
    const install_dir = b.addInstallFileWithDir(dir_bin, .bin, "DIR.BIN");
    b.getInstallStep().dependOn(&install_dir.step);

    // ------------------------------------------------------------------
    // Guest: fourteenth ESP user program (milestone eleven, card A2 — claim 8401)
    // CALC.BIN. Interactive graphical calculator with 64-bit engine.
    // ------------------------------------------------------------------
    const calc_prog = b.addExecutable(.{
        .name = "user-calc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/calc.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    calc_prog.linker_script = b.path("user/linker.ld");
    const calc_step = b.step("calc", "Build the fourteenth ESP user program (zig-out/bin/CALC.BIN)");
    const calc_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    calc_elf2bin.addFileArg(calc_prog.getEmittedBin());
    const calc_bin = calc_elf2bin.addOutputFileArg("CALC.BIN");
    calc_elf2bin.has_side_effects = true;
    calc_elf2bin.stdio = .inherit;
    calc_step.dependOn(&calc_elf2bin.step);
    const install_calc = b.addInstallFileWithDir(calc_bin, .bin, "CALC.BIN");
    b.getInstallStep().dependOn(&install_calc.step);

    // ------------------------------------------------------------------
    // Guest: fifteenth ESP user program (milestone eleven, card A3 — claim 3234)
    // NOTEPAD.BIN. Interactive graphical text editor with /data persistence.
    // ------------------------------------------------------------------
    const notepad_prog = b.addExecutable(.{
        .name = "user-notepad",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/notepad.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    notepad_prog.linker_script = b.path("user/linker.ld");
    const notepad_step = b.step("notepad", "Build the fifteenth ESP user program (zig-out/bin/NOTEPAD.BIN)");
    const notepad_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    notepad_elf2bin.addFileArg(notepad_prog.getEmittedBin());
    const notepad_bin = notepad_elf2bin.addOutputFileArg("NOTEPAD.BIN");
    notepad_elf2bin.has_side_effects = true;
    notepad_elf2bin.stdio = .inherit;
    notepad_step.dependOn(&notepad_elf2bin.step);
    const install_notepad = b.addInstallFileWithDir(notepad_bin, .bin, "NOTEPAD.BIN");
    b.getInstallStep().dependOn(&install_notepad.step);

    // ------------------------------------------------------------------
    // Guest: sixteenth ESP user program (milestone eleven, card A4 — claim 0680)
    // TOP.BIN. Graphical task manager & process monitor.
    // ------------------------------------------------------------------
    const top_prog = b.addExecutable(.{
        .name = "user-top",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/top.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    top_prog.linker_script = b.path("user/linker.ld");
    const top_step = b.step("top", "Build the sixteenth ESP user program (zig-out/bin/TOP.BIN)");
    const top_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    top_elf2bin.addFileArg(top_prog.getEmittedBin());
    const top_bin = top_elf2bin.addOutputFileArg("TOP.BIN");
    top_elf2bin.has_side_effects = true;
    top_elf2bin.stdio = .inherit;
    top_step.dependOn(&top_elf2bin.step);
    const install_top = b.addInstallFileWithDir(top_bin, .bin, "TOP.BIN");
    b.getInstallStep().dependOn(&install_top.step);

    // ------------------------------------------------------------------
    // Guest: seventeenth ESP user program (milestone eleven, card A5 — claim 2427)
    // DESKTOP.BIN. Desktop launcher & environment panel.
    // ------------------------------------------------------------------
    const desktop_prog = b.addExecutable(.{
        .name = "user-desktop",
        .root_module = b.createModule(.{
            .root_source_file = b.path("user/src/desktop.zig"),
            .target = kernel_target,
            .optimize = .ReleaseSmall,
        }),
    });
    desktop_prog.linker_script = b.path("user/linker.ld");
    const desktop_step = b.step("desktop", "Build the seventeenth ESP user program (zig-out/bin/DESKTOP.BIN)");
    const desktop_elf2bin = b.addSystemCommand(&.{ "python3", "tools/elf2bin.py" });
    desktop_elf2bin.addFileArg(desktop_prog.getEmittedBin());
    const desktop_bin = desktop_elf2bin.addOutputFileArg("DESKTOP.BIN");
    desktop_elf2bin.has_side_effects = true;
    desktop_elf2bin.stdio = .inherit;
    desktop_step.dependOn(&desktop_elf2bin.step);
    const install_desktop = b.addInstallFileWithDir(desktop_bin, .bin, "DESKTOP.BIN");
    b.getInstallStep().dependOn(&install_desktop.step);

    // ------------------------------------------------------------------
    // Top-level steps. System-command steps are marked as having side
    // effects (and inherit stdio) so they always execute instead of being
    // skipped by the build cache. (No QEMU path: this project targets Apple
    // Virtualization.framework only.)
    // ------------------------------------------------------------------
    const image_step = b.step("image", "Create the FAT32+GPT boot disk image at artifacts/disk.img (class A gate)");
    const image = b.addSystemCommand(&.{ "bash", "image/make-image.sh" });
    image.addFileArg(efi.getEmittedBin());
    image.addArg("artifacts/disk.img");
    image.addFileArg(kernel_bin); // make-image.sh: [EFI_BIN] [IMAGE] [KERNEL_BIN]
    image.addFileArg(user_bin); // ... [USER_BIN] (claim 6783: ESP user program)
    image.addFileArg(counter_bin); // ... [COUNTER_BIN] (claim 4613: second, never-exiting user program)
    image.addFileArg(peer_bin); // ... [PEER.BIN] (claim 5965: third user program, the IPC peer)
    image.addFileArg(status43_bin); // ... [STATUS43.BIN] (claim 9946: fourth user program, the wait gate's short target)
    image.addFileArg(udp_bin); // ... [UDP.BIN] (claim 1384: fifth user program, the UDP-syscall proof)
    image.addFileArg(win_bin); // ... [WIN.BIN] (claim 0487: sixth user program, the draw/window-syscall proof)
    image.addFileArg(winclose_bin); // ... [WINCLOSE.BIN] (claim 0487 follow-on: seventh user program, the draw/window-syscall RELEASE proof)
    image.addFileArg(winloop_bin); // ... [WINLOOP.BIN] (claim 0487 follow-on: eighth user program, the PERSISTENT window proof)
    image.addFileArg(winmove_bin); // ... [WINMOVE.BIN] (claim 0487 follow-on: ninth user program, the MOVE/RESTACK proof)
    image.addFileArg(keytest_bin); // ... [KEYTEST.BIN] (claim 9328: tenth user program, interactive event app)
    image.addFileArg(savetext_bin); // ... [SAVETEXT.BIN] (claim 0510: eleventh user program, write to /data)
    image.addFileArg(type_bin); // ... [TYPE.BIN] (claim 0510: twelfth user program, read from /data)
    image.addFileArg(dir_bin); // ... [DIR.BIN] (claim 0510: thirteenth user program, directory listing)
    image.addFileArg(calc_bin); // ... [CALC.BIN] (claim 8401: fourteenth user program, GUI calculator)
    image.addFileArg(notepad_bin); // ... [NOTEPAD.BIN] (claim 3234: fifteenth user program, GUI text editor)
    image.addFileArg(top_bin); // ... [TOP.BIN] (claim 0680: sixteenth user program, GUI task manager)
    image.addFileArg(desktop_bin); // ... [DESKTOP.BIN] (claim 2427: seventeenth user program, GUI desktop launcher)
    image.has_side_effects = true;
    image.stdio = .inherit;
    image_step.dependOn(&image.step);

    const inspect_step = b.step("inspect", "Inspect the EFI binary and the disk image (class A gate)");
    const inspect = b.addSystemCommand(&.{ "bash", "tools/inspect.sh" });
    inspect.addFileArg(efi.getEmittedBin());
    inspect.addArg("artifacts/disk.img");
    inspect.has_side_effects = true;
    inspect.stdio = .inherit;
    inspect_step.dependOn(&inspect.step);

    const failure_step = b.step("bad-handoff", "Build a deliberately corrupted handoff image for the pre-exit failure-path test (class A tooling; feeds the class B bad-handoff gate)");
    const failure_image = b.addSystemCommand(&.{ "bash", "image/make-image.sh" });
    failure_image.addFileArg(efi.getEmittedBin());
    failure_image.addArg("artifacts/bad-handoff.img");
    failure_image.addFileArg(kernel_bin);
    failure_image.addFileArg(user_bin); // USER.BIN rides the same image builder
    failure_image.addFileArg(counter_bin); // COUNTER.BIN too (claim 4613)
    failure_image.addFileArg(peer_bin); // PEER.BIN too (claim 5965)
    failure_image.addFileArg(status43_bin); // STATUS43.BIN too (claim 9946)
    failure_image.addFileArg(udp_bin); // UDP.BIN too (claim 1384)
    failure_image.addFileArg(win_bin); // WIN.BIN too (claim 0487)
    failure_image.addFileArg(winclose_bin); // WINCLOSE.BIN too (claim 0487 follow-on)
    failure_image.addFileArg(winloop_bin); // WINLOOP.BIN too (claim 0487 follow-on)
    failure_image.addFileArg(winmove_bin); // WINMOVE.BIN too (claim 0487 follow-on)
    failure_image.has_side_effects = true;
    failure_image.stdio = .inherit;
    failure_step.dependOn(&failure_image.step);

    const run_step = b.step("run", "Boot the disk image with the Swift Virtualization.framework runner (class B — live serial takeover gate, claim 0002; Apple silicon only; PASSING since claim 1517)");
    const run = b.addSystemCommand(&.{ "bash", "-c", run_vm_command });
    run.step.dependOn(&image.step);
    run.has_side_effects = true;
    run.stdio = .inherit;
    run_step.dependOn(&run.step);

    // macOS 27 spike (capability-audit step 3): boot with one custom virtio
    // device attached (--custom-virtio) so the guest's PCI discovery can
    // observe it on a real VZ boot. The runner prints the host-side
    // CUSTOM-VIRTIO evidence to stdout; guest-side discovery evidence still
    // needs a kernel PCI dump (the audit's next slice).
    const spike_virtio_step = b.step("spike-virtio", "Boot the disk image with the custom virtio spike device attached (macOS 27 capability-audit step 3; class B; Apple silicon only)");
    const spike_virtio = b.addSystemCommand(&.{ "bash", "-c", spike_virtio_vm_command });
    spike_virtio.step.dependOn(&image.step);
    spike_virtio.has_side_effects = true;
    spike_virtio.stdio = .inherit;
    spike_virtio_step.dependOn(&spike_virtio.step);

    const console_step = b.step("console", "Boot the disk image and open an interactive host serial console (class C — interactive/manual hardware gate; Apple silicon only)");
    const console = b.addSystemCommand(&.{ "bash", "-c", console_vm_command });
    console.step.dependOn(&image.step);
    console.has_side_effects = true;
    console.stdio = .inherit;
    console_step.dependOn(&console.step);

    const context_step = b.step("context", "Regenerate artifacts/context.md (deterministic project snapshot; class A gate)");
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
    const marker_step = b.step("marker", "Boot the disk image and save the host-side kernel marker dump (ADR 0004 D4 fallback; class B mechanism behind tools/verify-marker.sh; Apple silicon only)");
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
    const test_console_step = b.step("test-console", "Run the automated 'dipshit>' transcript test (M1.5 march step 19; class A — mock console, no VM)");
    const test_console = b.addSystemCommand(&.{ "bash", "tools/verify-transcript.sh" });
    test_console.has_side_effects = true;
    test_console.stdio = .inherit;
    test_console_step.dependOn(&test_console.step);

    // Claim 0015: NVRAM console channel. `zig build nvram-console` rebuilds
    // the image with `-Dnvram-console=true` and boots it, reconstructing
    // the post-exit console stream from the EFI variable store. The hard
    // gate with substring assertions lives in tools/verify-nvram-console.sh
    // (`just verify-nvram-console`). Apple silicon only (VZ VM).
    const nvram_console_step = b.step("nvram-console", "Boot the -Dnvram-console=true image and reconstruct the post-exit NVRAM console stream (class B mechanism behind tools/verify-nvram-console.sh; claim 0015; Apple silicon only)");
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
    const preexit_tx_step = b.step("preexit-tx", "Boot the -Dpreexit-tx=true image and check whether the pre-exit virtio TX reaches vm-serial.log (class D diagnostic — claim 0017; Apple silicon only)");
    const preexit_tx_run = b.addSystemCommand(&.{ "bash", "-c", preexit_tx_vm_command });
    preexit_tx_run.has_side_effects = true;
    preexit_tx_run.stdio = .inherit;
    preexit_tx_step.dependOn(&preexit_tx_run.step);

    // Claim 0018: post-exit virtio TX bisect. `zig build tx-diag` boots the
    // -Dtx-diag=true image once and saves the per-stage marker ladder; the
    // determinism gate (N identical boots, per-boot ladders + serial logs +
    // revision) lives in tools/verify-tx-diag.sh (`just verify-tx-diag`).
    // Apple silicon only (VZ VM).
    const tx_diag_step = b.step("tx-diag", "Boot the -Dtx-diag=true image and save the per-stage post-exit TX marker ladder (class D diagnostic — claim 0018; Apple silicon only)");
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

const spike_virtio_vm_command =
    \\set -e
    \\# -DSPIKE compiles the custom-virtio section (macOS 27 SDK types); the
    \\# base class-A build omits it so the CI toolchain (macOS 26 SDK) parses.
    \\swift build --package-path host/vm-runner --configuration release -Xswiftc -DSPIKE
    \\# Recent macOS requires the com.apple.security.virtualization entitlement;
    \\# ad-hoc codesign the binary with it before running.
    \\# Claims 0828/4374/9492/9737/4837: the guest's custom-virtio driver
    \\# (DID 0x1082) probes, negotiates features, arms both queues, runs the
    \\# transport experiment (concurrent in-flight exchanges + ring recycling,
    \\# the 12,340-byte multi-descriptor payload, the queue-1 log transport,
    \\# the negotiated kick/layout behavior), and reports the used-ring IRQ as
    \\# the "cvspike:" block in the serial log. Script mode forwards `pci` + an
    \\# echo once the terminal state appears and exits 0 iff the scripted echo
    \\# is observed. The host-side CUSTOM-VIRTIO lines (DRIVER_OK,
    \\# notifications, dequeued payloads, log lines, returnToQueue) print to
    \\# stdout.
    \\codesign --force --sign - --entitlements host/vm-runner/entitlements.plist host/vm-runner/.build/release/VMRunner
    \\echo 'pci' > artifacts/cvspike-script.txt
    \\echo 'echo cvspike-shell-ok' >> artifacts/cvspike-script.txt
    \\# --script-expect waits for the scripted echo output (which appears
    \\# only after the script is forwarded) — expecting the cvspike IRQ line
    \\# would exit the runner before pci/echo are sent (claim 0828).
    \\host/vm-runner/.build/release/VMRunner artifacts/disk.img artifacts/vm-spike.log --custom-virtio --script artifacts/cvspike-script.txt --script-expect "cvspike-shell-ok" --timeout 60
    \\    echo
    \\    echo "=== spike serial log ==="
    \\    cat artifacts/vm-spike.log 2>/dev/null || echo "(no serial output)"
    \\    echo
    \\    echo "=== spike guest evidence (vm-spike.log) ==="
    \\    grep -F -- "cvspike: irq=" artifacts/vm-spike.log || { echo "cvspike IRQ report missing from vm-spike.log"; exit 1; }
    \\    grep -F -- 'cvspike: init ok' artifacts/vm-spike.log || { echo "cvspike init did not arm the transport"; exit 1; }
    \\    grep -F -- 'cvspike: feat=0x' artifacts/vm-spike.log || { echo "cvspike feature report missing from vm-spike.log"; exit 1; }
    \\    grep -F -- 'cvspike: q0 heads=0x0000000000000000,0x0000000000000002,0x0000000000000004,0x0000000000000006 recycle=1' artifacts/vm-spike.log || { echo "cvspike ring-allocator recycle proof missing from vm-spike.log"; exit 1; }
    \\    grep -F -- 'cvspike: q0 big n=0x3034 echo=ok' artifacts/vm-spike.log || { echo "cvspike multi-descriptor payload echo missing from vm-spike.log"; exit 1; }
    \\    grep -F -- 'cvspike: q0 ok=1' artifacts/vm-spike.log || { echo "cvspike queue-0 exchanges did not all pass (q0 ok=1 missing from vm-spike.log)"; exit 1; }
    \\    grep -F -- 'cvspike: q1 ok=3' artifacts/vm-spike.log || { echo "cvspike log transport did not echo all lines (q1 ok=3 missing from vm-spike.log)"; exit 1; }
    \\    echo "spike-virtio: custom-virtio transport observed (queue transport + used-ring IRQ, ring allocator + multi-queue, multi-descriptor payloads, feature negotiation, guest log transport — host evidence in the runner stdout above)"
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

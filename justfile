# DipshitOS command aliases.
# Requires: just (https://github.com/casey/just)
# All recipes simply delegate to the Zig build system.
#
# Verification classes (canonical inventory: docs/gate-inventory.md):
#   A — portable / build CI. Deterministic, no Apple silicon, no VZ VM.
#       This is exactly what GitHub CI proves. `just verify-portable` runs
#       the same set locally (`just verify` is a legacy alias).
#   B — Apple-silicon Virtualization.framework hardware gate. Boots a real
#       VZ VM on Apple silicon. CI does NOT run these and cannot prove them;
#       run `just verify-vz` on a development host.
#   C — interactive / manual hardware gate. Needs a human at the keyboard.
#   D — diagnostic experiment. NOT an acceptance gate.

# Legacy alias for the full portable/build gate set (class A)
alias verify := verify-portable

# Run the full portable/build gate set (class A; mirrors CI). Does NOT run
# the Apple-silicon VZ hardware gates (class B) — that is `just verify-vz`.
verify-portable:
    zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig
    bash tools/verify-unit-tests.sh
    zig build test-console
    zig build
    zig build image
    zig build inspect
    swift build --package-path host/vm-runner
    zig build context
    bash tools/verify-coordination.sh
    bash tools/status/test-coordination.sh
    bash tools/verify-mmu-debt.sh

# Run the Apple-silicon VZ hardware gates (class B): serial takeover
# (zig build run, claim 1517), bad-handoff, marker, NVRAM console,
# host-console PTY, the live-transcript RX gate (claim 6684), the
# live timer IRQ-delivery gate (claim 9187), the live tasks scheduler
# gate (claim 5275), the EL0/SVC gate (claim 8215), the numbered syscall
# gate (claim 3594), the fault-safe uaccess gate (claim 6120), the
# per-task address-space gate (claim 5804), and the live reboot/shutdown
# gate (claim 0527). Apple silicon only — each boots VZ VMs.
verify-vz:
    zig build run
    bash tools/verify-bad-handoff.sh
    bash tools/verify-marker.sh
    bash tools/verify-nvram-console.sh
    bash tools/verify-host-console.sh
    bash tools/verify-live-transcript.sh
    bash tools/verify-live-fs.sh
    bash tools/verify-live-timer.sh
    bash tools/verify-live-tasks.sh
    bash tools/verify-live-userspace.sh
    bash tools/verify-live-svc.sh
    bash tools/verify-live-uaccess.sh
    bash tools/verify-live-addrspaces.sh
    bash tools/verify-live-lifecycle.sh
    bash tools/verify-live-exec.sh
    bash tools/verify-live-sleep.sh
    bash tools/verify-live-reboot.sh

# Compile the AArch64 UEFI application and kernel image (class A — zig build)
build:
    zig build

# Run the M1.5 kernel monitor module unit tests (class A — zig test per module; skips modules not yet landed)
test:
    bash tools/verify-unit-tests.sh

# Run the automated dipshit> transcript test — mock console, no VM (class A; M1.5 march step 19)
test-console:
    zig build test-console

# Boot the VM and save the host-side NVRAM marker ladder (class B mechanism — ADR 0004 D4 fallback, `zig build marker`; Apple silicon only)
marker:
    zig build marker

# Verify the ADR 0004 D4 fixed-memory-marker fallback gate (class B — boots a VZ VM; Apple silicon only)
verify-marker:
    bash tools/verify-marker.sh

# Boot the -Dnvram-console=true image and reconstruct the post-exit NVRAM console stream (class B mechanism — zig build nvram-console; claim 0015; Apple silicon only)
nvram-console:
    zig build nvram-console

# Verify the claim-0015 NVRAM console gate (class B — post-exit console bytes via the NVRAM channel; boots a VZ VM; Apple silicon only)
verify-nvram-console:
    bash tools/verify-nvram-console.sh

# Verify the claim-0017 pre-exit virtio-pci TX diagnostic (class D — can the transport TX while Boot Services + firmware address space are still active? boots a VZ VM; Apple silicon only)
verify-preexit-tx:
    bash tools/verify-preexit-tx.sh

# Boot the -Dpreexit-tx=true image and report whether the pre-exit virtio TX reached vm-serial.log (class D mechanism — zig build preexit-tx; claim 0017; Apple silicon only)
preexit-tx:
    zig build preexit-tx

# Verify the claim-0018 post-exit virtio TX bisect gate (class D — N identical VZ boots, per-stage markers, determinism report; Apple silicon only)
verify-tx-diag:
    bash tools/verify-tx-diag.sh

# Boot the -Dtx-diag=true image once and save the per-stage post-exit TX marker ladder (class D mechanism — zig build tx-diag; claim 0018; Apple silicon only)
tx-diag:
    zig build tx-diag

# Extract the flat kernel image zig-out/bin/KERNEL.BIN (class A tooling — zig build kernel; no VM)
kernel:
    zig build kernel

# Create the FAT32+GPT boot disk image (class A — zig build image)
image:
    zig build image

# Boot with the Swift Virtualization.framework runner (class B gate — the live serial takeover gate, claim 0002; PASSING since claim 1517; Apple silicon only)
run:
    zig build run

# Boot an interactive host serial console (class C — interactive/manual hardware gate; requires a human at the keyboard; Apple silicon only)
console:
    zig build console

# Inspect the EFI binary and disk image (class A — zig build inspect)
inspect:
    zig build inspect

# Regenerate artifacts/context.md (class A — zig build context)
context:
    zig build context

# Local Git-aware context engine — tools/ragshit (ragshit index/query/bundle/doctor ...)
ragshit *ARGS:
    python3 tools/ragshit/ragshit {{ARGS}}

# Verify the MMU takeover contract is intact (class A — ADR 0006 supersession + kernel T0SZ=16/TLBI comments; deterministic, no VM — claims 0022/1517)
verify-mmu-debt:
    bash tools/verify-mmu-debt.sh

# Verify the multiagent coordination surface (class A — claims/logs files + generated indexes)
verify-coordination:
    bash tools/verify-coordination.sh

# Test the coordination tooling itself (class A — escaped cells, deterministic claim IDs, structural validation)
test-coordination:
    bash tools/status/test-coordination.sh

# Regenerate the claim/log index tables from the files (developer tooling, not a gate — run after creating a claim or branch log)
refresh-indexes:
    bash tools/status/refresh-indexes.sh

# Verify the pre-exit failure path (class B — boots a VZ VM; Apple silicon only)
verify-bad-handoff:
    bash tools/verify-bad-handoff.sh

# Verify the live RX path + live dipshit> transcript (class B — boots a VZ VM; host scripted keystrokes reach the kernel end to end; claim 6684; Apple silicon only)
verify-live-transcript:
    bash tools/verify-live-transcript.sh

# Verify the live exception-vector gate (class B — boots a VZ VM; drives `fault`, asserts the [EXC] sync report + resume in vm-serial.log; claim 9746; Apple silicon only)
verify-live-exceptions:
    bash tools/verify-live-exceptions.sh

# Verify real timer IRQ delivery (class B — boots a VZ VM; drives `timer`, then requires five CNTP PPIs through the EL1 IRQ vector with irq=5/poll=0; claim 9187; Apple silicon only)
verify-live-timer:
    bash tools/verify-live-timer.sh

# Verify the live tick-driven task scheduler (class B — boots a VZ VM; proves the shell + worker both advance across real timer-tick context switches; claim 5275; Apple silicon only)
verify-live-tasks:
    bash tools/verify-live-tasks.sh

# Verify the user task lifecycle (class B — boots a VZ VM; spawn / exit / reap with explicit task states and the idle task; claim 6729; Apple silicon only)
verify-live-lifecycle:
    bash tools/verify-live-lifecycle.sh

# Verify the first real EL0 task and SVC boundary (class B — two sequenced SVC entries prove return to EL0; timer preemption returns to the EL1h shell; claim 8215)
verify-live-userspace:
    bash tools/verify-live-userspace.sh

# Verify the frozen syscall ABI and runtime dispatch table (class B — staged input waits for EL0 write/yield/exit, then asserts counters + a responsive shell; claim 3594)
verify-live-svc:
    bash tools/verify-live-svc.sh

# Verify the fault-safe uaccess layer (class B — EL0 observes EFAULT for a bad pointer and survives; the monitor command recovers a real data abort; claim 6120)
verify-live-uaccess:
    bash tools/verify-live-uaccess.sh

# Verify the live ESP file window (class B — boots VZ VMs; ls/cat from the pre-exit ESP snapshot + write persisted to EFI NVRAM and read back across a reboot; claim 3475, hard gate 5; Apple silicon only)
verify-live-fs:
    bash tools/verify-live-fs.sh

# Verify the live reboot/shutdown observation (class B — boots VZ VMs; a real EFI ResetSystem from a live dipshit> shell: reboot resets the machine, shutdown powers it off; claim 0527, hard gate 6; Apple silicon only)
verify-live-reboot:
    bash tools/verify-live-reboot.sh

# Verify the M1.5 host-side interactive serial plumbing (class B — boots VZ VMs; Apple silicon only)
verify-host-console:
    bash tools/verify-host-console.sh

# Git-aware change-impact reviewer context (developer tooling — ragshit impact)
impact *ARGS:
    python3 tools/ragshit/ragshit impact {{ARGS}}

# Deterministic budgeted reviewer packet (ragshit review)
review *ARGS:
    python3 tools/ragshit/ragshit review {{ARGS}}

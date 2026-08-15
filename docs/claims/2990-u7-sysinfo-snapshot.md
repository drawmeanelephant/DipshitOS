# Claim: Milestone eight, card U7 — sysinfo support snapshot

- **Owner:** buffy (`agent/buffy/u7-sysinfo`)
- **Prompt / plan:** `docs/march-m8.md`
- **Scope:** `kernel/src/monitor.zig`, `kernel/src/shell.zig`, `tests/transcript-console.txt`, `docs/march-m8.md`, `docs/status.md`
- **Depends on:** `docs/claims/8938-hig-adr-0008.md`, `docs/claims/8323-u6-first-boot-experience.md`
- **Status:** ✅ done

## Notes

Implements the ADR 0008 D5 support snapshot: the canonical `sysinfo` monitor command printing a unified diagnostic report across all active kernel subsystems:

1. **System & Handoff**: OS kernel version and handoff ABI v2 validation.
2. **CPU & Timer**: Architecture `aarch64`, GICv3 PPI timer heartbeat and IRQ delivery counters.
3. **Memory & Pages**: Memory map descriptors and usable space; physical page pool total, free, excluded, and region count.
4. **Tasks & Processes**: Scheduler state, task pool occupancy, context switches, active processes count and capacity.
5. **Storage**: Active FAT32 partition (`esp`/`data`) and files count.
6. **Network**: Virtio-net status, MAC address, static IP address.
7. **Graphics & Windows**: Virtio-gpu status, Road Pops status, Driving Award window count and focused window ID.
8. **Input**: xHCI controller status, enumerated HID devices count, input event FIFO status.

Verified against `zig test kernel/src/monitor.zig`, `zig test kernel/src/shell.zig`, `tools/verify-transcript.sh`, `tools/verify-unit-tests.sh`, and `tools/verify-live-help.sh`.

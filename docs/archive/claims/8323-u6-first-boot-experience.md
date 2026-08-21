# Claim: Milestone eight, card U6 — first-boot experience (welcome, tour, about, motd)

- **Owner:** buffy (`agent/buffy/u6-first-boot`)
- **Prompt / plan:** `docs/march-m8.md`
- **Scope:** `kernel/src/monitor.zig`, `kernel/src/shell.zig`, `tests/transcript-console.txt`, `docs/march-m8.md`, `docs/status.md`
- **Depends on:** `docs/claims/8938-hig-adr-0008.md`
- **Status:** ✅ done

## Notes

Implements the ADR 0008 D5 first-boot experience surface:

1. **Refreshed `about` screen**: Replaces the historical M1.5 placeholder text with accurate architectural detail (freestanding AArch64 Zig, no libc, no POSIX, GICv3 timer, round-robin scheduler, per-task TTBR0 address spaces, EL0 processes + ADR 0007 syscalls, FAT32 on ESP/DATA, Virtio-Net DHCP/TCP/UDP, Driving Award window compositor + Road Pops, and Apple xHCI HID).
2. **Guided `welcome` (alias `tour`) command**: A friendly, informative interactive walkthrough for new users (discovery via `help`, system identity, processes & scheduler, storage partitions, window compositor, networking, and docs pointers).
3. **Boot MOTD status line**: A deterministic status line emitted during boot banner output (`motd: aarch64 el1 kernel live; scheduler, uaccess, fs, net, gfx, xhci armed.`).
4. **Verification**: Checked against `zig test kernel/src/monitor.zig`, `zig test kernel/src/shell.zig`, and the byte-deterministic transcript gate (`tools/verify-transcript.sh` / `zig build test-console`).

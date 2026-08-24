# Claim: run-isolated gates via DiskImageKit overlays

- **Owner:** ox-alpha (`agent/ox-alpha/run-isolated-gates`)
- **Status:** ✅ done 2026-08-24 — PR #529 merged (957e452); flipped from 🔄 independently by ox-alpha in worktree `t3code/c259b00a` (for claim 3141) and in worktree `t3code-732c1e83` (for claim 5069) so the ACTIVE-Touches gate stops holding its files; both flips recorded here and in their branch logs
- **Touches:** host/vm-runner/Sources/VMRunner/main.swift, tools/lib/gate-run.sh, tools/verify-live-net-tcp.sh, docs/gate-inventory.md, AGENTS.md
- **Depends on:** 4928 (worktrees), 2564 (tracked-only gate)
- **Heartbeat:** 2026-08-24

## Problem

Issue #523 item 2. Live gates share mutable state across concurrent runs:
`artifacts/disk.img` (attached read-write by every run), hardcoded
`artifacts/efi-vars.bin` (VMRunner main.swift L730–742 regardless of which
disk is passed), and fixed evidence paths (`artifacts/vm-serial.log`,
`/tmp/live-*-rc*.txt`). Two agents running gates concurrently clobber each
other's disks, NVRAM stores, and evidence.

## Fix

1. **VMRunner `--overlay-base <path>`** (macOS 27 DiskImageKit): open the
   named base image read-only, append a throwaway ASIF overlay layer in a
   temp dir, attach the stack via the new
   `VZDiskImageStorageDeviceAttachment(diskImage:cachingMode:synchronizationMode:)`.
   Every run boots a pristine system by construction; writes land in the
   overlay. API surface verified against the Xcode 27 SDK swiftinterfaces
   (DiskImageKit + Virtualization), not from session notes.
2. **VMRunner `--vars <path>`**: EFI variable store location becomes a flag
   (default `artifacts/efi-vars.bin`, back-compat).
3. **tools/lib/gate-run.sh**: sourced helper — `gate_begin NAME` makes a
   private RUN_DIR (mktemp -d) with per-run copies of disk+vars;
   `gate_finish` copies designated evidence back into artifacts/. Scripts
   migrate one at a time; this PR converts verify-live-net-tcp.sh as the
   template.

## Verification

- Class A: swift build; coordination suite.
- Class B (this host is macOS 27.0 / Xcode 27): converted gate passes;
  **two instances of the same gate run concurrently** with separate
  RUN_DIRs, both succeed, neither sees the other's serial log or writes
  (demonstrated, not assumed).

## Notes

Remaining ~100 verify-live scripts migrate mechanically in follow-ups;
the helper + converted template define the pattern. Overlay cleanup on
runner exit (temp dir removed unless DIPSHIT_KEEP_OVERLAY=1).

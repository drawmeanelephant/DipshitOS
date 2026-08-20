# Claim: Milestone 16 Card C2 — guard pages + per-segment permissions (wishlist 14)

- **Owner:** Muse Spark (`docs/site-current-state-m15`)
- **Prompt / plan:** `docs/march-m16.md`
- **Scope:** Milestone 16, Card C2 (Issue #191: guard pages below stack + around data, per-segment permissions beyond W^X, hostile-EL0-refused live proof)
- **Depends on:** C1 (data segment shape to guard)
- **Status:** 🔄 docs/site-current-state-m15

## Notes

Wishlist 14: richer virtual memory. C1 gave data at 0x402000 (1 page guard at 0x401000 between text@0x400000 and data). Stack at random 0x80000000+ has guard below (one page unmapped). Data is RW+PXN+UXN (writable but not executable), text is RO+PXN (executable, not writable). Hostile EL0 fault handling via new `exceptions.FaultDispatcher` + `scheduler.handle_el0_fault` (exit 139) so a guard-page touch faults, is reported as `[EXC]` and reaped, never parking the kernel. Linker-m16 updated to place data at 0x402000 (guard at 0x401000). Hostile proof program `GUARDTEST.BIN` (DSK2) touches guard at 0x401000 via volatile and should be reaped with 139. Live gate: `verify-live-m16-guards.sh` — hostile exec → fault → exit 139 → reaped, neighbor BIGTEST still green. Zero heap, default VM byte-identical.

Progress 2026-08-20: linker guard + fault dispatcher + scheduler handler implemented and BIGTEST still PASS (data at 0x402000, guard unmapped, BIGTEST's 8-page RW still works). Hostile program `user/src/guardtest.zig` drafted but not yet wired into `build.zig`/`image/make-image.sh`/`mkfat32.py`; gate script not yet created; live proof not yet run. Next: wire GUARDTEST.BIN (DSK2, linker-m16), add to image, write gate, run VZ sweep, then flip this claim to ✅.

Constraints: zero heap, default VM byte-identical, full verify-vz sweep at landing.

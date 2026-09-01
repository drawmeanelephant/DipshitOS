# Claim: WASM import contract audit — wire-format corrections (amends #778)

- **Owner:** buffy (`freebuff/okay-shower-thoughts-here-we-re-using-fat32-for-so-b0ce3067-2b04-4b81-984d-9fd76bfcf123`)
- **Prompt / plan:** Deep-audit `docs/wasm-import-contract.md` (landed via PR #786, claim 7129) against the kernel dispatch table before W1b/W3 build on it, and amend the three wrong wire formats + the incomplete out-of-scope list.
- **Scope:** Audit + doc amendment only — no kernel/userland code. Verified every slot number, argument shape, and error code in the contract against `kernel/src/syscall.zig`, `file_table.zig`, `virtio_snd.zig`, `process.zig`; compiled the kernel's `AudioInfo` extern struct to prove `@sizeOf == 16`.
- **Touches:** docs/wasm-import-contract.md docs/claims/5335-contract-audit-fix.md docs/logs/freebuff-20260901-004.md
- **Depends on:** the contract landed (PR #786, claim 7129); W1b/W3 not yet claimed
- **Heartbeat:** 2026-09-01
- **Status:** ✅ done

## Notes

Audit verdict: all slot numbers + the −1..−10 ErrorCode enum verified correct; four discrepancies found — (A) AudioInfo is 16 B (`ready u32, format u8, rate u8, channels u8, padding u8, period_bytes u32, max_len u32`), not the 24-B all-u32 layout the contract claimed (the "24 bytes" comment in virtio_snd.zig/ui.zig is stale); (B) DirEntry is `name[32], size u32, is_dir u8, reserved[3]` (ADR 0010 D3), not `name[31], type u8, size u64` — the agent had copied the HF2 channel LIST shape; (C) file_open flags are `MODE_READ 0x1 / MODE_WRITE 0x2 / MODE_CREATE 0x4 / MODE_APPEND 0x8 / MODE_DIR 0x10` with flags==0 → EINVAL, not "bit0=O_CREATE, 0=read/write"; (D) munmap has no EFAULT path (EINVAL for zero/unaligned/partial); plus the §6 out-of-scope list omitted the window-depth/notify/pipe/font/ping/net-stats slots (46/47/49–53/55–62). All five corrected in this amendment.

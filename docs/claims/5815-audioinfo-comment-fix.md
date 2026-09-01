# Claim: Fix stale "24 bytes" AudioInfo comments in virtio_snd.zig / ui.zig

- **Owner:** buffy (`freebuff/okay-shower-thoughts-here-we-re-using-fat32-for-so-b0ce3067-2b04-4b81-984d-9fd76bfcf123`)
- **Prompt / plan:** claim 5335's audit found the `AudioInfo` wire layout is 16 bytes, but two comments still say "24 bytes" — `kernel/src/virtio_snd.zig` (the EL0 audio seam doc) and `user/src/lib/ui.zig` (the `sys_audio_info` doc). Fix both to say 16 bytes.
- **Scope:** comment-only, two lines. No code behavior, no contract changes, no FS files.
- **Touches:** kernel/src/virtio_snd.zig (comment), user/src/lib/ui.zig (comment), docs/claims/5815-audioinfo-comment-fix.md, docs/logs/freebuff-20260901-005.md
- **Depends on:** claim 5335 (audit that proved 16 bytes)
- **Heartbeat:** 2026-09-01
- **Status:** ✅ done

## Notes

Gate: `@sizeOf(AudioInfo) == 16` re-verified at HEAD by compiling the kernel struct (`ready u32@0, format u8@4, rate u8@5, channels u8@6, padding u8@7, period_bytes u32@8, max_len u32@12`) — `zig test` 1/1 pass. Both comments now say "16 bytes, fixed layout"; no other stale AudioInfo size references remain (the remaining "24 bytes" mentions are the audit records describing the fix).

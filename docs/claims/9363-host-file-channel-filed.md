# Claim: M34 seed — host file channel scoping doc + HF1–HF7 issue split

- **Owner:** buffy (`freebuff/okay-shower-thoughts-here-we-re-using-fat32-for-so-b0ce3067-2b04-4b81-984d-9fd76bfcf123`)
- **Prompt / plan:** `docs/host-file-channel-scoping.md` (HF1–HF7 gated card split, acceptance cases A–C)
- **Scope:** Post-M33 planning only — no kernel/userland code. Author the M34 host-file-channel scoping seed (FAT-free storage: the guest userland filesystem becomes a macOS folder served over the custom-virtio device), file it as GitHub issue #727 under a new M34 milestone (#21) + `m34-host-file-channel` label, split it into per-card issues HF1–HF7 (#735–#741) per the #630→SB1–SB6 precedent, close the seed with a child index, and record the M34 row in `docs/status.md`.
- **Touches:** docs/host-file-channel-scoping.md docs/issue-draft-host-file-channel.md docs/status.md docs/claims/9363-host-file-channel-filed.md docs/logs/freebuff-20260831-002.md
- **Depends on:** M32 complete; M33 seam B in flight but scheduling-independent (MMU/compositor vs storage); the custom-virtio control plane (claims 3141/9588/0680) already landed
- **Heartbeat:** 2026-08-31
- **Status:** ✅ done

## Notes

The goal is getting the guest off FAT32 for everything user-visible: the only
FAT left is the ESP boot volume, parsed by Apple's firmware pre-exit, never
touched by guest code after boot. The end-state moves the guest filesystem to
a host folder over the existing custom-virtio device (DID 0x1082), deleting
`fat.zig`, the DATA partition, and the embedded-apps image machinery. The
maintainer wants this worked sooner than other pending items; it is
scheduling-independent of M33 seam B.

Verified against current trunk before filing: queue-count capability rule
(5 queues today under `--cvc-snap`; a file queue is the deepest flag → 6),
the four existing custom-virtio gates, the monitor `.storage` category, the
hardware-contract channel-section layout, and the image facts (128 MiB /
36 MiB DATA). One fact corrected pre-filing: the BSS gate is 11.0 MiB (ADR
0013 D3.1), not 7.0 MiB as the first draft claimed.

## Result (2026-08-31)

Delivered: `docs/host-file-channel-scoping.md` (FAT-free end-state, wire
shape, dedup section §4, HF1–HF7 gated cards with issues #735–#741 in the
table, HF1 acceptance cases A (32 KiB device-write reply spike), B (class-A
fixture/byte-parity list G1–G6/S1–S4), C (VFWire module boundary));
`docs/issue-draft-host-file-channel.md` (the filed issue's source body);
GitHub: milestone #21 "M34 — FAT-free storage (host file channel)" created,
issue #727 filed and closed after the split, cards #735–#741 opened under
milestone + label; `docs/status.md` gains the M34 row. Zero code changes.
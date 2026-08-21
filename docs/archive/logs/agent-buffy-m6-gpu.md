# Log — agent/buffy/m6-gpu

Branch: `agent/buffy/m6-gpu` · Slug: `gpu` · Claim: [6053](claims/6053-gpu.md)
Prompt: [m6-gpu-prompt](m6-gpu-prompt.md) · Started from merged main
`0fcd96b` (docs: milestone-five cards N7/N8 planning-first prompt).

## 2026-08-12 — claim

- **Claim:** branch `agent/buffy/m6-gpu`; claim ID 6053 via
  `tools/status/claim-id.sh`; claim doc + this log +
  `refresh-indexes.sh`.
- **Prompt:** `docs/m6-gpu-prompt.md` (the milestone-six G1 planning
  doc, m5-net-tx-prompt pattern).
- **Status:** ✅ **DONE — the first non-blank guest framebuffer is live
  on VZ.**

## 2026-08-12 — landing

- **Runner:** `--display`/`--screenshot` attach
  `VZVirtioGraphicsDeviceConfiguration` (1280×720 scanout) + the
  VZVirtualMachineView window; OFF by default — the default VM stays
  byte-identical. The screenshots also capture in SCRIPT mode (the
  gate's evidence path).
- **Guest driver:** `kernel/src/virtio_gpu.zig` — discovery (DID 0x1050
  observed, class 0x038000, dev 7; claim-0013 config layout), VER1-only
  negotiation (the device offers
  RING_PACKED|RING_EVENT_IDX|RING_INDIRECT_DESC|VERSION_1), controlq 0
  + cursorq 1 (size 4), post-exit re-arm (**VZ resets the gpu at
  ExitBootServices — `pre-rearm st=00` observed, like blk/entropy,
  unlike net's `st=0f`**), and the spec 2D path to a writable BSS
  framebuffer (GET_DISPLAY_INFO → CREATE_2D B8G8R8X8 → ATTACH_BACKING
  → SET_SCANOUT → TRANSFER → FLUSH, one command outstanding at a time,
  polled used-ring drain). `screen` / `screen fill <rrggbb>` / `screen
  peek` (registry 34→35).
- **Claim-time findings (the debugging arc — all recorded in the
  hardware contract + claim doc):** the virtio-gpu **1.2** `display_one`
  (24-B pmodes; the pre-1.2 20-B shape made GET_DISPLAY_INFO's response
  344 vs the 408 the device writes and wedged the queue with
  DEVICE_NEEDS_RESET 0x40); the tail descriptor's `next` must be 0 (VZ
  walks the field without the NEXT flag); the command + framebuffer
  caches MUST be cleaned (dc cvac) before the kick/transfer — an
  MMU-on kernel is not the caches-off world of the reference drivers;
  and the scanout composites with ALPHA — an X/A byte of 0 renders
  fully transparent (the final black-screen fix; fills write X=0xff,
  0x00ff00 renders ~(117,251,76) through the color-managed pipeline).
- **Class A:** fmt, 277+ unit tests, byte-identical transcript (shell
  help grew with `screen`), build/image/inspect, swift build, context,
  coordination, mmu-debt — all green.
- **Class B:** `tools/verify-live-screen.sh` **PASS 1/1** — the
  transport report + the guest-side fill bytes (`screen peek`
  p1=0xff) + the DECODED capture: 14400/14400 sampled pixels are the
  fill green (evidence `artifacts/live-screen-*`,
  `artifacts/gpu-screen-*s`). The **35-gate `verify-vz` aggregate**
  re-ran green (`artifacts/m6-gpu-vz-sweep.log`) — proof the
  `--display` mode left the default VM byte-identical.
- **Docs:** march-m6 G1 → ✅; roadmap G1 card + Graphics surface row;
  status milestone-six row + next-step item; hardware-contract gpu
  entries [inferred] → [observed]; gate-inventory live-screen row +
  verify-vz aggregate; claim flip; indexes refreshed.

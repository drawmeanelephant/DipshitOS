# Claim: structured console + framebuffer snapshots over custom virtio (#523 item 3 capstone)

- **Owner:** t3code (`t3code/finish-523-console-snapshots`)
- **Prompt / plan:** issue #523 item 3 productionization TODO — the two open
  tranches after claims 9588/3141/9367 (input injection) landed; plus issue
  #523 item 6 (merge queue enablement, repo admin)
- **Scope:** (1) structured console — host-enabled kind-3 control message
  arms a line tee so kernel console lines ride custom-virtio queue 1 into a
  runner-written structured file (`--cvc-console-file`), retiring
  vm-serial.log parsing for gates that opt in; (2) framebuffer snapshots —
  kind-4 request over queue 3, guest streams raw BGRX chunks of the composed
  scanout back over queue 1 (tagged binary framing, per-chunk RFC-1071
  checksums, whole-frame checksum), runner reassembles to a raw file
  (`--snapshot-after`), replacing ScreenCaptureKit scraping and its Screen
  Recording TCC dependency; (3) headless end-to-end gate
  `tools/verify-live-virtio-e2e.sh`: injected input in, structured console +
  snapshot out, no CGEvent synthesis and no screenshot scraping anywhere in
  the critical path (#523 acceptance row); (4) enable GitHub merge queue on
  main via API and record the config (`docs/branch-protection.md`).
- **Touches:** kernel/src/virtio_custom.zig, kernel/src/main.zig,
  host/vm-runner/Sources/VMRunner/main.swift,
  tools/verify-live-virtio-e2e.sh, docs/hardware-contract.md,
  docs/status.md, docs/gate-inventory.md, docs/branch-protection.md
- **Depends on:** claims 9588/9367 (four-queue shape, injection ladder) —
  already merged via PRs #543/#545
- **Heartbeat:** 2026-08-24 (closed)
- **Status:** ✅ done

## Notes

Queue plan stays four-deep; capability signal stays queue-count + envelope
kinds. Console tee is default-off (armed only by an explicit host kind-3
message), snapshot streaming is demand-driven (one shot per kind-4), both
polled through the existing idle-loop pump seam — no new IRQ dependencies.
Snapshot chunks point directly into `virtio_gpu.gpu_fb` (no staging buffer,
no BSS-budget impact). Serial keeps its panic/fallback role untouched;
runner failures stay loud (no silent flag ignores).

Verification bar: new gate rc=0 live on this macOS 27 host (headless);
`GATE_VIRTIO=1 verify-live-input.sh`, `verify-live-pointer-virtio.sh`,
`verify-cvc-echo.sh`, `verify-custom-virtio.sh` regressions PASS unchanged;
`zig test` virtio_custom green incl. new kind-3/kind-4/framing tests;
`zig fmt --check`; swift build; verify-coordination.sh + test-coordination.sh.

## Outcome (2026-08-24)

All four tranches landed and verified live on macOS 27.0 build 26A5416b:

1. **Structured console**: kind-3 arm message → line tee onto queue 1
   (256-byte staging, idle-seam partial flush for the prompt, drop
   counter); host `--cvc-console-file` captures raw bytes. The e2e gate
   reads the typed command's own report (`events=6`) out of the FILE, not
   out of vm-serial.log.
2. **Framebuffer snapshots**: kind-4 request → the guest streams
   `gpu_fb` over the NEW FIFTH QUEUE as tagged header/chunk/done messages
   (32 KiB × 113 chunks pointing directly into the framebuffer — zero BSS
   impact), RFC-1071 checksums per chunk + whole frame; host
   `--snapshot-after <marker>` (repeatable) reassembles + verifies into a
   raw BGRX file.
3. **End-to-end gate** `tools/verify-live-virtio-e2e.sh`: PASS headless —
   injected input in, structured console + snapshot out, no CGEvent
   synthesis and no screenshot scraping anywhere in the critical path
   (#523 acceptance row verbatim). Regressions PASS unchanged:
   GATE_VIRTIO=1 verify-live-input, pointer-virtio, cvc-echo,
   custom-virtio. Unit tests green incl. checksum/framing/kind-3/kind-4/
   tee-accumulator vectors; bss-budget PASS (no new buffers).
4. **Merge queue (#523 item 6)**: attempted via the REST rulesets API;
   BLOCKED by plan — `merge_queue` rejected even on a disabled probe
   ruleset (Team/Enterprise feature). No partial state left; exact config
   + ready-to-run API call documented in docs/branch-protection.md.

Two live findings fixed en route (pinned in hardware-contract.md): polled
q1/q4 sends must free their descriptor chains (the spike's five lines
masked a leak that sustained tee traffic exhausted within seconds), and
RFC-1071 needs a u64 accumulator at whole-frame scale (u32 overflowed as a
host-side Swift arithmetic-overflow trap mid-stream).

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
- **Heartbeat:** 2026-08-24
- **Status:** 🔄 t3code/finish-523-console-snapshots

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

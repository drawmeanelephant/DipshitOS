# Claim: pointer injection over the custom-virtio INPUT queue (kind-2 HID pointer messages)

- **Owner:** t3code (`t3code/finish-issue-523-progress`)
- **Prompt / plan:** issue #523 item 3 productionization TODO (see also #151,
  the class-C-only pointer-focus proof); follows the claim-9588 keyboard
  channel shape.
- **Scope:** extend the custom-virtio input channel (queue 3) with kind 2 =
  absolute-pointer reports. Guest: `virtio_custom.zig` dispatches kind-2
  payloads through the same path XHCI pointer reports take (`input.zig`
  record/decode seam), wired in `main.zig`. Host: VMRunner gains a virtio
  pointer sequence (same grammar as `--pointer`, route `cv`) enqueued as
  16-byte kind-2 messages after a trigger marker. Wire format normative in
  `docs/hardware-contract.md`. Gate: headless proof that injected pointer
  reports drive click-to-focus with NO USB devices attached — upgrading
  #151's pointer-focus evidence from class-C-only to class-B-headless.
- **Touches:** kernel/src/virtio_custom.zig, kernel/src/main.zig, kernel/src/input.zig, host/vm-runner/Sources/VMRunner/main.swift, tools/verify-live-pointer-virtio.sh, docs/hardware-contract.md
- **Depends on:** 9588 (queue-3 input channel, landed), 3141 (host-push pattern, landed)
- **Heartbeat:** 2026-08-24
- **Status:** 🔄 t3code/finish-issue-523-progress

## Notes

The activation wall (claim 4769) blocks every synthesized pointer route:
VZ only translates host input for its KEY window, so pointer-focus proofs
were class-C-only (real mouse). Claim 9588 proved the escape hatch for
KEYBOARD: inject over the custom-virtio device's queue 3, headless — no
window, no view, no CGEvent, nothing for the wall to block. This claim
applies the identical lesson to POINTER reports.

Verification bar: `bash tools/verify-live-pointer-virtio.sh` rc=0 with
serial evidence of ptr-reports>0 and >=2 distinct focus moves while the
guest's own report shows armed=0 (no USB keyboard or pointer was ever
attached); regression `GATE_VIRTIO=1 bash tools/verify-live-input.sh` stays
green; unit tests cover the kind-2 envelope validation.

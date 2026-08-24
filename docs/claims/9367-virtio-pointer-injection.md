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
- **Status:** ✅ done 2026-08-24 — PASS observed live (see Evidence)

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

## Evidence

- **Live gate** `bash tools/verify-live-pointer-virtio.sh` — PASS
  2026-08-24 (macOS 27.0 build 26A5416b, real VZ boot, HEADLESS):
  `rc=0 armed=1(no-USB) ptr-reports=8 focus-lines=2 distinct=2 q3=1 q2=1
  winloop=1 done=1 gpu=1 host-seq=1 host-down=1 host-up=1 host-complete=1
  host-four-q=1 host-no-synthesis=1`. Serial: `input: armed=0 …
  ptr-reports=8` (no USB HID device ever attached) and the window
  manager's own `dui: pointer focus=2` → `focus=0`. Artifacts
  `live-pointer-virtio-*`.
- **Regression** `GATE_VIRTIO=1 bash tools/verify-live-input.sh` — PASS
  unchanged (keyboard channel untouched).
- **Unit tests**: `zig test kernel/src/virtio_custom.zig` 27/27 including
  the new kind-2 envelope-validation test; `zig test kernel/src/input.zig`
  189/189 after the `decode_pointer_report` rename; `verify-unit-tests`
  green.
- **Live findings pinned in hardware-contract.md**: (1) pointer messages
  pace at 2.5 s — presses are edge-detected once per shell-idle pass at
  the present cadence, and 0.25 s spacing collapsed every click (observed:
  ptr-reports=8, zero focus moves); (2) hit-testing scans the window array
  from the end and the fullscreen terminal sits last, so the gate raises
  WINLOOP (`dui raise 2`) as session setup before clicking it.

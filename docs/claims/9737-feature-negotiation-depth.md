# Claim: custom-virtio feature-negotiation depth (NOTIFICATION_DATA + ANY_LAYOUT)

- **Owner:** buffy (`agent/buffy/macos27-custom-virtio-spike`)
- **Prompt / plan:** claim 0828 "Next steps" item 3 — negotiate and
  exercise `VIRTIO_F_NOTIFICATION_DATA` (bit 38) and
  `VIRTIO_F_ANY_LAYOUT` (bit 27) on the custom device and report which
  features VZ's implementation actually accepts (mirrors claim 0016's
  spec-review discipline).
- **Scope:** `kernel/src/virtio_custom.zig` (read the full 64-bit device
  features word, accept VERSION_1 + ANY_LAYOUT + NOTIFICATION_DATA when
  offered, FEATURES_OK, then behave per the negotiated set: 32-bit
  notification-data kicks when NOTIFICATION_DATA is on, write-descriptor-
  first chains when ANY_LAYOUT is on); `kernel/src/main.zig` spike report
  (`cvspike: feat=0x… acc=0x… nd=<1|0> al=<1|0> notify=<32|16>bit`);
  `host/vm-runner/Sources/VMRunner/main.swift` (the delegate's
  read/write-buffer handling is descriptor-flag-based, so ANY_LAYOUT
  chains work unchanged); gate greps. Polled console paths and all
  existing gates untouched.
- **Depends on:** claim 4374 (the ring allocator / multi-queue transport
  the features gate the behavior of), claim 0828.
- **Status:** ✅ done 2026-08-10 on `agent/buffy/macos27-custom-virtio-spike`

## Notes

Deterministic claim ID from
`bash tools/status/claim-id.sh 'agent/buffy/macos27-custom-virtio-spike' 'feature-negotiation-depth'`
= `9737`.

Spec anchors (Virtio 1.3): `VIRTIO_F_ANY_LAYOUT` = bit 27 (device accepts
arbitrary descriptor layouts), `VIRTIO_F_NOTIFICATION_DATA` = bit 38
(driver writes a 32-bit `vqn << 16 | next_off | (ring_flags << 30)`
notification instead of the 16-bit queue index). Both are opt-in: the
guest reads the device's 64-bit features, ANDs its wanted mask against
what the device offers, accepts via the guest-features registers, verifies
FEATURES_OK, and then **must** use the negotiated behavior.

The claim's deliverable is the honest report of what VZ offers and what
the guest accepted, plus proof the negotiated path works end to end: when
NOTIFICATION_DATA is accepted the kicks become 32-bit and the exchanges
still complete; when ANY_LAYOUT is accepted at least one exchange posts
its device-write reply descriptor BEFORE the device-read payload
descriptors (any order per §2.7.6) and the host still reads/writes the
right spans. If VZ offers neither, the report says `nd=0 al=0
notify=16bit` and the exchanges pass with the classic format — that
absence is itself the finding.

## Result — the honest finding: VZ offers neither feature; VERSION_1 alone negotiates (class B)

```
cvspike: feat=0x530000000 acc=0x100000000 nd=0 al=0 notify=16bit
```

On macOS 27.0 (26A5388g) the custom device's 64-bit device-features word
is `0x530000000`: **bit 32 VERSION_1, bit 34 RING_PACKED, bit 29
RING_EVENT_IDX, bit 28 RING_INDIRECT_DESC — but NOT bit 27 ANY_LAYOUT and
NOT bit 38 NOTIFICATION_DATA**. The driver accepts only what is offered,
so the negotiated set is `VERSION_1` alone (`acc=0x100000000`), FEATURES_OK
verifies, and every kick uses the classic 16-bit queue-index format
(`notify=16bit`). The whole experiment — 4+4 concurrent exchanges, the
12,340-byte multi-descriptor payload, and the queue-1 log transport — ran
end to end over that classic path, so the absence of the two modern
features is a proven, non-blocking finding (not a hypothesis).

Class B live gate `tools/verify-custom-virtio.sh`.

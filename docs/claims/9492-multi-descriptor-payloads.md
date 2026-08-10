# Claim: custom-virtio guest→host payloads beyond 4 KiB / multi-descriptor reads

- **Owner:** buffy (`agent/buffy/macos27-custom-virtio-spike`)
- **Prompt / plan:** claim 0828 "Next steps" item 2 — prove payloads
  spanning several device-read descriptors (chain length > 2) and sizes
  past a page, verifying the host delegate reassembles the exact bytes
  (tests the `VZVirtioQueueElement.readBuffers()` span semantics).
- **Scope:** `kernel/src/virtio_custom.zig` (multi-descriptor chain posting:
  a scatter list of device-read buffers + one device-write reply in one
  element; the chain becomes `N` read descriptors + 1 write descriptor);
  `kernel/src/main.zig` spike orchestration (a 12,340-byte payload split
  across three 4-KiB-ish descriptors, guest-side full byte-for-byte reply
  verification); `host/vm-runner/Sources/VMRunner/main.swift` (host
  reassembly: concatenate `readBuffers()`, print the byte count + a bounded
  hex summary, echo the full payload back); gate greps in
  `tools/verify-custom-virtio.sh` + `build.zig`.
  Polled console paths and all existing gates untouched.
- **Depends on:** claim 4374 (the ring allocator — multi-descriptor chains
  need > 2 descriptors per element), claim 0828.
- **Status:** ✅ done 2026-08-10 on `agent/buffy/macos27-custom-virtio-spike`

## Notes

Deterministic claim ID from
`bash tools/status/claim-id.sh 'agent/buffy/macos27-custom-virtio-spike' 'multi-descriptor-payloads'`
= `9492`.

Claim 0828's exchanges were always one two-descriptor chain with a 16-byte
payload. This claim grows the chain: the guest posts a 12,340-byte payload
(`0x3034`, deliberately not a page multiple) as three device-read
descriptors (4 KiB + 4 KiB + 4116 B) plus a device-write reply descriptor
of the same size, in one avail entry. The host reads all `readBuffers()`
(three spans), reassembles them, prints `dequeued 12340 byte(s) (read
12340)`, and echoes the full payload back; the guest compares the reply to
the payload byte-for-byte and prints `cvspike: q0 big n=0x3034 echo=ok`
only on an exact match — the strongest possible reassembly proof.

The guest-side payload is a deterministic non-printable pattern
(`(i % 251) + 1`), so the host's hex/ascii print is bounded (first/last
16 bytes + a running sum) to keep the runner log sane while the byte count
+ guest echo carry the assertion.

## Result — a 12,340-byte payload across three descriptors, reassembled + echoed (class B)

The guest posts one element with a **4-descriptor chain**: three
device-read descriptors (4 KiB + 4 KiB + 4116 B) carrying the 12,340-byte
pattern plus one device-write reply descriptor. The host reassembles the
three `readBuffers()` spans and echoes the whole payload back:

```
CUSTOM-VIRTIO: dequeued 12340 byte(s) (read 12340): hex=[01 02 03 … 29 sum=0x0017a8c7] ascii="<binary>"
CUSTOM-VIRTIO: echoed 12340 byte(s) into 12340 byte(s) of write buffers
cvspike: q0 big n=0x3034 echo=ok
```

`read 12340` proves the framework presented all three spans; the guest's
`echo=ok` is a byte-for-byte comparison of the echoed reply against the
original payload (deterministic `(i % 251) + 1` pattern), so a single
dropped, reordered, or truncated byte fails the line. Class B live gate
`tools/verify-custom-virtio.sh`.

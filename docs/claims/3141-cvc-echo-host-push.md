# Claim: cvc-echo — host-initiated custom-virtio round trip (issue #523 item 3 spike)

- **Owner:** ox-alpha (`t3code/c259b00a`)
- **Prompt / plan:** session prompt (issue #523 item 3, first working end-to-end spike)
- **Scope:** macOS 27 `VZCustomVirtioDevice` spike — one deterministic HOST-initiated round trip: host app enqueues → guest driver receives → guest replies → host delegate observes, asserted by a new class-B gate with byte-exact expectations.
- **Touches:** host/vm-runner/Sources/VMRunner/main.swift, kernel/src/main.zig, kernel/src/virtio_custom.zig, tools/verify-cvc-echo.sh, docs/hardware-contract.md, docs/status.md
- **Depends on:** 5844/0828/4374/9492/9737/4837/5804 (custom-virtio transport + guest driver), 6637 (merged in #529 — its ACTIVE row declared main.swift; flipped ✅ in this branch with a log note so the Touches gate can pass)
- **Heartbeat:** 2026-08-24
- **Status:** 🔄 `t3code/c259b00a`

## Notes

### What is new (vs the existing transport claims)

The existing gate (tools/verify-custom-virtio.sh) proves GUEST-initiated
exchanges: guest kicks → host delegate dequeues → echoes → returnToQueue.
Issue #523 item 3 needs the reverse: the HOST APP chooses when to enqueue.

**SDK discovery (Xcode 27.0 / 27A5228h, MacOSX.sdk Virtualization.framework,
ObjC headers under Versions/A/Headers — the types are NOT in the
swiftinterface, they are ObjC-only):**

- `VZVirtioQueue` exposes ONLY `nextElement`, `queueIndex`, `queueSize`.
- There is NO host-side enqueue/element-construction API anywhere:
  elements exist only as descriptors the GUEST driver posted. The claim-5844
  audit note ("no host-triggered guest-interrupt API") still holds on the
  final SDK.
- Therefore "host app enqueues" must be realized the virtio-standard way
  (the virtio-net RX pattern): the guest PRE-ARMS an empty device-write
  receive buffer on a dedicated queue; the host dequeues it at a time of its
  choosing via `nextElement()`, writes the request with `writeData:error:`,
  and `returnToQueue` — the framework advances the used ring and asserts the
  device interrupt. That is the only host→guest data path, and it is
  event-driven from the guest's side (used-ring completion), which is what
  makes it deterministic without timing dances.
- Other shapes confirmed from headers: `VZCustomVirtioDevice.queueAtIndex:`
  (valid only after DRIVER_OK), `.deviceQueue` (serial — all delegate work
  single-threaded), `requestDeviceReset`,
  `updateDeviceSpecificConfiguration:completionHandler:`,
  `guestMemoryMappingAtPhysicalAddress:length:`, `negotiatedFeatures`
  (`VZNegotiatedVirtioFeatureSet`), save/restore delegate methods,
  `VZCustomVirtioDeviceConfiguration.mandatoryFeatures/optionalFeatures`
  (`VZVirtioFeatureSet`).

### Design

- New runner flag `--cvc-echo` (implies the device attach). With it the
  device exposes **3 queues**; plain `--custom-virtio` keeps exactly 2, so
  the old world stays intact. Queue-count IS the capability signal: the
  guest probes queue 2's size through the common config (0 ⇒ absent), no
  speculative feature-bit mapping needed.
- Protocol on queue 2 ("push echo"), byte-exact constants:
  - Guest pre-arms ONE rx buffer (16-byte device-write descriptor) + kicks.
  - Guest sends log line `cvc-push-armed` over queue 1 (existing transport).
  - Host delegate, ON observing that line (event-driven), dequeues the rx
    buffer, writes request `"CVC-PING-0x42"` (13 bytes), returns it.
    Host stdout: byte-exact CUSTOM-VIRTIO-PUSH lines.
  - Guest sees used-ring len 13, reads the bytes, replies by posting a
    read-descriptor carrying the request verbatim + a write ack buffer,
    kicks. Serial report: `cvspike: q2 ...`.
  - Host delegate verifies the reply bytes exactly, writes ack `"OK:13"`,
    returns the element; prints the verification line. Gate greps BOTH
    sides byte-exactly + shell alive.
- PCI identity unchanged from claim 5844 (VID 0x1af4 / DID 0x1082 =
  0x1040+deviceID 0x42, class 0x00/0x00); rationale + non-collision argument
  now documented in docs/hardware-contract.md.

### Verification

- Class A: zig build/test/fmt, swift build (-DSPIKE path compiles).
- Class B (this host: Apple silicon, macOS 27, Xcode 27): NEW
  tools/verify-cvc-echo.sh boots once and requires every link byte-exact;
  tools/verify-custom-virtio.sh re-run as the regression proof for the
  untouched default-off path.

### What remains for productionization (documented, not built here)

Input-injection device (HID over virtio-input replacing CGEvent synthesis —
issues #179/#151), structured console/gate markers over queues instead of
vm-serial.log parsing, framebuffer snapshot channel, feature-bit-driven
capability negotiation instead of queue-count probing.

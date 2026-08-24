# Log — t3code/c259b00a (cvc-echo host-push spike)

- **2026-08-24** — *ox-alpha (`t3code/c259b00a`)*: Opened claim 3141
  (cvc-echo — issue #523 item 3 first working end-to-end spike): one
  deterministic HOST-initiated custom-virtio round trip (host app enqueues →
  guest driver receives → guest replies → host delegate observes) behind a
  new `--cvc-echo` runner flag + a new class-B gate
  (tools/verify-cvc-echo.sh, byte-exact expectations both sides).
  SDK API shapes discovered from the installed Xcode 27.0 (27A5228h)
  Virtualization.framework ObjC headers (the custom-virtio types are NOT in
  the swiftinterface): no host-side enqueue exists — elements come only from
  guest-posted descriptors via VZVirtioQueue.nextElement, so the push uses
  the virtio-net-RX pattern (guest pre-arms a receive buffer; host dequeues,
  writes, returns). Touches: main.swift, kernel/src/{main,virtio_custom}.zig,
  NEW tools/verify-cvc-echo.sh, docs/hardware-contract.md, docs/status.md.
  Also flipped claim 6637 to ✅ from this branch: its PR #529 merged today
  (957e452) but the row was still 🔄, and as an ACTIVE row declaring
  host/vm-runner/Sources/VMRunner/main.swift it would fail the new Touches
  overlap gate against claim 3141 (same owner ox-alpha on both branches;
  flip noted here per append-only rules).

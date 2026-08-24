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

- **2026-08-24** — *ox-alpha (`t3code/c259b00a`)*: DONE (claim 3141 ✅).
  The HOST-initiated round trip is live and gate-proven. Guest driver
  (virtio_custom.zig): optional third queue probed via the common-config
  queue_size read at select=2 (0 ⇒ absent, per spec — the classic
  two-queue world untouched), `arm_push()` pre-arms one device-write rx
  buffer + kicks, `wait_any_push()` observes the host's completion,
  submit_ex/wait bounds relaxed from `queue_count` to `armed_queues` (the
  one real bug: the push reply was rejected by the old 2-queue bound —
  caught by the first gate run, fixed, re-run green). Kernel orchestration
  (main.zig): arm → signal "cvc-push-armed" over queue 1 → wait → verify
  req byte-exact (`req="CVC-PING-0x42" n=0x000000000000000d req=ok
  handle=ok`) → reply verbatim → verify ack `OK:13` → report
  (`cvspike: q2 ... ok=1`); honest skip line on two-queue devices.
  Host runner: `--cvc-echo` (implies attach; device gets virtioQueueCount
  3), delegate enqueues on observing the armed log line (event-driven,
  inline on the serial deviceQueue), verifies the reply byte-exactly and
  writes `OK:13`. Gate tools/verify-cvc-echo.sh PASS 1/1 (14 assertion
  groups, both sides byte-exact, shell alive); regression
  tools/verify-custom-virtio.sh PASS unchanged (select=2 probe reads 0 on
  the two-queue device as spec'd). zig build/test/fmt green; swift build
  base + -DSPIKE green. Docs: hardware-contract.md identity rationale +
  push-channel contract; status.md gate row; gate-inventory.md entry.
  Evidence artifacts/live-cvc-{gate,report}-*.txt, live-cvc-run-01.txt,
  live-cvc-serial-01.log.

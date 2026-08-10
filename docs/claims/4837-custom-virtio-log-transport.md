# Claim: guest console/log transport on the custom virtio device

- **Owner:** buffy (`agent/buffy/macos27-custom-virtio-spike`)
- **Prompt / plan:** claim 0828 "Next steps" item 4 — the natural end
  goal: a small guest-side logging path (polled) over the custom virtio
  queue, gated by a host-side echo of the guest's lines, replacing the
  one-shot proof exchanges.
- **Scope:** `kernel/src/virtio_custom.zig` (a reusable `cvlog_puts(line)`
  API: submit the line on queue 1, wait for the used ring, return the
  host's ack); `kernel/src/main.zig` spike orchestration (send several
  log lines through the transport and report each line's echo);
  `host/vm-runner/Sources/VMRunner/main.swift` (queue-1 delegate behavior:
  print `CUSTOM-VIRTIO-LOG: <line>` to the runner stdout and write an
  `ACK:<len>` reply back into the element); gate greps
  (`tools/verify-custom-virtio.sh` asserts the host's log lines AND the
  guest's echo readback). Polled console paths and all existing gates
  untouched.
- **Depends on:** claim 4374 (queue 1 transport), claim 0828.
- **Status:** ✅ done 2026-08-10 on `agent/buffy/macos27-custom-virtio-spike`

## Notes

Deterministic claim ID from
`bash tools/status/claim-id.sh 'agent/buffy/macos27-custom-virtio-spike' 'custom-virtio-log-transport'`
= `4837`.

Claim 0828's proof was a fixed schedule of exchanges; this claim turns the
transport into a general logging channel. `cvlog_puts` is a real driver
API: it posts one element on queue 1 (line as the device-read descriptor,
a small reply buffer as the device-write descriptor), kicks, polls the
used ring, and returns. The host delegate distinguishes queue 1: it prints
the line verbatim to its stdout (`CUSTOM-VIRTIO-LOG: …`) and writes back
an `ACK:<byte-count>` reply, so the guest can verify both directions per
line (`cvspike: q1 log="…" ack="ACK:NN" ok=…`).

The gate asserts both sides: the runner stdout contains every
`CUSTOM-VIRTIO-LOG:` line and the serial log contains the guest's
per-line echo + `cvspike: q1 ok=N`. Because the queue is polled
(no IRQ dependency), the path is robust against VZ's used-buffer IRQ
coalescing (claim 0828's honest finding) — the IRQ window just observes
whatever notifications arrive.

## Result — three guest log lines over queue 1, echoed + ACK-verified (class B)

```
CUSTOM-VIRTIO-LOG: cvlog-1
CUSTOM-VIRTIO-LOG: cvlog-2
CUSTOM-VIRTIO-LOG: cvlog-3
cvspike: q1 log="cvlog-1" ack="ACK:7" n=0x5
cvspike: q1 log="cvlog-2" ack="ACK:7" n=0x5
cvspike: q1 log="cvlog-3" ack="ACK:7" n=0x5
cvspike: q1 ok=3
```

Each line rides one queue-1 element: the guest posts the line as the
read descriptor, the host prints it verbatim and writes `ACK:<len>` (5
bytes: `ACK:7` for a 7-byte line — the used-ring `n=0x5` is the ack
length), and `cvlog_puts` parses the ack and verifies the byte count
matches the line. All three lines pass (`q1 ok=3`), so the transport
carries both directions per element. The transport is polled, and the
IRQ window still recorded device interrupts from the whole experiment
(`irq=0x112`, first=INTID 0x45 SPI 69 — the same SPI class as claim
0828), so the queue-1 path is independent of IRQ delivery. Class B live
gate `tools/verify-custom-virtio.sh`.

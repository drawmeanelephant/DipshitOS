# Claim: custom-virtio guest driver — queue transport + used-ring IRQ (DID 0x1082)

- **Owner:** buffy (`agent/buffy/macos27-custom-virtio-spike`)
- **Prompt / plan:** macOS 27 capability-audit steps 4+5 on the claim-5844
  spike device (VID 0x1af4 / DID 0x1082, `zig build spike-virtio`): write
  the smallest custom-virtio guest driver (probe DID 0x1082, negotiate
  VIRTIO_F_VERSION_1, DRIVER_OK, arm virtqueue 0 with one known-payload
  descriptor, kick), prove the host delegate dequeues the exact bytes
  (guest→host queue transport), then have the host return the element
  (`returnToQueue`) and prove a real IRQ enters the claim-9746 EL1 vector
  (host→guest used-ring IRQ delivery).
- **Scope:** new `kernel/src/virtio_custom.zig` driver; GIC SPI-window
  arm/disarm + non-timer INTID recording in `kernel/src/gic.zig` +
  `kernel/src/main.zig`; the host delegate's dequeue, reply write, and
  `returnToQueue` in `host/vm-runner/Sources/VMRunner/main.swift`;
  `build.zig` spike-virtio build-step gating;
  `tools/verify-custom-virtio.sh` class-B live gate; claim file +
  indexes. Polled console paths and all existing gates untouched (no
  regressions).
- **Depends on:** claim 5844 (host spike device + `pci` command), claim
  0013 (ECAM discovery + pre-exit discipline), claim 9187 (real CNTP PPI
  delivery — the GIC works, so device interrupts deliver too), claim 9746
  (live EL1 vectors), claim 1517 (post-MMU virtio access).
- **Status:** ✅ done 2026-08-09 on `agent/buffy/macos27-custom-virtio-spike`

## Notes

Deterministic claim ID from
`bash tools/status/claim-id.sh 'agent/buffy/macos27-custom-virtio-spike' 'custom-virtio-queue-irq'`
= `0828`. (The branch's host-side spike claim already owns slug
`macos27-custom-virtio-spike` → 5844.)

## Result — a full bidirectional exchange on a real VZ boot (macOS 27)

The driver is a **reusable submit/wait/reply API** (`submit()` arms a
caller-owned payload + reply buffer pair on queue 0, `wait()` spins on
the used ring and returns the used length, `reply_read()` copies exactly
that many bytes back out of the reply buffer). One boot runs **four
exchanges with varying reply sizes (8/17/25/33 bytes)** — arbitrary-length
bidirectional transfers, not one fixed shot:

```
cvspike: xchg=1 reply-hex=41 41 41 41 41 41 41 41 n=0x8 cap=0x40
cvspike: xchg=2 reply-hex=42 42 42 42 42 42 42 42 42 42 42 42 42 42 42 42 42 n=0x11 cap=0x40
cvspike: xchg=3 reply-hex=43 43 43 43 43 43 43 43 43 43 43 43 43 43 43 43 43 43 43 43 43 43 43 43 43 n=0x19 cap=0x40
cvspike: xchg=4 reply-hex=44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 n=0x21 cap=0x40
cvspike: irq=1 first=0x45 spi=0x45 armed=0x20..0xbf
```

Each exchange is one two-descriptor chain (Virtio 1.3 §2.7.6: desc 0
device-read payload + desc 1 device-write reply, queue size 2) with a
fixed 64-byte reply buffer; the used ring reports the exact written
length (`n=`) and the guest reads back exactly those bytes as hex. The
host dequeued every payload, wrote the matching reply (byte `0x40+L`
repeated `L` times) into the element's write buffers, and `returnToQueue`
advanced the used ring — with **`len` = the framework's
`writtenByteCount`**. A **real SPI IRQ (INTID 0x45 = SPI 69) entered the
claim-9746 vector and was acked/EOI'd** — the same SPI Linux's virtio1
uses on Apple silicon VMs. Both directions carry data on one element,
repeatedly and with arbitrary sizes.

### Root cause found along the way: the custom device boots with its BAR MMIO disabled

The first obstacle was not the driver — it was that **VZ's firmware never
enables the PCI command register for the custom device**. The standard
virtio devices (console/blk/entropy) boot with command `0x16` (memory
space + bus master + MWI) and their BAR0 windows (0x100000000,
0x100010000, 0x100028000) respond immediately. The custom device boots
with command `0x10` (MWI only), so its BAR0 (0x100020000) is **inert**:
every access — even a read — external-aborts (EC 0x25, DFSC 0x10) even
though the page tables map it and the firmware assigned the address. A
one-boot diagnostic (fault-resume probe across both BARs and all four
devices) isolated the exact correlation: memory-space-enable set ⇔ MMIO
backed. Linux's virtio-pci driver performs this enumeration step
(`pcibios_enable_device`), so real guests never hit it; the kernel's
console/blk drivers never needed it because the firmware pre-enables those
devices.

**Fix (claim 0828):** the custom driver enables the command register
itself — `pci_write32(ecam, bus, dev, 0, 0x04, 0x16)` (the console's exact
value, proven to make BAR0 respond) at the start of `init()`, before the
first common-cfg access. Post-exit config-space writes work on VZ (this
claim's observation; post-exit config reads already worked per claims
1517/6684).

A second wrong turn was reverted: an attempted 32-bit-widened common-cfg
accessor (hypothesized VZ access-size quirk) faulted with **alignment
aborts** on the 16-bit registers at odd offsets (0x16, 0x1e) — Device
memory rejects unaligned 32-bit stores. The console's natural-size
accessors (mmio_read8/16/32) are correct for every virtio device on VZ.

### Evidence (class B, real VZ boot)

Guest serial report (`artifacts/live-cvspike-serial-01.log`), one boot
carrying all four exchanges:

```
cvspike: dev=0x8 did=0x1082 common=0x100020000 notify=0x100024000 qoff=0x0 ready=1
cvspike: xchg=1 reply-hex=41 41 41 41 41 41 41 41 n=0x8 cap=0x40
cvspike: xchg=2 reply-hex=42 42 42 42 42 42 42 42 42 42 42 42 42 42 42 42 42 n=0x11 cap=0x40
cvspike: xchg=3 reply-hex=43 43 43 43 43 43 43 43 43 43 43 43 43 43 43 43 43 43 43 43 43 43 43 43 43 n=0x19 cap=0x40
cvspike: xchg=4 reply-hex=44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 44 n=0x21 cap=0x40
cvspike: irq=1 first=0x45 spi=0x45 armed=0x20..0xbf
```

Every read is **length-driven**: the write descriptor posts a 64-byte
reply buffer, the host writes only `L` bytes, and the guest prints
exactly the `L` bytes the used ring reports (`n=`). `reply_read_len()`
clamps the used length to the descriptor cap (host-tested: 16→16, 0→0,
0xffffffff→cap). Hex output keeps arbitrary contents (including
non-printables) faithfully represented via the kernel's `uart_hex8`.

Host runner stdout (`artifacts/live-cvspike-run-01.txt`), one line per
exchange:

```
CUSTOM-VIRTIO: guest set DRIVER_OK — negotiation complete, queues ready
CUSTOM-VIRTIO: guest notified queue 0 (size 2)
CUSTOM-VIRTIO: dequeued 16 byte(s) (read 16): hex=[44 49 50 53 48 49 54 4f 53 2d 43 56 30 78 34 32] ascii="DIPSHITOS-CV0x42"
CUSTOM-VIRTIO: wrote 8 byte(s) reply into 64 byte(s) of write buffers: hex=[41 41 41 41 41 41 41 41]
CUSTOM-VIRTIO: returned element to queue — used ring advanced, device interrupt asserted
CUSTOM-VIRTIO: dequeued 16 byte(s) (read 16): hex=[44 49 50 53 48 49 54 4f 53 2d 43 56 30 78 34 32] ascii="DIPSHITOS-CV0x42"
CUSTOM-VIRTIO: wrote 17 byte(s) reply into 64 byte(s) of write buffers: hex=[42 42 42 42 42 42 42 42 42 42 42 42 42 42 42 42 42]
CUSTOM-VIRTIO: returned element to queue — used ring advanced, device interrupt asserted
... (4 exchanges: 8/17/25/33-byte replies)
```

Observations worth recording:

- **INTID 0x45 = SPI 69**, matching Linux's virtio devices on Apple
  silicon VMs (virtio1 → SPI 69) — VZ's custom device asserts the same
  SPI class. The 32..191 window arm/disarm (gic.zig) captured it; the
  window is disarmed after the report so the shell runs interrupt-clean.
- **VZ coalesces used-buffer interrupts per burst, not per element:**
  four exchanges (four kicks, four used-ring advances, four reply
  reads) produced **exactly one IRQ** (`irq=1`) at report time — the
  framework asserts the device interrupt once for the burst, and a
  bounded post-loop drain was needed so the report captures it. All four
  replies still delivered reliably; the IRQ is a notification, not a
  per-element ack.
- **The used-ring length is the host's `writtenByteCount`**: an earlier
  single-descriptor run reported `used=1 len=0x0` because the delegate
  wrote nothing; with reply writes it reports the exact written length
  (`n=0x8/0x11/0x19/0x21`) and the guest reads precisely those bytes
  back, sized by that length rather than the fixed buffer
  (`writeBuffersByteCount` on the host side confirms the 64-byte
  window).
- The device's notify cap is 4 bytes at BAR0+0x4000 (mult 4) vs the
  console's 16 bytes (mult 16); the guest kicks queue 0 at
  notify + qoff*mult = notify + 0.

### Gates

- **Class B live:** `verify-custom-virtio.sh` PASS 2/2 (all twelve
  assertions: host DRIVER_OK/notified/dequeued/**replied**/returned,
  guest ready/**four length-driven reply readbacks with varying sizes
  (8/17/25/33)**/irq, pci device present, shell echo alive). The reply
  lines are generated in the gate with a typo-proof hex generator and
  checked all-of via an `all_grep` helper; `zig build spike-virtio`
  greps the exchange reports end-to-end too.
- **No regressions:** `verify-live-timer.sh` PASS (irq=5 poll=0),
  `verify-live-transcript.sh` PASS, `verify-live-exceptions.sh` PASS,
  `verify-unit-tests.sh` PASS, coordination indexes in sync, `zig fmt
  --check` clean, `zig build`/`zig build image`/`swift build -DSPIKE`
  green.
- The gate's `--script-expect` waits for the scripted echo output
  (`cvspike-shell-ok`) rather than the IRQ line: the IRQ report prints
  before the script is forwarded, so expecting it exited the runner before
  `pci`/`echo` were ever sent (observed: pci-device=0 shell-echo=0 on an
  otherwise fully passing boot).

Class A: monitor/shell/transcript/unit suites green (run directly via
`tools/verify-*.sh`; the live transcript run doubles as the standard
console gate and is byte-compatible with the pre-spike transcript).

Evidence under `artifacts/`: `live-cvspike-gate.txt`,
`live-cvspike-report.txt`, `live-cvspike-run-01.txt`,
`live-cvspike-serial-01.log`, `live-cvspike-script.txt`.

## Next steps — all four shipped 2026-08-10 on this branch

1. **Virtqueue ring allocator + multi-queue support** — ✅ claim 4374:
   32-deep split rings, free-list allocator with deterministic
   recycling, two queues, four concurrent in-flight exchanges.
2. **Guest→host payloads beyond 4 KiB / multi-descriptor reads** — ✅
   claim 9492: 12,340-byte payload across three read descriptors,
   reassembled + echoed byte-for-byte.
3. **Feature negotiation depth** — ✅ claim 9737: VZ offers neither
   ANY_LAYOUT nor NOTIFICATION_DATA; VERSION_1 alone negotiates and the
   classic 16-bit kick path carries the whole transport.
4. **Guest console/log transport on the custom device** — ✅ claim
   4837: `cvlog_puts` on queue 1 with host echo + ACK verification.

One cross-cutting root cause found during 4374/9492: **anonymous slice
array literals (`&.{a[0..], b[0..]}`) const-fold into .rodata with baked
link-time pointers**, and the flat kernel loader does not relocate — the
custom device then read image-relative GPAs and `nextElement()` returned
nil on every kick. The fix builds the scatter array in BSS at runtime
(`cv_scatter`), the same class of bug as the claim-0015 vtable and the
`cv_log_lines` slice table.

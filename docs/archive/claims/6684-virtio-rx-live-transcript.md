# Claim: M1.5 — virtio RX path + live-transcript gate (class B live-transcript-rx): host keystrokes reach the kernel end to end

- **Owner:** buffy (`freebuff/pull-git-and-check-status-to-make-sure-everything--9934c25c-63ea-4cf3-b3fb-4b98fb81b9f4`)
- **Prompt / plan:** user request 2026-08-08 — implement the next card: the virtio RX path and the live-transcript gate (class B `live-transcript-rx`) so host keystrokes reach the kernel end to end and a live `dipshit>` session can be asserted from `vm-serial.log`.
- **Scope:** guest RX + host scripted-input plumbing + the class-B gate. Guest: virtio-pci **receive queue (queue 0)** on the already-armed console transport — polled used-ring drain into a bounded FIFO, re-supply + kick, wired into `M15Console.readByte`/`rx_wired`; the shell's WFE idle becomes a bounded poll delay (no interrupts exist to wake WFE). Host: `--script <file>` / `--script-expect <substring>` runner mode (duplex attachment, waits for the guest terminal state, forwards scripted keystrokes, exits 0 iff the expected transcript appears in the log). Gate: `tools/verify-live-transcript.sh` (class B). No allocator/GIC/timer/scheduler/fs/network/graphics; no TX changes (the claim-1517 TX path is byte-identical).
- **Depends on:** claim 1517 (post-MMU virtio TX reliable — T0SZ=16 + TLBI at the switch; the transport is reachable post-MMU, which RX needs), claim 0013 (transport decoded: common/notify/BAR layout, 16-bit notify, aligned-u32 config reads), claim 0002 (VZ serial gate — now passing), claim 0003 (host duplex serial plumbing), claims 0004/0008 (console abstraction + mock transcript), ADR 0004 (polled TX-only console — RX is the missing half)
- **Status:** ✅ done 2026-08-08 — **live RX works end to end on real VZ hardware**: the polled virtio receive queue (queue 0) delivers host keystrokes to the shell, and `bash tools/verify-live-transcript.sh` asserts the live `dipshit>` transcript in `vm-serial.log` — **3/3 boots, byte-identical 4421-byte transcripts** (evidence under `artifacts/live-transcript-*`). Runner gains `--script`/`--script-expect` (non-interactive duplex mode: waits for the guest terminal state, forwards the scripted keystrokes, exits 0 iff the expected reply appears). All class-A gates pass (fmt, 50 unit tests, transcript gate, builds/image/inspect/context, swift build, coordination, test-coordination 15/15, mmu-debt); all class-B gates re-run green (serial gate `zig build run`, bad-handoff `kernel_rc=0x2`, marker `M2_TXST!`, nvram-console, host-console).

## Notes

**Why this card:** the milestone-two console was polled TX-only (ADR 0004);
the shell loop's `readByte` was an [inferred] no-RX stub, so no host
keystroke could reach a live VM. With post-MMU transport access fixed
(claim 1517), the receive side is the last piece between the mock-level
monitor and a real interactive `dipshit>` session — and it unblocks the
class-B `live-transcript-rx` gate (assert the transcript in `vm-serial.log`
on a live VZ run).

**Guest RX design (virtio-console queue 0):**

- Queue 0 is the console receiveq (virtio-console spec: queue 0 = receive,
  queue 1 = transmit). Configure it in `virtio_pci_init` (pre-exit, where
  config-space access is deterministic) between queue 1 and DRIVER_OK:
  select 0, size 1 (power of two), one 256-byte BSS buffer descriptor with
  VIRTQ_DESC_F_WRITE, ring GPA registers written as 32-bit halves (claim
  0013 access-size quirk), queue_enable, read queue 0's notify offset, then
  supply the initial avail entry and kick queue 0 right after DRIVER_OK.
- Polled RX (`virtio_read_byte`): invalidate the used ring line, if the
  device returned the buffer (used.idx advanced) drain it into a bounded
  512-byte FIFO, re-supply the descriptor (clean + kick), pop one byte.
  Never blocks; never allocates.
- `M15Console.readByte`/`rx_wired` dispatch to the virtio RX path when the
  console is virtio (nvram-console builds keep the scripted session).
- The shell's WFE idle wait is replaced by a bounded nop delay for RX-wired
  mode: the device delivers input with no interrupt, so WFE would sleep
  forever and never re-poll.

**Host + gate:** runner gains `--script <file>` and `--script-expect
<substring>`: a non-interactive duplex mode that waits for the guest
terminal state in the serial log, forwards the scripted keystrokes into the
serial attachment, tees guest output to the log, and exits 0 iff the
expected transcript substring appears (timeout/early-stop → 1).
`tools/verify-live-transcript.sh` boots the production image and asserts
the live transcript (banner, `dipshit> help` echo, command output, echo
reply) in `vm-serial.log`.

**Verification (all observed 2026-08-08 on this Apple M4 / macOS 27 VZ host):**

- Class A: fmt, 50 unit tests, transcript gate (mock transcript still
  byte-identical), `zig build`, image, inspect, swift runner build,
  context, coordination, test-coordination (15/15), mmu-debt — all pass.
- Class B: `tools/verify-live-transcript.sh` **3/3 boots PASS** — the
  live session (`help`/`version`/`mem`/`echo rx-live-ok`) shows the
  takeover banner, echoed keystrokes at `dipshit>`, `available
  commands:`, `dipshit-kernel` version output, `mem: descriptors=…` map
  summary, and the `rx-live-ok` echo reply in `vm-serial.log`, with
  byte-identical 4421-byte transcripts per boot. `zig build run` (serial
  gate) still passes (TX unregressed); `verify-bad-handoff.sh`
  (`kernel_rc=0x2`), `verify-marker.sh` (`M2_TXST!`), nvram-console,
  host-console re-run green.
- KERNEL.BIN default build changed with this claim (the RX queue + FIFO
  state were added; TX path unchanged). The runner gained `--script` /
  `--script-expect` (non-interactive scripted-input mode).

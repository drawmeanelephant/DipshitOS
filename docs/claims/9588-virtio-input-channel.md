# Claim: virtio input channel (custom-virtio queue 3)

- **Owner:** virtio (`agent/virtio/virtio-input-channel`)
- **Prompt / plan:** issue #523 item 3 (structured host↔guest control plane, input-injection slice)
- **Scope:** contract-first input channel over the macOS 27 `VZCustomVirtioDevice`:
  (1) wire-format section in `docs/hardware-contract.md`; (2) VMRunner gains an
  input queue and a `--via-virtio` mode for KEY-INJECT/KEY-SEQ/CHORD-SEQ that
  enqueues HID-shaped messages instead of synthesizing NSEvents into a view;
  (3) the guest driver (`kernel/src/virtio_custom.zig`) grows an input-queue
  handler that feeds the existing event FIFO through the same
  `input.decode_keyboard_report` path USB keyboard reports take, so
  `sys_poll_event`/`sys_wait_event` see injected keys as ordinary events;
  (4) live class-B proof: an injected key arrives with `events>0`, headless,
  without CGEvent synthesis and without window activation (#179, #151).
  Serial console stays panic/fallback; loud version detection, no silent
  degradation.
- **Touches:** host/vm-runner/Sources/VMRunner/main.swift kernel/src/virtio_custom.zig kernel/src/main.zig docs/hardware-contract.md tools/verify-live-input.sh
- **Depends on:** claims 0828/4374/4837/9737 (custom-virtio transport + log queue), claim 3141 (host-push rx pattern), claims 4116/6050 (HID report decode path)
- **Heartbeat:** 2026-08-24
- **Status:** 🔄 in progress

Copy to `docs/claims/<NNNN>-<slug>.md`, fill it in, set Status to
`🔄 <branch>` **before** starting work, and commit — the index tables
regenerate on main after merge (`.github/workflows/indexes.yml`); never
commit table churn from a branch. Flip Status to `✅`/`⛔` on completion.

While a claim is 🔄:
- **Touches** is machine-checked: two ACTIVE claims from different branches
  declaring overlapping files fail `verify-coordination.sh`. Keep tokens
  space/comma-free paths.
- **Heartbeat**: commit a heartbeat bump at least every couple of weeks. A
  🔄 claim whose file has no commit for STALE_DAYS (default 14) gets a
  gate warning; past ~21 days anyone may flip it ⛔ via their own branch
  log entry referencing the claim.

The claim number is **not** "next NNNN" — derive it deterministically with
`bash tools/status/claim-id.sh "<branch>" "<slug>"` (kebab-case slug). The
ID is a pure function of branch+slug, so concurrent claimers cannot pick
the same number; claims `0024+` are gate-enforced by
`tools/verify-coordination.sh` (legacy `0001–0023` are grandfathered).

## Notes

Design decisions (binding; the contract doc is normative):

- Queue plan stays "queue count IS the capability signal": plain
  `--custom-virtio` = 2 queues, `--cvc-echo` = 3 (+push echo), `--via-virtio`
  = 4 (+input queue at index 3). Virtqueues are contiguous, so
  `--via-virtio` implies the full shape including the claim-3141 push echo.
- Message format: fixed 16-byte envelope `[kind u8][flags u8][len u16le]`
  + 12-byte payload; kind 1 = raw 8-byte HID keyboard boot report
  (`[mods, 0, k0..k5]`). One message per pre-armed device-write receive
  buffer (the only host→guest data path the SDK exposes — the claim-3141
  virtio-net-RX pattern), pool of 8 buffers replenished per completion.
- Guest decode rides `input.decode_keyboard_report` verbatim — injected keys
  are indistinguishable from XHCI-delivered keys downstream (event FIFO,
  compose, keymap, `input` report counters).
- Proof gate: `GATE_VIRTIO=1 bash tools/verify-live-input.sh` boots HEADLESS
  (no `--display`, no `--input`) and asserts the guest's own
  `input: armed=0 … events=6 kb-usage=0x28 kb-byte=0xa` line — armed=0
  proves no USB keyboard existed; events=6 proves injection arrived over
  virtio. Default invocation of the gate keeps today's behavior.

Verification: zig fmt --check; tools/verify-unit-tests.sh; zig build
test-console; zig build; zig build image; zig build inspect; swift build
(base AND -DSPIKE); verify-coordination.sh + test-coordination.sh; the
proof script's rc=0 with evidence under artifacts/.

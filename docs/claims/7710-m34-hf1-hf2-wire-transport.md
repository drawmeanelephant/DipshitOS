# Claim: M34 HF1+HF2 — host file channel wire + transport, then vf ls/cat

- **Owner:** buffy (`agent/buffy/m34-hf1-hf2-host-file-channel`)
- **Prompt / plan:** M34 (milestone #21) seed issues #735 (HF1) + #736 (HF2);
  tracker `docs/host-file-channel-scoping.md`
- **Scope:** queue 5 wire + transport (VF_PROBE 32 KiB device-write spike,
  `virtio_file.zig` client, pure-Swift `VFWire` module + tests, checked-in
  fixtures) AND the first user surface (`vf ls` / `vf cat` monitor commands,
  host LIST/READ/STAT serving, `verify-live-vf.sh`) — one PR per the seed's
  staffing note.
- **Touches:** kernel/src/virtio_custom.zig, kernel/src/virtio_file.zig,
  kernel/src/monitor.zig, kernel/src/main.zig,
  host/vm-runner/Sources/VMRunner/main.swift,
  host/vm-runner/Sources/VFWire/VFWire.swift, host/vm-runner/Package.swift,
  host/vm-runner/Tests/VMRunnerTests, tests/vf-*.bin, tools/verify-live-vf.sh,
  tools/verify-vf-class-a.sh, tools/verify-unit-tests.sh, justfile,
  docs/hardware-contract.md
- **Depends on:** — (M34 seed PR #742 landed 2026-09-01)
- **Heartbeat:** 2026-09-01
- **Status:** ✅ done

## Notes

**What lands.** `--cvc-file <host-dir>` attaches a sixth virtqueue (queue 5,
deepest flag → implies the full five-queue shape; flag absent = default boot
byte-identical). The guest probes/arms queue 5 (`virtio_custom`), and
`kernel/src/virtio_file.zig` (mirroring fat.zig-on-virtio_blk) provides the
bounded polled client: VF_PROBE (0x00) spike proving a full 32,768-byte
device-WRITE reply (the one unproven transport fact — claim 0680 proved
32 KiB device-reads only), then LIST/READ/STAT for HF2's `vf ls`/`vf cat`.

**Wire (pin).** Request `[op u8][flags u8][len u16le][payload]`, reply
`[status u8][dlen u16le][data]`. The seed's VF_PROBE reply sketch
(`[status][dlen=0x8000][pattern 32768 B]`) is internally inconsistent by 3
bytes (n==32768 asserted while header+32,768-pattern = 32,771); the pinned
shape, baked into the shared class-A fixtures: **reply = exactly 32,768
bytes** = `[status=0][dlen=0x8000][32,765-byte pattern]`, where dlen carries
the 32 KiB capability marker (0x8000) and the pattern generator
`pattern[i] = (i & 0xff) ^ ((i >> 8) & 0xff)` runs over the 32,765 data
bytes. Guest asserts used-length 32768, status 0, dlen 0x8000, full compare
of the data field, RFC-1071 checksum; host asserts write-buffer ≥ 32768 and
writes exactly 32768. File ops use the same framing with dlen = data length.

**Host.** `VFWire` is a pure-Swift module (zero Virtualization imports) with
encode/decode + `resolveSubpath` path defense (rejects `..`, absolute,
symlink escapes) so `VMRunnerTests` can test it without a VM. main.swift
serves queue 5 with FileManager calls rooted at the share dir: VF_PROBE,
LIST (40-byte rows, ≤128), READ-with-offset (stateless, ≤ reply cap), STAT.
Unknown op → status 4 loudly, never hangs; over-cap replies → status 3
(honest truncation).

**Guest surface.** `vf ls [<path>]` / `vf cat <path>` (storage category);
honest "no host file channel" line when queue 5 is absent — default boots
byte-identical. `vf cat` prints the STAT byte count first, then streams via
READ round trips (≥2 for a >32 KiB file), checksumming the stream for the
gate's byte-exact assertion.

**Verification.** Class A: zig fmt/build, `verify-unit-tests.sh`
(MODULES += virtio_file; G1–G6), `swift test` (S1–S4), fixture sha256 pins,
`verify-bss-budget.sh` (11.0 MiB), coordination. Class B:
`tools/verify-live-vf.sh` PASS on VZ — probe line `vf: probe 32k ok
len=0x8000 cksum=…` + runner `VF-PROBE: wrote 32768/32768` + zero failure
counters, then the ls/cat surface against a share holding a >32 KiB fixture.

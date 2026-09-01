# Log — `agent/buffy/m34-hf1-hf2-host-file-channel`

Claim: [4515](../claims/4515-m34-hf1-hf2-wire-transport.md)

## 2026-09-01 — claimed M34 HF1+HF2 (issue #735 + #736, milestone #21)

Per the M34 seed (PR #742, merged 2026-09-01): the guest's user-visible
filesystem becomes a macOS folder served over the custom-virtio device.
HF1+HF2 are deliberately one agent / one PR. Branch created off `origin/main`
after the seed merge; claim 4515 filed; no code yet → 🔄 in progress.

## 2026-09-01 — implemented + verified (class A + class B green)

HF1: `--cvc-file <host-dir>` attaches queue 5 (6 queues, deepest flag),
guest probes/arms it, `kernel/src/virtio_file.zig` lands the bounded polled
client with the VF_PROBE 32 KiB device-write spike (the one unproven
transport fact), and a pure-Swift `VFWire` module + `VMRunnerTests` pin
byte-parity with checked-in fixtures (`tests/vf-*.bin`, sha256-pinned).
HF2: `vf ls` / `vf cat` monitor commands served by host-side LIST/READ/STAT
over FileManager with subpath defense (absolute/`..`/symlink-escape
refused). `verify-vf-class-a.sh` PASS (G1–G6, S1–S4, fixture pins, BSS
budget, coordination) and `verify-live-vf.sh` PASS 1/1 on VZ: probe line
`vf: probe 32k ok len=0x8000 cksum=0x0000 free=0020` + runner
`VF-PROBE: wrote 32768/32768` + 100,000-byte fixture streamed byte-exactly
across 4 READ round trips with the python-computed RFC-1071 checksum
matching. Regressions green: verify-live-virtio-e2e PASS (custom-virtio
control plane unchanged), verify-live-ps PASS (default boot unchanged).
Note: the seed's VF_PROBE reply sketch was internally inconsistent by 3
bytes; the pinned shape is the RAW 32,768-byte pattern reply (no frame —
the transport-only op needs none), documented in the claim, VFWire, and
hardware-contract.md.

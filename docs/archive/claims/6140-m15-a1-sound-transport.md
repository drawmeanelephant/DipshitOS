# Claim: M15 A1 — virtio-snd transport: `--sound` host mode + guest discovery, DID pinned by observation

- **Owner:** buffy (`freebuff/hey-bestie-the-chat-got-lost-so-we-re-so-back-can--53baf792-c2f8-470d-a9f1-6344aa90847a`)
- **Prompt / plan:** `docs/march-m15.md` card A1 (milestone fifteen — audio)
- **Scope:** M15 A1 — the virtio-snd TRANSPORT only (host `--sound` mode, guest device discovery + control-queue arm). PCM playback is card A2.
- **Depends on:** PR #187 (the M15 plan) — merged
- **Status:** ✅ done (2026-08-18)

## What A1 delivers

- **Host** (`host/vm-runner`): a flag-gated `--sound` mode — attaches one
  `VZVirtioSoundDeviceConfiguration` with one
  `VZVirtioSoundDeviceOutputStreamConfiguration` carrying a
  `VZHostAudioOutputStreamSink` (`config.audioDevices`, the SDK's actual
  member name — `soundDevices` does not exist). OFF by default:
  `config.audioDevices = []`, so every existing gate stays byte-identical.
- **Guest** (`kernel/src/virtio_snd.zig`): the virtio-pci sound transport —
  bus-0 discovery (modern DID **0x1059** expected = 0x1040 + device type
  25; transitional 0x1019 also accepted), capability walk
  (common/notify/device-config), feature negotiation
  (VIRTIO_F_VERSION_1), CONTROL queue 0 armed (split ring, size 4),
  DRIVER_OK, and the device-config counts captured pre-exit (claim 0013
  discipline). Post-MMU re-arm (the claim-6420 lesson) + identity-map
  window for the transport BAR.
- **Monitor**: `sound` command — observed DID/class/status/features/queue
  + the captured and fresh-read config counts.

## What was OBSERVED live on VZ (2026-08-18, claim-time)

```
SOUND: virtio-snd attached (1 output stream, host sink)
snd: pre-rearm st=0f          <- NOT reset by VZ (like net/gpu, not blk/entropy)
snd: rearm ok st=0f qoff=0x0
sound: ready
sound: did=0x1059 cls=0x040100 st=0x0f
sound: feats=0x30000000 qsz=4 qoff=0 common=0x100000000 devcfg=0x100001000
sound: cfg=jacks=0 streams=0 chmaps=0 fresh=jacks=0 streams=0 chmaps=0
```

- **DID 0x1059 — the 0x1040+25 prediction HELD.** Class 0x040100 (audio).
- The sound device is **NOT** reset at ExitBootServices (st=0x0f
  pre-rearm), like net/gpu — recorded, not assumed.
- **Finding:** the device-config counts read ALL ZEROS — jacks/streams/
  chmaps 0/0/0 from both the pre-exit firmware map and the post-exit
  identity map, and a 32-byte raw dump of the devcfg window is uniformly
  zero even with TWO output streams attached host-side. VZ's virtio-snd
  emulation does not populate the le32 config counts. Stream topology is
  therefore enumerated in card A2 via the spec-sanctioned CONTROL-queue
  JACK_INFO/PCM_INFO queries, not the config counts. Recorded in the
  module header + `docs/hardware-contract.md`.
- The transport itself is fully healthy: DRIVER_OK (st=0x0f), control
  queue armed (qsz=4, qoff=0), rearm idempotent and successful.

## Verification

- `zig fmt --check` on all touched kernel files; module unit tests green
  (virtio_snd: spec shapes — le32 config at 0/4/8, queue size 4, DID
  constant; unarmed transport reports honestly).
- `zig build` / `zig build image` green; `swift build` (release) green;
  runner codesigned with the virtualization entitlement.
- Live discovery run on VZ: the `sound` monitor output above, `--expect
  "sound:"` PASS (rc=0).
- Gate: `bash tools/verify-live-sound-device.sh` — **PASS 1/1 on VZ**
  (2026-08-18T22:00Z, re-run after the registry-row move; evidence
  `artifacts/live-sound-*`): attach reported, pre-rearm st=0f, rearm ok
  st=0f, DID 0x1059, class 0x040100, DRIVER_OK, qsz=4, cfg 0/0/0.
- Full class-A suite green (fmt, unit tests incl. the two virtio_snd
  tests, test-console byte-identical transcript, build/image/inspect,
  swift build, context, coordination ×2, mmu-debt, glyph-raster,
  mutations).

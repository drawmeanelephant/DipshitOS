# Claim: milestone four card 1 — virtio entropy driver + CSPRNG (real randomness)

- **Owner:** Buffy (`agent/buffy/m4-entropy-csprng`)
- **Prompt / plan:** [`docs/m4-entropy-csprng-prompt.md`](../m4-entropy-csprng-prompt.md)
- **Scope:** milestone four, card 1 — the kernel's first randomness source.
  A modern virtio-pci entropy driver (`kernel/src/virtio_entropy.zig`,
  DID 0x1044) with the claim-6420 post-MMU re-arm lesson, a freestanding
  no-libc ChaCha20 CSPRNG (`kernel/src/csprng.zig`, RFC 7539, KAT-pinned
  in `zig test`), a boot-time 64-byte seed pulled from the real device
  post-MMU (after the allocator arms), the `random [n]` monitor command
  (registry 27→28) with the mock transcript fixture updated deliberately,
  and ONE real consumer of the seed: the exec path (claim 6783) rebuilds
  the EL0 user root with a CSPRNG-randomized user stack VA (ASLR), threaded
  through `mmu.build_user_root` → `scheduler.register_exec_user` →
  `userspace.set_stack_va` → `syscall.set_user_regions`. Also creates the
  milestone-four tracker `docs/march-m4.md` (this card as row 1; general
  filesystem / process abstraction / network as ⬜ sketches) and a pointer
  in `docs/status.md`.
- **Depends on:** milestone-three close-out (merged `main`, PR #68, tag
  `m3-userspace`); the virtio transport patterns of `virtio_blk.zig` /
  `virtio_console.zig` (claim 6420 re-arm lesson), the claim-5804
  `build_user_root` + VZ TTBR1 fallback, the claim-6783 exec rebuild path,
  the registry/transcript-fixture pattern in `monitor.zig`/`shell.zig`,
  and the `pci` command's `[observed]` DID 0x1044 listing.
- **Status:** ✅ done 2026-08-10

## Notes

**Why it matters:** no entropy → no ASLR, no secure randomness, nothing to
seed future protocol work. The device has been present on the bus since
claim 5844's era (`pci` lists DID 0x1044) but no driver exists. The claim
-6420 lesson (VZ resets virtio devices at ExitBootServices — the block
device's status reads 0 post-exit and its queue is dead until re-armed)
is the load-bearing risk for this card: the entropy device is expected to
need the same post-MMU `entropy_rearm`.

**ASLR seam:** the boot-time static EL0 payload's root is built pre-seed
(fixed `userspace.stack_va`), so `live-addrspaces`'s exact-stack-VA
assertion stays green; the exec rebuild (post-seed, runtime) randomizes the
stack VA, and `cmd_addrspaces` reports the current VA truthfully. The
`exec` reply prints `stack=0x…`, so two boots show different placements —
the live non-determinism proof for the consumer as well as `random 32`.

**Honesty:** `entropy: seeded n=64` only when the real device read works;
a failed read prints `entropy: seed failed n=0 (deterministic fallback)`
and the CSPRNG falls back to a fixed key. The live gate requires the REAL
path.

## Verification

- **Class A:** `csprng` + `virtio_entropy` registered in
  `tools/verify-unit-tests.sh`; RFC 7539 KATs (quarter-round state §2.2.1,
  block §2.3.2, 114-byte ciphertext §2.4.2) plus stream/ASLR-helper tests;
  transcript fixture updated for the new `random` help row; full class-A
  set (fmt, unit tests, test-console, build, image, inspect, swift build,
  context, coordination, coordination-tooling, mmu-debt).
- **Class B on VZ:** new `bash tools/verify-live-entropy.sh` — `entropy:
  seeded n=64`, `random: n=32 hex=` (64 hex chars), responsive shell,
  DID 0x1044 present, TWO boots with DIFFERENT `random 32` hex AND
  different exec `stack=0x…` placements. Regressions: exec (the reply line
  still contains `exec: loaded USER.BIN size=` — stack text appended),
  addrspaces, lifecycle, uaccess, svc, userspace, tasks, timer, fs,
  transcript, reboot.
- **Evidence:** `artifacts/live-entropy-*`, `artifacts/m4-entropy-live.txt`.

# Milestone four, card 1 — virtio entropy driver + CSPRNG (real randomness, finally)

- **Branch:** `agent/buffy/m4-entropy-csprng` (claim 2665)
- **Date:** 2026-08-10
- **Depends on:** milestone-three close-out (merged on `main`, PR #68; tag
  `m3-userspace`). Everything below follows patterns already landed.

## The card

The kernel has no randomness source: no entropy driver, no CSPRNG, no ASLR.
The VZ host already attaches a virtio entropy device
(`VZVirtioEntropyDeviceConfiguration`, `host/vm-runner/Sources/VMRunner/main.swift`
line 309) and the guest sees it on bus 0 as `VID=0x1af4 DID=0x1044`
(`[observed]`, listed by the `pci` command) — but no driver exists. Build:

1. **Driver** (`kernel/src/virtio_entropy.zig`): modern virtio-pci transport
   (BAR/common-config, DRIVER_OK, single request queue) that reads real
   random bytes. Follow the claim-6420 lesson: VZ resets virtio devices at
   ExitBootServices — the entropy device is re-armed post-MMU
   (`entropy_rearm`, mirroring `blk_rearm`) before the first read. Handle
   short reads (device may return fewer bytes than requested) with bounded
   retry; cap a single read at 256 bytes.
2. **CSPRNG** (`kernel/src/csprng.zig`): freestanding, no-libc, no-heap
   ChaCha20 stream (RFC 7539). A small in-tree ChaCha20 (block function +
   stream state) keeps the module dependency-free and lets us pin the
   RFC 7539 known-answer test vectors in `zig test` (quarter-round state
   vector §2.2.1, block vector §2.3.2, and the 114-byte cipher vector
   §2.4.2).
3. **Boot-time seed**: post-MMU (after the allocator arms), pull a fixed
   seed (64 B) from the entropy device and key the CSPRNG. A failed read is
   handled honestly — deterministic fallback (`entropy: seed failed n=0
   (deterministic fallback)`), but the live gate requires the REAL device
   path to work (`entropy: seeded n=64`).
4. **`random [n]` monitor command** (registry 27 -> 28): prints `n` random
   bytes as hex from the seeded CSPRNG (bounded 1..256); no-arg prints a
   fixed-size 16-byte sample. Deterministic format, grep-able:
   `random: n=<n> hex=<2n hex chars>`. Update the mock transcript fixture
   deliberately (`help` derives from the registry — the `random` row lands
   in both `kernel/src/shell.zig`'s expected transcript and
   `tests/transcript-console.txt`; no fake diffs).
5. **One real consumer of the seed**: the exec path (claim 6783) rebuilds
   the EL0 user root around a loaded program; the EL0 user stack VA is now
   randomized there from the seeded CSPRNG (page-aligned, 64 KiB placement
   granularity, 256 MiB..2 GiB band clear of `text_va`). The stack VA is
   threaded through `mmu.build_user_root` → `scheduler.register_exec_user`
   (sp_el0) and the uaccess stack region follows via
   `userspace.set_stack_va` + `syscall.set_user_regions`. The `exec` reply
   prints `stack=0x…`, so two boots show different placements (the live
   gate's non-determinism proof for the consumer too). The boot-time static
   payload keeps the fixed `userspace.stack_va` (its root is built
   pre-seed), so `live-addrspaces`'s exact-stack-VA assertion is untouched.
6. **Tracker**: create `docs/march-m4.md` mirroring march-m3's structure
   with this card as row 1 and rows for the roadmap's other later-milestone
   items (general filesystem, process abstraction, network) as ⬜ sketches;
   add a pointer in `docs/status.md`'s related docs. This prompt doc lives
   at `docs/m4-entropy-csprng-prompt.md`.

## Design

### `kernel/src/csprng.zig`

- ChaCha20 core: 16×u32 state; constants `0x61707865 0x3320646e 0x79622d32
  0x6b206574`; quarter round (a+=b; d^=a; d<<<16; c+=d; b^=c; b<<<12;
  a+=b; d^=a; d<<<8; c+=d; b^=c; b<<<7); 10 double rounds (column + diagonal
  per RFC §2.3); add original state; serialize little-endian.
- Stream state: key `[32]u8`, nonce `[12]u8`, counter `u32` (starts at 1),
  64-byte keystream buffer, buffered counter, `seeded` flag.
- `seed(seed_bytes: *const [64]u8)`: key = bytes[0..32], nonce =
  bytes[32..44], counter = 1 | (le32(bytes[44..48]) & 0x7fffffff); then
  consume 16 bytes of stream (bytes[48..64] whitening) — all 64 seed bytes
  are used.
- `seed_fallback()`: deterministic all-zero key + fixed nonce (honest
  fallback; the live gate proves the real path).
- `random_bytes(out: []u8)` / `random_u64()` / `seeded()`.
- `random_stack_va()`: ASLR helper — fixed default when unseeded; else
  `0x1000_0000 + (random_u64() % slots) * 0x1_0000` for
  `slots = (0x8000_0000 - 0x1000_0000) / 0x1_0000`.
- Tests: RFC 7539 KATs — §2.2.1 quarter-round state, §2.3.2 block, §2.4.2
  114-byte ciphertext; stream continuity across block boundaries; seed
  determinism; `random_stack_va` bounds (in-band, page/64 KiB aligned,
  clear of text_va).

### `kernel/src/virtio_entropy.zig`

- Mirrors `virtio_blk.zig`: pre-exit discovery (DID 0x1044 on bus 0, BAR +
  virtio caps walk, feature negotiation accepting `VIRTIO_F_VERSION_1`,
  queue 0 = single request queue, size 4, DRIVER_OK) + post-MMU re-arm.
- `entropy_rearm()`: the claim-6420 lesson — VZ resets the device at
  ExitBootServices (status reads 0 post-exit), so the transport is
  re-initialized post-MMU before the first read. Unconditional (idempotent
  reset → re-init) so the driver works whether or not VZ reset it.
- `entropy_read(out: []u8) bool`: `out.len <= entropy_read_max` (256);
  loops with bounded retries, each iteration submitting one WRITE
  descriptor for the remaining bytes, polling the used ring (cache-
  invalidated), taking `used_elem.len` bytes (short reads advance the
  cursor and retry), cleaning/invalidating as the console/blk drivers do.
  Queue GPAs translated with `mmu.to_phys` (claim 5804).
- BAR0 (`ent_bar0`) is handed to `mmu.build_identity_map` as an extra
  Device window (like console/block/custom), so post-MMU MMIO reaches the
  transport.
- Host tests (no device): request layout/ring shapes, cap/bounds, honest
  not-ready failures.

### main.zig wiring

- Pre-exit (next to `virtio_blk_init`): `const ent_ready =
  virtio_entropy.virtio_entropy_init();` (discovery; no `st` needed).
- `extra_windows` grows 3 → 4; entropy BAR0 window added when `ent_ready`.
- Post-allocator seed (after `alloc.init`): re-arm, read 64 B, key the
  CSPRNG, print the seed line. That is the only takeover-path change.

### `random` monitor command

- Registry row `random` (help: "print n random bytes from the seeded
  CSPRNG (hex)", usage `random [n]`, `max_args = 1`), between `pci` and
  `reboot` alphabetically; `registry_count` 27 → 28.
- Output: `random: n=<count> hex=<hex>`; bounds 1..256; `parseInt` errors
  reported like `beans`; unseeded still prints (fallback key) but the live
  gate proves the real path.

### ASLR consumer (exec path)

- `userspace.zig`: `current_stack_va` runtime global (default `stack_va`),
  `set_stack_va` / `user_stack_va`; `stack_va_region()` uses the current VA.
- `exec.zig`: `stack_va = csprng.random_stack_va()`; `set_stack_va`;
  `build_user_root(..., stack_va, ...)`; `register_exec_user(entry_va,
  stack_va)`; re-`set_user_regions` so uaccess bounds follow; reply prints
  `stack=0x…`.
- `scheduler.register_exec_user(entry_va, stack_va)`: sp_el0 =
  stack_va + user_stack.len.
- `cmd_addrspaces` prints `userspace.user_stack_va()` (truthful after exec;
  identical before it, so `live-addrspaces` stays green).

### Live gate `tools/verify-live-entropy.sh`

Class B, 2 boots (the non-determinism proof). Script:
`pci\nrandom 32\nexec USER.BIN\necho rx-entropy-ok` — forwarded after the
static payload's exit (`tasks user-el0 exited status=7`), expect the exec
reap (`tasks user-exec reaped`). Per boot:
- `entropy: seeded n=64` in vm-serial.log,
- `random: n=32 hex=` present with exactly 64 hex chars extracted,
- exec reply contains `stack=0x` (the ASLR consumer's placement),
- shell responsive (`rx-entropy-ok`), no `[EXC] parking:`,
- `pci` lists `DID=0x0000000000001044` (device present).
Across the two boots: the `random 32` hex differs AND the exec stack VA
differs. Evidence saved under `artifacts/live-entropy-*` + `m4-entropy-live.txt`.

## Do not

- Touch `main.zig`'s takeover path beyond the seed call, or the syscall ABI
  (ADR 0007).
- Claim `[observed]` hardware behavior without a saved VZ log under
  `artifacts/`.
- Use a `const` function-pointer table anywhere new (ADR 0005).
- Add libc/POSIX/heap allocation.
- Hand-edit generated indexes (`refresh-indexes.sh` only).

## Process (hard gate)

1. Claim before you start (🔄): claim 2665 in `docs/claims/`, log in
   `docs/logs/agent-buffy-m4-entropy-csprng.md`, `refresh-indexes.sh`.
2. Write the plan (this document), then implement driver + CSPRNG +
   command + seed.
3. Class A: `zig fmt --check`, unit tests (register `csprng` +
   `virtio_entropy` in `tools/verify-unit-tests.sh`), `zig build
   test-console`, `zig build`, `zig build image`, `zig build inspect`,
   `swift build --package-path host/vm-runner`, `zig build context`,
   `bash tools/verify-coordination.sh`,
   `bash tools/status/test-coordination.sh`,
   `bash tools/verify-mmu-debt.sh`.
4. Class B live gate `tools/verify-live-entropy.sh` (registered in
   `docs/gate-inventory.md` + `just verify-vz`): boot the VM, assert the
   entropy path, save under `artifacts/live-entropy-*`.
5. Reconcile docs: `docs/status.md`, `docs/roadmap.md` (Entropy sketch ->
   done), `docs/hardware-contract.md` (entropy bullet: driver + seed path
   `[observed]`), `docs/march-m4.md`, README command count 27 -> 28.
   Append the log, flip the claim to ✅, refresh indexes, open the PR.
6. `bash tools/verify-coordination.sh` green before opening the PR.

## Definition of done

`random` served by a REAL virtio-entropy device on VZ (live gate 2/2,
non-deterministic across boots), a ChaCha20 CSPRNG with RFC 7539 KAT
coverage, one real consumer of the seed (exec-path EL0 stack ASLR), all
class A + class B gates green, `docs/march-m4.md` created, docs reconciled,
claim closed, PR open.

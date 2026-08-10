# Log — milestone four card 1: virtio entropy driver + CSPRNG (claim 2665)

- **Branch:** `agent/buffy/m4-entropy-csprng`
- **Claim:** [`docs/claims/2665-m4-entropy-csprng.md`](../claims/2665-m4-entropy-csprng.md)
- **Started:** 2026-08-10

## Progress

- **Claimed** (2026-08-10): claimed milestone-four card 1 (entropy driver +
  CSPRNG + seed + `random` command + one real ASLR consumer) on
  `agent/buffy/m4-entropy-csprng` with claim 2665. Plan written to
  `docs/m4-entropy-csprng-prompt.md` before any code. Depends on the
  milestone-three close-out (`main` @ PR #68, tag `m3-userspace`).

- **Survey** (2026-08-10): read the binding inputs — `AGENTS.md`,
  `docs/status.md`, `docs/roadmap.md` (Entropy/CSPRNG sketch),
  `docs/hardware-contract.md` (entropy bullet: DID 0x1044 `[observed: present
  on bus, no driver yet]`), `docs/gate-inventory.md`, `docs/march-m3.md`
  (tracker format to mirror), `kernel/src/virtio_blk.zig` +
  `virtio_console.zig` (transport, queue, DRIVER_OK, post-MMU re-arm),
  `kernel/src/pci.zig`, `kernel/src/monitor.zig` (registry 27 + transcript
  fixture pattern), `docs/decisions/0007-syscall-abi.md`. Design decisions:
  in-tree ChaCha20 (RFC 7539) rather than `std.crypto` (keeps the module
  dependency-free and KAT-pinnable); unconditional post-MMU `entropy_rearm`
  (idempotent reset → re-init, works whether or not VZ reset the device at
  ExitBootServices); exec-path ASLR (boot static payload keeps the fixed
  stack VA so `live-addrspaces` stays green); `random: n=<n> hex=<2n hex>`
  grep-able output format; RFC vectors taken from the RFC 7539 body
  (§2.2.1 quarter-round state, §2.3.2 block, §2.4.2 114-byte ciphertext).

- **Implemented** (2026-08-10): `kernel/src/csprng.zig` (freestanding
  ChaCha20, RFC 7539 — block function + stream state; 64-byte seed all
  used: key = bytes[0..32] with bytes[48..64] folded in, nonce =
  bytes[32..44], counter = 1 | le32(bytes[44..48]); KATs pinned in `zig
  test`: §2.2.1 quarter-round state, §2.3.2 block vector, §2.4.2
  114-byte ciphertext — all green; plus stream-continuity, fallback,
  and ASLR-placement tests). `kernel/src/virtio_entropy.zig` (pre-exit
  discovery of DID 0x1044 + BAR/caps walk + VERSION_1 + queue 0 size 4 +
  DRIVER_OK; post-MMU `entropy_rearm` mirroring `blk_rearm`;
  `entropy_read` with short-read retry, 256-byte cap, cache discipline;
  `ent_status` for the pre-re-arm observation). main.zig: pre-exit init,
  entropy BAR0 as a 4th extra Device window, and the post-allocator seed
  call (`entropy: pre-rearm st=..` / `entropy: seeded n=64`). Monitor
  `random [n]` (registry 27→28, `random: n=<n> hex=<2n hex>`, bounds
  1..256) + unit test. Transcript fixtures updated (shell.zig expected
  string + tests/transcript-console.txt — one `random` help row; the
  fixture's mixed CRLF/LF endings preserved byte-exactly). ASLR consumer:
  exec rebuilds the user root with `csprng.random_stack_va()` (band
  256 MiB..2 GiB, 64 KiB granularity), threaded through
  `build_user_root` → `register_exec_user(sp_el0)` →
  `userspace.set_stack_va` → `syscall.set_user_regions`; `cmd_addrspaces`
  prints the current stack VA; the `exec` reply prints `stack=0x…`.
  Registered `csprng` + `virtio_entropy` in `tools/verify-unit-tests.sh`;
  new class-B gate `tools/verify-live-entropy.sh`; gate-inventory +
  justfile (`verify-vz`) entries.

- **Live observation — the claim-6420 lesson applies to entropy too**
  (2026-08-10): `entropy: pre-rearm st=00` in `vm-serial.log` — VZ resets
  the entropy device at ExitBootServices exactly like virtio-blk; the
  post-MMU re-arm restores DRIVER_OK and the seed read delivered 64 real
  bytes (`entropy: seeded n=64`). The live gate's two boots produced
  DIFFERENT `random 32` hex and different exec stack VAs — genuine
  non-deterministic entropy and a working ASLR consumer.

- **Verification** (2026-08-10): class A all green (fmt incl. user/src,
  unit tests with the two new modules, transcript byte-identical, build,
  image, inspect, swift build, context, coordination, coordination-
  tooling, mmu-debt). Class B on VZ: new live-entropy gate **PASS 2/2**
  (evidence `artifacts/live-entropy-*`, `artifacts/m4-entropy-live.txt`)
  plus regressions all 1/1: exec, sleep, addrspaces, svc, uaccess,
  userspace, lifecycle, tasks, timer, transcript, fs, reboot.

- **Docs reconciled** (2026-08-10): claim 2665 + this log; new tracker
  `docs/march-m4.md` (row 1 done; general filesystem / process abstraction
  / network as ⬜ sketches) + status.md milestone-four row + related-docs
  pointer + command count 27→28; roadmap Entropy sketch → done;
  hardware-contract entropy bullet → driver + seed path `[observed]`;
  README command count + new modules + entropy-gate bullet; gate inventory
  `live-entropy` row + record + verify-vz; indexes refreshed;
  `verify-coordination.sh` green.

## Claim 3693 — extend ASLR to the boot-time static EL0 payload

- **Claimed** (2026-08-10): follow-on card — rebuild the user root
  post-seed with a randomized stack VA so the BOOT-time static EL0 payload
  (not just exec'd programs) gets per-boot stack ASLR. Claim file
  `docs/claims/3693-m4-aslr-boot-stack.md`; same branch, PR #69 absorbs it.

- **Survey** (2026-08-10): confirmed the seams — `register_user` derives
  sp_el0 + the timer-preemption witness via `userspace.bss_user_va`
  (the one place the boot stack base is consumed); `uaccess.diag` reads
  the registered TEXT region (re-setting regions post-rebuild is hygiene
  for sys_write, not required by the diag); the table carve-out is 1 MiB
  (256 tables) so one extra post-seed clone at boot is trivially safe;
  the `.userbss` witness/stack offsets are base-relative, so changing only
  the base preserves every relationship. The `live-addrspaces` gate's
  exact-stack-VA assertion (`stack=0x0000000080000000`) is the one gate
  that must change.

- **Implemented** (2026-08-10): `userspace.bss_user_va` now uses
  `current_stack_va` (the randomized base) instead of the const
  `stack_va`; main.zig, right after the claim-2665 seed, rebuilds the user
  root with `csprng.random_stack_va()` when the CSPRNG is genuinely seeded
  (`mmu.build_user_root` with the static text pages + `scheduler
  .user_stack_phys()` + `clean_table_storage`, then re-arm
  `syscall.set_user_regions`), printing `aslr: boot user stack=0x…`; an
  unseeded (fallback) boot skips the rebuild and keeps the fixed stack.
  `tools/verify-live-addrspaces.sh` updated: text VA stays fixed, the
  stack VA is extracted and validated in-band/aligned/≠ text instead of an
  exact match. `tools/verify-live-entropy.sh` extended: per-boot capture of
  the `aslr:` boot stack VA, asserted to differ across the two boots.

- **Verification** (2026-08-10): class A green (fmt, unit tests, transcript
  byte-identical, build/image/inspect, swift build, context, coordination,
  mmu-debt). Class B on VZ: updated live-addrspaces 1/1 (randomized stack
  in band), extended live-entropy 2/2 (different boot stack VAs + random
  hex), and boot-payload regressions 1/1: userspace, svc, uaccess, exec,
  sleep, lifecycle.

- **Docs reconciled** (2026-08-10): claim 3693 + this log; march-m4 row 1
  note extended (boot-time ASLR); status milestone-four row; indexes
  refreshed; `verify-coordination.sh` green.

- **Closed** (2026-08-10): claim 3693 flipped ✅. Note: PR #69 (claim
  2665) had already been merged into `main` before this follow-on landed,
  so the claim-3693 commit is carried on the same branch and opened as a
  fresh follow-on PR (only the new commit, since `main` already contains
  `f905ac4`). Full class A rerun green; live gates + boot-payload
  regressions all green (see Verification above).

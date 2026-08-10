# Milestone four march — real randomness (living tracker)

## Where we are

> [`docs/status.md`](status.md) is the canonical source for milestone-level
> facts, current gates, and what comes next. This file holds only
> milestone-four's per-card detail and collision-free agent split, following
> the same status/tracker boundary as [`docs/march-m3.md`](march-m3.md)
> (closed 2026-08-10, tag `m3-userspace`). Claim work first
> (`docs/claims/`), append to the branch log (`docs/logs/`), and link saved
> evidence before changing a row to `✅`.

Milestone four is the first post-milestone-three stream: the kernel's first
real randomness source (virtio entropy + CSPRNG), which unlocks ASLR and
anything that needs secure random bytes. Later-milestone items from
[`docs/roadmap.md`](roadmap.md) (general filesystem, process abstraction,
network) are sketched below as ⬜ rows so the tracker shows the whole
milestone-four horizon.

Legend: ⬜ not started · 🔄 in progress · ✅ done · ⛔ blocked (note why).

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| 1 | **Virtio entropy driver + CSPRNG (real randomness).** A modern virtio-pci entropy driver (DID 0x1044) with the claim-6420 post-MMU re-arm lesson, a freestanding ChaCha20 CSPRNG (RFC 7539, KAT-pinned), a boot-time 64-byte seed from the real device, the `random [n]` monitor command, and one real consumer of the seed (exec-path EL0 stack ASLR). | ✅ done | [Claim 2665](claims/2665-m4-entropy-csprng.md); prompt: [m4-entropy-csprng-prompt](m4-entropy-csprng-prompt.md) | Landed 2026-08-10: `kernel/src/virtio_entropy.zig` (pre-exit discovery, post-MMU `entropy_rearm` — VZ resets the device at ExitBootServices, observed `pre-rearm st=00` — 256-byte capped reads with short-read retry), `kernel/src/csprng.zig` (ChaCha20, RFC 7539 §2.2.1/§2.3.2/§2.4.2 KATs in `zig test`, 64-byte seed all used), boot seed post-allocator (`entropy: seeded n=64`), `random [n]` (registry 27→28), and exec-path ASLR (the loaded program's stack VA is CSPRNG-randomized per boot; the `exec` reply prints `stack=0x…`; uaccess regions follow). New class-B gate `tools/verify-live-entropy.sh` **PASS 2/2** — two boots produced DIFFERENT `random 32` hex AND different exec stack VAs (evidence `artifacts/live-entropy-*`, `artifacts/m4-entropy-live.txt`); all shared-seam live regressions green (exec/sleep/addrspaces/svc/uaccess/userspace/lifecycle/tasks/timer/transcript/fs/reboot). |
| 2 | **General (non-ESP) filesystem.** The claim-6420 FAT32 storage driver serves the ESP's FAT volume; a general filesystem (arbitrary disk layout, directories, file API beyond the ESP window) remains future work (roadmap). | ⬜ sketch | — | Not started — a later milestone-four card, only after the items above it are demonstrably working. |
| 3 | **Process abstraction.** A process object above the fixed task pool (address space, state, exit/reap, loader) — the milestone-three task lifecycle is the seam (claims 6729/6783). | ⬜ sketch | — | Not started — roadmap "Eventually" item. |
| 4 | **Network stack.** No networking today (the runner attaches none; ADR/AGENTS milestone rules forbid it). | ⬜ sketch | — | Not started — roadmap "Eventually" item; needs the process abstraction first. |

## Best agent split

| Agent / lane | Owns | Sequence / collision rule |
|--------------|------|---------------------------|
| **Buffy — card 1** | The entropy/CSPRNG lane: `kernel/src/{virtio_entropy,csprng}.zig`, the seed call in `main.zig`, `random` in `monitor.zig`, the exec-path ASLR seams (`userspace`/`scheduler`/`exec`), `tools/verify-live-entropy.sh`, `docs/march-m4.md`, `docs/status.md`, `docs/gate-inventory.md`, `docs/hardware-contract.md`, `docs/roadmap.md`. | **Complete 2026-08-10 (claim 2665)** — driver + CSPRNG + seed + command + ASLR consumer landed; live gate 2/2; docs reconciled. |

Merge through short-lived PR branches per ADR 0003. Before starting any lane,
create its deterministic claim and branch log, refresh the generated indexes,
and check the active claims again; the split above is an ownership plan, not a
substitute for the repository's one-editor-per-file rule.

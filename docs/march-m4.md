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
anything that needs secure random bytes, and the process abstraction above
the task pool (the program's image + address space + lifecycle + exit status
as one object). Later-milestone items from [`docs/roadmap.md`](roadmap.md)
(general filesystem, network) are sketched below as ⬜ rows so the tracker
shows the whole milestone-four horizon.

Legend: ⬜ not started · 🔄 in progress · ✅ done · ⛔ blocked (note why).

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| 1 | **Virtio entropy driver + CSPRNG (real randomness).** A modern virtio-pci entropy driver (DID 0x1044) with the claim-6420 post-MMU re-arm lesson, a freestanding ChaCha20 CSPRNG (RFC 7539, KAT-pinned), a boot-time 64-byte seed from the real device, the `random [n]` monitor command, and one real consumer of the seed (EL0 user-stack ASLR — exec'd programs AND the boot-time static payload). | ✅ done | [Claim 2665](claims/2665-m4-entropy-csprng.md), [Claim 3693](claims/3693-m4-aslr-boot-stack.md); prompt: [m4-entropy-csprng-prompt](m4-entropy-csprng-prompt.md) | Landed 2026-08-10: `kernel/src/virtio_entropy.zig` (pre-exit discovery, post-MMU `entropy_rearm` — VZ resets the device at ExitBootServices, observed `pre-rearm st=00` — 256-byte capped reads with short-read retry), `kernel/src/csprng.zig` (ChaCha20, RFC 7539 §2.2.1/§2.3.2/§2.4.2 KATs in `zig test`, 64-byte seed all used), boot seed post-allocator (`entropy: seeded n=64`), `random [n]` (registry 27→28). **ASLR consumer (claim 2665 + follow-on claim 3693):** the exec path rebuilds the user root with a CSPRNG-randomized stack VA, and the boot-time static EL0 payload's root is rebuilt post-seed too (`aslr: boot user stack=0x…`, covering the full `.userbss` section so the timer-preemption witness stays mapped) — EVERY EL0 task gets per-boot stack ASLR. New class-B gate `tools/verify-live-entropy.sh` **PASS 2/2** — two boots produced DIFFERENT `random 32` hex, DIFFERENT exec stack VAs, and DIFFERENT boot-time stack VAs (evidence `artifacts/live-entropy-*`, `artifacts/m4-entropy-live.txt`); `verify-live-addrspaces.sh` updated to assert the randomized stack is in-band instead of an exact value; all shared-seam live regressions green (exec/sleep/addrspaces/svc/uaccess/userspace/lifecycle/tasks/timer/transcript/fs/reboot). |
| 2 | **General (non-ESP) filesystem.** The claim-6420 FAT32 storage driver serves the ESP's FAT volume; a general filesystem (arbitrary disk layout, directories, file API beyond the ESP window) remains future work (roadmap). | ⬜ sketch | — | Not started — a later milestone-four card, only after the items above it are demonstrably working. |
| 3 | **Process abstraction.** A process object above the fixed task pool (address space, state, exit/reap, loader) — the milestone-three task lifecycle is the seam (claims 6729/6783). | ✅ done | [Claim 3848](claims/3848-process-abstraction.md); prompt: [m4-process-abstraction-prompt](m4-process-abstraction-prompt.md) | Landed 2026-08-10: **`kernel/src/process.zig`** — a bounded BSS registry (8 descriptors, no allocation) where each Process owns the loaded image (entry VA + content length), the address space (root phys, text/stack VAs), the lifecycle state (created → running → exited), and the **exit status (snapshotted at exit — it survives the executor task's reap)**; `create` takes the first free slot, else recycles the oldest exited. **Real consumers:** `exec_file` creates + binds a process (its sticky module globals are gone; `loaded()` reads the current process; `ExecResult.process_full` for the exhausted registry), the boot-time static EL0 payload registers as a process too, `exit_current` notifies the registry (exception-context safe), and the shell idle loop prints the process exit report (`procs <name> exited status=<n>`). **Observability:** the `procs` command (registry 28→29) prints the table — `procs: id=… name=… state=… task=… stack=0x… exit=…`, exited rows showing `task=reaped` with the kept status. New class-B gate `tools/verify-live-procs.sh` **PASS 1/1 on VZ**: the exec'd USER.BIN is a process (`state=running` with its ASLR stack VA) alongside the boot payload's `state=exited task=reaped exit=7`, and `procs USER.BIN exited status=43` prints with the unchanged task lifecycle (evidence `artifacts/live-procs-*`); live-exec + tasks/userspace/lifecycle/svc regressions green. |
| 4 | **Network stack.** No networking today (the runner attaches none; ADR/AGENTS milestone rules forbid it). | ⬜ sketch | — | Not started — roadmap "Eventually" item; needs the process abstraction first. |

## Best agent split

| Agent / lane | Owns | Sequence / collision rule |
|--------------|------|---------------------------|
| **Buffy — card 1** | The entropy/CSPRNG lane: `kernel/src/{virtio_entropy,csprng}.zig`, the seed call in `main.zig`, `random` in `monitor.zig`, the exec-path ASLR seams (`userspace`/`scheduler`/`exec`), `tools/verify-live-entropy.sh`, `docs/march-m4.md`, `docs/status.md`, `docs/gate-inventory.md`, `docs/hardware-contract.md`, `docs/roadmap.md`. | **Complete 2026-08-10 (claim 2665)** — driver + CSPRNG + seed + command + ASLR consumer landed; live gate 2/2; docs reconciled. |
| **Buffy — cards 2 + 3** | The general-filesystem lane (claim 3678, PR #71 — volume/path generalization + second on-disk partition, `mount`/`ls [dir]`/`cat <path>`) and the process-abstraction lane: `kernel/src/process.zig`, the exec/scheduler seams, `procs` in `monitor.zig`, `tools/verify-live-procs.sh`, `docs/march-m4.md`, `docs/status.md`, `docs/gate-inventory.md`, `docs/roadmap.md`. | Card 2 lands via PR #71 (merge pending). **Card 3 complete 2026-08-10 (claim 3848)** — process object + registry + exec/boot-payload consumers + `procs` command; live gate 1/1; docs reconciled (PR #72). |

Merge through short-lived PR branches per ADR 0003. Before starting any lane,
create its deterministic claim and branch log, refresh the generated indexes,
and check the active claims again; the split above is an ownership plan, not a
substitute for the repository's one-editor-per-file rule.

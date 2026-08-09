# AGENTS.md — rules for working in this repository

These rules bind any AI agent or human contributor working in this project.

## Project identity

- This is a from-scratch AArch64 operating system project.
- It runs on Apple silicon (macOS), hosted by Apple's
  Virtualization.framework. It is **not Linux, not Unix, and not QEMU**:
  no emulator, no libc, no POSIX, and no existing guest OS anywhere in the
  boot path.
- It must not depend on libc, POSIX, or an existing guest operating system.
- The guest implementation language is Zig; the host launcher is Swift.

## Current milestone

Milestones zero, one, two, and 1.5 are implemented (1.5 — the interactive
kernel monitor — closed and tagged `m1.5-interactive-monitor` on
2026-08-09; milestone two's VZ serial gate passes since 2026-08-08, claim
1517). The current stream is **milestone three's first cards**: the
physical page allocator is done (claims 3972/5162), GIC + timer interrupts
are programmed but IRQ delivery is blocked on VZ (claim 7948), and tasks
come after interrupts.
`docs/status.md` is the canonical, always-current answer to "where are we,
and what's next".

## Milestone scope rules

- Do not implement work from later milestones.
- Do not introduce libc or POSIX.
- Do not add a kernel during milestone zero. *(Historical — milestones
  zero and one are complete; a kernel has existed since milestone two.)*
- Do not add graphics, networking, SMP, processes, or filesystems.
- Host-side observation devices (serial console, a framebuffer used only to
  screenshot the guest, the BOOTED.TXT evidence file) are permitted and are
  not "graphics" or "filesystem" milestones; guest-side graphics, network,
  or storage stacks remain out of scope.
- Milestone zero ends at: a Zig-compiled AArch64 UEFI application boots
  from `EFI/BOOT/BOOTAA64.EFI` on a FAT image and prints its message.

## Evidence rules

- State what was directly observed versus inferred. Never present a guess
  as a result.
- Run available verification before claiming success. Save command output
  and logs under `artifacts/`.
- Do not fabricate successful command output. If a dependency or platform
  capability is unavailable, complete everything else and report the
  precise blocked step.

## Documentation rules

- Record hardware assumptions in `docs/hardware-contract.md`.
- Record important design choices as architecture decision records under
  `docs/decisions/`.
- Keep `docs/status.md` current: it is the canonical "where we are" answer,
  updated whenever a gate passes, fails, or a milestone completes. Other
  docs link to it instead of duplicating status prose.
- Keep `README.md` and `docs/testing.md` honest about what was observed.

## Repository tooling

- `tools/ragshit/` is a host-side context engine (local SQLite+FTS5 index,
  deterministic LLM-context bundles, no network calls). It is developer
  tooling, not guest software, and counts toward no milestone.

## Multiagent coordination rules

Multiple agents and humans develop this repo, sometimes in parallel. The
full coordination setup (per-claim files, per-branch logs, conventions)
lives under `docs/claims/`, `docs/logs/`, and `docs/status.md`; the binding
rules are:

- **Claim before you start.** Non-trivial work gets a claim file under
  `docs/claims/` (copy `docs/claims/TEMPLATE.md`) and a log entry in
  `docs/logs/<branch>.md` before code is written. Claimed work is not
  duplicated by other agents.
- **One editor per file at a time.** If two agents need the same file, the
  second waits or merges through the integration branch — never edit the
  same file (e.g. `kernel/src/main.zig`) concurrently.
- **The changelog is append-only, one file per branch.** Logs live under
  `docs/logs/` so parallel appends cannot collide. Never rewrite or delete
  entries; corrections are new entries referencing the old one.
- **Indexes are generated, not edited.** The claim and log index tables
  in `docs/claims/README.md` and `docs/logs/README.md` are generated from
  the claim/log files by `bash tools/status/refresh-indexes.sh` — run it
  after creating a claim file or branch log; never hand-edit a shared
  table. Run `bash tools/verify-coordination.sh` (`just
  verify-coordination`, also CI) before opening a PR; it fails on index
  drift or malformed claim/log files.
- **Update on completion and on blockers.** Flip your claim file's status
  and append a log entry when done; append one when blocked so the next
  agent does not repeat the attempt.
- **Doc edits go through `docs/status.md`.** Milestone-level status prose
  lives there; other docs link to it. Prefer pointer-level changes to other
  docs; claims and logs live in their own sharded files.

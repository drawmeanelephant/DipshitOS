# AGENTS.md — rules for working in this repository

These rules bind any AI agent or human contributor working in this project.

## Project identity

- This is a from-scratch AArch64 operating system project.
- It runs on Apple silicon running macOS 27 or newer, hosted by Apple's
  Virtualization.framework. It is **not Linux, not Unix, and not QEMU**:
  no emulator, no libc, no POSIX, and no existing guest OS anywhere in the
  boot path.
- It must not depend on libc, POSIX, or an existing guest operating system.
- The guest implementation language is Zig; the host launcher is Swift.

## Current milestone

Milestones zero through twelve are implemented and closed (boot pipeline;
kernel handoff; kernel proper — VZ serial gate since claim 1517;
`m1.5-interactive-monitor`; `m3-userspace`; `m4-processes`; milestone five
networking — virtio-net through TCP; milestone six graphics — Road Pops +
Driving Award; milestone seven input — USB XHCI + HID; milestone eight
usability — ADR 0008; milestone nine app events — ADR 0009; milestone ten
userland storage — ADR 0010; milestone eleven desktop platform — ADR 0011;
milestone twelve userland network applications — ADR 0012). Milestone
thirteen — **files & applications** — has all four cards live 2026-08-16
(claims 5801/8877/4742/4046): the mutating filesystem seam (ADR 0007
slots 34–37), the `APPS.TXT` application manifest, the `FILE.BIN` file
browser, and manifest-driven desktop composition. The current stream is
**milestone fourteen — shared user services** (planned 2026-08-16,
issues #175–#178, per `docs/march-m14.md`): S1 clipboard (slots 38–39),
S2 app timers (slots 40–41), S3 composition capstone, S4
security/isolation hardening. Known open threads: M8 U4 pointer focus is
class-C-only for its live proof (issue #151, claim 4769), and the
synthesized keyboard seam reports `events=0` (issue #179). For the
canonical, always-current answer to "where are we, and what's next", read
`docs/status.md`.

## Milestone scope rules

- Do not implement work from later milestones.
- Do not introduce libc or POSIX.
- Do not add a kernel during milestone zero. *(Historical — milestones
  zero and one are complete; a kernel has existed since milestone two.)*
- Do not add graphics, networking, SMP, processes, or filesystems.
  *(Historical — the allocator (claims 3972/5162), exception vectors (9746),
  and the guest-side FAT32 storage driver on the ESP (claim 6420) all
  landed post-tag; the list is the milestone promise.)*
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

- **One worktree per agent.** Concurrent agents never share a checkout.
  Create yours with `just new-agent <name> <slug>` (worktree at
  `../dipshitos-<name>`, branch `agent/<name>/<slug>` off `origin/main`),
  reattach later with `just resume-agent`, clean up with `just drop-agent`.
  Each worktree has its own `.build/` and `artifacts/`, so builds and
  class-B VM gates cannot collide. Claim and log from inside your own
  worktree. Shared-checkout staging leaks caused PR #524's false
  coordination failure; claim 2564 made the gate immune to it, worktrees
  remove the entire class.
- **Claim before you start.** Non-trivial work gets a claim file under
  `docs/claims/` (copy `docs/claims/TEMPLATE.md`) and a log entry in
  `docs/logs/<branch>.md` before code is written. Claimed work is not
  duplicated by other agents. Declare the files you will edit in
  `- **Touches:**` and bump `- **Heartbeat:**` while 🔄: the gate fails
  when two ACTIVE claims from different branches declare overlapping
  files, and warns when a 🔄 claim has had no commit for 14+ days (past
  ~21 days, anyone may flip it ⛔ via their own branch log entry).
- **One editor per file at a time.** If two agents need the same file, the
  second waits or merges through the integration branch — never edit the
  same file (e.g. `kernel/src/main.zig`) concurrently.
- **The changelog is append-only, one file per branch.** Logs live under
  `docs/logs/` so parallel appends cannot collide. Never rewrite or delete
  entries; corrections are new entries referencing the old one.
- **Indexes are generated at merge time — never by your branch.** The
  claim and log index tables in `docs/claims/README.md` and
  `docs/logs/README.md` are generated from the git-tracked claim/log files,
  but since claim 2599 **branches do not regenerate or commit them**:
  `.github/workflows/indexes.yml` owns both tables after merge (the single
  serialized writer of a shared
  derived artifact). Committing table churn from a branch is what made
  those two files collide on nearly every near-simultaneous merge; don't
  reintroduce it. Branch protection forbids direct pushes, so after every
  merge the workflow opens (or updates) one **auto-merge regeneration PR**
  (`indexes/bot-regenerate`) instead of pushing to main — tables land a few
  minutes later, through the normal required checks. A local `bash tools/status/refresh-indexes.sh` (`just
  refresh-indexes`) is an optional preview of what the table will look
  like — do not commit its output. The coordination gate judges tracked
  files only, so other agents' untracked staging files in a shared checkout
  cannot fail your PR. Run `bash tools/verify-coordination.sh`
  (`just verify-coordination`, also CI) before opening a PR; it fails on
  malformed claim/log files and structurally broken tables, not on index
  drift (a branch's committed indexes are stale by design).
- **Index-region merge conflicts: resolve by regeneration.** If you hit a
  textual conflict inside a generated index region (legacy branches,
  rebases onto old mains), do not hand-resolve rows: take either side
  wholesale (`git checkout --ours/--theirs <file>`), optionally run
  `bash tools/status/refresh-indexes.sh` to preview correctness, and
  commit — or simply drop the hunk entirely; the bot regenerates the truth
  on main after merge.
- **Update on completion and on blockers.** Flip your claim file's status
  and append a log entry when done; append one when blocked so the next
  agent does not repeat the attempt.
- **Doc edits go through `docs/status.md`.** Milestone-level status prose
  lives there; other docs link to it. Prefer pointer-level changes to other
  docs; claims and logs live in their own sharded files.

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

Milestones zero through **thirty-two** are implemented and closed — the boot
pipeline; kernel handoff; kernel proper (VZ serial gate since claim 1517);
`m1.5-interactive-monitor`; `m3-userspace`; `m4-processes`; milestone five
networking — virtio-net through TCP; milestone six graphics — Road Pops +
Driving Award; milestone seven input — USB XHCI + HID; milestone eight
usability — ADR 0008; milestone nine app events — ADR 0009; milestone ten
userland storage — ADR 0010; milestone eleven desktop platform — ADR 0011;
milestone twelve userland network applications — ADR 0012; milestone
thirteen files & applications (ADR 0007 slots 34–37, the `APPS.TXT`
manifest, `FILE.BIN`, manifest-driven desktop); milestone fourteen shared
user services (clipboard, app timers, hardening); milestone fifteen audio;
milestone sixteen kernel consolidation; milestone seventeen desktop
completeness plus the post-M17 arcs; M18 terminal & shell depth; M19 shell
as a programming environment; M20 text rendering & Unicode; M21 window
management depth; M22 developer tools; M23 the text editor; M24 CALC grows
up; M25 file manager depth; M26 network experience; M27 desktop polish &
completeness; M28 SMP; M29 VM depth (demand paging, COW, anonymous mmap);
M30 dynamic linking & shared libraries (`LD.SO`, `LIBUI.SO`, `LIBFONT.SO`);
M31 the dynamic linking ecosystem (dynamic desktop apps, `dlopen`/
`dlsym`); and M32 the WM server migration (WMS1–WMS9, issues #621–#629).

All GitHub milestones are closed and the issue tracker is at **zero open
issues** (2026-08-28); the two long-running threads are resolved — the M8 U4
pointer-focus proof is now class-B-headless via custom-virtio pointer
injection (claim 9367, issue #151), and the synthesized-keyboard `events=0`
report is fixed by the headless virtio input channel (claims 9588/0680,
issue #179). The project is now **VirelaiOS** (ADR 0017 ACCEPTED 2026-08-31,
issue #676 — the DipshitOS name is retired to `docs/archive/dipshitos-name.md`
and history). **M33 (seam B — full pixel ownership) done 2026-08-31**
(SB1–SB6: ADR 0016 ACCEPTED, shared-anon mmap, surface handoff, damage
tracking, WM compose-N, perf payoff — GH milestone 17 closed); **M34
(FAT-free storage — the host file channel, issue #727) done 2026-09-02 —
GH milestone 21 closed 8/8** (HF1–HF7, PRs #745/#747/#749/#792/#806/#816,
including the HF7 CLONE COW dedup work); M35 (WASM core) done 2026-09-02
(6/6, GH milestone 22). The open flake tracked: #810 (boot-probe S1PTW
walk window; self-decoding instrumentation + claim 9094). For the
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

## Host toolchain sanity check (source me first)

This repo's build + gate scripts assume the **modern Homebrew builds** of the
Unix toolchain. macOS still ships 2007-era GNU bash 3.2 under `/bin/bash` and
BSD sed under `/usr/bin/sed`; non-interactive agents frequently get PATH with
`/usr/bin`/`/bin` in front of `/opt/homebrew/bin`, so `bash`/`sed` silently
resolve to the old system versions and the gates misbehave in confusing ways.

**Before starting any work in a fresh session, run:**

```bash
source tools/env-check.sh        # or: just check-env; or: bash tools/env-check.sh
```

It ensures `$HOMEBREW_BIN` leads PATH, verifies the resolved `bash`/`sed`/
`jq`/`yq` are the modern builds, and prints a very loud red complaint (returning
non-zero) when the system versions win. Fix with
`brew install bash gnu-sed jq yq &&` fix PATH, then re-source. Safe and
idempotent — run it from your login/agent startup once per session.

## Multiagent coordination rules

Multiple agents and humans develop this repo, sometimes in parallel. The
full coordination setup (per-claim files, per-branch logs, conventions)
lives under `docs/claims/`, `docs/logs/`, and `docs/status.md`; the binding
rules are:

- **One worktree per agent.** Concurrent agents never share a checkout.
  Create yours with `just new-agent <name> <slug>` (worktree at
  `../virelaios-<name>`, branch `agent/<name>/<slug>` off `origin/main`),
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

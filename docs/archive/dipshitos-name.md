# The DipshitOS Name — Memorial & Historical Record

> *"Rien ne se perd, rien ne se crée, tout se transforme."*
> *(Nothing is lost, nothing is created, everything is transformed.)*
> — **Antoine-Laurent de Lavoisier**, *Traité Élémentaire de Chimie* (1789)

This file is the project's own record of the name it retired. It lives in
`docs/archive/` on purpose: archived history is protected by design, so the
name remains findable here long after it stops appearing anywhere live.

## The name

**DipshitOS.** The project's name from its first commit, `a022fea`
(2026-08-05), until the rename commit that landed on 2026-08-31 — **834
commits, 341 merged pull requests, and milestones zero through thirty-three**
under the old name: the UEFI boot pipeline, the kernel proper, the interactive
`dipshit>` monitor, userspace, processes, the full IPv4/TCP stack, graphics
and the Driving Award window manager, USB input, shared user services, audio,
SMP, demand paging and COW, dynamic linking, and the WMS window-server
migration.

The name was a joke on purpose. The engineering was not. The tell was the
evidence discipline: every byte gated on real hardware, every claim
deterministically numbered, every log append-only. A repository that named its
environment checker's rant "YOU ARE ABOUT TO RUN THE WRONG TOOLS, YOU
MAGNIFICENT IDIOT" and then made that checker *enforce* the correct toolchain
was always serious underneath.

## What it stood for

- **No libc, no POSIX, no emulator.** A from-scratch AArch64 operating system
  booting real UEFI firmware on Apple silicon through
  Virtualization.framework.
- **Rule 1: directly observed, never inferred.** Never present a guess as a
  result. The name was profane; the accounting was not.
- **The boot transcript that never lies.** `dipshit>` — eight bytes wide —
  was the prompt whose exact-byte transcript gates kept the whole machine
  honest, and the new name keeps the same rhythm: `virelai>` is the same
  width, so the gates never skipped a beat.

## Where the name survives

The sweep that retired it was deliberate about what stays:

- **This file** — `docs/archive/dipshitos-name.md` (protected by ADR 0017).
- **`docs/archive/**`** — archived milestone trackers, prompts, claims, logs,
  and ragshit evidence, untouched by design.
- **Historical claims & logs** — `docs/claims/**`, `docs/logs/**`: every
  claimed task and branch log written before the rename keeps its original
  text.
- **ADRs 0001–0016** — the architecture decision record ledger, untouched.
- **`tools/ragshit/CHANGELOG.md`** — the context engine's own history.
- **GitHub URLs and the repository slug** —
  `github.com/drawmeanelephant/DipshitOS`, the Pages URL, and badges stay
  `DipshitOS` until the repo itself is renamed.
- **Git history itself** — 834 commits of commit messages, diffs, and gate
  logs that say the old name out loud.

## The successor

The rename went to **VirelaiOS**, and the conservation epigraph enacted
itself on the name: the letters were conserved, only the arrangement was
transformed. **VIRELAIOS is an exact anagram of LAVOISIER** — a virelai being
a medieval French *forme fixe* built on a returning refrain, which is fitting
for a project whose refrain is a gate that returns on every merge.

## Inscription

> DipshitOS: the elephant has left the building — but the beans were always
> counted, the gates were always green, and the name is still here whenever
> anyone wants to remember the joke that held the engineering up.

**Rest easy, old name. The transcript reads on.**

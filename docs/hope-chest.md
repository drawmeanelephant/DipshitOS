# The hope chest → the road to M99

> **This is a map, not a promise.** The 20-item maintainer wishlist at the
> end of [`roadmap.md`](roadmap.md) is the source of truth — *destinations*,
> not commitments. This file arranges the wishlist's **remaining** items and
> the distant-mountain list into a tiered road map so agents can see what
> the next gas stations are and how far each one is from the M99 peaks.
> Milestone numbers here are **tentative**; a number freezes only when a
> `march-mNN.md` tracker + GitHub issues exist for it (the M14 precedent).
> No agent should see a mountain here and buy climbing gear — the
> wishlist's own warning applies to every tier below.

## The metaphor

- **Tucson** = right now. M8–M13 are shipped; M14 S1–S3 (clipboard, timers,
  composition capstone) are done and only S4 hardening remains. The
  immediate miles are M14 S4, then the first genuinely *new* subsystem
  after it (audio).
- **Gas stations** = the milestones between here and the peaks. Each one has
  cards, a live gate, and — per the roadmap meta-requirement — **a small
  program or experience that consumes it**. A gas station with no consuming
  experience is a rest stop, not a destination.
- **California** = the mid-far destination where DipshitOS stops being a
  "kernel with demos" and becomes a **self-hosted weird little computer**:
  it can install apps over its own network, and it can rebuild and run its
  own programs on itself.
- **Japan** = M99, the far peaks: SMP, 3D, dynamic linking, POSIX-ish
  compatibility, browser-grade networking, USB-everything, and self-hosting
  the full toolchain. These are "keep visible, do not climb yet" — listed so
  nobody thinks we forgot them.

## The map at a glance

| Tier | Milestone (tentative) | Wishlist item | What it delivers | Consuming experience |
|---|---|---|---|---|
| Tucson | **M14** — shared user services | 11, 12, 19 | Clipboard, app timers, composition, hardening | NOTEPAD copy/paste with a timer-driven cursor |
| Tucson | **M15** — audio | 18 | A sound device + PCM pipeline + a note engine | A boot jingle; a piano you can *play* |
| Crossing | **M16** — resource-model cleanup | 13 | Dynamic kernel objects where the fixed pools hurt | Run past the pool walls without a reboot |
| Crossing | **M17** — richer VM | 14 | Guard pages, bigger programs, mmap-ish primitives | A program that outgrows today's page budget |
| Crossing | **M18** — executable formats + linking | 15 | DSK1 → structured/ELF, shared libraries | NOTEPAD and CALC sharing `ui.zig` as a library |
| Crossing | **M19** — filesystem depth | 17 | Atomic-ish updates, corruption handling, beyond FAT32 | A settings write that survives power loss |
| California | **M2x** — the self-hosted desktop | (composes 13–18) | On-device build loop + network-installed apps | A third-party app none of us wrote |
| Japan | **M99** — the far peaks | 20 | SMP, 3D, dynamic linking, POSIX, TLS-grade networking, USB-everything, full self-hosting | "DipshitOS is a computer" |

---

## Tier 1 — Tucson (immediate miles)

### M14 — shared user services *(S1–S3 done, S4 planned; issues #175–#178)*

S1 clipboard (ADR 0007 slots 38–39), S2 app timers (slots 40–41 posting
`TIMER` events on the ADR 0009 queue), and S3 the composition capstone are
landed (claims 2611/5390/0120) — NOTEPAD copy/paste + timer cursor proven
TOGETHER live on VZ. S4 security/isolation hardening remains. See
[`march-m14.md`](march-m14.md).

### M15 — audio *(proposed; wishlist 18)*

The first genuinely new device/service pipeline after M14, and the one the
wishlist calls "fun, and another real device/service pipeline." Apple's
Virtualization.framework exposes a virtio-sound device configuration
(`VZVirtioSoundDeviceConfiguration`) — **[inferred] until observed on VZ,
like every device DID before it.** Sketch of the ladder, honest bounds
included:

- **A1 — device discovery + PCM transport.** Find the sound device, map its
  queues, observe the reset-at-ExitBootServices behavior (the
  claim-6420/2665 lesson — each device is different), and post a fixed-BSS
  PCM buffer. `sound` monitor command.
- **A2 — a bounded mixer + tone engine.** A fixed-rate PCM ring and a
  square/sine note generator; `beep`/`tone <hz> <ms>` commands. No heap, no
  DMA scatter — one bounded buffer like every other device.
- **A3 — the consuming experience.** A boot jingle (two notes on boot) and
  `PIANO.BIN` — a tiny EL0 app that plays notes from M9 `KEY_DOWN` events,
  so a keyboard makes noise. Live gate: honest about the evidence channel —
  VZ exposes no host-side audio capture by default, so the gate asserts
  device/PCM/`tone` state (`sound: played hz=440 n=…`) until a capture route
  is found; the route search is recorded in `hardware-contract.md`, not
  faked.

---

## Tier 2 — the crossing to California (mid-term gas stations)

These are the wishlist's "let real apps create the pressure first" items.
Each is ordered by the dependency it sits on; none should start before the
pressure is actually felt, and each must name its consumer.

### M16 — resource-model cleanup *(wishlist 13)*

The fixed pools (windows, processes, mailboxes, net state, event queues,
file handles) are the project's proudest invariant — grow them only when a
real app hits the wall. The gate is the reverse of today's `pool_full`
tests: **run enough apps/windows to exhaust a pool, then grow that pool
dynamically and watch the same workload succeed.** Not a rewrite; a
pressure-driven relaxation.

### M17 — richer VM *(wishlist 14)*

Guard pages, programs bigger than the current page budget, and mmap-ish
primitives. The consuming experience: a program (or image) that today would
be refused for size loads and runs, and a memory-mapped read of a large file
replaces the read-all-then-copy path. COW and demand paging stay *later*
(they are Japan-tier).

### M18 — executable formats + dynamic linking *(wishlist 15)*

The DSK1 flat-image model has carried every program so far; the pressure
point is **shared code** — today NOTEPAD, CALC, TOP, FILE, and DESKTOP each
carry their own copy of `ui.zig`'s raster logic. The gas station is a
structured/ELF loader plus a bounded dynamic-linker story so those five apps
share one `ui` library. The consuming experience: link `ui.zig` once and
drop every app's image size. ADR 0002's DSK1 header stays frozen until this
card is actually claimed.

### M19 — filesystem depth *(wishlist 17)*

Atomic-ish updates, truncation/delete/rename already landed in M13 (B1);
what remains is corruption handling and the beyond-FAT32 question. The
consuming experience: a settings/config write that is visibly safe across a
power loss, and (if the pressure appears) a second volume format behind the
same file-handle ABI so apps never notice the switch.

---

## Tier 3 — California (the self-hosted desktop)

**M2x — DipshitOS builds and runs its own programs.** The destination that
the whole trajectory (userland FS → network apps → manifest → launcher →
clipboard/timers) has been aiming at:

1. **A network-installed app story.** FETCH (M12) already retrieves bytes
   over TCP; the launcher (M11) already runs programs; the manifest (M13)
   already names them. Wire them together: download a `.BIN` + a manifest
   line, install to `/data/`, and it appears in DESKTOP. The consuming
   experience: `install http://…/SNAKE.BIN` then run it.
2. **An on-device build loop.** Edit → build → run without leaving the
   machine. This is the real stress test of the app boundary: if compiling a
   program needs a kernel change, the boundary is wrong (wishlist item 4's
   test, applied to the toolchain).
3. **A third-party app none of us wrote.** The proof that the platform is
   real: someone outside the project writes a program against ADR 0007 and
   the ui.zig toolkit, and it just runs.

California is **not** a single PR — it is the moment the last gas station
(M16–M19) makes self-hosting feel inevitable rather than heroic.

---

## Tier 4 — Japan (M99 — the far peaks)

Keep visible, do not climb yet. M99 is a symbolic label for the distant
mountains in wishlist item 20 plus the hardest of the rest, not a literal
99-step ladder. In rough order of "most likely to become real first":

- **Dynamic linking done well** (the M18 first step, taken all the way:
  versioned shared libraries, lazy binding, a real loader).
- **SMP** — the boot CPU owns the world today; a second CPU is a scheduler,
  MMU, GIC, and locking rewrite, not an increment.
- **USB-everything** — mass storage and more device classes beyond the two
  HID devices M7 enumerated; the xHCI transport is already the hard half.
- **Sophisticated VM** — demand paging, COW, swap, more flexible mappings.
- **3D acceleration** — the virtio-gpu 2D path stays the only path until a
  real 3D workload demands the device's 3D command set.
- **Browser-grade networking** — TLS, HTTP/2/3, a real URL/security stack.
- **POSIX-ish compatibility** — only if it ever earns its keep; the project
  explicitly is *not* POSIX and this stays a deliberate choice, not a
  default.
- **Full self-hosting** — the Zig toolchain compiling DipshitOS on
  DipshitOS, closing the loop California started.

## What we deliberately do *not* do on the way

- No new syscall numbers without an ADR 0007 amendment (M14 already books
  slots 38–41; the next free slot after M14 is 42).
- No heap in the kernel or the toolkit; no libc; no POSIX; no QEMU path.
- No milestone-sized work from a later tier until the pressure is observed
  live, per `AGENTS.md` scope rules.

## Open threads to clear while driving

These are not cards, but they sit on the road and should be resolved before
relying on the gates they touch:

- **Issue #179** — the synthesized keyboard seam reports `events=0` in the
  guest event ring (observed during the M13/pointer work). Confirm no
  session dependency before live *input* gates are trusted.
- **Issue #151 / U4** — M8's pointer live proof is class-C-only (real mouse
  via `tools/verify-pointer-manual.sh`); the VZ synthesized-pointer wall is
  root-caused (claim 4769) but not crossed.
- **Stale M13 claim bookkeeping** — claim files `4046`/`2223`/`8877`/
  `4742`/`5801`/`5776` still read `🔄 in progress` though their PRs merged;
  flip them and regenerate the indexes before opening the next claim.

## Wishlist accounting (all 20 items)

| # | Wishlist item | Where it lives |
|---|---|---|
| 1 | M8 usability consolidation | ✅ M8 (U0–U8) |
| 2 | Interactive EL0 events | ✅ M9 (E0–E6) |
| 3 | Userland app support layer | ✅ M11 A1 (`ui.zig`) |
| 4 | Several small GUI apps | ✅ M11 (CALC/NOTEPAD/TOP/DESKTOP) |
| 5 | Userland filesystem access | ✅ M10 (F0–F4) |
| 6 | Graphical file browser | ✅ M13 B3 (`FILE.BIN`) |
| 7 | Userland TCP/network API | ✅ M12 (N1) |
| 8 | DNS | ✅ M12 (N2) |
| 9 | Application identity/metadata | ✅ M13 B2 (manifest) |
| 10 | A launcher | ✅ M11 A5 (`DESKTOP.BIN`) |
| 11 | Clipboard | ✅ M14 S1 |
| 12 | Timers/events for apps | ✅ M14 S2 |
| 13 | Resource-model cleanup | 🗺️ M16 (proposed) |
| 14 | Richer VM | 🗺️ M17 (proposed) |
| 15 | Executable-format evolution | 🗺️ M18 (proposed) |
| 16 | Reusable UI toolkit | ✅ M11 A1 (`ui.zig`) |
| 17 | Better FS semantics | 🗺️ M19 (proposed) |
| 18 | Audio | 🗺️ M15 (proposed) |
| 19 | Security/isolation hardening | 🚧 M14 S4 |
| 20 | Distant mountains (SMP/3D/POSIX/…) | 🏔️ Japan / M99 |

> Legend: ✅ shipped · 🚧 planned · 🗺️ mapped here · 🏔️ keep visible, do not
> climb yet.

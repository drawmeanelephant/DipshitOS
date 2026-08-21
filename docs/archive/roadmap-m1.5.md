# Roadmap archive — Milestone 1.5 — interactive kernel monitor (the Dipshit Monitor)

> **Archived 2026-08-21** from `docs/roadmap.md` (issue #264, claim 2860):
> the milestone is complete; this file preserves its roadmap plan/detail
> verbatim as history, not an active work order. Canonical status:
> [`docs/status.md`](../status.md).
>
> Also archived here: the "M1.5 close-out" bullet that lived under the old
> `Later milestones (sketches only, not commitments)` section.

---

## Milestone 1.5 — interactive kernel monitor (implemented 2026-08-09)

> **Scope frozen 2026-08-06.** The next deliverable is an interactive
> command monitor served by the kernel's own polled serial console — not
> further kernel-proper plumbing first.

Named **Milestone 1.5, the "Dipshit Monitor"**: boot into a terminal,
display a banner, accept commands at `dipshit>`, and execute at least ten
useful commands (identity, memory-map inspection, shell utilities, and
machine controls). Milestone two's kernel already owns the console and
never returns; the monitor is its terminal-loop payload. It promises no new
allocator, MMU work, interrupts, scheduler, or userspace. *(Post-tag, the
allocator, exception vectors, and — claim 6420 — a guest-side FAT32
storage driver on the ESP landed anyway; the milestone's promise list is
historical.)*

**Progress as of 2026-08-08:** the host plumbing (duplex serial attachment,
terminal handling, `zig build console`), console & shell core (RX abstraction,
line editor, tokenizer, `dipshit>` prompt loop), command registry (20 commands,
mock-tested), and transcript test gate (`zig build test-console`) are all
✅ done and gate-passing in CI. The MMU-takeover death is fixed (claim 0010),
the console is identified (virtio-pci, claim 0013), the NVRAM console
channel carries post-exit bytes (claim 0015), and — since claim 1517 — the
**VZ serial gate passes** (`zig build run`: post-MMU virtio TX lands the
banner + `dipshit>` prompt in `vm-serial.log`), and **live RX is wired**
(claim 6684: the polled virtio receive queue delivers host keystrokes end
to end — `verify-live-transcript.sh` asserts the live `dipshit>`
transcript in `vm-serial.log`), and the **live reboot/shutdown
observation is done** (claim 0527: `reboot` resets the machine, `shutdown`
powers it off — 4/4 boots via `verify-live-reboot.sh`), and the
**filesystem gate is closed** (claim 3475, 2026-08-09: `ls`/`cat`/`write`
persist through reboot via the pre-exit ESP snapshot + NVRAM-persisted
writes, `verify-live-fs.sh` — the ESP file window, registry now 20
commands) **and upgraded the same day to a real FAT32 storage driver**
(claim 6420: `ls`/`cat`/`write` read and write the live ESP's FAT volume
through a virtio-blk transport; files persist on the disk itself;
NVRAM variables are no longer the persistence medium). **Closed
2026-08-09: all 7 hard gates pass; the milestone is tagged
`m1.5-interactive-monitor`.** Current gate
state: [`docs/status.md`](../status.md).

The M1.5 hard gates, target screen, and milestone status live in
**`docs/status.md`** (the living status document); the twenty-step plan,
agent split, and per-step progress tracker lived in
**`docs/archive/march-m15.md`** (M1.5 closed 2026-08-09, tagged
`m1.5-interactive-monitor`; the active per-milestone tracker is
**`docs/march-m3.md`**). The monitor itself is implemented and
host-tested (console abstraction, line editor, tokenizer, 20 commands,
banner, mock-level transcript gate), and the host-side `--console`
plumbing landed (steps 4–7); the VZ serial gate **passes** (claim 1517 —
post-MMU virtio TX fixed with T0SZ=16 + TLBI at the switch), the **RX
path is live** (claim 6684 — the polled virtio receive queue delivers
host keystrokes; the live `dipshit>` transcript is asserted in
`vm-serial.log` by `verify-live-transcript.sh`), a **live
reboot/shutdown is observed end to end** (claim 0527:
`verify-live-reboot.sh` — `reboot` resets the machine, `shutdown` powers
it off), and the **filesystem gate is closed** (claim 3475, 2026-08-09:
`ls`/`cat`/`write` persist through reboot via the pre-exit ESP snapshot +
NVRAM-persisted writes, `verify-live-fs.sh`, 1/1 pair) **and upgraded to
a real FAT32 storage driver** (claim 6420: the ESP's FAT volume is
mounted and written through a virtio-blk transport, files persist on the
disk itself). **The milestone is closed 2026-08-09: all 7 M1.5 hard
gates pass; tagged `m1.5-interactive-monitor`** (see
[`docs/status.md`](../status.md)).

---

## Later-milestones close-out bullet (archived verbatim)

- ~~**M1.5 close-out: milestone tag (all hard gates now pass).**~~ **DONE
  2026-08-09 (tag `m1.5-interactive-monitor`)** — the transport layer is
  **done**: post-MMU TX (claim 1517: T0SZ=16 + TLBI at the switch),
  **live RX** (claim 6684: the polled virtio receive queue delivers host
  keystrokes end to end — `verify-live-transcript.sh` asserts the live
  `dipshit>` transcript in `vm-serial.log`), the **live reboot/shutdown
  observation** (claim 0527: `verify-live-reboot.sh` — `reboot` resets
  the machine, `shutdown` powers it off, 4/4 boots; `ResetSystem`
  unit-proven in claim 0011), and the **filesystem gate** (claim 3475:
  `ls`/`cat`/`write` persist through reboot via the pre-exit ESP snapshot
  + NVRAM-persisted writes, `verify-live-fs.sh`, 1/1 pair — the last
  previously-deferred hard gate) **upgraded to a real FAT32 storage
  driver** (claim 6420: the ESP's FAT volume is mounted + written through
  a virtio-blk transport; files persist on the disk; NVRAM is no longer
  the persistence medium). **All 7 hard gates pass; milestone closed.**
  *(The milestone-three cards continue in the Milestone three section
  above; canonical ordering: `docs/status.md`.)*

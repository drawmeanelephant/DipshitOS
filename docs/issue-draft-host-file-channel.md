# Issue draft: Host file channel — FAT-free storage (HF1+HF2 first slice)

Copy-paste body for the GitHub issue. Full design: `docs/host-file-channel-scoping.md`.

---

## Summary / Goal

The guest should stop using FAT32 for anything user-visible. The only FAT
left is the ESP boot volume — parsed by Apple's firmware pre-exit, never
touched by guest code after boot. End-state: the guest's user-visible
filesystem is a **macOS folder** served over the existing custom-virtio
device (DID 0x1082); `fat.zig`, the DATA partition, the post-exit
virtio-blk path, and the embedded-apps image machinery are deleted.

**This issue scopes the first slice: HF1+HF2 as one PR** — the vertical
proof that the whole idea works. It lands the host file channel end to end
(`--cvc-file <dir>` → queue 5 → guest client → `vf ls`/`vf cat`) with a
live class-B gate. Pays off early: it is the first PR of a deletion story,
and every later card rides this transport.

## Milestone / scheduling — pull this forward

Repo state at filing: **M32 complete (2026-08-30)**; M33 seam B (pixel
ownership, `docs/march-m33-seam-b-pixel-ownership.md`, ADR 0016) is in
flight. This issue seeds a **proposed M34 — FAT-free storage**, and the
maintainer wants it worked **sooner than other pending items**: seam B is
MMU/compositor, this is storage — no shared code, so the two tracks don't
coordinate. Staff **HF1+HF2 first** (deliberately sized as one agent /
one PR). One coordination note: HF1's queue-5 probe/arm edits
`kernel/src/virtio_custom.zig`, so it must claim while no other agent sits
on that file (single-editor rule).

## In scope (this PR)

- **Host:** `--cvc-file <host-dir>` runner flag — attach a sixth virtqueue
  (queue 5) to the custom-virtio device. Queue count stays the capability
  signal (a deeper flag implies the full shape below it; the flag absent =
  default boot byte-identical).
- **Wire protocol** (normative section in `docs/hardware-contract.md`):
  request `[op u8][flags u8][len u16le][payload]`, reply
  `[status u8][dlen u16le][data]`; ops LIST / READ / STAT; **READ carries
  an explicit offset** so big files stream statelessly (the host holds zero
  state between requests — an untrusted guest cannot leak host fds);
  directory rows reuse ADR 0010's 40-byte `DirEntry` shape; caps — path ≤
  255, reply ≤ 32 KiB (the proven snapshot chunk size; the full-cap
  device-write reply is an explicit HF1 validation case, not an
  assumption), LIST ≤ 128 entries; honest truncation (report the cap,
  never silently truncate). Version byte in the framing from day one.
- **Guest:** `virtio_custom.zig` probes/arms queue 5 (`file_qidx`,
  `has_file_queue`); new `kernel/src/virtio_file.zig` client (pure,
  host-testable encode/decode; bounded polled transport on queue 5 with the
  claim-0680 chain-free discipline); monitor commands `vf ls [<path>]` and
  `vf cat <path>` (storage category; honest "no host file channel" line when
  queue 5 is absent).
- **Host service:** queue-5 delegate serves LIST/READ/STAT via Swift
  `FileManager` rooted at the share directory, with traversal defense
  (reject `..`, absolute paths, symlink escapes).
- **Tests:** guest-side wire encode/decode (zig test, `virtio_file` added
  to `tools/verify-unit-tests.sh`); host wire code extracted into a pure
  `VFWire` Swift module + new `VMRunnerTests` target, fixture-driven
  byte-parity locks on both sides (full list: HF1 acceptance case B); new
  class-B gate `tools/verify-live-vf.sh`; new `tools/verify-vf-class-a.sh`
  hook (fixture sha256 + both test suites).
- **Docs:** hardware-contract.md wire section; claim + branch log per the
  coordination rules; status.md post-milestone landing line.

## Out of scope (later cards, per `docs/host-file-channel-scoping.md`)

- Mutation ops (OPEN / CLOSE / WRITE / TRUNCATE / RENAME / MKDIR / DELETE /
  FSYNC — handles ride in here, where cursors earn their keep) — HF3
- App delivery from the host folder (drop a `.ELF`, exec it; the
  image-rebuild loop dies) — HF4
- User-data migration (`/data` deprecation; settings, notepad, downloads,
  screenshots → host folder) — HF5
- FAT removal (delete `fat.zig` + post-exit virtio-blk path + DATA
  partition; slim the image to a boot volume; gate fleet to one shared
  read-only boot image) — HF6
- CLONE → `clonefile` COW dedup + the ZFS-backed-share option (the worktree
  workload) — HF7
- Never: full virtio-fs/FUSE, a custom guest filesystem, guest-side
  block-level dedup (rationale in the scoping doc's out-of-scope section).

## Acceptance gate

- **Class A:** `zig fmt --check`, `zig build`, `zig build image`/`inspect`,
  `tools/verify-unit-tests.sh` (incl. the new `virtio_file` module),
  `swift build`, `tools/verify-coordination.sh`,
  `tools/verify-bss-budget.sh` — all green; wire-format byte-parity tests
  green on both sides (incl. the generator fixture that locks acceptance
  case A).
- **Default boot unchanged:** without `--cvc-file` the VM config is
  byte-identical, queue 5 is absent, `vf` prints the honest no-channel line,
  and the existing custom-virtio gates (`verify-cvc-echo.sh`,
  `verify-custom-virtio.sh`, `verify-live-input.sh`,
  `verify-live-virtio-e2e.sh`) PASS unchanged.
- **Class B:** `tools/verify-live-vf.sh` PASS on VZ — run 1 asserts **HF1
  acceptance case A** (the 32 KiB device-write reply spike: guest
  `vf: probe 32k ok` + runner `VF-PROBE: wrote 32768/32768`, spec in
  `docs/host-file-channel-scoping.md`); run 2 boots with a share dir
  containing a fixture file **larger than the 32 KiB reply cap**; the guest
  lists the directory and streams the file byte-exactly across ≥ 2 round
  trips (`vf cat` prints the STAT byte count first); runner exits 0 on the
  expected reply.

## Risks

- **The opcode set IS the FS API** — a bad surface bakes in; hence the
  version byte in the framing from day one.
- **Host sandboxing** — the share must be root-confinement tight (the guest
  is untrusted code running with the runner's privileges).
- **Polled latency + chain leaks** — bounded budgets and `free_chain_q` on
  every send (claim 0680 lesson).
- **Full-cap 32 KiB device-write reply** — a modest extension of the proven
  large-payload paths (claim 9492/0680 were device-read); validated in HF1
  with an explicit acceptance case, not assumed.
- **BSS budget** — new buffers bounded; the 11.0 MiB gate (ADR 0013 D3.1,
  `tools/verify-bss-budget.sh`) must re-run green.
- **Flag-gated additive** — nothing regresses without the flag.

## Touched files (first slice)

`kernel/src/virtio_custom.zig` (queue-5 probe/arm) ·
`kernel/src/virtio_file.zig` (new — client + wire) ·
`kernel/src/monitor.zig` (`vf ls`/`vf cat`, registry_count) ·
`host/vm-runner/Sources/VMRunner/main.swift` (`--cvc-file`, queue-5
service) · `host/vm-runner/Sources/VFWire/*.swift` (new — pure wire
module) · `host/vm-runner/Package.swift` + `VMRunnerTests` (test target) ·
`tests/vf-pattern-32k.bin` + `tests/vf-req-read.bin` + `tests/vf-reply-*.bin`
(new fixtures) · `docs/hardware-contract.md` (wire format) ·
`tools/verify-live-vf.sh` (new gate) + `tools/verify-vf-class-a.sh` (new
hook) + `justfile` · `tools/verify-unit-tests.sh` (MODULES += virtio_file) ·
`docs/claims/<id>-host-file-channel.md` + `docs/logs/<branch>.md` (per
coordination rules; claim id via `bash tools/status/claim-id.sh`).
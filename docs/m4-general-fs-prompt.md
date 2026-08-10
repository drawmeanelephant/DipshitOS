# Milestone four, card 2 — general (non-ESP) filesystem

Planning-first prompt doc for DipshitOS, milestone-four card 2 (march-m4 row 2).
Produced BEFORE code; the claim (`docs/claims/3678-general-filesystem.md`) is
the card's claim, this doc is the written plan.

- **Branch:** `agent/buffy/m4-general-fs` (claim first: claim-id.sh → claim
  file in `docs/claims/` + log entry in `docs/logs/`, then
  `bash tools/status/refresh-indexes.sh`; merge per ADR 0003)
- **Date:** 2026-08-10
- **Depends on:** milestone-four card 1 (merged PRs #69/#70 — entropy + CSPRNG
  + ASLR) and the claim-6420 FAT32 storage driver (`kernel/src/fat.zig`,
  `kernel/src/esp.zig`, `kernel/src/virtio_blk.zig`) — everything below
  follows patterns already landed.
- **Inputs (binding):** `AGENTS.md`, `docs/status.md`, `docs/roadmap.md`
  ("A guest-side filesystem … A general (non-ESP) filesystem remains future
  work"), `docs/march-m4.md` (row 2 sketch), `docs/march-m3.md`,
  `kernel/src/fat.zig` + `kernel/src/esp.zig` (the volume being generalized),
  `kernel/src/virtio_blk.zig` (the injected sector interface),
  `image/mkfat32.py` (the on-disk format the kernel must parse),
  `kernel/src/monitor.zig` (`ls`/`cat`/`write` command surface),
  `tools/verify-live-fs.sh` (the existing storage gate).

## The card

The claim-6420 FAT32 driver is hard-wired to the ESP in three ways:

1. **Volume discovery is ESP-specific.** `fat.mount` scans the GPT for the
   ESP type GUID and mounts *that* partition; the geometry and every LBA
   computation are relative to `esp_lba`. A general filesystem must mount
   ANY FAT32 volume at ANY disk offset (arbitrary disk layout).
2. **Directory access is root-only.** `list_root`/`find_slot`/`write_file`
   only ever walk `root_cluster`; the EFI/BOOT subdirectories already on the
   image are invisible to the API. A general filesystem needs arbitrary
   directory walking + path resolution (`EFI/BOOT/BOOTAA64.EFI`).
3. **The file API is the ESP snapshot window.** `esp.zig` snapshots the root
   into a fixed 48-entry / 2 KiB-content window; `ls`/`cat`/`write` serve
   that window. A general file API reads from the volume directly, by path,
   from any directory — not just the window.

The card closes all three, staged so each stage is independently landed and
gated.

## Staged plan

### Stage A — volume generalization (the "arbitrary disk layout" foundation)

- `fat.mount_partition(ops, base_lba)` — parse + mount the FAT32 BPB at an
  arbitrary LBA (today's BPB half of `mount`). `mount(ops)` keeps the GPT →
  ESP discovery and delegates to it. Behavior of the ESP path is byte-for-
  byte identical.
- `Geo.esp_lba` → `Geo.vol_lba` (the mounted volume's base; honest name —
  nothing outside fat.zig reads it today).
- Host tests: a fixture with a SECOND FAT volume at a different LBA mounts
  via `mount_partition` and serves list/read/write; a non-FAT LBA is
  rejected (`bad_bpb`); the ESP wrapper still finds the ESP by GUID.
- Gate: full class A (fat/esp tests, transcript byte-identical, build/image/
  inspect, swift, context, coordination ×2, mmu-debt).

### Stage B — directories

- Generalize the slot walk: `collect_dir_slots(cluster)` over any directory
  cluster chain; `list_dir(cluster, out)`; `find_slot_in(cluster, name)`.
- Path resolution: split on `/`, walk components from the root (or from a
  base cluster), `..` support, bounded component count.
- `read_file`/`write_file` by path; the ESP root is the special case of
  walking from `root_cluster`.
- Host tests over the existing fixture's `/EFI/` + `/EFI/BOOT/` trees
  (already on the disk image mkfat32.py builds); live-visible target:
  `cat EFI/BOOT/BOOTAA64.EFI` on VZ.

### Stage C — file API beyond the ESP window

- A direct volume read API (`fat.read_file_at`-style, path-based, bounded
  buffer) that does not depend on the esp.zig snapshot window; the window
  stays the `ls` convenience but reads/cats can go straight to the volume.
- Monitor surface: `ls [<dir>]` / `cat <path>` path arguments (help derives
  from the registry; transcript fixture updated deliberately).

### Stage D — second volume live + docs + gates

- `image/mkfat32.py` gains a second FAT32 partition on the same disk image
  (the GPT already supports 128 entries — no host/runner change needed), so
  the general driver is OBSERVED on VZ, not just host-tested: boot, mount
  volume 2, list/read/write, persistence across boots.
- New class-B gate `tools/verify-live-gfs.sh` (registered in
  `docs/gate-inventory.md` + `just verify-vz`) or an extended live-fs gate.
- Reconcile: `docs/status.md` (milestone-four row), `docs/roadmap.md`
  (general-filesystem sketch → done), `docs/hardware-contract.md`,
  `docs/march-m4.md` (row 2 ⬜ → ✅). Append log, flip claim, refresh
  indexes, open the PR. `bash tools/verify-coordination.sh` green before
  the PR.

## Do not

- Touch the syscall ABI (ADR 0007) or the userspace/scheduler seams.
- Add libc/POSIX/heap allocation — fixed BSS only (honesty rules).
- Use a `const` function-pointer table anywhere new (ADR 0005).
- Hand-edit generated indexes (`refresh-indexes.sh` only).
- Claim `[observed]` hardware behavior without a saved VZ log under
  `artifacts/`.

## Definition of done

A FAT32 driver that mounts any volume at any LBA, walks arbitrary
directories, resolves paths, and reads files beyond the ESP snapshot window —
all host-tested; the second-partition path observed live on VZ (class B);
`docs/march-m4.md` row 2 ✅; docs reconciled; claim closed; PR open.

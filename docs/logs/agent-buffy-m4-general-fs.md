# Log — milestone four card 2: general (non-ESP) filesystem (claim 3678)

- **Branch:** `agent/buffy/m4-general-fs`
- **Claim:** [`docs/claims/3678-general-filesystem.md`](../claims/3678-general-filesystem.md)
- **Prompt / plan:** [`docs/m4-general-fs-prompt.md`](../m4-general-fs-prompt.md)
- **Started:** 2026-08-10

## Progress

- **Claimed** (2026-08-10): claimed milestone-four card 2 (general
  filesystem) on `agent/buffy/m4-general-fs` with claim 3678, branched off
  `origin/main` (`d2f163d`, PRs #69/#70 merged). Written plan first
  (`docs/m4-general-fs-prompt.md`) — the plan's Stage A (volume
  generalization) is this claim's first landing.

- **Survey** (2026-08-10): read the binding inputs — roadmap ("A general
  (non-ESP) filesystem remains future work"), march-m4 row 2,
  `kernel/src/fat.zig` (GPT→ESP discovery in `mount`, BPB parse, all LBA
  math relative to `esp_lba`, root-only directory access), `kernel/src/
  esp.zig` (the snapshot window `ls`/`cat`/`write` serve),
  `kernel/src/virtio_blk.zig` (the `fat.DiskOps` sector interface), the
  runner (`main.swift`: ONE disk attached — a second partition on the same
  image needs no host change), `kernel/src/monitor.zig` (cmd_ls/cmd_cat/
  cmd_write), `tools/verify-live-fs.sh`. Design decisions: split GPT
  discovery from BPB parsing — `mount_partition(ops, base_lba)` is the
  general entry point, `mount(ops)` keeps the ESP discovery and delegates;
  rename `Geo.esp_lba` → `Geo.vol_lba` (nothing outside fat.zig reads it);
  the `esp window:` boot line prints only counts, so the transcript
  fixture is untouched by Stage A.

- **Implemented — Stage A** (2026-08-10): `kernel/src/fat.zig` gains
  `pub fn mount_partition(ops, base_lba)` (the BPB half of today's
  `mount`, geometry rooted at `vol_lba`) and `mount(ops)` keeps the LBA-1
  GPT header walk for the ESP type GUID then delegates. `Geo.esp_lba` →
  `Geo.vol_lba`; `cluster_lba`/`fat_lba` use it. New host tests: a second
  FAT volume written at a different LBA (LBA 100000, not in the GPT)
  mounts via `mount_partition` and serves list/read/write; a non-FAT LBA
  (the GPT header sector) is rejected `bad_bpb`; the ESP `mount` wrapper
  still finds the ESP by GUID. All existing fat/esp tests unchanged and
  green.

- **Verification** (2026-08-10): class A all green — fmt, unit tests (fat
  11/11 incl. the new volume tests, esp 16/16, all monitor modules),
  transcript byte-identical, build, image, inspect, swift build, context,
  coordination, test-coordination, mmu-debt. Class B sanity: `live-fs`
  1/1 on VZ — the refactored `mount` → `mount_partition` ESP path still
  mounts the real volume, and `write`/`ls`/`cat` persist through reboot
  (run A `hello world` to the FAT volume; run B still lists/cats it).

- **Remaining on this claim:** Stage B (directories: arbitrary cluster
  chains + `/` paths — the image's EFI/BOOT tree), Stage C (direct path
  reads beyond the esp window + monitor path args), Stage D (second FAT
  partition on the image + live gate + docs reconciliation + PR).

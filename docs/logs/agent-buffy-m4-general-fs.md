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

- **Implemented — Stage B (directories + paths)** (2026-08-10):
  `kernel/src/fat.zig` generalizes the directory machinery from the root to
  ANY cluster chain — `collect_dir_slots(cluster)` (the slot walk),
  `list_dir(cluster)` (the listing decode; `list_root` delegates),
  `find_slot_in(cluster, name)` (`find_slot` delegates) — plus `/`-path
  resolution: `dir_cluster_of_path` (bounded components, `.`/`..` with an
  explicit parent stack), `find_slot_path`, `list_path`, and path-aware
  `read_file`/`write_file` (the last `/`-component is the 8.3 name; the
  parent must resolve to an existing directory, else the new
  `WriteResult.bad_path`). `esp`/`monitor` gain the `bad_path` variant
  (esp's `valid_name` still rejects '/' today, so it is dead code until
  Stage C's monitor path args — added for exhaustive switches). Bare names
  still resolve against the root: every existing test passes unchanged.
  New tests: `/EFI` and `/EFI/BOOT` list by path, `EFI/BOOT/BOOTAA64.EFI`
  reads three levels deep (leading '/', `..`-back-to-root, trailing '/',
  absent components), and `write_file` writes into `/EFI/BOOT` and reports
  `bad_path` for missing / non-directory parents.

- **Verification — Stage B** (2026-08-10): class A all green — fmt, unit
  tests (fat 13/13, esp 18/18, monitor 163), transcript byte-identical,
  build/image/inspect, swift build, context, coordination, test-
  coordination, mmu-debt. Class B sanity: `live-fs` 1/1 on VZ — the ESP
  mount + list/read/write paths (now routed through the generalized
  directory machinery) persist through reboot unchanged.

- **Implemented — Stage C (monitor path arguments)** (2026-08-10):
  `kernel/src/fat.zig` gains `file_size` (a file's on-disk size by name or
  `/`-path — the monitor's truncation-honesty check); `kernel/src/
  monitor.zig` — `ls [<dir>]` lists a subdirectory straight from the FAT
  volume (`ls: <path> entries=N` + the same row format; honest "is a file"
  vs "not found" diagnostics), `cat <file|path>` reads a `/`-path
  directly (size checked first: files larger than the bounded 2048-byte
  buffer are reported honestly, never silently truncated); bare names keep
  the proven window paths. Registry help/usage updated for `ls` and `cat`;
  the transcript fixture + shell.zig expected string updated deliberately
  for the two help rows (byte-exact — the fixture's mixed CRLF/LF
  preserved). New monitor test: the path branches report honest no-volume
  errors in a host test process (success is the live gate).

- **Verification — Stage C** (2026-08-10): class A all green — fmt, unit
  tests (fat 14/14, monitor 165), transcript byte-identical, build/image/
  inspect, swift build, context, coordination, test-coordination,
  mmu-debt. Class B: `verify-live-fs.sh` extended (run A adds `ls
  EFI/BOOT` + `cat EFI/BOOT/BOOTAA64.EFI`) — **PASS 1/1 on VZ**: the
  path listing shows the loader's dir (`ls: EFI/BOOT entries=1`,
  `BOOTAA64.EFI 0x29600 [esp]`) and cat reports the honest direct-read cap
  (`file is 0x29600 bytes; direct read caps at 0x800 bytes`) — the
  EFI/BOOT tree is reachable from the shell on real hardware
  (`artifacts/live-fs-serial-A-1.log`).

- **Implemented — Stage D (a second FAT32 partition on the disk + live
  gate)** (2026-08-10): `image/mkfat32.py` — the default image grew to
  128 MiB (two FAT32 volumes each need >65,525 clusters for FAT32
  geometry) with the ESP at LBA 2048 (186335 sectors) and a 36 MiB DATA
  partition (Linux-FS type GUID `0FC63DAF-8483-4772-8E79-3D69D8477DE4`)
  at LBA 188383, built by `build_data_volume` (volume label DIPSHITOS;
  README.TXT + DATA.TXT); `--list` reports both partitions; the cat-file
  reader's partition-offset math was fixed (entries are 128 B, 4 per
  sector — the old code read entry 4 as if it were entry 1, which only
  ever matched the ESP by luck). `make-image.sh` passes the new 128 MiB
  default through. Kernel: the GPT walk was refactored into a shared
  `find_partition_by_type`; `fat.mount_data(ops)` mounts the DATA volume
  by GUID; `esp` gained `set_volume`/`resnapshot` so the window
  re-snapshots the active volume's root; new monitor command `mount
  <esp|data>` (registry 28→29, registered in shell.zig help + the
  transcript fixture byte-exactly via perl); `cmd_write`'s success reply
  now names the REAL volume (`persisted N bytes to FAT on the <volume>`)
  instead of always claiming the ESP. virtio_blk's host test gained an
  explicit `fat.mount(null)` unmount (monitor now imports virtio_blk, so
  the test runs inside the monitor binary where an earlier test leaves
  FAT mounted against a freed fixture).

- **Verification — Stage D** (2026-08-10): class A all green — fmt, unit
  tests (fat 15, esp 20, monitor 168 incl. the new `mount` no-disk test),
  transcript byte-identical, build/image/inspect, swift build, context,
  coordination, test-coordination, mmu-debt. Class B: new
  `tools/verify-live-gfs.sh` (registered in gate-inventory + `just
  verify-vz`) **PASS 1/1 on VZ** — run A: `mount data` →
  `mount: data vol_lba=0x2dfdf files=2`, `ls` lists README.TXT/DATA.TXT
  `[data]`, `cat DATA.TXT` prints the data-volume content, `write
  hello.txt hello world` → `write: ok (persisted 11 bytes to FAT on the
  data)`; run B (SAME disk image, fresh boot): `mount data` lists
  `HELLO.TXT [data]` and `cat hello.txt` prints `hello world` — the
  general volume persisted the write ON THE DISK across reboot,
  independent of the ESP. Evidence: `artifacts/live-gfs-*`
  (`live-gfs-serial-A-1.log` / `-B-1.log`). live-fs regression 1/1.

- **Docs reconciled — claim closed** (2026-08-10): claim 3678 → ✅;
  march-m4 row 2 ✅ (process abstraction / network remain ⬜); status.md
  milestone-four row + related-docs pointer + 28→29 command count;
  roadmap general-filesystem sketch → done; hardware-contract disk bullet
  (two-partition layout `[observed]`); README (29 commands, card-2
  paragraph); gate-inventory `live-gfs` row + `verify-vz` aggregate;
  indexes refreshed. Committed + PR #71 updated.

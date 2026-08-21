# Claim: general (non-ESP) filesystem — volume generalization, directories, file API beyond the ESP window

- **Owner:** Buffy (`agent/buffy/m4-general-fs`)
- **Prompt / plan:** milestone-four march card 2 ([`docs/march-m4.md`](../march-m4.md)):
  the claim-6420 FAT32 driver serves the ESP's FAT volume; a general
  filesystem (arbitrary disk layout, directories, file API beyond the ESP
  window) remains future work (roadmap). Written plan first:
  [`docs/m4-general-fs-prompt.md`](../m4-general-fs-prompt.md).
- **Scope:** the card closes three ESP-specific couplings in
  `kernel/src/fat.zig` / `kernel/src/esp.zig`, staged: **Stage A** (this
  claim's first landing) generalizes volume discovery —
  `fat.mount_partition(ops, base_lba)` mounts any FAT32 volume at an
  arbitrary LBA, `fat.mount(ops)` keeps the GPT→ESP discovery and
  delegates, `Geo.esp_lba` → `Geo.vol_lba`; host tests prove a second
  volume at a different LBA mounts/serves list/read/write and a non-FAT
  LBA is rejected — the ESP path is byte-for-byte unchanged. **Stage B**
  generalizes directory access (arbitrary cluster chains + `/`-path
  resolution — the image's EFI/BOOT tree becomes reachable). **Stage C**
  adds a direct path-based volume read API beyond the esp.zig snapshot
  window + monitor path arguments. **Stage D** puts a second FAT32
  partition on the disk image (mkfat32.py — the GPT already supports 128
  entries, no runner change) so the general path is observed on VZ, plus a
  new/extended class-B gate and docs reconciliation.
- **Depends on:** milestone-four card 1 (merged PRs #69/#70), claim 6420
  (FAT32 storage driver + virtio-blk), claim 3475 (the file window being
  generalized).
- **Status:** ✅ done 2026-08-10 — all four stages landed (volume
  generalization, directories/paths, monitor path arguments, and the
  second on-disk partition with a live gate); class A green + the new
  `tools/verify-live-gfs.sh` class-B gate PASS 1/1 on VZ (see Notes).

## Notes

**Why it matters:** the driver is honest and real but ESP-shaped — `mount`
walks the GPT for the ESP type GUID and every LBA is relative to `esp_lba`;
directory access is root-only (the image's EFI/BOOT dirs are invisible to
the API); `ls`/`cat`/`write` serve the fixed snapshot window, not the
volume. The roadmap defers "a general (non-ESP) filesystem" explicitly;
this card is that item.

**Stage A design:** the GPT walk and the FAT32 BPB parse are orthogonal —
split them. `mount_partition(ops, base_lba)` parses the BPB at `base_lba`
into `Geo` (`vol_lba` = the volume's first sector); `mount(ops)` keeps the
LBA-1 GPT header scan for the ESP type GUID and delegates. All cluster/FAT
LBA math switches to `vol_lba`. No behavior change for the ESP path: same
mount result, same geometry values, same diagnostics (`esp window:` boot
line prints only counts — transcript fixture untouched).

**Stage A verification:** class A — `fat` unit tests incl. the new second-
volume + bad-BPB tests (all existing tests unchanged), `esp` tests,
transcript byte-identical, build/image/inspect, swift build, context,
coordination, test-coordination, mmu-debt. No class-B change in Stage A
(the ESP path is identical); Stages B/D carry the live gates.

**Stage B (directories + paths):** `collect_dir_slots`/`list_dir`/
`find_slot_in` generalize the slot walk + decode to ANY directory cluster
chain (`list_root`/`find_slot` are the root special cases);
`dir_cluster_of_path` resolves bounded `/`-paths with `.`/`..`;
`find_slot_path`/`list_path`/`read_file`/`write_file` are path-aware
(`write_file` gains `WriteResult.bad_path` for missing/non-directory
parents; `esp`/`monitor` mirror the variant for exhaustive switches — dead
until Stage C's monitor path args). Bare names still resolve against the
root. Host tests cover the fixture's EFI/BOOT tree (list, read 3 levels
deep, `..`, write into a subdir, `bad_path`); live-fs 1/1 on VZ unchanged.

**Stage C (monitor path arguments):** `ls [<dir>]` lists a subdirectory
straight from the FAT volume and `cat <file|path>` reads a `/`-path
directly — both with honest diagnostics (`file_size` gates cat's
2048-byte bounded read: bigger files are reported, never silently
truncated); bare names keep the proven window paths. Registry help/usage
updated; transcript fixture + shell.zig expected string updated
byte-exactly for the two help rows. Class A green (fat 14/14, monitor
165, transcript byte-identical); class B — `verify-live-fs.sh` extended
with `ls EFI/BOOT` + `cat EFI/BOOT/BOOTAA64.EFI`, PASS 1/1 on VZ: the
loader's directory lists and cat reports `file is 0x29600 bytes; direct
read caps at 0x800 bytes` (`artifacts/live-fs-serial-A-1.log`).

**Stage D (a second FAT32 partition on the disk + live gate):**
`image/mkfat32.py` grew to a 128 MiB default disk (two FAT32 volumes need
>65,525 clusters each) with the ESP at LBA 2048 (186335 sectors) and a
36 MiB **DATA partition** (Linux-FS type GUID `0FC63DAF-…`) at LBA
188383 built by `build_data_volume` (volume label `DIPSHITOS`, README.TXT
+ DATA.TXT) — `--list` reports both partitions. Kernel: the GPT walk was
refactored into a shared `find_partition_by_type`; `fat.mount_data(ops)`
mounts the data volume by GUID and `esp` gained `set_volume`/`resnapshot`
so the window re-snapshots the active volume's root with an honest label.
New monitor command `mount <esp|data>` (registry 28→29) switches the
active FAT volume; `cmd_write`'s success reply now names the actual
volume (`persisted N bytes to FAT on the <volume>`) instead of always
claiming the ESP. Host tests: fat 15 (mount_data over a two-partition
fixture, bad-GUID rejection), esp 20, monitor 168. Live gate
`tools/verify-live-gfs.sh` (registered in gate-inventory + `just
verify-vz`) — **PASS 1/1 on VZ**: run A mounts the DATA volume by GUID
(`mount: data vol_lba=0x2dfdf`), lists README.TXT/DATA.TXT `[data]`,
cats DATA.TXT, writes `hello.txt`; run B (same disk, fresh boot) still
lists `HELLO.TXT [data]` and prints `hello world` — the general volume
persisted ON THE DISK across reboot, independent of the ESP. Evidence:
`artifacts/live-gfs-*` + `artifacts/gates-gfs-3678.txt`.

## Verification

- **Class A (all stages):** fmt, unit tests (fat 15 incl. new volume tests,
  esp 20, all monitor modules 168), transcript byte-identical,
  build/image/inspect, swift build, context, coordination ×2,
  mmu-debt — green 2026-08-10.
- **Class B:** Stages B/C — `verify-live-fs.sh` 1/1 on VZ (refactored ESP
  path + `ls EFI/BOOT` / `cat EFI/BOOT/BOOTAA64.EFI`); Stage D — new
  `tools/verify-live-gfs.sh` **PASS 1/1** (data volume mounted by GUID,
  listed, read, written, persistent across reboot); regressions
  live-fs/exec/entropy re-run.
- **Evidence:** `artifacts/live-gfs-*`, `artifacts/live-fs-*`,
  `artifacts/gates-gfs-3678.txt`.

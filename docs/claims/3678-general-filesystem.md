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
- **Status:** 🔄 in progress 2026-08-10 — **Stage A landed** (volume
  generalization, class A green; see Notes); Stages B–D remain on this
  claim.

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

## Verification

- **Class A (Stage A):** fmt, unit tests (fat incl. new volume tests, esp,
  all monitor modules), transcript byte-identical, build/image/inspect,
  swift build, context, coordination ×2, mmu-debt — green 2026-08-10.
- **Class B:** Stages B/D — new `tools/verify-live-gfs.sh` (or extended
  live-fs) on VZ: second partition mounted, list/read/write, persistence
  across boots; regressions live-fs/exec/entropy re-run.
- **Evidence:** `artifacts/live-gfs-*` (Stage D).

# live-usb-block.spec -- M43 U3 (issue #1034) + M70f F1 (issue #1458): the
# block-device userland seam and its read-only FAT32 volume surface.
#
# M43 U3: the EL0 app BLKD.BIN opens the file-table `.usb` read-only volume
# (slots 23/24/26), reads 1024 bytes (LBA 0 + LBA 1) through the U2 BOT/SCSI
# driver, and prints the host-staged LBA-1 marker.
#
# M70f F1: the same disk now carries real volumes. The spec proves, in one
# boot, that the guest can (a) walk the MBR and report each slot's FAT32
# geometry, (b) list a volume directory and a subdirectory, (c) read a file
# BYTE-EXACT from EL0 through the `usb1/<path>` file-table handle, and (d)
# refuse honestly when the partition is not a FAT32 volume, the partition does
# not exist, or the name is absent. Two reads carry a whole-file FNV-1a 32:
# `PROBE.TXT` (120 B, one cluster) and `DOCS/NOTE.TXT` (5000 B, three clusters
# 5 -> 6 -> 7), so a multi-cluster chain walk is verified over EVERY byte
# without dumping 5 KB of serial. The pinned checksums are recomputed by the
# setup python below, which fails the run if the staged content ever changes.
#
# The disk image is a 12 MiB MBR-partitioned disk because VZ's sniffer refuses
# a bare/zeroed image; the marker bytes and the file bytes are the byte-exact
# composition proofs. Partition 2 is deliberately a non-FAT32 type (0x83) so
# the "honest refusal" half of the card is observed, not asserted in prose.

vgate_name live-usb-block "M43 U3 + M70f F1: EL0 reads the USB disk raw and through a read-only FAT32 volume"
vgate_share seed
vgate_runner_flags -Xswiftc -DSPIKE
vgate_repeat 1 BOOTS

vgate_file script.txt <<'EOF'
usb vol
echo rx-usb-vol
usb ls usb1
echo rx-usb-ls
usb ls usb1/DOCS
echo rx-usb-ls-docs
usb cat usb1/PROBE.TXT
echo rx-usb-cat-probe
usb cat usb1/DOCS/NOTE.TXT
echo rx-usb-cat-note
usb cat usb2/PROBE.TXT
echo rx-usb-cat-p2
usb ls usb3
echo rx-usb-ls-p3
usb cat usb1/NOPE.TXT
echo rx-usb-cat-missing
usb cat usb1/DOCS
echo rx-usb-cat-dir
usb ls usb1/PROBE.TXT
echo rx-usb-ls-file
exec BLKD.BIN
echo rx-usb-block
EOF

vgate_setup_python <<'PY'
import os
import struct

run_dir = os.environ["RUN_DIR"]
msd = os.path.join(run_dir, "msd.img")

# The probe device is a 12 MiB MBR-partitioned disk: partition 1 = a hand-built
# minimal FAT32 volume (7 MiB at LBA 2048) carrying PROBE.TXT and DOCS/NOTE.TXT,
# partition 2 = a non-FAT32 partition (type 0x83) at LBA 16384, plus a
# deterministic pattern at LBA 1 (the M43 U3 raw marker). VZ's disk-image
# sniffer REFUSES a fully zeroed raw image AND a bare 0x55AA MBR
# (VZErrorDomain Code=5 "disk image format is not recognized"), and this host's
# hdiutil/newfs_msdos are sandbox-denied for the gate harness, so the volume is
# constructed in pure python.
if os.path.exists(msd):
    os.remove(msd)

SECTOR = 512
VOL_SECTORS = 7 * 1024 * 1024 // SECTOR  # 14336
SPC = 4            # sectors per cluster (2 KiB clusters)
RESERVED = 32
NFATS = 2
FATSZ = 28         # sectors per FAT (3562 clusters * 4 B / 512 rounded up)
ROOT_CLUSTER = 2
DATA_START = RESERVED + NFATS * FATSZ  # sector 88
PART1_LBA = 2048
PART2_LBA = 16384
PART2_SECTORS = 4096
IMAGE_SECTORS = 24576  # 12 MiB

PROBE = b"usb-bulk-probe\n" * 8                      # 120 bytes -> one cluster
NOTE = b"".join(("fatchain-%04d\n" % i).encode() for i in range(400))[:5000]
MARKER = b"M43USBMSDPROBE" + bytes(range(256)) + bytes(range(242))  # 512 bytes

# The whole-file checksums the gate asserts. Recomputed here (and checked)
# so an edit to either staged file fails loudly at setup instead of producing
# a mysterious serial mismatch. The reader's FNV is the same streaming FNV-1a
# 32 the host test pins against the standard "a" vector.
def fnv1a32(data, seed=2166136261):
    h = seed
    for c in data:
        h ^= c
        h = (h * 16777619) & 0xffffffff
    return h

PROBE_FNV = 0x133d22a5
NOTE_FNV = 0x52e785f5
assert fnv1a32(PROBE) == PROBE_FNV, "PROBE.TXT checksum drifted: 0x%08x" % fnv1a32(PROBE)
assert fnv1a32(NOTE) == NOTE_FNV, "NOTE.TXT checksum drifted: 0x%08x" % fnv1a32(NOTE)

def dir_entry(name11, attr, first_cluster, size):
    """One 32-byte 8.3 directory entry."""
    e = bytearray(32)
    e[0:11] = name11
    e[11] = attr
    struct.pack_into("<H", e, 20, first_cluster & 0xFFFF)
    struct.pack_into("<H", e, 26, (first_cluster >> 16) & 0xFFFF)
    struct.pack_into("<I", e, 28, size)
    return e

def cluster_sector(cluster):
    """Volume-relative sector of a cluster's first sector."""
    return DATA_START + (cluster - 2) * SPC

def fat32_volume():
    vol = bytearray(VOL_SECTORS * SECTOR)
    # Boot sector (BPB).
    b = bytearray(SECTOR)
    b[0:3] = b"\xeb\x3c\x90"
    b[3:11] = b"VIRELAIO"  # OEM string, exactly 8 bytes
    struct.pack_into("<H", b, 11, SECTOR)
    b[13] = SPC
    struct.pack_into("<H", b, 14, RESERVED)
    b[16] = NFATS
    struct.pack_into("<H", b, 21, 0xF8)     # media descriptor at offset 21
    struct.pack_into("<I", b, 32, VOL_SECTORS)
    struct.pack_into("<I", b, 36, FATSZ)
    struct.pack_into("<I", b, 44, ROOT_CLUSTER)
    struct.pack_into("<H", b, 48, 1)        # FSInfo sector
    struct.pack_into("<H", b, 50, 6)        # backup boot sector
    b[64] = 0x80
    b[66] = 0x29                             # extended boot signature
    struct.pack_into("<I", b, 67, 0x41424344)  # volume id (deterministic)
    b[71:82] = b"USBPROBE   "  # volume label, exactly 11 bytes
    b[82:90] = b"FAT32   "
    b[510:512] = b"\x55\xaa"
    vol[0:SECTOR] = b
    # FSInfo sector.
    fs = bytearray(SECTOR)
    struct.pack_into("<I", fs, 0, 0x41615252)
    struct.pack_into("<I", fs, 484, 0x61417272)
    struct.pack_into("<I", fs, 488, 0xFFFFFFFF)  # free count (unknown)
    struct.pack_into("<I", fs, 492, 0xFFFFFFFF)  # next free
    struct.pack_into("<I", fs, 508, 0xAA550000)
    vol[1 * SECTOR : 2 * SECTOR] = fs
    # Backup boot = sector 6.
    vol[6 * SECTOR : 7 * SECTOR] = b
    # FATs: [0] media, [1] EOC, [2] root EOC, [3] PROBE.TXT EOC,
    # [4] DOCS EOC, and NOTE.TXT's chain 5 -> 6 -> 7 -> EOC (5000 bytes over
    # 2 KiB clusters is three clusters).
    fatvals = {
        0: 0x0FFFFFF8, 1: 0x0FFFFFFF, 2: 0x0FFFFFFF, 3: 0x0FFFFFFF,
        4: 0x0FFFFFFF, 5: 6, 6: 7, 7: 0x0FFFFFFF,
    }
    for n in range(NFATS):
        base = (RESERVED + n * FATSZ) * SECTOR
        for cluster, value in fatvals.items():
            struct.pack_into("<I", vol, base + cluster * 4, value)
    # Root dir (cluster 2): volume label + PROBE.TXT (cluster 3) + DOCS (dir).
    root = cluster_sector(ROOT_CLUSTER) * SECTOR
    lbl = bytearray(32)
    lbl[0:11] = b"USBPROBE   "  # exactly 11 bytes (the 8.3 label field)
    lbl[11] = 0x08
    vol[root : root + 32] = lbl
    vol[root + 32 : root + 64] = dir_entry(b"PROBE   TXT", 0x20, 3, len(PROBE))
    vol[root + 64 : root + 96] = dir_entry(b"DOCS       ", 0x10, 4, 0)
    # DOCS (cluster 4): the dot entries + NOTE.TXT (cluster 5).
    docs = cluster_sector(4) * SECTOR
    vol[docs : docs + 32] = dir_entry(b".          ", 0x10, 4, 0)
    vol[docs + 32 : docs + 64] = dir_entry(b"..         ", 0x10, 0, 0)
    vol[docs + 64 : docs + 96] = dir_entry(b"NOTE    TXT", 0x20, 5, len(NOTE))
    # File content.
    off = cluster_sector(3) * SECTOR
    vol[off : off + len(PROBE)] = PROBE
    off = cluster_sector(5) * SECTOR
    vol[off : off + len(NOTE)] = NOTE
    return vol

img = bytearray(IMAGE_SECTORS * SECTOR)
vol = fat32_volume()
img[PART1_LBA * SECTOR : PART1_LBA * SECTOR + len(vol)] = vol
# MBR: slot 1 = FAT32 LBA over LBA 2048..16383; slot 2 = a plain 0x83 partition
# (not FAT32) over LBA 16384..20479. Slot 2 exists so the honest-refusal half of
# the card is observed live instead of argued.
mbr = bytearray(SECTOR)
e1 = bytearray(16)
e1[0] = 0x80
e1[1:4] = b"\xfe\xff\xff"
e1[4] = 0x0C
e1[5:8] = b"\xfe\xff\xff"
e1[8:12] = PART1_LBA.to_bytes(4, "little")
e1[12:16] = VOL_SECTORS.to_bytes(4, "little")
mbr[446:462] = e1
e2 = bytearray(16)
e2[4] = 0x83
e2[8:12] = PART2_LBA.to_bytes(4, "little")
e2[12:16] = PART2_SECTORS.to_bytes(4, "little")
mbr[462:478] = e2
mbr[510:512] = b"\x55\xaa"
img[0:SECTOR] = mbr
# Partition 2's region: deterministic non-filesystem bytes (the reader refuses
# it by TYPE, before reading a byte of it — this just keeps the MBR honest).
p2 = b"NOT-A-FILESYSTEM\n"
fill = (p2 * ((PART2_SECTORS * SECTOR) // len(p2) + 1))[: PART2_SECTORS * SECTOR]
img[PART2_LBA * SECTOR : PART2_LBA * SECTOR + len(fill)] = fill
img[512:1024] = MARKER
with open(msd, "wb") as f:
    f.write(img)
PY

# Boot with only the MSD attached; the shell drives the volume surface and then
# exec's the EL0 consumer from the host share. No HID device, so `input: armed`
# must be absent, and the MSD lives on its own controller (M43 U6, [observed]).
vgate_run 01 -- --script '$RUN_DIR/script.txt' --script-after "virelai>" --usb-msd '$RUN_DIR/msd.img' --timeout 240

vgate_assert 01 serial-contains 'VirelaiOS kernel has seized control.'

# --- M70f F1: MBR walk. Three distinct answers, one per line shape. --------
vgate_assert 01 serial-contains 'usb vol: partitions=2'
# The FAT32 volume: geometry straight from the BPB, clamped to the partition.
vgate_assert 01 serial-contains 'usb vol: part=1 boot=1 type=0x0c start_lba=2048 sectors=14336 fat=1 label=USBPROBE cluster_bytes=2048 clusters=3562 root_cluster=2'
# A present partition that is not FAT32 is refused by TYPE, not by a parse error.
vgate_assert 01 serial-contains 'usb vol: part=2 boot=0 type=0x83 start_lba=16384 sectors=4096 fat=0 reason=type'
vgate_assert 01 serial-contains 'usb vol: part=3 absent'
vgate_assert 01 serial-contains 'usb vol: part=4 absent'
vgate_assert 01 serial-contains 'rx-usb-vol'

# --- M70f F1: directory listing (root + subdirectory). ---------------------
vgate_assert 01 serial-contains 'usb ls: vol=1 path=/ label=USBPROBE'
vgate_assert 01 serial-contains 'usb ls: PROBE.TXT size=120 dir=0 cluster=3 attr=0x20'
vgate_assert 01 serial-contains 'usb ls: DOCS size=0 dir=1 cluster=4 attr=0x10'
# The volume-label entry is metadata, not a file: exactly two root entries.
vgate_assert 01 serial-contains 'usb ls: entries=2 broken=0'
vgate_assert 01 serial-contains 'rx-usb-ls'
vgate_assert 01 serial-contains 'usb ls: vol=1 path=DOCS label=USBPROBE'
vgate_assert 01 serial-contains 'usb ls: NOTE.TXT size=5000 dir=0 cluster=5 attr=0x20'
# `.` and `..` are skipped, so the subdirectory lists exactly one entry.
vgate_assert 01 serial-contains 'usb ls: entries=1 broken=0'
vgate_assert 01 serial-contains 'rx-usb-ls-docs'

# --- M70f F1: byte-exact reads, whole-file checksums. ----------------------
vgate_assert 01 serial-contains 'usb cat: vol=1 path=PROBE.TXT size=120'
vgate_assert 01 serial-contains 'usb-bulk-probe'
vgate_assert 01 serial-contains 'usb cat: read=120 sum=0x00000000133d22a5 printed=120 of 120 broken=0 capped=0'
vgate_assert 01 serial-contains 'rx-usb-cat-probe'
# 5000 bytes across clusters 5 -> 6 -> 7: the checksum covers every byte, so a
# bounded print still proves the whole chain was walked correctly.
vgate_assert 01 serial-contains 'usb cat: vol=1 path=DOCS/NOTE.TXT size=5000'
vgate_assert 01 serial-contains 'fatchain-0000'
vgate_assert 01 serial-contains 'fatchain-0017'
vgate_assert 01 serial-contains 'usb cat: read=5000 sum=0x0000000052e785f5 printed=256 of 5000 broken=0 capped=0'
vgate_assert 01 serial-contains 'rx-usb-cat-note'

# --- M70f F1: the honest refusals (observed, not asserted in prose). -------
vgate_assert 01 serial-contains 'usb: partition 2 is not a readable FAT32 volume (not-fat32)'
vgate_assert 01 serial-contains 'rx-usb-cat-p2'
vgate_assert 01 serial-contains 'usb: no such MBR partition'
vgate_assert 01 serial-contains 'rx-usb-ls-p3'
vgate_assert 01 serial-contains 'usb cat: not found'
vgate_assert 01 serial-contains 'rx-usb-cat-missing'
vgate_assert 01 serial-contains 'usb cat: is a directory (use `usb ls`)'
vgate_assert 01 serial-contains 'rx-usb-cat-dir'
vgate_assert 01 serial-contains 'usb ls: is a file (use `usb cat`)'
vgate_assert 01 serial-contains 'rx-usb-ls-file'
# A refusal is never a trap, and no volume path may fall through to the share.
vgate_assert 01 serial-absent '[EXC] parking:'

# --- M43 U3: the raw `.usb` device, unchanged (the regression proof). ------
vgate_assert 01 serial-contains 'exec: loaded BLKD.BIN size='
vgate_assert 01 serial-contains 'blkd: pattern=M43USBMSDPROBE'
vgate_assert 01 serial-contains 'blkd: done'
# --- M70f F1: the same app reading the volume through the file table. ------
vgate_assert 01 serial-contains 'blkd: fat=usb-bulk-probe'
vgate_assert 01 serial-contains 'blkd: fat-eof=1'
vgate_assert 01 serial-contains 'rx-usb-block'
vgate_assert 01 serial-absent 'blkd: open failed'
vgate_assert 01 serial-absent 'blkd: vol open failed'
vgate_assert 01 serial-absent 'blkd: fat short read'
vgate_assert 01 serial-absent 'blkd: fat not eof'
vgate_assert 01 serial-absent 'input: armed'
vgate_assert 01 serial-absent '[EXC] parking:'

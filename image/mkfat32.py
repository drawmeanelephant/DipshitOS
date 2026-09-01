#!/usr/bin/env python3
"""Build or inspect the bootable FAT32 + GPT disk image for VirelaiOS.

Pure Python 3 standard library only -- no mtools, no root, no loopback
devices. Used by image/make-image.sh and tools/inspect.sh.

Modes:
  create:  mkfat32.py [--size-mb 0] IMAGE EFI_FILE KERNEL_FILE
  list:    mkfat32.py --list IMAGE

M34 HF6 (issue #740): the image is a BOOT VOLUME ONLY. It contains
exactly two files -- EFI/BOOT/BOOTAA64.EFI and KERNEL.BIN -- parsed by
Apple's firmware pre-exit (the loader writes \\BOOTED.TXT / \\MEMMAP.TXT /
LOADER.TXT and reads \\KERNEL.BIN through the UEFI Simple File System
protocol). NO guest code speaks FAT after boot: the DATA partition, the
embedded-app machinery, and the guest FAT driver are all gone. Apps live
in the macOS host share (runner flag --cvc-file <host-dir>).

Layout produced:
  LBA 0        protective MBR
  LBA 1        GPT header (partition entries at LBA 2..33, backup at end)
  LBA 2048..   one ESP FAT32 volume (hidden_sectors = 2048) containing
               EFI/BOOT/BOOTAA64.EFI and KERNEL.BIN

Size: the volume is pinned at the FAT32 cluster-count floor (> 65525
clusters with spc=1, 512-byte sectors), which lands the raw image at
~34 MiB (mostly zeros; the file content is ~1.5 MiB). --size-mb overrides
when a larger image is wanted.

Deterministic: the same inputs always produce byte-identical images.
"""

import argparse
import os
import struct
import sys
import zlib

BYTES_PER_SECTOR = 512
ESP_OFFSET = 2048  # 1 MiB: LBA of the ESP volume (hidden_sectors = 2048)
# FAT32 requires > 65525 clusters per volume (spc=1, 512-byte sectors).
# The volume sector count below is the smallest that satisfies that with
# room for two FATs; the fixed-point FAT-size iteration in Fat32Geometry
# resolves the exact geometry. 0 means "compute the floor".
SIZE_MB_DEFAULT = 0
FAT_EOC = 0x0FFFFFFF  # end-of-chain marker for FAT32
FAT_BAD = 0x0FFFFFF7
# GPT type GUID for the EFI System Partition (mixed-endian byte layout).
ESP_GUID = bytes([0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11,
                  0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B])
# Fixed GUIDs so `zig build image` produces byte-identical images every run.
DISK_GUID = bytes([0x44, 0x49, 0x50, 0x53, 0x48, 0x49, 0x54, 0x4F,
                   0x53, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x31])
PART_GUID = bytes([0x44, 0x49, 0x50, 0x53, 0x48, 0x49, 0x54, 0x4F,
                   0x53, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x32])


# --------------------------------------------------------------------------
# GPT helpers
# --------------------------------------------------------------------------

def protective_mbr(total_sectors):
    mbr = bytearray(BYTES_PER_SECTOR)
    mbr[0] = 0x00  # no boot code
    # Partition entry 0: type 0xEE (protective), covering the whole disk.
    size = min(total_sectors - 1, 0xFFFFFFFF)
    mbr[446:462] = struct.pack("<B3sB3sII", 0x00, b"\x00\x00\x00", 0xEE,
                               b"\xff\xff\xff", 1, size)
    mbr[510:512] = b"\x55\xaa"
    return bytes(mbr)


def gpt_header(current_lba, backup_lba, first_usable, last_usable,
               entries_lba, entries_crc, disk_guid):
    hdr = bytearray(92)
    hdr[0:8] = b"EFI PART"
    struct.pack_into("<I", hdr, 8, 0x00010000)     # revision 1.0
    struct.pack_into("<I", hdr, 12, 92)            # header size
    struct.pack_into("<I", hdr, 16, 0)             # crc32 (computed below)
    struct.pack_into("<I", hdr, 20, 0)             # reserved
    struct.pack_into("<Q", hdr, 24, current_lba)
    struct.pack_into("<Q", hdr, 32, backup_lba)
    struct.pack_into("<Q", hdr, 40, first_usable)
    struct.pack_into("<Q", hdr, 48, last_usable)
    hdr[56:72] = disk_guid
    struct.pack_into("<Q", hdr, 72, entries_lba)
    struct.pack_into("<I", hdr, 80, 128)           # number of entries
    struct.pack_into("<I", hdr, 84, 128)           # entry size
    struct.pack_into("<I", hdr, 88, entries_crc)
    crc = zlib.crc32(hdr) & 0xFFFFFFFF
    struct.pack_into("<I", hdr, 16, crc)
    return bytes(hdr)


def partition_entry(type_guid, first_lba, last_lba, name, unique_guid=PART_GUID):
    e = bytearray(128)
    e[0:16] = type_guid
    e[16:32] = unique_guid
    struct.pack_into("<Q", e, 32, first_lba)
    struct.pack_into("<Q", e, 40, last_lba)
    struct.pack_into("<Q", e, 48, 0)               # attributes
    enc = name.encode("utf-16-le")
    assert len(enc) <= 72, "partition name too long"
    e[56:56 + len(enc)] = enc
    return bytes(e)


# --------------------------------------------------------------------------
# FAT32 helpers
# --------------------------------------------------------------------------

class Fat32Geometry:
    """FAT32 layout for one volume, computed from its sector count."""

    def __init__(self, volume_sectors, base_lba):
        self.bps = BYTES_PER_SECTOR
        self.spc = 1
        self.reserved = 32
        self.nfats = 2
        self.base_lba = base_lba
        self.total_sectors = volume_sectors
        # Fixed-point iteration for sectors-per-FAT (FAT32: 4 bytes/entry).
        fat_sectors = 1
        while True:
            clusters = volume_sectors - self.reserved - self.nfats * fat_sectors
            need = (clusters * 4 + self.bps - 1) // self.bps
            if need == fat_sectors:
                break
            fat_sectors = need
        self.fat_sectors = fat_sectors
        self.clusters = clusters
        self.data_start = self.reserved + self.nfats * self.fat_sectors
        self.root_cluster = 2

    def cluster_sector(self, cluster):
        """Absolute sector of a data cluster (cluster >= 2)."""
        return self.base_lba + self.data_start + (cluster - self.root_cluster) * self.spc

    def fat_sector(self, fat_index):
        return self.base_lba + self.reserved + fat_index * self.fat_sectors

    def checks(self):
        if self.clusters <= 65525:
            raise ValueError(
                "FAT32 requires > 65525 clusters (got %d); increase image size" %
                self.clusters)
        if self.total_sectors > 0xFFFFFFFF:
            raise ValueError("volume too large for FAT32 (max 2 TiB)")


def minimum_volume_sectors():
    """Smallest sector count whose FAT32 geometry passes the > 65525 check."""
    v = 66000
    while True:
        g = Fat32Geometry(v, 0)
        if g.clusters > 65525:
            return v
        v += 512  # a full cluster of slack per step keeps iteration tiny


def boot_sector(geo):
    b = bytearray(BYTES_PER_SECTOR)
    b[0:3] = b"\xeb\x58\x90"
    b[3:11] = b"MSDOS5.0"
    struct.pack_into("<H", b, 11, geo.bps)
    b[13] = geo.spc
    struct.pack_into("<H", b, 14, geo.reserved)
    b[16] = geo.nfats
    struct.pack_into("<H", b, 17, 0)          # root entries (0 for FAT32)
    struct.pack_into("<H", b, 19, 0)          # total sectors 16-bit
    b[21] = 0xF8                              # media descriptor
    struct.pack_into("<H", b, 22, 0)          # FAT size 16-bit
    struct.pack_into("<H", b, 24, 32)         # sectors per track
    struct.pack_into("<H", b, 26, 64)         # number of heads
    struct.pack_into("<I", b, 28, geo.base_lba)     # hidden sectors (volume base)
    struct.pack_into("<I", b, 32, geo.total_sectors)
    struct.pack_into("<I", b, 36, geo.fat_sectors)
    struct.pack_into("<H", b, 40, 0)          # extended flags
    struct.pack_into("<H", b, 42, 0)          # filesystem version
    struct.pack_into("<I", b, 44, geo.root_cluster)
    struct.pack_into("<H", b, 48, 1)          # FSInfo sector
    struct.pack_into("<H", b, 50, 6)          # backup boot sector
    b[64] = 0x80                              # drive number
    b[66] = 0x29                              # extended boot signature
    struct.pack_into("<I", b, 67, 0x44495031)  # volume id
    b[71:82] = b"VIRELAIOS  "
    b[82:90] = b"FAT32   "
    b[510:512] = b"\x55\xaa"
    return bytes(b)


def fs_info_sector():
    fi = bytearray(BYTES_PER_SECTOR)
    struct.pack_into("<I", fi, 0, 0x41615252)   # "RRaA"
    struct.pack_into("<I", fi, 4, 0x61417272)   # "rrAa"
    struct.pack_into("<I", fi, 8, 0xFFFFFFFF)   # free cluster count (unknown)
    struct.pack_into("<I", fi, 12, 0xFFFFFFFF)  # next free cluster (unknown)
    struct.pack_into("<I", fi, 508, 0xAA550000)
    return bytes(fi)


def dir_entry(name11, attr, cluster, size):
    assert len(name11) == 11, "8.3 name must be exactly 11 bytes, got %r" % name11
    e = bytearray(32)
    e[0:11] = name11
    e[11] = attr
    struct.pack_into("<H", e, 20, (cluster >> 16) & 0xFFFF)  # cluster high
    struct.pack_into("<H", e, 26, cluster & 0xFFFF)          # cluster low
    struct.pack_into("<I", e, 28, size)
    return bytes(e)


def build_fat32_image(img, geo, efi_bytes, kernel_bytes):
    """Write the single FAT32 volume (boot sector, FSInfo, FATs, root,
    EFI/BOOT, KERNEL.BIN) into `img` at the volume's offset.

    Cluster layout: 2=root, 3=EFI, 4=BOOT, 5=BOOTAA64.EFI data,
    5+kernel_clusters..=KERNEL.BIN data. Deterministic.
    """
    geo.checks()
    bps = geo.bps
    efi_clusters = (len(efi_bytes) + bps - 1) // bps
    kernel_clusters = (len(kernel_bytes) + bps - 1) // bps

    # root: vol label + EFI dir + KERNEL.BIN
    root_entries_count = 3
    root_clusters = (root_entries_count * 32 + bps - 1) // bps
    efi_dir_cluster = 2 + root_clusters
    boot_dir_cluster = efi_dir_cluster + 1
    efi_start = boot_dir_cluster + 1
    kernel_start = efi_start + efi_clusters
    allocated = kernel_start + kernel_clusters - 2  # clusters used beyond root(2)
    if allocated > geo.clusters:
        raise ValueError(
            "boot files need %d clusters but the volume has only %d; "
            "increase --size-mb" % (allocated, geo.clusters))

    # --- cluster chain -------------------------------------------------
    fat = [0] * (geo.clusters + 2)
    fat[0] = 0x0FFFFFF8
    fat[1] = 0x0FFFFFFF

    def chain(start, count):
        for i in range(count):
            fat[start + i] = start + i + 1 if i < count - 1 else 0x0FFFFFFF

    chain(2, root_clusters)           # root directory
    chain(efi_dir_cluster, 1)         # EFI directory
    chain(boot_dir_cluster, 1)        # BOOT directory
    chain(efi_start, efi_clusters)    # BOOTAA64.EFI data
    chain(kernel_start, kernel_clusters)  # KERNEL.BIN data

    def wsec(sector, data):
        off = sector * bps
        img[off:off + len(data)] = data

    # --- boot sector / FSInfo / backups --------------------------------
    bs = boot_sector(geo)
    wsec(geo.base_lba + 0, bs)
    wsec(geo.base_lba + 1, fs_info_sector())
    wsec(geo.base_lba + 6, bs)          # backup boot sector
    wsec(geo.base_lba + 7, fs_info_sector())

    # --- FATs (two copies) ----------------------------------------------
    fat_bytes = b"".join(struct.pack("<I", e) for e in fat)
    fat_bytes = fat_bytes.ljust(geo.fat_sectors * bps, b"\x00")
    for i in range(geo.nfats):
        wsec(geo.fat_sector(i), fat_bytes)

    # --- directory tree --------------------------------------------------
    vol_label = dir_entry(b"VIRELAIOS  ", 0x08, 0, 0)
    efi_entry = dir_entry(b"EFI        ", 0x10, efi_dir_cluster, 0)
    boot_entry = dir_entry(b"BOOT       ", 0x10, boot_dir_cluster, 0)
    file_entry = dir_entry(b"BOOTAA64EFI", 0x20, efi_start, len(efi_bytes))
    kernel_entry = dir_entry(b"KERNEL  BIN", 0x20, kernel_start, len(kernel_bytes))
    dot_efi = dir_entry(b".          ", 0x10, efi_dir_cluster, 0)
    dotdot_efi = dir_entry(b"..         ", 0x10, 2, 0)
    dot_boot = dir_entry(b".          ", 0x10, boot_dir_cluster, 0)
    dotdot_boot = dir_entry(b"..         ", 0x10, efi_dir_cluster, 0)

    root_entries = (vol_label + efi_entry + kernel_entry).ljust(
        root_clusters * bps, b"\x00")
    for i in range(root_clusters):
        chunk = root_entries[i * bps:(i + 1) * bps]
        wsec(geo.cluster_sector(2 + i), chunk)
    wsec(geo.cluster_sector(efi_dir_cluster),
         (dot_efi + dotdot_efi + boot_entry).ljust(bps, b"\x00"))
    wsec(geo.cluster_sector(boot_dir_cluster),
         (dot_boot + dotdot_boot + file_entry).ljust(bps, b"\x00"))

    # --- file data -----------------------------------------------------
    for i in range(efi_clusters):
        chunk = efi_bytes[i * bps:(i + 1) * bps]
        wsec(geo.cluster_sector(efi_start + i), chunk.ljust(bps, b"\x00"))
    for i in range(kernel_clusters):
        chunk = kernel_bytes[i * bps:(i + 1) * bps]
        wsec(geo.cluster_sector(kernel_start + i), chunk.ljust(bps, b"\x00"))


# --------------------------------------------------------------------------
# GPT + FAT32 volume assembly
# --------------------------------------------------------------------------

def build_image(path, efi_bytes, kernel_bytes, size_mb):
    if size_mb and size_mb > 0:
        total_sectors = size_mb * 1024 * 1024 // BYTES_PER_SECTOR
    else:
        total_sectors = ESP_OFFSET + minimum_volume_sectors()
    volume_sectors = total_sectors - ESP_OFFSET
    geo = Fat32Geometry(volume_sectors, ESP_OFFSET)

    img = bytearray(total_sectors * BYTES_PER_SECTOR)
    img[0:BYTES_PER_SECTOR] = protective_mbr(total_sectors)

    # GPT header at LBA 1, entries at LBA 2..33, backup at the end.
    first_usable = 34
    last_usable = total_sectors - 34
    entries_lba = 2
    backup_entries_lba = last_usable + 1  # == total_sectors - 33
    # Entries region: 128 entries of 128 bytes at LBA 2 (zero-filled).
    entries = bytearray(128 * 128)
    entries[0:128] = partition_entry(ESP_GUID, ESP_OFFSET, last_usable,
                                     "EFI SYSTEM", PART_GUID)
    entries_crc = zlib.crc32(bytes(entries)) & 0xFFFFFFFF
    img[BYTES_PER_SECTOR:2 * BYTES_PER_SECTOR] = gpt_header(
        1, total_sectors - 1, first_usable, last_usable,
        entries_lba, entries_crc, DISK_GUID)
    img[2 * BYTES_PER_SECTOR:2 * BYTES_PER_SECTOR + len(entries)] = entries
    img[(total_sectors - 1) * BYTES_PER_SECTOR:
        (total_sectors - 1) * BYTES_PER_SECTOR + BYTES_PER_SECTOR] = gpt_header(
            total_sectors - 1, 1, first_usable, last_usable,
            backup_entries_lba, entries_crc, DISK_GUID)
    img[backup_entries_lba * BYTES_PER_SECTOR:
        backup_entries_lba * BYTES_PER_SECTOR + len(entries)] = entries

    build_fat32_image(img, geo, efi_bytes, kernel_bytes)

    with open(path, "wb") as f:
        f.write(img)


# --------------------------------------------------------------------------
# Listing (used by make-image.sh self-verify and tools/inspect.sh)
# --------------------------------------------------------------------------

def decode_83(e):
    """Decode an 11-byte 8.3 directory name ("KERNEL  BIN" -> "KERNEL.BIN")."""
    name = e[0:8].decode("latin-1", "replace").rstrip(" ")
    ext = e[8:11].decode("latin-1", "replace").rstrip(" ")
    return (name + "." + ext) if ext else name


def list_image(path):
    """Print the image's GPT + FAT contents in the historical --list format
    (make-image.sh self-verify and tools/inspect.sh grep for "KERNEL.BIN" /
    "BOOTAA64.EFI" in the decoded 8.3 names)."""
    with open(path, "rb") as f:
        data = f.read()
    total_sectors = len(data) // BYTES_PER_SECTOR
    bps = BYTES_PER_SECTOR

    print("size: %d bytes (%d sectors)" % (len(data), total_sectors))
    print("LBA0: %s" % ("MBR present" if data[510:512] == b"\x55\xaa" else "no MBR signature"))

    if data[512:520] == b"EFI PART":
        hdr_crc = struct.unpack_from("<I", data, 512 + 16)[0]
        print("GPT: valid signature, header crc32=0x%08x" % hdr_crc)
    else:
        print("GPT: no GPT signature at LBA 1 (expecting one for VirelaiOS images)")
        return 1

    # Find the ESP partition entry (type ESP_GUID) in the primary GPT.
    entries_lba = struct.unpack_from("<Q", data, 512 + 72)[0]
    first_lba = None
    for i in range(128):
        e = data[entries_lba * bps + i * 128: entries_lba * bps + (i + 1) * 128]
        if len(e) < 128:
            break
        if e[0:16] == ESP_GUID:
            first_lba = struct.unpack_from("<Q", e, 32)[0]
            break
    if first_lba is None:
        print("FAT: no ESP partition found -- cannot list FAT contents")
        return 1

    base = first_lba * bps
    if data[base + 510:base + 512] != b"\x55\xaa" or data[base + 82:base + 90] != b"FAT32   ":
        print("FAT: no boot signature / FAT32 label at the ESP volume")
        return 1
    reserved = struct.unpack_from("<H", data, base + 14)[0]
    fat_sectors = struct.unpack_from("<I", data, base + 36)[0]
    root_cluster = struct.unpack_from("<I", data, base + 44)[0]
    spc = data[base + 13]
    total = struct.unpack_from("<I", data, base + 32)[0]
    data_start = first_lba + reserved + 2 * fat_sectors
    vol_label = data[base + 71:base + 82].decode("latin-1", "replace").rstrip(" ")

    print("GPT: ESP partition at LBA %d, %d sectors" % (first_lba, total))
    print("FAT: boot sig ok, label=%r, %d-byte sectors, %d sector/cluster, "
          "%d reserved, %d FATs x %d sectors, root cluster %d" %
          (vol_label, bps, spc, reserved, 2, fat_sectors, root_cluster))

    def cluster_sector(cluster):
        return data_start + (cluster - root_cluster) * spc

    def read_cluster_entries(cluster):
        sec = cluster_sector(cluster)
        blob = data[sec * bps:(sec + 1) * bps]
        return [blob[i * 32:(i + 1) * 32] for i in range(bps // 32)]

    def fat_next(cluster):
        off = (first_lba + reserved) * bps + cluster * 4
        return struct.unpack_from("<I", data, off)[0] & 0x0FFFFFFF

    print("FAT: directory tree:")

    def walk(cluster, indent):
        seen = set()
        while cluster not in (FAT_EOC, FAT_BAD) and cluster not in seen:
            seen.add(cluster)
            for e in read_cluster_entries(cluster):
                if e[0] == 0x00:
                    break
                if e[0] == 0xE5:
                    continue
                attr = e[11]
                if attr & 0x08:  # volume label
                    continue
                name = decode_83(e)
                if name in (".", ".."):
                    continue
                cl = (struct.unpack_from("<H", e, 20)[0] << 16) | struct.unpack_from("<H", e, 26)[0]
                size = struct.unpack_from("<I", e, 28)[0]
                if attr & 0x10:
                    print("%s%s/" % (indent, name))
                    walk(cl, indent + "  ")
                else:
                    print("%s%s  (%d bytes)" % (indent, name, size))
            cluster = fat_next(cluster)

    walk(root_cluster, "  ")
    return 0


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--size-mb", type=int, default=SIZE_MB_DEFAULT,
                    help="image size in MiB (0 = the FAT32 floor, default)")
    ap.add_argument("--list", action="store_true",
                    help="list the image's partitions and files instead of creating")
    ap.add_argument("args", nargs="*")
    opts = ap.parse_args()

    if opts.list:
        if len(opts.args) != 1:
            ap.error("--list takes exactly one IMAGE argument")
        list_image(opts.args[0])
        return

    if len(opts.args) != 3:
        ap.error("create mode takes IMAGE EFI_FILE KERNEL_FILE "
                 "(M34 HF6: the boot volume is exactly these two files)")
    image, efi_file, kernel_file = opts.args
    with open(efi_file, "rb") as f:
        efi_bytes = f.read()
    with open(kernel_file, "rb") as f:
        kernel_bytes = f.read()
    build_image(image, efi_bytes, kernel_bytes, opts.size_mb)
    print("mkfat32: wrote %s (%s EFI + %s kernel bytes)" %
          (image, len(efi_bytes), len(kernel_bytes)))


if __name__ == "__main__":
    main()

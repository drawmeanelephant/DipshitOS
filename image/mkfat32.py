#!/usr/bin/env python3
"""Build or inspect a bootable FAT32 + GPT disk image for DipshitOS.

Pure Python 3 standard library only -- no mtools, no root, no loopback
devices. Used by image/make-image.sh and tools/inspect.sh.

Modes:
  create:  mkfat32.py [--size-mb 128] [--esp-offset 2048] IMAGE EFI_FILE [KERNEL_FILE] [USER_FILE] [COUNTER_FILE] [PEER_FILE] [STATUS43_FILE] [UDP_FILE] [WIN_FILE] [WINCLOSE_FILE] [WINLOOP_FILE] [WINMOVE_FILE]
  list:    mkfat32.py --list IMAGE

Layout produced:
  LBA 0        protective MBR
  LBA 1        GPT header (partition entries at LBA 2..33, backup at end)
  LBA 2048..   ESP FAT32 volume (hidden_sectors = 2048) containing
               EFI/BOOT/BOOTAA64.EFI, KERNEL.BIN when a KERNEL_FILE is
               given (the milestone-one kernel image), USER.BIN when a
               USER_FILE is given (the milestone-three ESP user program,
               claim 6783), COUNTER.BIN when a COUNTER_FILE is given
               (the milestone-four follow-on 2 never-exiting user program,
               claim 4613), PEER.BIN when a PEER_FILE is given (the
               follow-on 3 card 3f IPC peer, claim 5965), UDP.BIN when a
               UDP_FILE is given (the milestone-five card N6 UDP-syscall
               proof, claim 1384), WIN.BIN when a WIN_FILE is given
               (the milestone-six card G6 draw/window-syscall proof,
               claim 0487), WINCLOSE.BIN when a WINCLOSE_FILE is given
               (the claim-0487 teardown follow-on release proof), and
               WINLOOP.BIN when a WINLOOP_FILE is given (the claim-0487
               ownership follow-on persistent-window proof), and
               WINMOVE.BIN when a WINMOVE_FILE is given (the claim-0487
               move/raise follow-on).
  tail         DATA FAT32 partition (Linux-FS type GUID, 36 MiB) — a second
               volume on the same disk for the general (non-ESP) filesystem
               (milestone-four card 2, claim 3678); the kernel's `mount`
               command switches to it.
Deterministic: the same inputs always produce byte-identical images.
"""

import argparse
import struct
import sys
import zlib

BYTES_PER_SECTOR = 512
ESP_OFFSET_DEFAULT = 2048  # 1 MiB
# 128 MiB so TWO FAT32 volumes fit: FAT32 needs > 65525 clusters per volume
# (spc=1, 512-byte sectors -> ~32 MiB each), and the image also holds the
# ESP plus a second "data" partition (milestone-four card 2, claim 3678).
SIZE_MB_DEFAULT = 128
# Size of the second (data) partition, in MiB. 36 MiB > the FAT32 minimum.
DATA_MB = 36
FAT_EOC = 0x0FFFFFFF  # end-of-chain marker for FAT32
FAT_BAD = 0x0FFFFFF7
# GPT type GUID for the EFI System Partition (mixed-endian byte layout).
ESP_GUID = bytes([0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11,
                  0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B])
# GPT type GUID for the data partition: the Linux filesystem GUID
# (0FC63DAF-8483-4772-8E79-3D69D8477DE4, mixed-endian byte layout) — a
# standard "general data" partition type, not the ESP.
DATA_GUID = bytes([0xAF, 0x3D, 0xC6, 0x0F, 0x83, 0x84, 0x72, 0x47,
                   0x8E, 0x79, 0x3D, 0x69, 0xD8, 0x47, 0x7D, 0xE4])
# Fixed GUIDs so `zig build image` produces byte-identical images every run.
DISK_GUID = bytes([0x44, 0x49, 0x50, 0x53, 0x48, 0x49, 0x54, 0x4F,
                   0x53, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x31])
PART_GUID = bytes([0x44, 0x49, 0x50, 0x53, 0x48, 0x49, 0x54, 0x4F,
                   0x53, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x32])
DATA_PART_GUID = bytes([0x44, 0x49, 0x50, 0x53, 0x48, 0x49, 0x54, 0x4F,
                        0x53, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x33])


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
    b[71:82] = b"DIPSHITOS  "
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


def build_fat32_image(img, geo, efi_bytes, kernel_bytes=None, user_bytes=None,
                      counter_bytes=None, peer_bytes=None, status43_bytes=None,
                      udp_bytes=None, win_bytes=None, winclose_bytes=None,
                      winloop_bytes=None, winmove_bytes=None,
                      keytest_bytes=None, savetext_bytes=None,
                      type_bytes=None, dir_bytes=None,
                      calc_bytes=None, notepad_bytes=None,
                      top_bytes=None, desktop_bytes=None):
    """Write a FAT32 volume (boot sector, FSInfo, FATs, directories, files)
    into `img` at the volume's offset.

    Directory layout:
      /              DIPSHITOS volume label, EFI/, KERNEL.BIN (when given),
                     USER.BIN (when given), COUNTER.BIN (when given),
                     PEER.BIN (when given), STATUS43.BIN (when given),
                     UDP.BIN (when given), WIN.BIN (when given),
                     WINCLOSE.BIN (when given), WINLOOP.BIN (when given),
                     WINMOVE.BIN (when given), KEYTEST.BIN (when given),
                     SAVETEXT.BIN (when given), TYPE.BIN (when given),
                     DIR.BIN (when given), CALC.BIN (when given),
                     NOTEPAD.BIN (when given), TOP.BIN (when given),
                     DESKTOP.BIN (when given)
      /EFI/          ., .., BOOT/
      /EFI/BOOT/     ., .., BOOTAA64.EFI
    Cluster layout: 2=root, 3=EFI, 4=BOOT, then file data in order.
    Deterministic.
    """
    geo.checks()
    bps = geo.bps
    kernel_clusters = (len(kernel_bytes) + bps - 1) // bps if kernel_bytes else 0
    user_clusters = (len(user_bytes) + bps - 1) // bps if user_bytes else 0
    counter_clusters = (len(counter_bytes) + bps - 1) // bps if counter_bytes else 0
    peer_clusters = (len(peer_bytes) + bps - 1) // bps if peer_bytes else 0
    status43_clusters = (len(status43_bytes) + bps - 1) // bps if status43_bytes else 0
    udp_clusters = (len(udp_bytes) + bps - 1) // bps if udp_bytes else 0
    win_clusters = (len(win_bytes) + bps - 1) // bps if win_bytes else 0
    winclose_clusters = (len(winclose_bytes) + bps - 1) // bps if winclose_bytes else 0
    winloop_clusters = (len(winloop_bytes) + bps - 1) // bps if winloop_bytes else 0
    winmove_clusters = (len(winmove_bytes) + bps - 1) // bps if winmove_bytes else 0
    keytest_clusters = (len(keytest_bytes) + bps - 1) // bps if keytest_bytes else 0
    savetext_clusters = (len(savetext_bytes) + bps - 1) // bps if savetext_bytes else 0
    type_clusters = (len(type_bytes) + bps - 1) // bps if type_bytes else 0
    dir_clusters = (len(dir_bytes) + bps - 1) // bps if dir_bytes else 0
    calc_clusters = (len(calc_bytes) + bps - 1) // bps if calc_bytes else 0
    notepad_clusters = (len(notepad_bytes) + bps - 1) // bps if notepad_bytes else 0
    top_clusters = (len(top_bytes) + bps - 1) // bps if top_bytes else 0
    desktop_clusters = (len(desktop_bytes) + bps - 1) // bps if desktop_bytes else 0
    file_clusters = (len(efi_bytes) + bps - 1) // bps
    root_entries_count = 2  # vol_label + efi_entry
    if kernel_bytes: root_entries_count += 1
    if user_bytes: root_entries_count += 1
    if counter_bytes: root_entries_count += 1
    if peer_bytes: root_entries_count += 1
    if status43_bytes: root_entries_count += 1
    if udp_bytes: root_entries_count += 1
    if win_bytes: root_entries_count += 1
    if winclose_bytes: root_entries_count += 1
    if winloop_bytes: root_entries_count += 1
    if winmove_bytes: root_entries_count += 1
    if keytest_bytes: root_entries_count += 1
    if savetext_bytes: root_entries_count += 1
    if type_bytes: root_entries_count += 1
    if dir_bytes: root_entries_count += 1
    if calc_bytes: root_entries_count += 1
    if notepad_bytes: root_entries_count += 1
    if top_bytes: root_entries_count += 1
    if desktop_bytes: root_entries_count += 1

    root_clusters = (root_entries_count * 32 + bps - 1) // bps
    efi_dir_cluster = 2 + root_clusters
    boot_dir_cluster = efi_dir_cluster + 1
    kernel_start = boot_dir_cluster + 1
    user_start = kernel_start + kernel_clusters
    counter_start = user_start + user_clusters
    peer_start = counter_start + counter_clusters
    status43_start = peer_start + peer_clusters
    udp_start = status43_start + status43_clusters
    win_start = udp_start + udp_clusters
    winclose_start = win_start + win_clusters
    winloop_start = winclose_start + winclose_clusters
    winmove_start = winloop_start + winloop_clusters
    keytest_start = winmove_start + winmove_clusters
    savetext_start = keytest_start + keytest_clusters
    type_start = savetext_start + savetext_clusters
    dir_start = type_start + type_clusters
    calc_start = dir_start + dir_clusters
    notepad_start = calc_start + calc_clusters
    top_start = notepad_start + notepad_clusters
    desktop_start = top_start + top_clusters
    efi_start = desktop_start + desktop_clusters
    allocated = efi_start + file_clusters - 2  # clusters used beyond root(2)
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
            fat[start + i] = start + i + 1 if i < count - 1 else FAT_EOC

    chain(2, root_clusters)           # root directory
    chain(efi_dir_cluster, 1)         # EFI directory
    chain(boot_dir_cluster, 1)        # BOOT directory
    if kernel_bytes:
        chain(kernel_start, kernel_clusters)  # KERNEL.BIN data
    if user_bytes:
        chain(user_start, user_clusters)      # USER.BIN data
    if counter_bytes:
        chain(counter_start, counter_clusters)  # COUNTER.BIN data
    if peer_bytes:
        chain(peer_start, peer_clusters)        # PEER.BIN data
    if status43_bytes:
        chain(status43_start, status43_clusters)  # STATUS43.BIN data
    if udp_bytes:
        chain(udp_start, udp_clusters)            # UDP.BIN data
    if win_bytes:
        chain(win_start, win_clusters)            # WIN.BIN data
    if winclose_bytes:
        chain(winclose_start, winclose_clusters)  # WINCLOSE.BIN data
    if winloop_bytes:
        chain(winloop_start, winloop_clusters)    # WINLOOP.BIN data
    if winmove_bytes:
        chain(winmove_start, winmove_clusters)    # WINMOVE.BIN data
    if keytest_bytes:
        chain(keytest_start, keytest_clusters)    # KEYTEST.BIN data
    if savetext_bytes:
        chain(savetext_start, savetext_clusters)  # SAVETEXT.BIN data
    if type_bytes:
        chain(type_start, type_clusters)          # TYPE.BIN data
    if dir_bytes:
        chain(dir_start, dir_clusters)            # DIR.BIN data
    if calc_bytes:
        chain(calc_start, calc_clusters)          # CALC.BIN data
    if notepad_bytes:
        chain(notepad_start, notepad_clusters)    # NOTEPAD.BIN data
    if top_bytes:
        chain(top_start, top_clusters)            # TOP.BIN data
    if desktop_bytes:
        chain(desktop_start, desktop_clusters)    # DESKTOP.BIN data
    chain(efi_start, file_clusters)            # BOOTAA64.EFI data

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
    vol_label = dir_entry(b"DIPSHITOS  ", 0x08, 0, 0)
    efi_entry = dir_entry(b"EFI        ", 0x10, efi_dir_cluster, 0)
    boot_entry = dir_entry(b"BOOT       ", 0x10, boot_dir_cluster, 0)
    file_entry = dir_entry(b"BOOTAA64EFI", 0x20, efi_start, len(efi_bytes))
    dot_efi = dir_entry(b".          ", 0x10, efi_dir_cluster, 0)
    dotdot_efi = dir_entry(b"..         ", 0x10, 2, 0)
    dot_boot = dir_entry(b".          ", 0x10, boot_dir_cluster, 0)
    dotdot_boot = dir_entry(b"..         ", 0x10, efi_dir_cluster, 0)

    root_entries = vol_label + efi_entry
    if kernel_bytes:
        root_entries += dir_entry(b"KERNEL  BIN", 0x20, kernel_start, len(kernel_bytes))
    if user_bytes:
        root_entries += dir_entry(b"USER    BIN", 0x20, user_start, len(user_bytes))
    if counter_bytes:
        root_entries += dir_entry(b"COUNTER BIN", 0x20, counter_start, len(counter_bytes))
    if peer_bytes:
        root_entries += dir_entry(b"PEER    BIN", 0x20, peer_start, len(peer_bytes))
    if status43_bytes:
        root_entries += dir_entry(b"STATUS43BIN", 0x20, status43_start, len(status43_bytes))
    if udp_bytes:
        root_entries += dir_entry(b"UDP     BIN", 0x20, udp_start, len(udp_bytes))
    if win_bytes:
        root_entries += dir_entry(b"WIN     BIN", 0x20, win_start, len(win_bytes))
    if winclose_bytes:
        root_entries += dir_entry(b"WINCLOSEBIN", 0x20, winclose_start, len(winclose_bytes))
    if winloop_bytes:
        root_entries += dir_entry(b"WINLOOP BIN", 0x20, winloop_start, len(winloop_bytes))
    if winmove_bytes:
        root_entries += dir_entry(b"WINMOVE BIN", 0x20, winmove_start, len(winmove_bytes))
    if keytest_bytes:
        root_entries += dir_entry(b"KEYTEST BIN", 0x20, keytest_start, len(keytest_bytes))
    if savetext_bytes:
        root_entries += dir_entry(b"SAVETEXTBIN", 0x20, savetext_start, len(savetext_bytes))
    if type_bytes:
        root_entries += dir_entry(b"TYPE    BIN", 0x20, type_start, len(type_bytes))
    if dir_bytes:
        root_entries += dir_entry(b"DIR     BIN", 0x20, dir_start, len(dir_bytes))
    if calc_bytes:
        root_entries += dir_entry(b"CALC    BIN", 0x20, calc_start, len(calc_bytes))
    if notepad_bytes:
        root_entries += dir_entry(b"NOTEPAD BIN", 0x20, notepad_start, len(notepad_bytes))
    if top_bytes:
        root_entries += dir_entry(b"TOP     BIN", 0x20, top_start, len(top_bytes))
    if desktop_bytes:
        root_entries += dir_entry(b"DESKTOP BIN", 0x20, desktop_start, len(desktop_bytes))

    root_entries = root_entries.ljust(root_clusters * bps, b"\x00")
    for i in range(root_clusters):
        chunk = root_entries[i * bps:(i + 1) * bps]
        wsec(geo.cluster_sector(2 + i), chunk)
    wsec(geo.cluster_sector(efi_dir_cluster), (dot_efi + dotdot_efi + boot_entry).ljust(bps, b"\x00"))
    wsec(geo.cluster_sector(boot_dir_cluster), (dot_boot + dotdot_boot + file_entry).ljust(bps, b"\x00"))

    # --- file data --------------------------------------------------------
    if kernel_bytes:
        for i in range(kernel_clusters):
            chunk = kernel_bytes[i * bps:(i + 1) * bps]
            wsec(geo.cluster_sector(kernel_start + i), chunk.ljust(bps, b"\x00"))
    if user_bytes:
        for i in range(user_clusters):
            chunk = user_bytes[i * bps:(i + 1) * bps]
            wsec(geo.cluster_sector(user_start + i), chunk.ljust(bps, b"\x00"))
    if counter_bytes:
        for i in range(counter_clusters):
            chunk = counter_bytes[i * bps:(i + 1) * bps]
            wsec(geo.cluster_sector(counter_start + i), chunk.ljust(bps, b"\x00"))
    if peer_bytes:
        for i in range(peer_clusters):
            chunk = peer_bytes[i * bps:(i + 1) * bps]
            wsec(geo.cluster_sector(peer_start + i), chunk.ljust(bps, b"\x00"))
    if status43_bytes:
        for i in range(status43_clusters):
            chunk = status43_bytes[i * bps:(i + 1) * bps]
            wsec(geo.cluster_sector(status43_start + i), chunk.ljust(bps, b"\x00"))
    if udp_bytes:
        for i in range(udp_clusters):
            chunk = udp_bytes[i * bps:(i + 1) * bps]
            wsec(geo.cluster_sector(udp_start + i), chunk.ljust(bps, b"\x00"))
    if win_bytes:
        for i in range(win_clusters):
            chunk = win_bytes[i * bps:(i + 1) * bps]
            wsec(geo.cluster_sector(win_start + i), chunk.ljust(bps, b"\x00"))
    if winclose_bytes:
        for i in range(winclose_clusters):
            chunk = winclose_bytes[i * bps:(i + 1) * bps]
            wsec(geo.cluster_sector(winclose_start + i), chunk.ljust(bps, b"\x00"))
    if winloop_bytes:
        for i in range(winloop_clusters):
            chunk = winloop_bytes[i * bps:(i + 1) * bps]
            wsec(geo.cluster_sector(winloop_start + i), chunk.ljust(bps, b"\x00"))
    if winmove_bytes:
        for i in range(winmove_clusters):
            chunk = winmove_bytes[i * bps:(i + 1) * bps]
            wsec(geo.cluster_sector(winmove_start + i), chunk.ljust(bps, b"\x00"))
    if keytest_bytes:
        for i in range(keytest_clusters):
            chunk = keytest_bytes[i * bps:(i + 1) * bps]
            wsec(geo.cluster_sector(keytest_start + i), chunk.ljust(bps, b"\x00"))
    if savetext_bytes:
        for i in range(savetext_clusters):
            chunk = savetext_bytes[i * bps:(i + 1) * bps]
            wsec(geo.cluster_sector(savetext_start + i), chunk.ljust(bps, b"\x00"))
    if type_bytes:
        for i in range(type_clusters):
            chunk = type_bytes[i * bps:(i + 1) * bps]
            wsec(geo.cluster_sector(type_start + i), chunk.ljust(bps, b"\x00"))
    if dir_bytes:
        for i in range(dir_clusters):
            chunk = dir_bytes[i * bps:(i + 1) * bps]
            wsec(geo.cluster_sector(dir_start + i), chunk.ljust(bps, b"\x00"))
    if calc_bytes:
        for i in range(calc_clusters):
            chunk = calc_bytes[i * bps:(i + 1) * bps]
            wsec(geo.cluster_sector(calc_start + i), chunk.ljust(bps, b"\x00"))
    if notepad_bytes:
        for i in range(notepad_clusters):
            chunk = notepad_bytes[i * bps:(i + 1) * bps]
            wsec(geo.cluster_sector(notepad_start + i), chunk.ljust(bps, b"\x00"))
    if top_bytes:
        for i in range(top_clusters):
            chunk = top_bytes[i * bps:(i + 1) * bps]
            wsec(geo.cluster_sector(top_start + i), chunk.ljust(bps, b"\x00"))
    if desktop_bytes:
        for i in range(desktop_clusters):
            chunk = desktop_bytes[i * bps:(i + 1) * bps]
            wsec(geo.cluster_sector(desktop_start + i), chunk.ljust(bps, b"\x00"))
    for i in range(file_clusters):
        chunk = efi_bytes[i * bps:(i + 1) * bps]
        wsec(geo.cluster_sector(efi_start + i), chunk.ljust(bps, b"\x00"))


def build_data_volume(img, geo):
    """Write the second (data) FAT32 volume — the milestone-four card 2
    general-filesystem partition (arbitrary disk layout, not the ESP).

    Directory layout: / DIPSHITOS volume label, README.TXT (cluster 3),
    DATA.TXT (cluster 4). Deterministic, like the ESP volume.
    """
    geo.checks()
    bps = geo.bps
    readme = (b"DipshitOS general filesystem: a second FAT32 volume on the "
              b"same disk (claim 3678, milestone four card 2)\n")
    data = b"general data volume contents: 1234567890\n"

    fat = [0] * (geo.clusters + 2)
    fat[0] = 0x0FFFFFF8
    fat[1] = 0x0FFFFFFF
    fat[2] = FAT_EOC  # root directory
    fat[3] = FAT_EOC  # README.TXT
    fat[4] = FAT_EOC  # DATA.TXT

    def wsec(sector, blob):
        off = sector * bps
        img[off:off + len(blob)] = blob

    bs = boot_sector(geo)
    wsec(geo.base_lba + 0, bs)
    wsec(geo.base_lba + 1, fs_info_sector())
    wsec(geo.base_lba + 6, bs)
    wsec(geo.base_lba + 7, fs_info_sector())
    fat_bytes = b"".join(struct.pack("<I", e) for e in fat)
    fat_bytes = fat_bytes.ljust(geo.fat_sectors * bps, b"\x00")
    for i in range(geo.nfats):
        wsec(geo.fat_sector(i), fat_bytes)

    root_entries = (dir_entry(b"DIPSHITOS  ", 0x08, 0, 0) +
                    dir_entry(b"README  TXT", 0x20, 3, len(readme)) +
                    dir_entry(b"DATA    TXT", 0x20, 4, len(data)))
    wsec(geo.cluster_sector(2), root_entries.ljust(bps, b"\x00"))
    wsec(geo.cluster_sector(3), readme.ljust(bps, b"\x00"))
    wsec(geo.cluster_sector(4), data.ljust(bps, b"\x00"))


# --------------------------------------------------------------------------
# Shared FAT/GPT parsing for --list and --cat-file
# --------------------------------------------------------------------------

def find_partition_offset(data, type_guid):
    """Return the start LBA of the first partition with `type_guid` (0 if
    absent). Shared by the ESP lookup and the data-partition lookup. Entries
    are 128 bytes, four per sector: entry i lives at
    `entries_lba * sector + i * 128`."""
    if data[512:520] != b"EFI PART":
        return 0
    entries_lba = struct.unpack_from("<Q", data, 512 + 72)[0]
    num = struct.unpack_from("<I", data, 512 + 80)[0]
    for i in range(min(num, 16)):
        off = entries_lba * BYTES_PER_SECTOR + i * 128
        e = data[off:off + 128]
        if e[0:16] == type_guid:
            return struct.unpack_from("<Q", e, 32)[0]
    return 0


def find_esp_offset(data):
    return find_partition_offset(data, ESP_GUID)


def find_data_offset(data):
    return find_partition_offset(data, DATA_GUID)


def read_fat_geometry(data, base_lba):
    """Parse the FAT32 BPB at `base_lba` into a lightweight geo object."""
    base = base_lba * BYTES_PER_SECTOR
    if data[base + 510] != 0x55 or data[base + 511] != 0xAA:
        raise ValueError("no FAT boot signature at LBA %d" % base_lba)
    geo = Fat32Geometry.__new__(Fat32Geometry)
    geo.bps = struct.unpack_from("<H", data, base + 11)[0]
    geo.spc = data[base + 13]
    geo.reserved = struct.unpack_from("<H", data, base + 14)[0]
    geo.nfats = data[base + 16]
    geo.fat_sectors = struct.unpack_from("<I", data, base + 36)[0]
    geo.root_cluster = struct.unpack_from("<I", data, base + 44)[0]
    geo.base_lba = base_lba
    geo.data_start = geo.reserved + geo.nfats * geo.fat_sectors
    geo.total_sectors = struct.unpack_from("<I", data, base + 32)[0]
    geo.clusters = 0
    return geo


def encode_83(name):
    """Encode a short path component as an 11-byte 8.3 name."""
    stem, _, ext = name.upper().rpartition(".")
    stem = stem[:8].ljust(8)
    ext = ext[:3].ljust(3)
    return (stem + ext).encode("latin-1")


def cat_file(path, wanted):
    """Print the contents of one file on the FAT volume, resolved by 8.3
    path (e.g. /BOOTED.TXT). Returns 0 on success, 1 if not found."""
    with open(path, "rb") as f:
        data = f.read()
    esp = find_esp_offset(data)
    if esp == 0:
        print("cat-file: no ESP partition found", file=sys.stderr)
        return 1
    geo = read_fat_geometry(data, esp)
    parts = [p for p in wanted.strip("/\\").split("/") if p]
    if not parts:
        print("cat-file: empty path", file=sys.stderr)
        return 1

    def read_dir(cluster):
        entries = []
        seen = set()
        while cluster not in (FAT_EOC, FAT_BAD) and cluster not in seen:
            seen.add(cluster)
            entries.extend(read_cluster(data, geo, cluster))
            cluster = fat_next(data, geo, cluster)
        return entries

    cluster = geo.root_cluster
    for part in parts:
        target = encode_83(part)
        found = None
        for e in read_dir(cluster):
            if e[0] in (0x00, 0xE5):
                continue
            if e[0:11] == target:
                found = e
                break
        if found is None:
            print("cat-file: %r not found in volume" % wanted, file=sys.stderr)
            return 1
        cluster = ((struct.unpack_from("<H", found, 20)[0] << 16)
                   | struct.unpack_from("<H", found, 26)[0])
        if not (found[11] & 0x10) and part is not parts[-1]:
            print("cat-file: %r is not a directory" % part, file=sys.stderr)
            return 1

    size = struct.unpack_from("<I", found, 28)[0]
    out = bytearray()
    seen = set()
    while cluster not in (FAT_EOC, FAT_BAD) and cluster not in seen and len(out) < size:
        seen.add(cluster)
        sec = geo.cluster_sector(cluster)
        blob = data[sec * geo.bps:(sec + 1) * geo.bps]
        out.extend(blob[:size - len(out)])
        cluster = fat_next(data, geo, cluster)
    sys.stdout.buffer.write(bytes(out))
    if out and not out.endswith(b"\n"):
        sys.stdout.buffer.write(b"\n")
    return 0


# --------------------------------------------------------------------------
# Inspection (--list)
# --------------------------------------------------------------------------

def read_cluster(data, geo, cluster):
    """Return the raw bytes of one cluster as a list of 32-byte entries."""
    sec = geo.cluster_sector(cluster)
    blob = data[sec * geo.bps:(sec + 1) * geo.bps]
    return [blob[i * 32:(i + 1) * 32] for i in range(16)]


def fat_next(data, geo, cluster):
    """Read the FAT to find the next cluster in a chain (FAT copy 0)."""
    off = geo.fat_sector(0) * geo.bps + cluster * 4
    return struct.unpack_from("<I", data, off)[0] & 0x0FFFFFFF


def decode_83(e):
    name = e[0:8].decode("latin-1", "replace").rstrip(" ")
    ext = e[8:11].decode("latin-1", "replace").rstrip(" ")
    return (name + "." + ext) if ext else name


def list_image(path):
    with open(path, "rb") as f:
        data = f.read()
    total_sectors = len(data) // BYTES_PER_SECTOR

    print("size: %d bytes (%d sectors)" % (len(data), total_sectors))
    print("LBA0: %s" % ("MBR present" if data[510:512] == b"\x55\xaa" else "no MBR signature"))

    if data[512:520] == b"EFI PART":
        hdr_crc = struct.unpack_from("<I", data, 512 + 16)[0]
        print("GPT: valid signature, header crc32=0x%08x" % hdr_crc)
    else:
        print("GPT: no GPT signature at LBA 1 (expecting one for DipshitOS images)")

    esp_offset = find_esp_offset(data)
    if esp_offset == 0:
        print("FAT: no ESP partition found -- cannot list FAT contents")
        return 1

    try:
        geo = read_fat_geometry(data, esp_offset)
    except ValueError as exc:
        print("FAT: %s" % exc)
        return 1
    base = esp_offset * BYTES_PER_SECTOR
    vol_label = data[base + 71:base + 82].decode("latin-1", "replace").rstrip(" ")
    print("GPT: ESP partition at LBA %d, %d sectors" %
          (esp_offset, geo.total_sectors))
    data_offset = find_data_offset(data)
    if data_offset:
        dgeo = read_fat_geometry(data, data_offset)
        print("GPT: DATA partition at LBA %d, %d sectors" %
              (data_offset, dgeo.total_sectors))
    print("FAT: boot sig ok, label=%r, %d-byte sectors, %d sector/cluster, "
          "%d reserved, %d FATs x %d sectors, root cluster %d" %
          (vol_label, geo.bps, geo.spc, geo.reserved, geo.nfats,
           geo.fat_sectors, geo.root_cluster))

    def walk(cluster, indent):
        seen = set()
        while cluster not in (FAT_EOC, FAT_BAD) and cluster not in seen:
            seen.add(cluster)
            for e in read_cluster(data, geo, cluster):
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
            cluster = fat_next(data, geo, cluster)

    print("FAT: directory tree:")
    walk(geo.root_cluster, "  ")
    return 0


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

def build_image(total_sectors, esp_offset, efi_bytes, kernel_bytes=None,
                user_bytes=None, counter_bytes=None, peer_bytes=None,
                status43_bytes=None, udp_bytes=None, win_bytes=None,
                winclose_bytes=None, winloop_bytes=None, winmove_bytes=None,
                keytest_bytes=None, savetext_bytes=None, type_bytes=None,
                dir_bytes=None, calc_bytes=None, notepad_bytes=None,
                top_bytes=None, desktop_bytes=None):
    img = bytearray(total_sectors * BYTES_PER_SECTOR)
    last_usable = total_sectors - 34
    first_usable = 34
    disk_guid = DISK_GUID

    # Partition table: the ESP (LBA esp_offset..) plus a second "data"
    # FAT32 partition at the tail of the disk (milestone-four card 2). The
    # data partition must be > 65525 clusters (FAT32) — 36 MiB at spc=1.
    data_sectors = DATA_MB * 1024 * 1024 // BYTES_PER_SECTOR
    data_start = last_usable - data_sectors + 1
    esp_last = data_start - 1
    entries = bytearray(128 * 128)
    entries[0:128] = partition_entry(ESP_GUID, esp_offset, esp_last, "EFI SYSTEM")
    entries[128:256] = partition_entry(DATA_GUID, data_start, last_usable,
                                       "DIPSHITOS DATA", unique_guid=DATA_PART_GUID)
    entries_crc = zlib.crc32(bytes(entries)) & 0xFFFFFFFF
    backup_entries_lba = last_usable + 1  # == total_sectors - 33

    img[0:BYTES_PER_SECTOR] = protective_mbr(total_sectors)
    # NOTE: every write below uses closed slices whose length matches the
    # RHS length. A mismatched slice assignment would silently grow or shrink
    # the bytearray and corrupt the image.
    hdr = gpt_header(1, total_sectors - 1, first_usable, last_usable,
                     2, entries_crc, disk_guid)
    img[BYTES_PER_SECTOR:2 * BYTES_PER_SECTOR] = hdr.ljust(BYTES_PER_SECTOR, b"\x00")
    img[2 * BYTES_PER_SECTOR:2 * BYTES_PER_SECTOR + len(entries)] = entries
    bhdr = gpt_header(total_sectors - 1, 1, first_usable, last_usable,
                      backup_entries_lba, entries_crc, disk_guid)
    img[(total_sectors - 1) * BYTES_PER_SECTOR:
        (total_sectors - 1) * BYTES_PER_SECTOR + BYTES_PER_SECTOR] = \
        bhdr.ljust(BYTES_PER_SECTOR, b"\x00")
    img[backup_entries_lba * BYTES_PER_SECTOR:
        backup_entries_lba * BYTES_PER_SECTOR + len(entries)] = entries

    # FAT32 volumes: the ESP and the data partition.
    volume_sectors = esp_last - esp_offset + 1
    geo = Fat32Geometry(volume_sectors, esp_offset)
    build_fat32_image(img, geo, efi_bytes, kernel_bytes, user_bytes,
                      counter_bytes, peer_bytes, status43_bytes, udp_bytes,
                      win_bytes, winclose_bytes, winloop_bytes, winmove_bytes,
                      keytest_bytes, savetext_bytes, type_bytes, dir_bytes,
                      calc_bytes, notepad_bytes, top_bytes, desktop_bytes)
    geo_data = Fat32Geometry(data_sectors, data_start)
    build_data_volume(img, geo_data)
    return bytes(img)


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--size-mb", type=int, default=SIZE_MB_DEFAULT,
                    help="total image size in MiB (default %d)" % SIZE_MB_DEFAULT)
    ap.add_argument("--esp-offset", type=int, default=ESP_OFFSET_DEFAULT,
                    help="ESP start LBA (default %d)" % ESP_OFFSET_DEFAULT)
    ap.add_argument("--list", action="store_true",
                    help="inspect an existing image instead of building")
    ap.add_argument("--cat-file", metavar="PATH",
                    help="print the contents of a file on the FAT volume")
    ap.add_argument("image", help="disk image path")
    ap.add_argument("efi_file", nargs="?", help="PE/COFF EFI application to embed")
    ap.add_argument("kernel_file", nargs="?",
                    help="optional flat kernel image (KERNEL.BIN) to embed at the volume root")
    ap.add_argument("user_file", nargs="?",
                    help="optional flat user program (USER.BIN) to embed at the volume root (claim 6783)")
    ap.add_argument("counter_file", nargs="?",
                    help="optional flat user program (COUNTER.BIN) to embed at the volume root (claim 4613)")
    ap.add_argument("peer_file", nargs="?",
                    help="optional flat user program (PEER.BIN) to embed at the volume root (claim 5965)")
    ap.add_argument("status43_file", nargs="?",
                    help="optional flat user program (STATUS43.BIN) to embed at the volume root (claim 9946)")
    ap.add_argument("udp_file", nargs="?",
                    help="optional flat user program (UDP.BIN) to embed at the volume root (claim 1384)")
    ap.add_argument("win_file", nargs="?",
                    help="optional flat user program (WIN.BIN) to embed at the volume root (claim 0487)")
    ap.add_argument("winclose_file", nargs="?",
                    help="optional flat user program (WINCLOSE.BIN) to embed at the volume root (claim 0487 teardown follow-on)")
    ap.add_argument("winloop_file", nargs="?",
                    help="optional flat user program (WINLOOP.BIN) to embed at the volume root (claim 0487 ownership follow-on)")
    ap.add_argument("winmove_file", nargs="?",
                    help="optional flat user program (WINMOVE.BIN) to embed at the volume root (claim 0487 move/raise follow-on)")
    ap.add_argument("keytest_file", nargs="?",
                    help="optional flat user program (KEYTEST.BIN) to embed at the volume root (claim 9328)")
    ap.add_argument("savetext_file", nargs="?",
                    help="optional flat user program (SAVETEXT.BIN) to embed at the volume root (claim 0510)")
    ap.add_argument("type_file", nargs="?",
                    help="optional flat user program (TYPE.BIN) to embed at the volume root (claim 0510)")
    ap.add_argument("dir_file", nargs="?",
                    help="optional flat user program (DIR.BIN) to embed at the volume root (claim 0510)")
    ap.add_argument("calc_file", nargs="?",
                    help="optional flat user program (CALC.BIN) to embed at the volume root (claim 8401)")
    ap.add_argument("notepad_file", nargs="?",
                    help="optional flat user program (NOTEPAD.BIN) to embed at the volume root")
    ap.add_argument("top_file", nargs="?",
                    help="optional flat user program (TOP.BIN) to embed at the volume root")
    ap.add_argument("desktop_file", nargs="?",
                    help="optional flat user program (DESKTOP.BIN) to embed at the volume root")
    args = ap.parse_args(argv)

    if args.list:
        return list_image(args.image)

    if args.cat_file:
        return cat_file(args.image, args.cat_file)

    if not args.efi_file:
        ap.error("efi_file is required when not using --list")
    with open(args.efi_file, "rb") as f:
        efi_bytes = f.read()
    if not efi_bytes.startswith(b"MZ"):
        print("WARNING: %s does not start with 'MZ'; it may not be a valid "
              "PE/COFF EFI application" % args.efi_file, file=sys.stderr)

    kernel_bytes = None
    if args.kernel_file:
        with open(args.kernel_file, "rb") as f:
            kernel_bytes = f.read()
        if kernel_bytes[:4] != b"DSK1":
            print("WARNING: %s does not start with the 'DSK1' magic; it may "
                  "not be a DipshitOS kernel image" % args.kernel_file,
                  file=sys.stderr)

    user_bytes = None
    if args.user_file:
        with open(args.user_file, "rb") as f:
            user_bytes = f.read()
        if user_bytes[:4] != b"DSK1":
            print("WARNING: %s does not start with the 'DSK1' magic; it may "
                  "not be a DipshitOS user program image" % args.user_file,
                  file=sys.stderr)

    counter_bytes = None
    if args.counter_file:
        with open(args.counter_file, "rb") as f:
            counter_bytes = f.read()
        if counter_bytes[:4] != b"DSK1":
            print("WARNING: %s does not start with the 'DSK1' magic; it may "
                  "not be a DipshitOS user program image" % args.counter_file,
                  file=sys.stderr)

    peer_bytes = None
    if args.peer_file:
        with open(args.peer_file, "rb") as f:
            peer_bytes = f.read()
        if peer_bytes[:4] != b"DSK1":
            print("WARNING: %s does not start with the 'DSK1' magic; it may "
                  "not be a DipshitOS user program image" % args.peer_file,
                  file=sys.stderr)

    status43_bytes = None
    if args.status43_file:
        with open(args.status43_file, "rb") as f:
            status43_bytes = f.read()
        if status43_bytes[:4] != b"DSK1":
            print("WARNING: %s does not start with the 'DSK1' magic; it may "
                  "not be a DipshitOS user program image" % args.status43_file,
                  file=sys.stderr)

    udp_bytes = None
    if args.udp_file:
        with open(args.udp_file, "rb") as f:
            udp_bytes = f.read()
        if udp_bytes[:4] != b"DSK1":
            print("WARNING: %s does not start with the 'DSK1' magic; it may "
                  "not be a DipshitOS user program image" % args.udp_file,
                  file=sys.stderr)

    win_bytes = None
    if args.win_file:
        with open(args.win_file, "rb") as f:
            win_bytes = f.read()
        if win_bytes[:4] != b"DSK1":
            print("WARNING: %s does not start with the 'DSK1' magic; it may "
                  "not be a DipshitOS user program image" % args.win_file,
                  file=sys.stderr)

    winclose_bytes = None
    if args.winclose_file:
        with open(args.winclose_file, "rb") as f:
            winclose_bytes = f.read()
        if winclose_bytes[:4] != b"DSK1":
            print("WARNING: %s does not start with the 'DSK1' magic; it may "
                  "not be a DipshitOS user program image" % args.winclose_file,
                  file=sys.stderr)

    winloop_bytes = None
    if args.winloop_file:
        with open(args.winloop_file, "rb") as f:
            winloop_bytes = f.read()
        if winloop_bytes[:4] != b"DSK1":
            print("WARNING: %s does not start with the 'DSK1' magic; it may "
                  "not be a DipshitOS user program image" % args.winloop_file,
                  file=sys.stderr)

    winmove_bytes = None
    if args.winmove_file:
        with open(args.winmove_file, "rb") as f:
            winmove_bytes = f.read()
        if winmove_bytes[:4] != b"DSK1":
            print("WARNING: %s does not start with the 'DSK1' magic; it may "
                  "not be a DipshitOS user program image" % args.winmove_file,
                  file=sys.stderr)

    keytest_bytes = None
    if args.keytest_file:
        with open(args.keytest_file, "rb") as f:
            keytest_bytes = f.read()
        if keytest_bytes[:4] != b"DSK1":
            print("WARNING: %s does not start with the 'DSK1' magic; it may "
                  "not be a DipshitOS user program image" % args.keytest_file,
                  file=sys.stderr)

    savetext_bytes = None
    if args.savetext_file:
        with open(args.savetext_file, "rb") as f:
            savetext_bytes = f.read()
        if savetext_bytes[:4] != b"DSK1":
            print("WARNING: %s does not start with the 'DSK1' magic; it may "
                  "not be a DipshitOS user program image" % args.savetext_file,
                  file=sys.stderr)

    type_bytes = None
    if args.type_file:
        with open(args.type_file, "rb") as f:
            type_bytes = f.read()
        if type_bytes[:4] != b"DSK1":
            print("WARNING: %s does not start with the 'DSK1' magic; it may "
                  "not be a DipshitOS user program image" % args.type_file,
                  file=sys.stderr)

    dir_bytes = None
    if args.dir_file:
        with open(args.dir_file, "rb") as f:
            dir_bytes = f.read()
        if dir_bytes[:4] != b"DSK1":
            print("WARNING: %s does not start with the 'DSK1' magic; it may "
                  "not be a DipshitOS user program image" % args.dir_file,
                  file=sys.stderr)

    calc_bytes = None
    if args.calc_file:
        with open(args.calc_file, "rb") as f:
            calc_bytes = f.read()
        if calc_bytes[:4] != b"DSK1":
            print("WARNING: %s does not start with the 'DSK1' magic; it may "
                  "not be a DipshitOS user program image" % args.calc_file,
                  file=sys.stderr)

    notepad_bytes = None
    if args.notepad_file:
        with open(args.notepad_file, "rb") as f:
            notepad_bytes = f.read()
        if notepad_bytes[:4] != b"DSK1":
            print("WARNING: %s does not start with the 'DSK1' magic; it may "
                  "not be a DipshitOS user program image" % args.notepad_file,
                  file=sys.stderr)

    top_bytes = None
    if args.top_file:
        with open(args.top_file, "rb") as f:
            top_bytes = f.read()
        if top_bytes[:4] != b"DSK1":
            print("WARNING: %s does not start with the 'DSK1' magic; it may "
                  "not be a DipshitOS user program image" % args.top_file,
                  file=sys.stderr)

    desktop_bytes = None
    if args.desktop_file:
        with open(args.desktop_file, "rb") as f:
            desktop_bytes = f.read()
        if desktop_bytes[:4] != b"DSK1":
            print("WARNING: %s does not start with the 'DSK1' magic; it may "
                  "not be a DipshitOS user program image" % args.desktop_file,
                  file=sys.stderr)

    total_sectors = args.size_mb * 1024 * 1024 // BYTES_PER_SECTOR
    img = build_image(total_sectors, args.esp_offset, efi_bytes, kernel_bytes,
                      user_bytes, counter_bytes, peer_bytes, status43_bytes,
                      udp_bytes, win_bytes, winclose_bytes, winloop_bytes,
                      winmove_bytes, keytest_bytes, savetext_bytes, type_bytes,
                      dir_bytes, calc_bytes, notepad_bytes, top_bytes, desktop_bytes)
    with open(args.image, "wb") as f:
        f.write(img)
    extra = ", %d-byte kernel image embedded" % len(kernel_bytes) if kernel_bytes else ""
    extra += ", %d-byte user program embedded" % len(user_bytes) if user_bytes else ""
    extra += ", %d-byte counter program embedded" % len(counter_bytes) if counter_bytes else ""
    extra += ", %d-byte peer program embedded" % len(peer_bytes) if peer_bytes else ""
    extra += ", %d-byte status43 program embedded" % len(status43_bytes) if status43_bytes else ""
    extra += ", %d-byte udp program embedded" % len(udp_bytes) if udp_bytes else ""
    extra += ", %d-byte win program embedded" % len(win_bytes) if win_bytes else ""
    extra += ", %d-byte winclose program embedded" % len(winclose_bytes) if winclose_bytes else ""
    extra += ", %d-byte winloop program embedded" % len(winloop_bytes) if winloop_bytes else ""
    extra += ", %d-byte winmove program embedded" % len(winmove_bytes) if winmove_bytes else ""
    extra += ", %d-byte keytest program embedded" % len(keytest_bytes) if keytest_bytes else ""
    extra += ", %d-byte savetext program embedded" % len(savetext_bytes) if savetext_bytes else ""
    extra += ", %d-byte type program embedded" % len(type_bytes) if type_bytes else ""
    extra += ", %d-byte dir program embedded" % len(dir_bytes) if dir_bytes else ""
    extra += ", %d-byte calc program embedded" % len(calc_bytes) if calc_bytes else ""
    extra += ", %d-byte notepad program embedded" % len(notepad_bytes) if notepad_bytes else ""
    extra += ", %d-byte top program embedded" % len(top_bytes) if top_bytes else ""
    extra += ", %d-byte desktop program embedded" % len(desktop_bytes) if desktop_bytes else ""
    print("wrote %s: %d MiB, ESP at LBA %d, %d-byte EFI application embedded%s" %
          (args.image, args.size_mb, args.esp_offset, len(efi_bytes), extra))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

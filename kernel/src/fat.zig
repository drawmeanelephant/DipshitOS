//! DipshitOS FAT32 storage driver (milestone-three card, claim 6420).
//!
//! A real FAT32 filesystem over the ESP: GPT partition discovery, FAT32
//! mount, root-directory listing, file reads (short + long names), and file
//! writes (cluster allocation + FAT + directory-entry updates). It replaces
//! claim 3475's NVRAM persistence medium: `ls`/`cat`/`write` now serve the
//! live ESP through this module (driven on VZ by `virtio_blk.zig`).
//! Milestone four card 2 generalizes it: `mount_partition` mounts ANY
//! volume at any LBA, and the directory machinery walks ANY cluster chain
//! with `/`-path resolution (`read_file`/`write_file`/`list_path` reach
//! subdirectories like `EFI/BOOT/BOOTAA64.EFI`).
//!
//! The module is pure filesystem logic over an injected sector interface —
//! no hardware, no libc, no allocation, no interrupts. Host tests run it
//! against an in-memory image built with the exact byte layout of
//! `image/mkfat32.py` (the deterministic image the build produces), so the
//! parser is verified against the real on-disk format before it ever sees a
//! virtio-blk device.
//!
//! Honesty rules (mirroring the codebase): every limit is a fixed constant;
//! every walk is bounded; a failed sector read/write is reported and never
//! changes control flow; `write` updates the FAT copies and the directory
//! entry with the same structural validity the firmware's own parser
//! expects (the loader writes BOOTED.TXT/MEMMAP.TXT/LOADER.TXT on the same
//! volume via EFI Simple File System, so a corrupted write would break the
//! next boot). GPT header CRCs are not verified (bounded reads only; the
//! partition-type GUID is the identity check). FSInfo hints are not
//! maintained — cluster allocation is authoritative FAT scanning.

const std = @import("std");

pub const sector_size: usize = 512;
/// Per-file write cap. Matches the ESP window's per-file content cap
/// (`esp.esp_content_max`) so every written file is also content-loaded for
/// `cat`.
pub const write_content_max: usize = 2048;
/// Display-name cap (long names longer than this fall back to the 8.3
/// short name).
pub const name_max: usize = 64;
/// Root-directory slot window (32-byte entries). The image's root is one
/// cluster (16 slots); the chain follower bounds at this many slots.
pub const max_root_slots: usize = 128;
/// Bound on clusters followed per chain (files / directory chains).
const max_chain_clusters: usize = 512;
/// Bound on clusters allocated for one write (write_content_max / 512 + 1).
const max_alloc_clusters: usize = 64;
/// Bound on LFN parts kept in memory (a 255-char name needs 20; the root
/// cluster holds 16 slots, so 16 parts is already generous).
const max_lfn_parts: usize = 16;
/// Maximum path depth (components) — bounds the directory walk (each
/// component is additionally bounded by `name_max`).
const max_path_parts: usize = 8;

/// FAT end-of-chain markers (FAT32 spec §7.4): 0x0FFFFFF8+.
const fat_eoc: u32 = 0x0fffffff;
const fat_eoc_min: u32 = 0x0ffffff8;

/// GPT type GUID of the EFI System Partition (the bytes mkfat32.py writes).
const esp_type_guid = [16]u8{ 0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11, 0xba, 0x4b, 0x00, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b };

/// GPT type GUID of the DATA partition — the Linux filesystem GUID
/// 0FC63DAF-8483-4772-8E79-3D69D8477DE4 (the bytes mkfat32.py writes). A
/// second FAT32 volume on the same disk, mounted by `mount_data`
/// (milestone four card 2: the general, non-ESP filesystem).
const data_type_guid = [16]u8{ 0xaf, 0x3d, 0xc6, 0x0f, 0x83, 0x84, 0x72, 0x47, 0x8e, 0x79, 0x3d, 0x69, 0xd8, 0x47, 0x7d, 0xe4 };

/// The injected sector interface. Each call transfers exactly one 512-byte
/// sector; `true` on success. `virtio_blk.zig` implements these over the
/// virtio-blk queue; tests implement them over an in-memory image.
pub const DiskOps = struct {
    read: *const fn (lba: u64, buf: *[sector_size]u8) bool,
    write: *const fn (lba: u64, data: *const [sector_size]u8) bool,
};

pub const MountResult = enum { ok, no_disk, bad_gpt, bad_bpb, io_failed };

pub const WriteResult = enum {
    ok,
    no_disk,
    name_too_long,
    content_too_long,
    /// A `/`-path parent component is absent or is not a directory.
    bad_path,
    disk_full,
    io_failed,
};

/// One decoded root-directory entry (as `ls` reports it).
pub const DirEntry = struct {
    /// Display name (LFN when present and valid, else the 8.3 name).
    name: [name_max]u8,
    name_len: u8,
    size: u32,
    is_dir: bool,
    cluster: u32,
    /// The raw 8.3 short name (write lookup / replace key).
    short: [11]u8,
};

/// The parsed geometry, exposed for diagnostics. `vol_lba` is the first
/// sector of the MOUNTED volume (the ESP at boot; any partition via
/// `mount_partition` — milestone four card 2).
pub const Geo = struct {
    vol_lba: u64,
    bps: u16,
    spc: u8,
    reserved: u16,
    nfats: u8,
    fat_sectors: u32,
    root_cluster: u32,
    data_start: u64,
    total_sectors: u32,
    total_clusters: u32,
};

// ---------------------------------------------------------------------------
// Module state (fixed BSS; single-threaded kernel)
// ---------------------------------------------------------------------------

const State = struct {
    ops: ?DiskOps = null,
    mounted: bool = false,
    geo: Geo = .{
        .vol_lba = 0,
        .bps = sector_size,
        .spc = 1,
        .reserved = 0,
        .nfats = 0,
        .fat_sectors = 0,
        .root_cluster = 0,
        .data_start = 0,
        .total_sectors = 0,
        .total_clusters = 0,
    },
    /// LBA of the last failed sector operation (diagnostics).
    last_fail_lba: u64 = 0,
};

var state: State = .{};

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Install the sector interface and mount the FAT32 volume at `base_lba`
/// (the partition's first sector, holding its BPB) — the general volume
/// entry point (milestone four card 2): ANY FAT32 volume at ANY disk
/// offset, not just the ESP. Parses the BPB and computes the geometry;
/// `ops == null` mounts nothing (honest no-disk state; `write`/`read`
/// report it).
pub fn mount_partition(ops: ?DiskOps, base_lba: u64) MountResult {
    if (ops == null) {
        state.ops = null;
        state.mounted = false;
        return .no_disk;
    }
    state.ops = ops;
    state.mounted = false;
    state.last_fail_lba = 0;

    // FAT32 BPB at the volume start.
    var hdr: [sector_size]u8 = undefined;
    if (!read_sector(base_lba, &hdr)) return .io_failed;
    if (hdr[510] != 0x55 or hdr[511] != 0xaa) return .bad_bpb;
    const bps = read_le(u16, hdr[11..13]);
    const spc = hdr[13];
    const reserved = read_le(u16, hdr[14..16]);
    const nfats = hdr[16];
    const total_sectors = read_le(u32, hdr[32..36]);
    const fat_sectors = read_le(u32, hdr[36..40]);
    const root_cluster = read_le(u32, hdr[44..48]);
    if (bps != sector_size or spc == 0 or reserved == 0 or nfats == 0 or fat_sectors == 0) return .bad_bpb;
    if (root_cluster < 2) return .bad_bpb;
    const data_start: u64 = @as(u64, reserved) + @as(u64, nfats) * fat_sectors;
    if (data_start >= total_sectors) return .bad_bpb;
    const total_clusters: u32 = @intCast((@as(u64, total_sectors) - data_start) / spc);

    state.geo = .{
        .vol_lba = base_lba,
        .bps = bps,
        .spc = spc,
        .reserved = reserved,
        .nfats = nfats,
        .fat_sectors = fat_sectors,
        .root_cluster = root_cluster,
        .data_start = data_start,
        .total_sectors = total_sectors,
        .total_clusters = total_clusters,
    };
    state.mounted = true;
    return .ok;
}

/// Install the sector interface and mount the ESP: locate the EFI System
/// Partition by type GUID in the GPT and mount its volume
/// (`mount_partition`). The ESP stays the boot default (claim 6420);
/// `mount_partition` is the general entry point and `mount_data` mounts
/// the second FAT32 volume (milestone four card 2).
pub fn mount(ops: ?DiskOps) MountResult {
    if (ops == null) {
        state.ops = null;
        state.mounted = false;
        return .no_disk;
    }
    state.ops = ops;
    state.mounted = false;
    state.last_fail_lba = 0;
    switch (gpt_partition_lba(esp_type_guid)) {
        .found => |lba| return mount_partition(ops, lba),
        .not_found => return .bad_gpt,
        .io_failed => return .io_failed,
    }
}

/// Mount the DATA partition — the second FAT32 volume on the disk
/// (Linux-filesystem type GUID, the bytes mkfat32.py writes) — the general,
/// non-ESP filesystem (milestone four card 2). GPT discovery then
/// `mount_partition`.
pub fn mount_data(ops: ?DiskOps) MountResult {
    if (ops == null) {
        state.ops = null;
        state.mounted = false;
        return .no_disk;
    }
    state.ops = ops;
    state.mounted = false;
    state.last_fail_lba = 0;
    switch (gpt_partition_lba(data_type_guid)) {
        .found => |lba| return mount_partition(ops, lba),
        .not_found => return .bad_gpt,
        .io_failed => return .io_failed,
    }
}

/// Walk the GPT partition entries (header at LBA 1, entries table after)
/// for the first partition whose type GUID matches `type_guid` — the shared
/// discovery behind `mount` (ESP) and `mount_data` (data partition).
const GptLookup = union(enum) { found: u64, not_found, io_failed };

fn gpt_partition_lba(type_guid: [16]u8) GptLookup {
    // GPT header at LBA 1 (mkfat32.py layout; the protective MBR at LBA 0
    // is not parsed — the GPT is the identity).
    var hdr: [sector_size]u8 = undefined;
    if (!read_sector(1, &hdr)) return .io_failed;
    if (!std.mem.eql(u8, hdr[0..8], "EFI PART")) return .not_found;
    const entries_lba = read_le(u64, hdr[72..80]);
    const num_entries = read_le(u32, hdr[80..84]);
    const entry_size = read_le(u32, hdr[84..88]);
    if (entries_lba == 0 or num_entries == 0 or num_entries > 128 or entry_size < 128 or entry_size > sector_size) return .not_found;

    var ei: u32 = 0;
    while (ei < num_entries) : (ei += 1) {
        const slot = entries_lba + @as(u64, ei) * entry_size / sector_size;
        const off = @as(usize, ei) * entry_size % sector_size;
        if (!read_sector(slot, &hdr)) return .io_failed;
        if (off + 128 > sector_size) continue;
        if (std.mem.eql(u8, hdr[off .. off + 16], &type_guid)) {
            return .{ .found = read_le(u64, hdr[off + 32 .. off + 40]) };
        }
    }
    return .not_found;
}

pub fn mounted() bool {
    return state.mounted;
}

pub fn geometry() Geo {
    return state.geo;
}

/// LBA of the last failed sector operation (0 = none this mount).
pub fn last_fail_lba() u64 {
    return state.last_fail_lba;
}

/// Number of free clusters (FAT entries == 0). Bounded scan; 0 on error or
/// when not mounted (callers report it honestly as "unknown").
pub fn free_clusters() u32 {
    if (!state.mounted) return 0;
    var free: u32 = 0;
    var scan = FatScan{};
    var c: u32 = 2;
    while (c < state.geo.total_clusters and free < 0x7fffffff) : (c += 1) {
        if (scan.entry(c) == 0) free += 1;
    }
    return free;
}

/// List a DIRECTORY's entries (any cluster chain — milestone four card 2):
/// skipping the volume label, `.`/`..`, and deleted slots. Returns the
/// number of entries written to `out` (≤ out.len). Long-name entries are
/// decoded into the display name when their checksum matches the following
/// short entry. The root directory is the special case
/// `cluster == state.geo.root_cluster`.
pub fn list_dir(cluster: u32, out: []DirEntry) usize {
    if (!state.mounted) return 0;
    var slots: [max_root_slots]SlotRef = undefined;
    const n = collect_dir_slots(cluster, &slots);
    var count: usize = 0;
    var lfn: LfnAccum = .{};
    var i: usize = 0;
    while (i < n and count < out.len) : (i += 1) {
        const ref = slots[i];
        var raw: [32]u8 = undefined;
        if (!read_dir_slot(ref, &raw)) {
            lfn = .{};
            continue;
        }
        const first = raw[0];
        if (first == 0x00) break; // end of directory
        if (first == 0xe5) { // deleted slot
            lfn = .{};
            continue;
        }
        const attr = raw[11];
        if (attr & 0x0f == 0x0f) { // LFN part
            lfn.accumulate(raw);
            continue;
        }
        if (attr & 0x08 != 0) { // volume label
            lfn = .{};
            continue;
        }
        var e = decode_entry(raw, lfn.consume(raw));
        lfn = .{};
        if (std.mem.eql(u8, e.name[0..e.name_len], ".") or std.mem.eql(u8, e.name[0..e.name_len], "..")) continue;
        out[count] = e;
        count += 1;
    }
    return count;
}

/// List the root directory (unchanged behavior — the root is the special
/// case of `list_dir`; the ESP window's snapshot source).
pub fn list_root(out: []DirEntry) usize {
    return list_dir(state.geo.root_cluster, out);
}

/// List a directory by `/`-path (every component must be a directory; a
/// bare name or empty path lists the root). 0 when a component is absent
/// or not a directory, or the volume is unmounted.
pub fn list_path(path: []const u8, out: []DirEntry) usize {
    if (!state.mounted) return 0;
    const cluster = dir_cluster_of_path(path) orelse return 0;
    return list_dir(cluster, out);
}

/// Read a file's content into `out` — by bare name (against the root, as
/// before) or by `/`-path (milestone four card 2). Returns the number of
/// bytes copied (min(file size, out.len)), or null when the file is absent
/// or is a directory. Case-insensitive on the 8.3 name (FAT semantics) and
/// on the display name.
pub fn read_file(name: []const u8, out: []u8) ?usize {
    const found = find_slot_path(name) orelse return null;
    if (found.entry.is_dir) return null;
    var remaining: u32 = @min(found.entry.size, @as(u32, @intCast(out.len)));
    var cur = found.entry.cluster;
    var wrote: usize = 0;
    var hops: usize = 0;
    var buf: [sector_size]u8 = undefined;
    while (remaining > 0 and !is_eoc(cur) and hops < max_chain_clusters) : (hops += 1) {
        var s: u8 = 0;
        while (s < state.geo.spc and remaining > 0) : (s += 1) {
            if (!read_sector(cluster_lba(cur) + s, &buf)) return wrote;
            const take = @min(@as(usize, remaining), sector_size);
            @memcpy(out[wrote..][0..take], buf[0..take]);
            wrote += take;
            remaining -= @intCast(take);
        }
        cur = fat_entry(cur);
    }
    return wrote;
}

/// The on-disk size of a file (by bare name or `/`-path), or null when it
/// is absent or is a directory. Milestone four card 2 Stage C: lets the
/// monitor check a file's size before printing it (honest truncation
/// reporting).
pub fn file_size(path: []const u8) ?u32 {
    const found = find_slot_path(path) orelse return null;
    if (found.entry.is_dir) return null;
    return found.entry.size;
}

/// Write `content` to `name` — a bare name writes into the root (as
/// before); a `/`-path writes into an EXISTING subdirectory (milestone
/// four card 2; the parent components must resolve to directories, else
/// `.bad_path`). Allocate clusters from the free chain, write the data,
/// update the FAT (all copies), and create/replace the directory entry.
/// The name must fit FAT 8.3 (stem ≤ 8, ext ≤ 3); content ≤
/// `write_content_max`. A failed write reports `.io_failed` / `.disk_full`
/// honestly — never a partial success.
pub fn write_file(path: []const u8, content: []const u8) WriteResult {
    // Bounds are validated before any persistence attempt (a name that can
    // never be written is reported as such even without a disk).
    if (content.len > write_content_max) return .content_too_long;
    // The last `/`-component is the 8.3 file name; everything before it is
    // the parent directory path (empty = the root).
    var name: []const u8 = path;
    var parent: []const u8 = "";
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
        parent = path[0..idx];
        name = path[idx + 1 ..];
    }
    if (name.len == 0) return .name_too_long; // trailing '/' — nothing to write
    var short: [11]u8 = undefined;
    if (!encode_83(name, &short)) return .name_too_long;
    if (!state.mounted) return .no_disk;
    const dir_cluster = dir_cluster_of_path(parent) orelse return .bad_path;

    // Locate the directory slot: the existing same-name entry (freed first)
    // or the first free slot (0x00 / 0xE5).
    var slots: [max_root_slots]SlotRef = undefined;
    const n = collect_dir_slots(dir_cluster, &slots);
    var target: ?SlotRef = null;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var raw: [32]u8 = undefined;
        if (!read_dir_slot(slots[i], &raw)) continue;
        const first = raw[0];
        if (first == 0x00 and target == null) target = slots[i]; // end: first free slot
        if (first == 0x00) break;
        if (first == 0xe5) {
            if (target == null) target = slots[i];
            continue;
        }
        const attr = raw[11];
        if (attr & 0x0f == 0x0f or attr & 0x08 != 0) continue; // LFN / volume label
        if (std.mem.eql(u8, raw[0..11], &short)) {
            target = slots[i];
            // Free the existing chain before overwriting (bounded walk).
            const old_cluster = cluster_of_raw(raw);
            if (old_cluster >= 2) _ = free_chain(old_cluster);
            break;
        }
    }
    const slot = target orelse return .disk_full;

    // Allocate clusters (first-fit scan of the FAT).
    const bytes_per_cluster = @as(usize, state.geo.spc) * sector_size;
    const needed = (content.len + bytes_per_cluster - 1) / bytes_per_cluster;
    var alloc: [max_alloc_clusters]u32 = undefined;
    var got: usize = 0;
    if (needed > 0) {
        var scan = FatScan{};
        var c: u32 = 2;
        while (c < state.geo.total_clusters and got < needed) : (c += 1) {
            if (scan.entry(c) == 0) {
                alloc[got] = c;
                got += 1;
            }
        }
        if (got < needed) {
            // Release what was claimed — the disk is not left with orphans.
            for (alloc[0..got]) |cl| _ = set_fat_entry(cl, 0);
            return .disk_full;
        }
        // Link the chain.
        var k: usize = 0;
        while (k < got) : (k += 1) {
            if (!set_fat_entry(alloc[k], if (k + 1 < got) alloc[k + 1] else fat_eoc)) return .io_failed;
        }
        // Write the data clusters.
        var off: usize = 0;
        var buf: [sector_size]u8 = undefined;
        for (alloc[0..got]) |cl| {
            var s: u8 = 0;
            while (s < state.geo.spc) : (s += 1) {
                @memset(&buf, 0);
                const take = @min(content.len - off, sector_size);
                if (take > 0) @memcpy(buf[0..take], content[off .. off + take]);
                if (!write_sector(cluster_lba(cl) + s, &buf)) return .io_failed;
                off += take;
                if (off >= content.len) break;
            }
        }
    }

    // Directory entry: 8.3 name, archive attribute, first cluster, size.
    var raw: [32]u8 = @splat(0);
    @memcpy(raw[0..11], short[0..11]);
    raw[11] = 0x20; // archive
    const start_cluster: u32 = if (needed > 0) alloc[0] else 0;
    std.mem.writeInt(u16, raw[20..22], @truncate(start_cluster >> 16), .little);
    std.mem.writeInt(u16, raw[26..28], @truncate(start_cluster), .little);
    std.mem.writeInt(u32, raw[28..32], @intCast(content.len), .little);
    if (!write_dir_slot(slot, &raw)) return .io_failed;
    return .ok;
}

/// M27 G27 (Issue #470): write the framebuffer to a 24-bpp BMP file on the active FAT volume.
/// Streams 24-bpp BGR bottom-up rows directly from the 32-bpp BGRA/BGRX framebuffer with 54-byte BMP header.
pub fn write_fb_bmp(path: []const u8, width: u32, height: u32, fb: [*]const u8) WriteResult {
    var name: []const u8 = path;
    var parent: []const u8 = "";
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
        parent = path[0..idx];
        name = path[idx + 1 ..];
    }
    if (name.len == 0) return .name_too_long;
    var short: [11]u8 = undefined;
    if (!encode_83(name, &short)) return .name_too_long;
    if (!state.mounted) return .no_disk;
    const dir_cluster = dir_cluster_of_path(parent) orelse return .bad_path;

    var slots: [max_root_slots]SlotRef = undefined;
    const n = collect_dir_slots(dir_cluster, &slots);
    var target: ?SlotRef = null;
    var old_cluster_to_free: u32 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var raw: [32]u8 = undefined;
        if (!read_dir_slot(slots[i], &raw)) continue;
        const first = raw[0];
        if (first == 0x00 and target == null) target = slots[i];
        if (first == 0x00) break;
        if (first == 0xe5) {
            if (target == null) target = slots[i];
            continue;
        }
        const attr = raw[11];
        if (attr & 0x0f == 0x0f or attr & 0x08 != 0) continue;
        if (std.mem.eql(u8, raw[0..11], &short)) {
            target = slots[i];
            const oc = cluster_of_raw(raw);
            if (oc >= 2) old_cluster_to_free = oc;
            break;
        }
    }
    const slot = target orelse return .disk_full;

    const row_raw: usize = @as(usize, width) * 3;
    const row_pad: usize = (4 - (row_raw % 4)) % 4;
    const row_stride: usize = row_raw + row_pad;
    const total_pixel_bytes: usize = row_stride * @as(usize, height);
    const total_file_size: usize = 54 + total_pixel_bytes;

    var scan = FatScan{};
    var first_cl: u32 = 0;
    var prev_cl: u32 = 0;
    var cl_search: u32 = 2;

    var sec_buf: [sector_size + 4]u8 = undefined;
    var sec_buf_len: usize = 0;
    var cluster_sec_idx: u8 = 0;

    // 54-byte standard BMP header
    var header: [54]u8 = @splat(0);
    header[0] = 'B';
    header[1] = 'M';
    std.mem.writeInt(u32, header[2..6], @intCast(total_file_size), .little);
    std.mem.writeInt(u32, header[10..14], 54, .little);
    std.mem.writeInt(u32, header[14..18], 40, .little);
    std.mem.writeInt(i32, header[18..22], @intCast(width), .little);
    std.mem.writeInt(i32, header[22..26], @intCast(height), .little);
    std.mem.writeInt(u16, header[26..28], 1, .little);
    std.mem.writeInt(u16, header[28..30], 24, .little);
    std.mem.writeInt(u32, header[30..34], 0, .little);
    std.mem.writeInt(u32, header[34..38], @intCast(total_pixel_bytes), .little);
    std.mem.writeInt(i32, header[38..42], 2835, .little);
    std.mem.writeInt(i32, header[42..46], 2835, .little);

    @memcpy(sec_buf[0..54], header[0..54]);
    sec_buf_len = 54;

    const fb_stride = @as(usize, width) * 4;
    var cur_y: usize = height;
    while (cur_y > 0) {
        cur_y -= 1;
        const row_start = cur_y * fb_stride;
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const px_off = row_start + x * 4;
            sec_buf[sec_buf_len] = fb[px_off];
            sec_buf[sec_buf_len + 1] = fb[px_off + 1];
            sec_buf[sec_buf_len + 2] = fb[px_off + 2];
            sec_buf_len += 3;

            if (sec_buf_len >= sector_size) {
                if (cluster_sec_idx == 0) {
                    var next_cl: u32 = 0;
                    while (cl_search < state.geo.total_clusters) : (cl_search += 1) {
                        if (scan.entry(cl_search) == 0) {
                            next_cl = cl_search;
                            cl_search += 1;
                            break;
                        }
                    }
                    if (next_cl == 0) {
                        if (first_cl >= 2) _ = free_chain(first_cl);
                        return .disk_full;
                    }
                    if (first_cl == 0) {
                        first_cl = next_cl;
                    } else {
                        if (!set_fat_entry(prev_cl, next_cl)) {
                            if (first_cl >= 2) _ = free_chain(first_cl);
                            return .io_failed;
                        }
                    }
                    prev_cl = next_cl;
                }

                if (!write_sector(cluster_lba(prev_cl) + cluster_sec_idx, sec_buf[0..sector_size])) {
                    if (first_cl >= 2) _ = free_chain(first_cl);
                    return .io_failed;
                }
                cluster_sec_idx += 1;
                if (cluster_sec_idx >= state.geo.spc) cluster_sec_idx = 0;

                const excess = sec_buf_len - sector_size;
                if (excess > 0) {
                    var k: usize = 0;
                    while (k < excess) : (k += 1) {
                        sec_buf[k] = sec_buf[sector_size + k];
                    }
                }
                sec_buf_len = excess;
            }
        }

        if (row_pad > 0) {
            var p: usize = 0;
            while (p < row_pad) : (p += 1) {
                sec_buf[sec_buf_len] = 0;
                sec_buf_len += 1;
                if (sec_buf_len >= sector_size) {
                    if (cluster_sec_idx == 0) {
                        var next_cl: u32 = 0;
                        while (cl_search < state.geo.total_clusters) : (cl_search += 1) {
                            if (scan.entry(cl_search) == 0) {
                                next_cl = cl_search;
                                cl_search += 1;
                                break;
                            }
                        }
                        if (next_cl == 0) {
                            if (first_cl >= 2) _ = free_chain(first_cl);
                            return .disk_full;
                        }
                        if (first_cl == 0) {
                            first_cl = next_cl;
                        } else {
                            if (!set_fat_entry(prev_cl, next_cl)) {
                                if (first_cl >= 2) _ = free_chain(first_cl);
                                return .io_failed;
                            }
                        }
                        prev_cl = next_cl;
                    }

                    if (!write_sector(cluster_lba(prev_cl) + cluster_sec_idx, sec_buf[0..sector_size])) {
                        if (first_cl >= 2) _ = free_chain(first_cl);
                        return .io_failed;
                    }
                    cluster_sec_idx += 1;
                    if (cluster_sec_idx >= state.geo.spc) cluster_sec_idx = 0;

                    const excess = sec_buf_len - sector_size;
                    if (excess > 0) {
                        var k: usize = 0;
                        while (k < excess) : (k += 1) {
                            sec_buf[k] = sec_buf[sector_size + k];
                        }
                    }
                    sec_buf_len = excess;
                }
            }
        }
    }

    if (sec_buf_len > 0) {
        if (cluster_sec_idx == 0) {
            var next_cl: u32 = 0;
            while (cl_search < state.geo.total_clusters) : (cl_search += 1) {
                if (scan.entry(cl_search) == 0) {
                    next_cl = cl_search;
                    cl_search += 1;
                    break;
                }
            }
            if (next_cl == 0) {
                if (first_cl >= 2) _ = free_chain(first_cl);
                return .disk_full;
            }
            if (first_cl == 0) {
                first_cl = next_cl;
            } else {
                if (!set_fat_entry(prev_cl, next_cl)) {
                    if (first_cl >= 2) _ = free_chain(first_cl);
                    return .io_failed;
                }
            }
            prev_cl = next_cl;
        }
        while (sec_buf_len < sector_size) : (sec_buf_len += 1) {
            sec_buf[sec_buf_len] = 0;
        }
        if (!write_sector(cluster_lba(prev_cl) + cluster_sec_idx, sec_buf[0..sector_size])) {
            if (first_cl >= 2) _ = free_chain(first_cl);
            return .io_failed;
        }
    }

    if (prev_cl >= 2) {
        if (!set_fat_entry(prev_cl, fat_eoc)) {
            if (first_cl >= 2) _ = free_chain(first_cl);
            return .io_failed;
        }
    }

    var raw: [32]u8 = @splat(0);
    @memcpy(raw[0..11], short[0..11]);
    raw[11] = 0x20;
    std.mem.writeInt(u16, raw[20..22], @truncate(first_cl >> 16), .little);
    std.mem.writeInt(u16, raw[26..28], @truncate(first_cl), .little);
    std.mem.writeInt(u32, raw[28..32], @intCast(total_file_size), .little);
    if (!write_dir_slot(slot, &raw)) {
        if (first_cl >= 2) _ = free_chain(first_cl);
        return .io_failed;
    }

    if (old_cluster_to_free >= 2 and old_cluster_to_free != first_cl) {
        _ = free_chain(old_cluster_to_free);
    }
    return .ok;
}

// ---------------------------------------------------------------------------
// Mutating operations (Milestone 13, card B1 — claim 5801)
// ---------------------------------------------------------------------------

pub const DeleteResult = enum { ok, no_disk, not_found, is_dir, io_failed };
pub const RenameResult = enum { ok, no_disk, not_found, exists, is_dir, name_too_long, bad_path, io_failed };
pub const TruncateResult = enum { ok, no_disk, not_found, is_dir, too_large, io_failed };

/// Delete a file (bare name or `/`-path): free its cluster chain and mark
/// the directory slot deleted (0xE5). Directories are refused (deleting a
/// tree is out of scope); LFN companions are left as orphaned slots — the
/// data paths this seam serves carry none.
pub fn delete_file(path: []const u8) DeleteResult {
    if (!state.mounted) return .no_disk;
    const found = find_slot_path(path) orelse return .not_found;
    if (found.entry.is_dir) return .is_dir;
    if (found.entry.cluster >= 2) _ = free_chain(found.entry.cluster);
    var raw: [32]u8 = undefined;
    if (!read_dir_slot(found.slot, &raw)) return .io_failed;
    raw[0] = 0xe5;
    if (!write_dir_slot(found.slot, &raw)) return .io_failed;
    return .ok;
}

/// Rename a file in place (same directory — cross-directory moves are out
/// of scope for B1). Rewrites the 8.3 short name in the existing slot;
/// refuses when the new name already exists.
pub fn rename_file(old_path: []const u8, new_path: []const u8) RenameResult {
    if (!state.mounted) return .no_disk;
    var old_parent: []const u8 = "";
    var old_name: []const u8 = old_path;
    if (std.mem.lastIndexOfScalar(u8, old_path, '/')) |i| {
        old_parent = old_path[0..i];
        old_name = old_path[i + 1 ..];
    }
    var new_parent: []const u8 = "";
    var new_name: []const u8 = new_path;
    if (std.mem.lastIndexOfScalar(u8, new_path, '/')) |i| {
        new_parent = new_path[0..i];
        new_name = new_path[i + 1 ..];
    }
    if (old_name.len == 0 or new_name.len == 0) return .bad_path;

    var short: [11]u8 = undefined;
    if (!encode_83(new_name, &short)) return .name_too_long;

    const found = find_slot_path(old_path) orelse return .not_found;
    if (found.entry.is_dir) return .is_dir;
    if (find_slot_path(new_path) != null) return .exists;

    const old_dir = dir_cluster_of_path(old_parent) orelse return .bad_path;
    const new_dir = dir_cluster_of_path(new_parent) orelse return .bad_path;
    if (old_dir != new_dir) return .bad_path;

    var raw: [32]u8 = undefined;
    if (!read_dir_slot(found.slot, &raw)) return .io_failed;
    @memcpy(raw[0..11], short[0..11]);
    if (!write_dir_slot(found.slot, &raw)) return .io_failed;
    return .ok;
}

/// Resize a file to `new_size` bytes (≤ write_content_max). Shrinks by
/// truncation and grows by zero-fill; both reuse write_file's replace path.
pub fn truncate_file(path: []const u8, new_size: u32) TruncateResult {
    if (!state.mounted) return .no_disk;
    if (new_size > write_content_max) return .too_large;
    const found = find_slot_path(path) orelse return .not_found;
    if (found.entry.is_dir) return .is_dir;

    var staging: [write_content_max]u8 = [_]u8{0} ** write_content_max;
    _ = read_file(path, &staging) orelse return .not_found;
    const wr = write_file(path, staging[0..@as(usize, @intCast(new_size))]);
    return switch (wr) {
        .ok => .ok,
        .disk_full, .content_too_long => .too_large,
        else => .io_failed,
    };
}

/// Free bytes on the mounted volume (free clusters × bytes-per-cluster).
pub fn free_space() u64 {
    if (!state.mounted) return 0;
    const bpc: u64 = @as(u64, state.geo.spc) * sector_size;
    return @as(u64, free_clusters()) * bpc;
}

// ---------------------------------------------------------------------------
// Directory creation + recursive size (M25 Lane B — claims 2539/0434)
// ---------------------------------------------------------------------------

pub const MkdirResult = enum { ok, no_disk, exists, name_too_long, bad_path, disk_full, io_failed };

/// Create a directory by `/`-path (the last component is the new name).
/// FAT32-honest: allocates one cluster, zeroes it, writes the `.`
/// / `..` dot entries (self / parent clusters; root parent is cluster 0)
/// and emits a directory-attribute slot in the parent. The listing seam
/// (`list_dir`) skips dot entries, so the new directory shows only its
/// own contents.
pub fn create_dir(path: []const u8) MkdirResult {
    var name: []const u8 = path;
    var parent: []const u8 = "";
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
        parent = path[0..idx];
        name = path[idx + 1 ..];
    }
    if (name.len == 0) return .name_too_long; // trailing '/'
    var short: [11]u8 = undefined;
    if (!encode_83(name, &short)) return .name_too_long;
    if (!state.mounted) return .no_disk;
    const dir_cluster = dir_cluster_of_path(parent) orelse return .bad_path;

    // Collision check first: an existing entry (file OR directory) with
    // that name refuses — mkdir never overwrites.
    if (find_slot_in(dir_cluster, name) != null) return .exists;

    // Locate a free slot (0x00 end marker or 0xE5 deleted) — same search
    // discipline as write_file's replace path, minus the overwrite case.
    var slots: [max_root_slots]SlotRef = undefined;
    const n = collect_dir_slots(dir_cluster, &slots);
    var target: ?SlotRef = null;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var raw: [32]u8 = undefined;
        if (!read_dir_slot(slots[i], &raw)) continue;
        const first = raw[0];
        if (first == 0x00) {
            target = slots[i]; // end-of-directory marker: consume it
            break;
        }
        if (first == 0xe5 and target == null) target = slots[i];
    }
    const slot = target orelse return .disk_full;

    // Allocate one cluster for the directory contents.
    var dir_cl: u32 = 0;
    var c: u32 = 2;
    while (c < state.geo.total_clusters) : (c += 1) {
        if (fat_entry(c) == 0) {
            dir_cl = c;
            break;
        }
    }
    if (dir_cl == 0) return .disk_full;
    if (!set_fat_entry(dir_cl, fat_eoc)) return .io_failed;

    // Zero the cluster, then write the dot entries:
    //   `.`  → this directory's own cluster
    //   `..` → the parent's cluster (0 when the parent is the root)
    var zero: [sector_size]u8 = [_]u8{0} ** sector_size;
    var s: u8 = 0;
    while (s < state.geo.spc) : (s += 1) {
        if (!write_sector(cluster_lba(dir_cl) + s, &zero)) {
            _ = set_fat_entry(dir_cl, 0); // release on failure — no orphans
            return .io_failed;
        }
    }
    const dot_self = make_dot_entry(".", dir_cl);
    const dot_parent = make_dot_entry("..", if (dir_cluster == state.geo.root_cluster) 0 else dir_cluster);
    if (!write_bytes_at_cluster(dir_cl, 0, &dot_self) or !write_bytes_at_cluster(dir_cl, 32, &dot_parent)) {
        _ = set_fat_entry(dir_cl, 0); // release on failure — no orphans
        return .io_failed;
    }

    // The parent's directory slot: 8.3 name, directory attribute,
    // first cluster, size 0 (directories always report size 0).
    var raw: [32]u8 = @splat(0);
    @memcpy(raw[0..11], short[0..11]);
    raw[11] = attr_directory;
    std.mem.writeInt(u16, raw[20..22], @truncate(dir_cl >> 16), .little);
    std.mem.writeInt(u16, raw[26..28], @truncate(dir_cl), .little);
    if (!write_dir_slot(slot, &raw)) {
        _ = set_fat_entry(dir_cl, 0);
        return .io_failed;
    }
    return .ok;
}

/// ATTR_DIRECTORY (FAT32 spec §11.1): marks a directory-entry subdirectory.
pub const attr_directory: u8 = 0x10;

/// Build one 32-byte dot entry (`.` / `..`, padded to short-name width).
fn make_dot_entry(comptime dot: []const u8, cluster: u32) [32]u8 {
    comptime std.debug.assert(dot.len <= 11);
    var raw: [32]u8 = @splat(' ');
    @memcpy(raw[0..dot.len], dot);
    raw[11] = attr_directory;
    std.mem.writeInt(u16, raw[20..22], @truncate(cluster >> 16), .little);
    std.mem.writeInt(u16, raw[26..28], @truncate(cluster), .little);
    return raw;
}

/// Write `bytes` at `off` inside the FIRST cluster `start` (single-sector
/// read-modify-write; the dot entries this serves are 64 bytes at offsets
/// 0/32 of a freshly zeroed cluster). Returns false when the range would
/// cross a sector boundary or the I/O fails.
fn write_bytes_at_cluster(start: u32, off: usize, bytes: []const u8) bool {
    if (off >= sector_size or off + bytes.len > sector_size) return false;
    var buf: [sector_size]u8 = undefined;
    const lba = cluster_lba(start) + off / sector_size;
    const within = off % sector_size;
    if (!read_sector(lba, &buf)) return false;
    @memcpy(buf[within .. within + bytes.len], bytes);
    return write_sector(lba, &buf);
}

/// True when `path` resolves to an existing DIRECTORY entry (du uses this
/// to validate its argument).
pub fn path_is_dir(path: []const u8) bool {
    if (!state.mounted) return false;
    const found = find_slot_path(path) orelse return false;
    return found.entry.is_dir;
}

/// Recursive byte total of `path`'s subtree: files count their sizes,
/// directories recurse into their listings. Breadth-first with
/// MODULE-SCOPE buffers — a per-level `[128]DirEntry` listing would sit
/// on the 16 KiB kernel stack at every recursion depth (claim 1809's
/// lesson), so the walk queues child paths instead. Bounded at
/// `max_du_depth` levels of nesting (the march note's non-blocking cap).
pub const max_du_depth: usize = 3;

/// Children queued per walk (bounds the BSS; overflow skips the tail —
/// reported via `.truncated` by the du seam below).
const du_queue_max: usize = 64;

const DuResult = struct {
    bytes: u64 = 0,
    dirs_walked: u32 = 0,
    truncated: bool = false,
};

var du_listing: [max_root_slots]DirEntry = undefined;
var du_paths: [du_queue_max][name_max * 2 + 2]u8 = undefined;
var du_depths: [du_queue_max]usize = undefined;
var du_lens: [du_queue_max]usize = undefined;

pub fn dir_size_recursive(root: []const u8) DuResult {
    var res: DuResult = .{};
    if (!state.mounted) return res;
    // Seed the queue with the root directory itself.
    if (root.len > du_paths[0].len) return res;
    @memcpy(du_paths[0][0..root.len], root);
    du_lens[0] = root.len;
    du_depths[0] = 0;
    var head: usize = 0;
    var tail: usize = 1;
    while (head < tail) : (head += 1) {
        const cur = du_paths[head][0..du_lens[head]];
        const depth = du_depths[head];
        if (depth >= max_du_depth) continue;
        const n = list_path(cur, &du_listing);
        for (du_listing[0..n]) |e| {
            res.bytes += e.size;
            if (!e.is_dir) continue;
            if (tail >= du_queue_max) {
                res.truncated = true;
                continue;
            }
            const parent = du_paths[head][0..du_lens[head]];
            if (join_child_path(parent, e.name[0..e.name_len], &du_paths[tail])) |joined| {
                du_lens[tail] = joined.len;
                du_depths[tail] = depth + 1;
                tail += 1;
                res.dirs_walked += 1;
            }
        }
    }
    return res;
}

/// Join a parent directory path and a child name into a `/`-path (stack
/// buffer; returns null when it would overflow — those subtrees are
/// skipped rather than miscounted).
pub fn join_child_path(parent: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    if (parent.len == 0 or (parent.len == 1 and parent[0] == '/')) {
        if (1 + name.len > buf.len) return null;
        buf[0] = '/';
        @memcpy(buf[1 .. 1 + name.len], name);
        return buf[0 .. 1 + name.len];
    }
    if (parent.len + 1 + name.len > buf.len) return null;
    @memcpy(buf[0..parent.len], parent);
    buf[parent.len] = '/';
    @memcpy(buf[parent.len + 1 ..][0..name.len], name);
    return buf[0 .. parent.len + 1 + name.len];
}

// ---------------------------------------------------------------------------
// Sector helpers
// ---------------------------------------------------------------------------

fn read_sector(lba: u64, buf: *[sector_size]u8) bool {
    const o = state.ops orelse return false;
    if (!o.read(lba, buf)) {
        state.last_fail_lba = lba;
        return false;
    }
    return true;
}

fn write_sector(lba: u64, buf: *const [sector_size]u8) bool {
    const o = state.ops orelse return false;
    if (!o.write(lba, buf)) {
        state.last_fail_lba = lba;
        return false;
    }
    return true;
}

fn cluster_lba(cluster: u32) u64 {
    return state.geo.vol_lba + state.geo.data_start + (@as(u64, cluster) - state.geo.root_cluster) * state.geo.spc;
}

fn fat_lba() u64 {
    return state.geo.vol_lba + state.geo.reserved;
}

/// FAT entry for a cluster (FAT copy 0; the copies mirror by construction).
fn fat_entry(cluster: u32) u32 {
    if (cluster < 2 or cluster >= state.geo.total_clusters) return fat_eoc;
    const byte_off = @as(u64, cluster) * 4;
    var buf: [sector_size]u8 = undefined;
    if (!read_sector(fat_lba() + byte_off / sector_size, &buf)) return fat_eoc;
    const off: usize = @intCast(byte_off % sector_size);
    if (off + 4 > sector_size) return fat_eoc;
    return read_le(u32, buf[off .. off + 4]) & 0x0fffffff;
}

/// First-fit FAT allocation scan with one sector of read caching. The
/// scan may walk tens of thousands of clusters (the ESP is a 94 MiB
/// volume), and 128 clusters share a single 512-byte FAT sector — without
/// the cache each `fat_entry` re-reads the same sector 128 times in a
/// row. The cache turns a worst-case full-volume scan into ~1 read per
/// FAT sector (1434 reads, not ~183k). The cache is call-local: scans are
/// read-only and no write can interleave, so it never goes stale.
const FatScan = struct {
    sector: u64 = 0,
    have: bool = false,
    buf: [sector_size]u8 = undefined,

    /// FAT entry value for `cluster`, or null when the cluster is out of
    /// range or the sector read failed. Callers treat null as "not free"
    /// (identical to `fat_entry` returning `fat_eoc` on a read failure).
    fn entry(self: *FatScan, cluster: u32) ?u32 {
        if (cluster < 2 or cluster >= state.geo.total_clusters) return null;
        const lba = fat_lba() + @as(u64, cluster) * 4 / sector_size;
        if (!self.have or self.sector != lba) {
            if (!read_sector(lba, &self.buf)) return null;
            self.sector = lba;
            self.have = true;
        }
        const off = @as(usize, cluster * 4) % sector_size;
        return read_le(u32, self.buf[off .. off + 4]) & 0x0fffffff;
    }
};

/// Write a FAT entry to ALL FAT copies. Returns false on a sector failure.
fn set_fat_entry(cluster: u32, value: u32) bool {
    if (cluster < 2) return false;
    const byte_off = @as(u64, cluster) * 4;
    const sec = fat_lba() + byte_off / sector_size;
    const off: usize = @intCast(byte_off % sector_size);
    var buf: [sector_size]u8 = undefined;
    if (!read_sector(sec, &buf)) return false;
    write_le(u32, buf[off .. off + 4], value & 0x0fffffff);
    var f: u8 = 0;
    while (f < state.geo.nfats) : (f += 1) {
        const copy = fat_lba() + @as(u64, f) * state.geo.fat_sectors + byte_off / sector_size;
        if (!write_sector(copy, &buf)) return false;
    }
    return true;
}

/// Walk a cluster chain setting every entry free (0). Bounded; returns
/// false if the chain is malformed (never frees past the bound).
fn free_chain(start: u32) bool {
    var cur = start;
    var hops: usize = 0;
    while (!is_eoc(cur) and hops < max_chain_clusters) : (hops += 1) {
        if (cur < 2 or cur >= state.geo.total_clusters) return false;
        const next = fat_entry(cur);
        _ = set_fat_entry(cur, 0);
        cur = next;
    }
    return true;
}

fn is_eoc(v: u32) bool {
    return v >= fat_eoc_min;
}

// ---------------------------------------------------------------------------
// Directory access
// ---------------------------------------------------------------------------

const SlotRef = struct { lba: u64, byte_off: usize };

/// Collect the 32-byte slot references of a DIRECTORY's entries, following
/// its cluster chain (bounded). Stops at the first 0x00 slot (end of
/// directory marker) or when the slot window fills. The root directory is
/// the special case `cluster == state.geo.root_cluster` (milestone four
/// card 2: any directory chain, not just the root).
fn collect_dir_slots(cluster: u32, out: []SlotRef) usize {
    var count: usize = 0;
    var cur = cluster;
    var hops: usize = 0;
    while (!is_eoc(cur) and hops < max_chain_clusters) : (hops += 1) {
        if (cur < 2 or cur >= state.geo.total_clusters) break;
        var s: u8 = 0;
        while (s < state.geo.spc) : (s += 1) {
            const base = cluster_lba(cur) + s;
            var off: usize = 0;
            while (off < sector_size and count < out.len) : (off += 32) {
                out[count] = .{ .lba = base, .byte_off = off };
                count += 1;
            }
        }
        cur = fat_entry(cur);
    }
    return count;
}

fn collect_root_slots(out: []SlotRef) usize {
    return collect_dir_slots(state.geo.root_cluster, out);
}

fn read_dir_slot(ref: SlotRef, out: *[32]u8) bool {
    var buf: [sector_size]u8 = undefined;
    if (!read_sector(ref.lba, &buf)) return false;
    if (ref.byte_off + 32 > sector_size) return false;
    @memcpy(out, buf[ref.byte_off .. ref.byte_off + 32]);
    return true;
}

fn write_dir_slot(ref: SlotRef, data: *const [32]u8) bool {
    var buf: [sector_size]u8 = undefined;
    if (!read_sector(ref.lba, &buf)) return false;
    if (ref.byte_off + 32 > sector_size) return false;
    @memcpy(buf[ref.byte_off .. ref.byte_off + 32], data);
    return write_sector(ref.lba, &buf);
}

fn cluster_of_raw(raw: [32]u8) u32 {
    return (@as(u32, read_le(u16, raw[20..22])) << 16) | read_le(u16, raw[26..28]);
}

const Found = struct { slot: SlotRef, entry: DirEntry };

/// Find an entry in a DIRECTORY (any cluster chain) by name: matches the
/// 8.3-encoded short name OR the display name, case-insensitively. Returns
/// its slot (the caller can then read or overwrite the entry) plus the
/// decoded entry. The root directory is the special case.
fn find_slot_in(cluster: u32, name: []const u8) ?Found {
    var short: [11]u8 = undefined;
    const has_short = encode_83(name, &short);
    var slots: [max_root_slots]SlotRef = undefined;
    const n = collect_dir_slots(cluster, &slots);
    var lfn: LfnAccum = .{};
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var raw: [32]u8 = undefined;
        if (!read_dir_slot(slots[i], &raw)) {
            lfn = .{};
            continue;
        }
        const first = raw[0];
        if (first == 0x00) break;
        if (first == 0xe5) {
            lfn = .{};
            continue;
        }
        const attr = raw[11];
        if (attr & 0x0f == 0x0f) {
            lfn.accumulate(raw);
            continue;
        }
        if (attr & 0x08 != 0) {
            lfn = .{};
            continue;
        }
        const e = decode_entry(raw, lfn.consume(raw));
        lfn = .{};
        const disp = e.name[0..e.name_len];
        if ((has_short and std.mem.eql(u8, raw[0..11], &short)) or name_eql_ci(disp, name)) {
            return .{ .slot = slots[i], .entry = e };
        }
    }
    return null;
}

/// Find a root entry by name (the root is the special case of
/// `find_slot_in`).
fn find_slot(name: []const u8) ?Found {
    return find_slot_in(state.geo.root_cluster, name);
}

/// Find an entry by `/`-path (milestone four card 2): the components
/// before the last must be directories (walked from the root); the LAST
/// component is the entry itself (file or directory). A bare name resolves
/// against the root — identical to `find_slot`. Returns null when the path
/// ends in '/' (a directory, not an entry), any component is absent, or an
/// intermediate component is not a directory.
fn find_slot_path(path: []const u8) ?Found {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| {
        const parent = path[0..idx];
        const name = path[idx + 1 ..];
        if (name.len == 0) return null; // trailing '/' — a directory
        const cluster = dir_cluster_of_path(parent) orelse return null;
        return find_slot_in(cluster, name);
    }
    return find_slot(path);
}

// ---------------------------------------------------------------------------
// Path resolution (milestone four card 2)
// ---------------------------------------------------------------------------

/// Resolve a `/`-separated path to the cluster of its LAST DIRECTORY
/// component (every component must exist and be a directory). `.` is a
/// no-op; `..` pops to the parent (the root's parent is itself). A bare
/// name or empty path resolves to the root cluster. Each component is
/// bounded by `name_max` and the depth by `max_path_parts` (over-deep
/// paths return null). The FAT layer no longer speaks only root-relative
/// names — the "arbitrary disk layout" companion to `mount_partition`.
fn dir_cluster_of_path(path: []const u8) ?u32 {
    // Split into bounded components (tokenizeScalar skips empty runs, so
    // leading/trailing '/' and "//" are tolerated).
    var parts: [max_path_parts][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len > name_max) return null;
        if (n >= max_path_parts) return null;
        parts[n] = part;
        n += 1;
    }
    // Walk with an explicit parent stack so ".." pops correctly.
    var stack: [max_path_parts + 1]u32 = undefined;
    var depth: usize = 1;
    stack[0] = state.geo.root_cluster;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (std.mem.eql(u8, parts[i], ".")) continue;
        if (std.mem.eql(u8, parts[i], "..")) {
            if (depth > 1) depth -= 1;
            continue;
        }
        const found = find_slot_in(stack[depth - 1], parts[i]) orelse return null;
        if (!found.entry.is_dir) return null;
        if (depth > max_path_parts) return null;
        stack[depth] = found.entry.cluster;
        depth += 1;
    }
    return stack[depth - 1];
}

fn decode_entry(raw: [32]u8, long: ?[]const u8) DirEntry {
    var e: DirEntry = undefined;
    e.size = read_le(u32, raw[28..32]);
    e.is_dir = (raw[11] & 0x10) != 0;
    e.cluster = cluster_of_raw(raw);
    e.name_len = 0;
    @memcpy(e.short[0..11], raw[0..11]);
    if (long) |l| {
        const take = @min(l.len, name_max);
        @memcpy(e.name[0..take], l[0..take]);
        e.name_len = @intCast(take);
    } else {
        e.name_len = @intCast(short_display(raw[0..11], &e.name));
    }
    return e;
}

/// 8.3 short name -> display name ("HELLO   TXT" -> "HELLO.TXT"; a blank
/// extension is dropped).
fn short_display(short: []const u8, out: *[name_max]u8) usize {
    var stem_len: usize = 0;
    while (stem_len < 8 and short[stem_len] != ' ') : (stem_len += 1) {}
    var ext_len: usize = 0;
    while (ext_len < 3 and short[8 + ext_len] != ' ') : (ext_len += 1) {}
    var n: usize = 0;
    @memcpy(out[0..stem_len], short[0..stem_len]);
    n += stem_len;
    if (ext_len > 0) {
        out[n] = '.';
        n += 1;
        @memcpy(out[n .. n + ext_len], short[8 .. 8 + ext_len]);
        n += ext_len;
    }
    return n;
}

// ---------------------------------------------------------------------------
// Long file name (LFN) accumulation
// ---------------------------------------------------------------------------

const LfnAccum = struct {
    /// 13 chars per part, max_lfn_parts parts; ASCII (non-ASCII -> '?').
    chars: [13 * max_lfn_parts]u8 = undefined,
    parts: [max_lfn_parts]bool = .{false} ** max_lfn_parts,
    seen: usize = 0,
    last_seen: bool = false,
    checksum: u8 = 0,
    /// Stable buffer the returned slice points into (consumed immediately).
    name: [name_max]u8 = undefined,
    name_len: usize = 0,

    /// Accumulate one LFN directory entry (attr 0x0F). Entries precede the
    /// short entry in file order with DESCENDING sequence numbers; the part
    /// with sequence 1 (adjacent to the short entry) carries the 0x40 bit.
    fn accumulate(self: *LfnAccum, raw: [32]u8) void {
        const seq_raw = raw[0];
        const seq = seq_raw & 0x1f;
        if (seq == 0 or seq > max_lfn_parts) {
            self.reset();
            return;
        }
        if (self.parts[seq - 1]) {
            self.reset(); // duplicate part: malformed, drop the name
            return;
        }
        self.parts[seq - 1] = true;
        self.seen += 1;
        if ((seq_raw & 0x40) != 0) self.last_seen = true;
        self.checksum = raw[13];
        const base = (seq - 1) * 13;
        @memset(self.chars[base .. base + 13], 0);
        var k: usize = 0;
        var slot: usize = 0;
        while (k < 13) : (k += 1) {
            const src: []const u8 = if (k < 5)
                raw[1 + k * 2 .. 3 + k * 2]
            else if (k < 11)
                raw[14 + (k - 5) * 2 .. 16 + (k - 5) * 2]
            else
                raw[28 + (k - 11) * 2 .. 30 + (k - 11) * 2];
            const ch = read_le(u16, src);
            if (ch == 0 or ch == 0xffff) break; // terminator / padding
            self.chars[base + slot] = if (ch > 0x7f) '?' else @intCast(ch);
            slot += 1;
        }
    }

    /// After the short entry arrives, consume the accumulated name — but
    /// only when it is complete (all parts 1..seen present, the 0x40 part
    /// seen) and its checksum matches the short name.
    fn consume(self: *LfnAccum, short_raw: [32]u8) ?[]const u8 {
        if (self.seen == 0 or !self.last_seen) return null;
        if (self.checksum != lfn_checksum(short_raw[0..11])) return null;
        var p: usize = 0;
        while (p < self.seen) : (p += 1) {
            if (!self.parts[p]) return null;
        }
        var n: usize = 0;
        while (n < self.seen * 13 and n < name_max) : (n += 1) {
            if (self.chars[n] == 0) break;
            self.name[n] = self.chars[n];
        }
        if (n == 0) return null;
        self.name_len = n;
        return self.name[0..n];
    }

    fn reset(self: *LfnAccum) void {
        self.parts = .{false} ** max_lfn_parts;
        self.seen = 0;
        self.last_seen = false;
        self.checksum = 0;
    }
};

/// FAT LFN checksum: rotate-right-1 then add, over the 11 short-name bytes.
fn lfn_checksum(short: []const u8) u8 {
    var sum: u8 = 0;
    for (short[0..11]) |b| {
        sum = ((sum >> 1) | (sum << 7)) +% b;
    }
    return sum;
}

// ---------------------------------------------------------------------------
// 8.3 names + helpers
// ---------------------------------------------------------------------------

/// Encode a display name as an 11-byte FAT 8.3 name (uppercase, space
/// padded). Returns false when the name does not fit (stem > 8, ext > 3,
/// empty stem).
fn encode_83(name: []const u8, out: *[11]u8) bool {
    var stem: []const u8 = name;
    var ext: []const u8 = "";
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| {
        stem = name[0..i];
        ext = name[i + 1 ..];
    }
    if (stem.len == 0 or stem.len > 8 or ext.len > 3) return false;
    @memset(out, ' ');
    for (stem, 0..) |c, i| out[i] = ascii_upper(c);
    for (ext, 0..) |c, i| out[8 + i] = ascii_upper(c);
    return true;
}

fn ascii_upper(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

fn ascii_lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn name_eql_ci(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (ascii_lower(x) != ascii_lower(y)) return false;
    }
    return true;
}

fn read_le(comptime T: type, bytes: []const u8) T {
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

fn write_le(comptime T: type, bytes: []u8, value: T) void {
    std.mem.writeInt(T, bytes[0..@sizeOf(T)], value, .little);
}

// ---------------------------------------------------------------------------
// Tests — in-memory fixture with the mkfat32.py byte layout
// ---------------------------------------------------------------------------

const test_allocator = std.testing.allocator;

const Fixture = struct {
    buf: []u8,
    fat_sectors: u32,
    data_start: u32,
};

/// The fake disk target (module-level; Zig tests cannot capture).
var test_fixture: []u8 = undefined;

fn fake_read(lba: u64, out: *[sector_size]u8) bool {
    const off = lba * sector_size;
    if (off + sector_size > test_fixture.len) return false;
    @memcpy(out, test_fixture[off .. off + sector_size]);
    return true;
}

fn fake_write(lba: u64, data: *const [sector_size]u8) bool {
    const off = lba * sector_size;
    if (off + sector_size > test_fixture.len) return false;
    @memcpy(test_fixture[off .. off + sector_size], data);
    return true;
}

fn test_ops() DiskOps {
    return .{ .read = &fake_read, .write = &fake_write };
}

/// Build an in-memory disk image in the exact layout mkfat32.py produces:
/// protective MBR, GPT header + ESP partition entry, then a FAT32 volume at
/// LBA 2048 with spc=1, reserved=32, 2 FATs, root cluster 2. Contents:
/// /DIPSHITOS (volume label), /EFI/ and /EFI/BOOT/ (dirs), /KERNEL.BIN
/// (cluster 5), /BOOTED.TXT (cluster 6), /BOOTAA64.EFI (cluster 7), and —
/// when `with_lfn` is set — /Long File Name.TXT (cluster 8) behind an LFN
/// chain.
fn build_fixture(alloc: std.mem.Allocator, with_lfn: bool) !Fixture {
    const total_sectors: u64 = 128 * 1024 * 1024 / sector_size; // 128 MiB
    const esp_offset: u64 = 2048;
    const last_usable: u64 = total_sectors - 34;
    const volume_sectors: u32 = @intCast(last_usable - esp_offset + 1);

    // Fixed-point FAT-size iteration (mkfat32.Fat32Geometry).
    var fat_sectors: u32 = 1;
    while (true) {
        const clusters = volume_sectors - 32 - 2 * fat_sectors;
        const need: u32 = @intCast((clusters * 4 + sector_size - 1) / sector_size);
        if (need == fat_sectors) break;
        fat_sectors = need;
    }
    const data_start: u32 = 32 + 2 * fat_sectors;

    const img = try alloc.alloc(u8, @intCast(total_sectors * sector_size));
    @memset(img, 0);

    // LBA 0: protective MBR signature.
    img[510] = 0x55;
    img[511] = 0xaa;
    // LBA 1: GPT header.
    const hdr_off: usize = 1 * sector_size;
    @memcpy(img[hdr_off .. hdr_off + 8], "EFI PART");
    std.mem.writeInt(u32, img[hdr_off + 8 ..][0..4], 0x00010000, .little);
    std.mem.writeInt(u32, img[hdr_off + 12 ..][0..4], 92, .little);
    std.mem.writeInt(u64, img[hdr_off + 24 ..][0..8], 1, .little);
    std.mem.writeInt(u64, img[hdr_off + 32 ..][0..8], total_sectors - 1, .little);
    std.mem.writeInt(u64, img[hdr_off + 40 ..][0..8], 34, .little);
    std.mem.writeInt(u64, img[hdr_off + 48 ..][0..8], last_usable, .little);
    std.mem.writeInt(u64, img[hdr_off + 72 ..][0..8], 2, .little);
    std.mem.writeInt(u32, img[hdr_off + 80 ..][0..4], 128, .little);
    std.mem.writeInt(u32, img[hdr_off + 84 ..][0..4], 128, .little);
    // LBA 2: partition entries — entry 0 = ESP.
    const ent_off: usize = 2 * sector_size;
    @memcpy(img[ent_off .. ent_off + 16], &esp_type_guid);
    std.mem.writeInt(u64, img[ent_off + 32 ..][0..8], esp_offset, .little);
    std.mem.writeInt(u64, img[ent_off + 40 ..][0..8], last_usable, .little);

    // FAT32 volume at esp_offset.
    const base: usize = @intCast(esp_offset * sector_size);
    const bs = img[base .. base + sector_size];
    const jmp_boot = [_]u8{ 0xeb, 0x58, 0x90 };
    @memcpy(bs[0..3], &jmp_boot);
    @memcpy(bs[3..11], "MSDOS5.0");
    std.mem.writeInt(u16, bs[11..13], sector_size, .little);
    bs[13] = 1; // sectors per cluster
    std.mem.writeInt(u16, bs[14..16], 32, .little);
    bs[16] = 2; // number of FATs
    bs[21] = 0xf8;
    std.mem.writeInt(u32, bs[28..32], @intCast(esp_offset), .little);
    std.mem.writeInt(u32, bs[32..36], volume_sectors, .little);
    std.mem.writeInt(u32, bs[36..40], fat_sectors, .little);
    std.mem.writeInt(u32, bs[44..48], 2, .little); // root cluster
    bs[510] = 0x55;
    bs[511] = 0xaa;

    // FAT (both copies): root/EFI/BOOT = one cluster each; KERNEL.BIN -> 5,
    // BOOTED.TXT -> 6, BOOTAA64.EFI -> 7; optional LFN file -> 8.
    const fat_off: usize = @intCast((esp_offset + 32) * sector_size);
    const fat_bytes = fat_sectors * sector_size;
    const fat = try alloc.alloc(u8, fat_bytes);
    @memset(fat, 0);
    std.mem.writeInt(u32, fat[0..4], 0x0ffffff8, .little);
    std.mem.writeInt(u32, fat[4..8], 0x0fffffff, .little);
    var chain = [_]u32{ 2, 3, 4, 5, 6, 7, 8 };
    var chain_len: usize = 6;
    if (with_lfn) chain_len = 7;
    for (chain[0..chain_len]) |c| std.mem.writeInt(u32, fat[@as(usize, c) * 4 ..][0..4], fat_eoc, .little);
    for (0..2) |f| {
        @memcpy(img[fat_off + f * fat_bytes ..][0..fat_bytes], fat);
    }
    alloc.free(fat);

    // Root directory (cluster 2).
    const booted = "DIPSHITOS BOOTLOADER\nfirmware has agreed to cooperate\n";
    const root_lba = esp_offset + data_start; // cluster 2
    const root_off: usize = @intCast(root_lba * sector_size);
    var root = [_]u8{0} ** sector_size;
    var slot: usize = 0;
    write_entry(&root, slot, "DIPSHITOS  ", 0x08, 0, 0);
    slot += 1;
    write_entry(&root, slot, "EFI        ", 0x10, 3, 0);
    slot += 1;
    write_entry(&root, slot, "KERNEL  BIN", 0x20, 5, 0x100);
    slot += 1;
    write_entry(&root, slot, "BOOTED  TXT", 0x20, 6, booted.len);
    slot += 1;
    if (with_lfn) {
        // LFN chain for "Long File Name.TXT" (short name LONG    TXT).
        const lfn_name = "Long File Name.TXT";
        const parts = write_lfn_chain(&root, slot, lfn_name, "LONG    TXT");
        slot += parts;
        write_entry(&root, slot, "LONG    TXT", 0x20, 8, lfn_name.len);
        slot += 1;
    }
    @memcpy(img[root_off .. root_off + sector_size], &root);

    // /EFI (cluster 3) and /EFI/BOOT (cluster 4).
    var efi = [_]u8{0} ** sector_size;
    write_entry(&efi, 0, ".          ", 0x10, 3, 0);
    write_entry(&efi, 1, "..         ", 0x10, 2, 0);
    write_entry(&efi, 2, "BOOT       ", 0x10, 4, 0);
    const efi_off: usize = @intCast((esp_offset + data_start + 1) * sector_size);
    @memcpy(img[efi_off .. efi_off + sector_size], &efi);
    var boot = [_]u8{0} ** sector_size;
    write_entry(&boot, 0, ".          ", 0x10, 4, 0);
    write_entry(&boot, 1, "..         ", 0x10, 2, 0);
    write_entry(&boot, 2, "BOOTAA64EFI", 0x20, 7, 0x200);
    const boot_off: usize = @intCast((esp_offset + data_start + 2) * sector_size);
    @memcpy(img[boot_off .. boot_off + sector_size], &boot);

    // File data: KERNEL.BIN (cluster 5), BOOTED.TXT (cluster 6),
    // BOOTAA64.EFI (cluster 7), optional LFN file (cluster 8).
    const kernel = "DSK1 kernel image payload, padded to 0x100";
    const kernel_data = try alloc.alloc(u8, 0x100);
    @memset(kernel_data, 0);
    const kd = @min(kernel.len, 0x100);
    @memcpy(kernel_data[0..kd], kernel[0..kd]);
    const k_off: usize = @intCast((esp_offset + data_start + 3) * sector_size);
    @memcpy(img[k_off .. k_off + 0x100], kernel_data);
    alloc.free(kernel_data);
    const b_off: usize = @intCast((esp_offset + data_start + 4) * sector_size);
    @memcpy(img[b_off .. b_off + booted.len], booted);
    const efi_bytes = "BOOTAA64.EFI payload, padded to 0x200";
    const ef_off: usize = @intCast((esp_offset + data_start + 5) * sector_size);
    @memcpy(img[ef_off .. ef_off + efi_bytes.len], efi_bytes);
    if (with_lfn) {
        const lf_off: usize = @intCast((esp_offset + data_start + 6) * sector_size);
        @memcpy(img[lf_off .. lf_off + "Long File Name.TXT".len], "Long File Name.TXT");
    }

    return .{ .buf = img, .fat_sectors = fat_sectors, .data_start = data_start };
}

/// Write one 32-byte directory entry at slot `slot` of a 512-byte cluster.
fn write_entry(cluster: *[sector_size]u8, slot: usize, name11: *const [11]u8, attr: u8, cluster_no: u32, size: u32) void {
    const off = slot * 32;
    @memcpy(cluster[off .. off + 11], name11[0..11]);
    cluster[off + 11] = attr;
    std.mem.writeInt(u16, cluster[off + 20 ..][0..2], @truncate(cluster_no >> 16), .little);
    std.mem.writeInt(u16, cluster[off + 26 ..][0..2], @truncate(cluster_no), .little);
    std.mem.writeInt(u32, cluster[off + 28 ..][0..4], size, .little);
}

/// Write an LFN chain (attr 0x0F entries) for `name` before its short
/// entry, starting at slot `slot`. Returns the number of slots consumed
/// (LFN parts). The short entry is written by the caller after it.
fn write_lfn_chain(cluster: *[sector_size]u8, slot: usize, name: []const u8, short11: []const u8) usize {
    const checksum = lfn_checksum(short11);
    const parts = (name.len + 12) / 13;
    var p: usize = 0;
    while (p < parts) : (p += 1) {
        const off = (slot + p) * 32;
        // File order: the first entry carries the highest sequence number
        // (no 0x40); the last (adjacent to the short entry) has sequence 1
        // with the 0x40 bit.
        const seq = parts - p;
        cluster[off] = if (p == parts - 1) @intCast(0x40 | seq) else @intCast(seq);
        cluster[off + 11] = 0x0f;
        cluster[off + 13] = checksum;
        const base = (seq - 1) * 13;
        var k: usize = 0;
        while (k < 13) : (k += 1) {
            const ch: u16 = if (base + k < name.len) name[base + k] else 0xffff;
            const dst = off + (if (k < 5) 1 + k * 2 else if (k < 11) 14 + (k - 5) * 2 else 28 + (k - 11) * 2);
            std.mem.writeInt(u16, cluster[dst..][0..2], ch, .little);
        }
    }
    return parts;
}

fn make_state_fixture(fxt: *Fixture) void {
    state = .{};
    test_fixture = fxt.buf;
}

test "fat: mount parses the GPT + BPB geometry" {
    var fxt = try build_fixture(test_allocator, false);
    defer test_allocator.free(fxt.buf);
    make_state_fixture(&fxt);
    try std.testing.expectEqual(MountResult.ok, mount(test_ops()));
    try std.testing.expect(mounted());
    const g = geometry();
    try std.testing.expectEqual(@as(u64, 2048), g.vol_lba);
    try std.testing.expectEqual(@as(u16, 512), g.bps);
    try std.testing.expectEqual(@as(u8, 1), g.spc);
    try std.testing.expectEqual(@as(u16, 32), g.reserved);
    try std.testing.expectEqual(@as(u8, 2), g.nfats);
    try std.testing.expectEqual(fxt.fat_sectors, g.fat_sectors);
    try std.testing.expectEqual(@as(u32, 2), g.root_cluster);
    try std.testing.expectEqual(fxt.data_start, @as(u32, @intCast(g.data_start)));
    try std.testing.expect(g.total_clusters > 65525); // real FAT32
}

test "fat: no disk mounts nothing and is reported honestly" {
    state = .{};
    try std.testing.expectEqual(MountResult.no_disk, mount(null));
    try std.testing.expect(!mounted());
    try std.testing.expectEqual(WriteResult.no_disk, write_file("x.txt", "x"));
    var buf: [16]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, null), read_file("x.txt", &buf));
}

test "fat: list_root decodes entries, skips volume label and dot entries" {
    var fxt = try build_fixture(test_allocator, false);
    defer test_allocator.free(fxt.buf);
    make_state_fixture(&fxt);
    try std.testing.expectEqual(MountResult.ok, mount(test_ops()));
    var out: [32]DirEntry = undefined;
    const n = list_root(&out);
    try std.testing.expectEqual(@as(usize, 3), n); // EFI, KERNEL.BIN, BOOTED.TXT (label skipped)
    try std.testing.expectEqualStrings("EFI", out[0].name[0..out[0].name_len]);
    try std.testing.expect(out[0].is_dir);
    try std.testing.expectEqualStrings("KERNEL.BIN", out[1].name[0..out[1].name_len]);
    try std.testing.expectEqual(@as(u32, 0x100), out[1].size);
    try std.testing.expectEqualStrings("BOOTED.TXT", out[2].name[0..out[2].name_len]);
    try std.testing.expectEqual(@as(u32, 54), out[2].size); // "DIPSHITOS BOOTLOADER\nfirmware has agreed to cooperate\n"
}

test "fat: read_file returns content by 8.3 name, case-insensitive" {
    var fxt = try build_fixture(test_allocator, false);
    defer test_allocator.free(fxt.buf);
    make_state_fixture(&fxt);
    try std.testing.expectEqual(MountResult.ok, mount(test_ops()));
    var buf: [512]u8 = undefined;
    const n = (read_file("BOOTED.TXT", &buf) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("DIPSHITOS BOOTLOADER\nfirmware has agreed to cooperate\n", buf[0..n]);
    // Case-insensitive lookup (FAT semantics).
    try std.testing.expect((read_file("booted.txt", &buf) orelse return error.TestUnexpectedResult) == n);
    try std.testing.expect(read_file("KERNEL.BIN", &buf) != null);
    try std.testing.expect(read_file("EFI", &buf) == null); // directory
    try std.testing.expect(read_file("NOPE.TXT", &buf) == null);
}

test "fat: write_file creates a file, persists in the image, survives remount" {
    var fxt = try build_fixture(test_allocator, false);
    defer test_allocator.free(fxt.buf);
    make_state_fixture(&fxt);
    try std.testing.expectEqual(MountResult.ok, mount(test_ops()));
    try std.testing.expectEqual(WriteResult.ok, write_file("hello.txt", "hello world"));
    // Immediately visible to list + read (uppercase 8.3 on disk).
    var out: [32]DirEntry = undefined;
    const n = list_root(&out);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualStrings("HELLO.TXT", out[3].name[0..out[3].name_len]);
    try std.testing.expectEqual(@as(u32, 11), out[3].size);
    var buf: [512]u8 = undefined;
    const got = (read_file("hello.txt", &buf) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("hello world", buf[0..got]);

    // "Reboot": fresh module state, same image, mount again.
    state = .{};
    test_fixture = fxt.buf;
    try std.testing.expectEqual(MountResult.ok, mount(test_ops()));
    try std.testing.expectEqual(@as(usize, 4), list_root(&out));
    const got2 = (read_file("HELLO.TXT", &buf) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("hello world", buf[0..got2]);
}

test "fat: write_file replaces an existing file (size + content)" {
    var fxt = try build_fixture(test_allocator, false);
    defer test_allocator.free(fxt.buf);
    make_state_fixture(&fxt);
    try std.testing.expectEqual(MountResult.ok, mount(test_ops()));
    try std.testing.expectEqual(WriteResult.ok, write_file("BOOTED.TXT", "new booted content"));
    var buf: [512]u8 = undefined;
    const got = (read_file("BOOTED.TXT", &buf) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("new booted content", buf[0..got]);
    // The old chain was freed; the pool still reports free clusters.
    try std.testing.expect(free_clusters() > 0);
}

test "fat: write_file bounds — long names, over-long content, empty file" {
    var fxt = try build_fixture(test_allocator, false);
    defer test_allocator.free(fxt.buf);
    make_state_fixture(&fxt);
    try std.testing.expectEqual(MountResult.ok, mount(test_ops()));
    try std.testing.expectEqual(WriteResult.name_too_long, write_file("verylongname.txt", "x"));
    try std.testing.expectEqual(WriteResult.name_too_long, write_file(".txt", "x"));
    try std.testing.expectEqual(WriteResult.content_too_long, write_file("big.txt", &([_]u8{'x'} ** (write_content_max + 1))));
    // Empty content is a legal zero-length file.
    try std.testing.expectEqual(WriteResult.ok, write_file("empty.txt", ""));
    var buf: [512]u8 = undefined;
    try std.testing.expectEqual(@as(?usize, 0), read_file("empty.txt", &buf));
}

test "fat: multi-cluster write spans and reads back across clusters" {
    var fxt = try build_fixture(test_allocator, false);
    defer test_allocator.free(fxt.buf);
    make_state_fixture(&fxt);
    try std.testing.expectEqual(MountResult.ok, mount(test_ops()));
    // 1500 bytes > 512 (spc=1) — spans 3 clusters.
    const content = "abc" ** 500; // 1500 bytes
    try std.testing.expectEqual(WriteResult.ok, write_file("multi.txt", content));
    var buf: [write_content_max]u8 = undefined;
    const got = (read_file("multi.txt", &buf) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(usize, 1500), got);
    try std.testing.expectEqualStrings(content, buf[0..1500]);
}

test "fat: delete_file frees the slot and the chain (claim 5801)" {
    var fxt = try build_fixture(test_allocator, false);
    defer test_allocator.free(fxt.buf);
    make_state_fixture(&fxt);
    try std.testing.expectEqual(MountResult.ok, mount(test_ops()));
    try std.testing.expectEqual(WriteResult.ok, write_file("gone.txt", "temporary"));

    const before = free_clusters();
    try std.testing.expectEqual(DeleteResult.ok, delete_file("gone.txt"));
    var buf: [512]u8 = undefined;
    try std.testing.expect(read_file("gone.txt", &buf) == null);
    try std.testing.expectEqual(DeleteResult.not_found, delete_file("gone.txt"));
    try std.testing.expect(free_clusters() >= before); // chain returned
}

test "fat: rename_file moves the name in place, refusing a taken name (claim 5801)" {
    var fxt = try build_fixture(test_allocator, false);
    defer test_allocator.free(fxt.buf);
    make_state_fixture(&fxt);
    try std.testing.expectEqual(MountResult.ok, mount(test_ops()));
    try std.testing.expectEqual(WriteResult.ok, write_file("old.txt", "same content"));

    try std.testing.expectEqual(RenameResult.ok, rename_file("old.txt", "new.txt"));
    var buf: [512]u8 = undefined;
    try std.testing.expect(read_file("old.txt", &buf) == null);
    const got = (read_file("new.txt", &buf) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("same content", buf[0..got]);

    // Refuses a name that already exists, and a bad 8.3 name.
    try std.testing.expectEqual(WriteResult.ok, write_file("taken.txt", "occupied"));
    try std.testing.expectEqual(RenameResult.exists, rename_file("new.txt", "taken.txt"));
    try std.testing.expectEqual(RenameResult.name_too_long, rename_file("new.txt", "toolongname.txt"));
    try std.testing.expectEqual(RenameResult.not_found, rename_file("absent.txt", "x.txt"));
}

test "fat: truncate_file shrinks and grows with zero-fill (claim 5801)" {
    var fxt = try build_fixture(test_allocator, false);
    defer test_allocator.free(fxt.buf);
    make_state_fixture(&fxt);
    try std.testing.expectEqual(MountResult.ok, mount(test_ops()));
    try std.testing.expectEqual(WriteResult.ok, write_file("trunc.txt", "hello world"));

    try std.testing.expectEqual(TruncateResult.ok, truncate_file("trunc.txt", 5));
    var buf: [512]u8 = undefined;
    const short = (read_file("trunc.txt", &buf) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(usize, 5), short);
    try std.testing.expectEqualStrings("hello", buf[0..5]);

    try std.testing.expectEqual(TruncateResult.ok, truncate_file("trunc.txt", 12));
    const grown = (read_file("trunc.txt", &buf) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(usize, 12), grown);
    try std.testing.expectEqualStrings("hello", buf[0..5]);
    try std.testing.expectEqual(@as(u8, 0), buf[5]); // zero-fill
    try std.testing.expectEqual(@as(u8, 0), buf[11]);

    try std.testing.expectEqual(TruncateResult.too_large, truncate_file("trunc.txt", write_content_max + 1));
    try std.testing.expectEqual(TruncateResult.not_found, truncate_file("absent.txt", 4));
}

test "fat: free_space reports clusters × bytes-per-cluster (claim 5801)" {
    var fxt = try build_fixture(test_allocator, false);
    defer test_allocator.free(fxt.buf);
    make_state_fixture(&fxt);
    try std.testing.expectEqual(MountResult.ok, mount(test_ops()));
    const free = free_space();
    try std.testing.expect(free > 0);
    try std.testing.expectEqual(@as(u64, 0), free % sector_size); // whole clusters
    try std.testing.expectEqual(free, @as(u64, free_clusters()) * sector_size);
}

test "fat: LFN entries decode into the display name" {
    var fxt = try build_fixture(test_allocator, true);
    defer test_allocator.free(fxt.buf);
    make_state_fixture(&fxt);
    try std.testing.expectEqual(MountResult.ok, mount(test_ops()));
    var out: [32]DirEntry = undefined;
    const n = list_root(&out);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualStrings("Long File Name.TXT", out[3].name[0..out[3].name_len]);
    // Lookup works by long name and by short name.
    var buf: [512]u8 = undefined;
    const got = (read_file("Long File Name.TXT", &buf) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("Long File Name.TXT", buf[0..got]);
    try std.testing.expect(read_file("LONG.TXT", &buf) != null); // short name
}

test "fat: io failures are reported honestly" {
    var fxt = try build_fixture(test_allocator, false);
    defer test_allocator.free(fxt.buf);
    make_state_fixture(&fxt);
    const failing = DiskOps{
        .read = &fake_read,
        .write = struct {
            fn f(lba: u64, _: *const [sector_size]u8) bool {
                // Fail every write at or beyond the FAT area.
                return lba < 2048 + 32;
            }
        }.f,
    };
    try std.testing.expectEqual(MountResult.ok, mount(failing));
    try std.testing.expectEqual(WriteResult.io_failed, write_file("x.txt", "x"));
    try std.testing.expect(last_fail_lba() != 0);
}

/// Lay a minimal, INDEPENDENT FAT32 volume at `base_lba` (not in the GPT):
/// BPB + both FAT copies + a root holding one file "DATA.TXT" (cluster 3,
/// content "hello disk"). Proves `mount_partition` mounts ANY volume at
/// ANY LBA — the "arbitrary disk layout" half of milestone-four card 2.
fn write_min_volume(img: []u8, base_lba: u64) void {
    const base: usize = @intCast(base_lba * sector_size);
    const bs = img[base .. base + sector_size];
    const jmp_boot = [_]u8{ 0xeb, 0x58, 0x90 };
    @memcpy(bs[0..3], &jmp_boot);
    @memcpy(bs[3..11], "MSDOS5.0");
    std.mem.writeInt(u16, bs[11..13], sector_size, .little);
    bs[13] = 1; // sectors per cluster
    std.mem.writeInt(u16, bs[14..16], 32, .little); // reserved
    bs[16] = 2; // number of FATs
    bs[21] = 0xf8;
    std.mem.writeInt(u32, bs[32..36], 100, .little); // total sectors
    std.mem.writeInt(u32, bs[36..40], 1, .little); // FAT sectors (tiny volume)
    std.mem.writeInt(u32, bs[44..48], 2, .little); // root cluster
    bs[510] = 0x55;
    bs[511] = 0xaa;

    // FAT copies: cluster 2 (root) and cluster 3 (DATA.TXT) both EOC.
    const fat_off: usize = @intCast((base_lba + 32) * sector_size);
    var fat_buf = [_]u8{0} ** sector_size;
    std.mem.writeInt(u32, fat_buf[0..4], 0x0ffffff8, .little);
    std.mem.writeInt(u32, fat_buf[4..8], 0x0fffffff, .little);
    std.mem.writeInt(u32, fat_buf[8..12], 0x0fffffff, .little);
    @memcpy(img[fat_off .. fat_off + sector_size], &fat_buf);
    @memcpy(img[fat_off + sector_size ..][0..sector_size], &fat_buf);

    // Root (cluster 2 → LBA base+34) and DATA.TXT (cluster 3 → LBA base+35).
    const root_off: usize = @intCast((base_lba + 34) * sector_size);
    var root = [_]u8{0} ** sector_size;
    write_entry(&root, 0, "DATA    TXT", 0x20, 3, 10);
    @memcpy(img[root_off .. root_off + sector_size], &root);
    const data_off: usize = @intCast((base_lba + 35) * sector_size);
    @memcpy(img[data_off .. data_off + 10], "hello disk");
}

test "fat: mount_partition mounts ANY FAT32 volume at an arbitrary LBA" {
    var fxt = try build_fixture(test_allocator, false);
    defer test_allocator.free(fxt.buf);
    // A second, independent volume at LBA 100000 — not in the GPT.
    write_min_volume(fxt.buf, 100000);

    // The ESP wrapper is unchanged: still finds the ESP by GUID.
    make_state_fixture(&fxt);
    try std.testing.expectEqual(MountResult.ok, mount(test_ops()));
    try std.testing.expectEqual(@as(u64, 2048), geometry().vol_lba);

    // The general entry point mounts the second volume and serves it.
    try std.testing.expectEqual(MountResult.ok, mount_partition(test_ops(), 100000));
    try std.testing.expectEqual(@as(u64, 100000), geometry().vol_lba);
    var out: [8]DirEntry = undefined;
    try std.testing.expectEqual(@as(usize, 1), list_root(&out));
    try std.testing.expectEqualStrings("DATA.TXT", out[0].name[0..out[0].name_len]);
    var buf: [64]u8 = undefined;
    const got = (read_file("DATA.TXT", &buf) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("hello disk", buf[0..got]);
    try std.testing.expectEqual(WriteResult.ok, write_file("written.txt", "from volume 2"));
    var buf2: [64]u8 = undefined;
    const got2 = (read_file("written.txt", &buf2) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("from volume 2", buf2[0..got2]);

    // A non-FAT LBA is rejected honestly (the GPT header sector is not a BPB).
    try std.testing.expectEqual(MountResult.bad_bpb, mount_partition(test_ops(), 1));
    // And the ESP path still works after a failed mount attempt.
    try std.testing.expectEqual(MountResult.ok, mount(test_ops()));
    try std.testing.expectEqual(@as(u64, 2048), geometry().vol_lba);
}

test "fat: paths reach subdirectories (EFI/BOOT/BOOTAA64.EFI)" {
    var fxt = try build_fixture(test_allocator, false);
    defer test_allocator.free(fxt.buf);
    make_state_fixture(&fxt);
    try std.testing.expectEqual(MountResult.ok, mount(test_ops()));

    // Root listing is unchanged (bare names still resolve to the root).
    var out: [32]DirEntry = undefined;
    try std.testing.expectEqual(@as(usize, 3), list_root(&out));

    // The image's EFI and EFI/BOOT trees are reachable by path.
    try std.testing.expectEqual(@as(usize, 1), list_path("EFI", &out));
    try std.testing.expectEqualStrings("BOOT", out[0].name[0..out[0].name_len]);
    try std.testing.expectEqual(@as(usize, 1), list_path("EFI/BOOT", &out));
    try std.testing.expectEqualStrings("BOOTAA64.EFI", out[0].name[0..out[0].name_len]);
    try std.testing.expectEqual(@as(usize, 0), list_path("EFI/NOPE", &out));
    try std.testing.expectEqual(@as(usize, 0), list_path("NOPE/DEEP", &out));
    try std.testing.expectEqual(@as(usize, 3), list_path("", &out)); // empty = root

    // Read a file three levels deep. BOOTAA64.EFI's entry size is 0x200 but
    // the fixture stores 37 content bytes (zero-padded) — read into a small
    // buffer and compare the real prefix.
    var buf: [64]u8 = undefined;
    const got = (read_file("EFI/BOOT/BOOTAA64.EFI", &buf) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqual(@as(usize, 64), got);
    try std.testing.expectEqualStrings("BOOTAA64.EFI payload, padded to 0x200", buf[0..37]);

    // Leading '/' and ".." (walking back to the root) both resolve.
    _ = (read_file("/EFI/BOOT/BOOTAA64.EFI", &buf) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("BOOTAA64.EFI payload, padded to 0x200", buf[0..37]);
    const got3 = (read_file("EFI/BOOT/../../BOOTED.TXT", &buf) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("DIPSHITOS BOOTLOADER\nfirmware has agreed to cooperate\n", buf[0..got3]);

    // Directories, absent paths, and trailing '/' stay null.
    try std.testing.expect(read_file("EFI/BOOT", &buf) == null); // a directory
    try std.testing.expect(read_file("EFI/BOOT/", &buf) == null); // trailing '/'
    try std.testing.expect(read_file("EFI/BOOT/NOPE.BIN", &buf) == null);
    try std.testing.expect(read_file("NOPE/DEEP/X.TXT", &buf) == null);
}

test "fat: write_file resolves into an existing subdirectory by path" {
    var fxt = try build_fixture(test_allocator, false);
    defer test_allocator.free(fxt.buf);
    make_state_fixture(&fxt);
    try std.testing.expectEqual(MountResult.ok, mount(test_ops()));
    try std.testing.expectEqual(WriteResult.ok, write_file("EFI/BOOT/hello.txt", "hi from boot dir"));
    // Visible through the path listing and readable back.
    var out: [8]DirEntry = undefined;
    try std.testing.expectEqual(@as(usize, 2), list_path("EFI/BOOT", &out));
    var buf: [64]u8 = undefined;
    const got = (read_file("EFI/BOOT/hello.txt", &buf) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("hi from boot dir", buf[0..got]);
    // The root listing is untouched (the write went into /EFI/BOOT).
    try std.testing.expectEqual(@as(usize, 3), list_root(&out));
    // A missing / non-directory parent is reported honestly (bad_path).
    try std.testing.expectEqual(WriteResult.bad_path, write_file("NOPE/x.txt", "x"));
    try std.testing.expectEqual(WriteResult.bad_path, write_file("EFI/NOPE/x.txt", "x"));
    try std.testing.expectEqual(WriteResult.bad_path, write_file("KERNEL.BIN/x.txt", "x")); // file, not a dir
    try std.testing.expectEqual(WriteResult.name_too_long, write_file("EFI/BOOT/", "x")); // trailing '/'
}

/// Add a DATA partition (Linux-FS type GUID) at `base_lba` to the fixture's
/// GPT entries and lay a minimal data volume there — mirrors the real
/// image's two-partition layout so `mount_data` has a second partition to
/// discover by GUID.
fn add_data_partition(img: []u8, base_lba: u64) void {
    const ent_off: usize = 2 * sector_size + 128; // GPT entry index 1
    @memcpy(img[ent_off .. ent_off + 16], &data_type_guid);
    std.mem.writeInt(u64, img[ent_off + 32 ..][0..8], base_lba, .little);
    std.mem.writeInt(u64, img[ent_off + 40 ..][0..8], base_lba + 100, .little);
    write_min_volume(img, base_lba);
}

test "fat: mount_data mounts the second FAT32 partition by type GUID" {
    var fxt = try build_fixture(test_allocator, false);
    defer test_allocator.free(fxt.buf);
    add_data_partition(fxt.buf, 100000);
    make_state_fixture(&fxt);
    // The ESP wrapper is unchanged: still finds the ESP by GUID.
    try std.testing.expectEqual(MountResult.ok, mount(test_ops()));
    try std.testing.expectEqual(@as(u64, 2048), geometry().vol_lba);
    // mount_data discovers the DATA partition by its type GUID.
    try std.testing.expectEqual(MountResult.ok, mount_data(test_ops()));
    try std.testing.expectEqual(@as(u64, 100000), geometry().vol_lba);
    var out: [8]DirEntry = undefined;
    try std.testing.expectEqual(@as(usize, 1), list_root(&out));
    try std.testing.expectEqualStrings("DATA.TXT", out[0].name[0..out[0].name_len]);
    var buf: [64]u8 = undefined;
    const got = (read_file("DATA.TXT", &buf) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("hello disk", buf[0..got]);

    // A disk without a data partition reports bad_gpt honestly, and the ESP
    // path still works after the failed lookup.
    var fxt2 = try build_fixture(test_allocator, false);
    defer test_allocator.free(fxt2.buf);
    make_state_fixture(&fxt2);
    try std.testing.expectEqual(MountResult.bad_gpt, mount_data(test_ops()));
    try std.testing.expectEqual(MountResult.ok, mount(test_ops()));
    try std.testing.expectEqual(@as(u64, 2048), geometry().vol_lba);
}

test "fat: file_size reports sizes by name and /-path, null for dirs" {
    var fxt = try build_fixture(test_allocator, false);
    defer test_allocator.free(fxt.buf);
    make_state_fixture(&fxt);
    try std.testing.expectEqual(MountResult.ok, mount(test_ops()));
    try std.testing.expectEqual(@as(u32, 54), (file_size("BOOTED.TXT") orelse return error.TestUnexpectedResult));
    try std.testing.expectEqual(@as(u32, 0x200), (file_size("EFI/BOOT/BOOTAA64.EFI") orelse return error.TestUnexpectedResult));
    try std.testing.expect(file_size("EFI") == null); // a directory
    try std.testing.expect(file_size("EFI/BOOT") == null); // a directory
    try std.testing.expect(file_size("NOPE.TXT") == null);
}

// ---------------------------------------------------------------------------
// M25 Lane B (claim 2539): FAT32 directory creation + recursive size
// ---------------------------------------------------------------------------

test "fat: create_dir makes a real directory with dot entries (claim 2539)" {
    var fxt = try build_fixture(test_allocator, false);
    defer test_allocator.free(fxt.buf);
    make_state_fixture(&fxt);
    try std.testing.expectEqual(MountResult.ok, mount(test_ops()));

    try std.testing.expectEqual(MkdirResult.ok, create_dir("DOCS"));
    // Visible in the root listing as a directory entry.
    var out: [32]DirEntry = undefined;
    const n = list_root(&out);
    var found: ?DirEntry = null;
    for (out[0..n]) |e| {
        if (std.mem.eql(u8, e.name[0..e.name_len], "DOCS")) found = e;
    }
    const docs = found orelse return error.TestUnexpectedResult;
    try std.testing.expect(docs.is_dir);
    try std.testing.expectEqual(@as(u32, 0), docs.size); // dirs report size 0
    try std.testing.expect(docs.cluster >= 2); // a real data cluster

    // The listing seam skips dot entries; the new dir lists as empty.
    try std.testing.expectEqual(@as(usize, 0), list_path("/DOCS", &out));
    try std.testing.expect(path_is_dir("/DOCS"));
    try std.testing.expect(!path_is_dir("/DOCS/missing"));

    // Dot entries on disk: `.` → self, `..` → parent (root cluster 2),
    // both ATTR_DIRECTORY.
    const self_raw = blk: {
        var raw: [32]u8 = undefined;
        const lba = cluster_lba(docs.cluster);
        try std.testing.expect(read_dir_slot(.{ .lba = lba, .byte_off = 0 }, &raw));
        break :blk raw;
    };
    try std.testing.expectEqual(@as(u8, '.'), self_raw[0]);
    try std.testing.expectEqual(attr_directory, self_raw[11]);
    try std.testing.expectEqual(docs.cluster, cluster_of_raw(self_raw));
    const parent_raw = blk: {
        var raw: [32]u8 = undefined;
        const lba = cluster_lba(docs.cluster);
        try std.testing.expect(read_dir_slot(.{ .lba = lba, .byte_off = 32 }, &raw));
        break :blk raw;
    };
    try std.testing.expectEqual(@as(u8, '.'), parent_raw[0]);
    try std.testing.expectEqual(@as(u8, '.'), parent_raw[1]);
    // Spec §6.5: `..` stores 0 when the parent is the root (the root has
    // no cluster number).
    try std.testing.expectEqual(@as(u32, 0), cluster_of_raw(parent_raw));

    // Files can be written INTO it and read back by path.
    try std.testing.expectEqual(WriteResult.ok, write_file("/DOCS/NOTE.TXT", "in a real dir"));
    var buf: [64]u8 = undefined;
    const got = (read_file("/DOCS/NOTE.TXT", &buf) orelse return error.TestUnexpectedResult);
    try std.testing.expectEqualStrings("in a real dir", buf[0..got]);

    // Collision refuses — against files and directories alike.
    try std.testing.expectEqual(MkdirResult.exists, create_dir("DOCS"));
    try std.testing.expectEqual(MkdirResult.exists, create_dir("KERNEL.BIN"));
}

test "fat: dir_size_recursive sums files across bounded depth (claim 2539 F4)" {
    var fxt = try build_fixture(test_allocator, false);
    defer test_allocator.free(fxt.buf);
    make_state_fixture(&fxt);
    try std.testing.expectEqual(MountResult.ok, mount(test_ops()));

    // Tree: /DU (10) + /DU/SUB (20 + nested 40).
    try std.testing.expectEqual(WriteResult.ok, write_file("/DU_A.TXT", &([_]u8{'a'} ** 10)));
    try std.testing.expectEqual(MkdirResult.ok, create_dir("DU"));
    try std.testing.expectEqual(WriteResult.ok, write_file("/DU/B.TXT", &([_]u8{'b'} ** 20)));
    try std.testing.expectEqual(MkdirResult.ok, create_dir("/DU/SUB"));
    try std.testing.expectEqual(WriteResult.ok, write_file("/DU/SUB/C.TXT", &([_]u8{'c'} ** 40)));

    const sub = dir_size_recursive("/DU");
    try std.testing.expectEqual(@as(u64, 60), sub.bytes); // 20 + 40
    try std.testing.expect(!sub.truncated);

    // The whole volume from the root: fixture files + the DU tree.
    const all = dir_size_recursive("");
    try std.testing.expect(all.bytes >= 10 + 60);
}

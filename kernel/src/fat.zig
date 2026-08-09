//! DipshitOS FAT32 storage driver (milestone-three card, claim 6420).
//!
//! A real FAT32 filesystem over the ESP: GPT partition discovery, FAT32
//! mount, root-directory listing, file reads (short + long names), and file
//! writes (cluster allocation + FAT + directory-entry updates). It replaces
//! claim 3475's NVRAM persistence medium: `ls`/`cat`/`write` now serve the
//! live ESP through this module (driven on VZ by `virtio_blk.zig`).
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
const max_chain_clusters: usize = 256;
/// Bound on clusters allocated for one write (write_content_max / 512 + 1).
const max_alloc_clusters: usize = 64;
/// Bound on LFN parts kept in memory (a 255-char name needs 20; the root
/// cluster holds 16 slots, so 16 parts is already generous).
const max_lfn_parts: usize = 16;

/// FAT end-of-chain markers (FAT32 spec §7.4): 0x0FFFFFF8+.
const fat_eoc: u32 = 0x0fffffff;
const fat_eoc_min: u32 = 0x0ffffff8;

/// GPT type GUID of the EFI System Partition (the bytes mkfat32.py writes).
const esp_type_guid = [16]u8{ 0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11, 0xba, 0x4b, 0x00, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b };

/// The injected sector interface. Each call transfers exactly one 512-byte
/// sector; `true` on success. `virtio_blk.zig` implements these over the
/// virtio-blk queue; tests implement them over an in-memory image.
pub const DiskOps = struct {
    read: *const fn (lba: u64, buf: *[sector_size]u8) bool,
    write: *const fn (lba: u64, data: *const [sector_size]u8) bool,
};

pub const MountResult = enum { ok, no_disk, bad_gpt, bad_bpb, io_failed };

pub const WriteResult = enum { ok, no_disk, name_too_long, content_too_long, disk_full, io_failed };

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

/// The parsed geometry, exposed for diagnostics (`disk` boot line).
pub const Geo = struct {
    esp_lba: u64,
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
        .esp_lba = 0,
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

/// Install the sector interface and mount the ESP. Reads the GPT (LBA 1 +
/// partition entries), locates the EFI System Partition, parses its FAT32
/// BPB, and computes the geometry. `ops == null` mounts nothing (honest
/// no-disk state; `write`/`read` report it).
pub fn mount(ops: ?DiskOps) MountResult {
    if (ops == null) {
        state.ops = null;
        state.mounted = false;
        return .no_disk;
    }
    state.ops = ops;
    state.mounted = false;
    state.last_fail_lba = 0;

    // GPT header at LBA 1 (mkfat32.py layout; the protective MBR at LBA 0
    // is not parsed — the GPT is the identity).
    var hdr: [sector_size]u8 = undefined;
    if (!read_sector(1, &hdr)) return .io_failed;
    if (!std.mem.eql(u8, hdr[0..8], "EFI PART")) return .bad_gpt;
    const entries_lba = read_le(u64, hdr[72..80]);
    const num_entries = read_le(u32, hdr[80..84]);
    const entry_size = read_le(u32, hdr[84..88]);
    if (entries_lba == 0 or num_entries == 0 or num_entries > 128 or entry_size < 128 or entry_size > sector_size) return .bad_gpt;

    // Walk the partition entries for the ESP type GUID.
    var esp_lba: u64 = 0;
    var ei: u32 = 0;
    while (ei < num_entries) : (ei += 1) {
        const slot = entries_lba + @as(u64, ei) * entry_size / sector_size;
        const off = @as(usize, ei) * entry_size % sector_size;
        if (!read_sector(slot, &hdr)) return .io_failed;
        if (off + 128 > sector_size) continue;
        if (std.mem.eql(u8, hdr[off .. off + 16], &esp_type_guid)) {
            esp_lba = read_le(u64, hdr[off + 32 .. off + 40]);
            break;
        }
    }
    if (esp_lba == 0) return .bad_gpt;

    // FAT32 BPB at the ESP start.
    if (!read_sector(esp_lba, &hdr)) return .io_failed;
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
        .esp_lba = esp_lba,
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
    var c: u32 = 2;
    while (c < state.geo.total_clusters and free < 0x7fffffff) : (c += 1) {
        if (fat_entry(c) == 0) free += 1;
    }
    return free;
}

/// List the root directory (skipping the volume label, `.`/`..`, and
/// deleted slots). Returns the number of entries written to `out` (≤
/// out.len). Long-name entries are decoded into the display name when their
/// checksum matches the following short entry.
pub fn list_root(out: []DirEntry) usize {
    if (!state.mounted) return 0;
    var slots: [max_root_slots]SlotRef = undefined;
    const n = collect_root_slots(&slots);
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

/// Read a file's content into `out`. Returns the number of bytes copied
/// (min(file size, out.len)), or null when the file is absent or is a
/// directory. Case-insensitive on the 8.3 name (FAT semantics) and on the
/// display name.
pub fn read_file(name: []const u8, out: []u8) ?usize {
    const found = find_slot(name) orelse return null;
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

/// Write `content` to `name` on the ESP: allocate clusters from the free
/// chain, write the data, update the FAT (all copies), and create/replace
/// the root directory entry. `name` must fit FAT 8.3 (stem ≤ 8, ext ≤ 3);
/// content ≤ `write_content_max`. A failed write reports `.io_failed` /
/// `.disk_full` honestly — never a partial success.
pub fn write_file(name: []const u8, content: []const u8) WriteResult {
    // Bounds are validated before any persistence attempt (a name that can
    // never be written is reported as such even without a disk).
    if (content.len > write_content_max) return .content_too_long;
    var short: [11]u8 = undefined;
    if (!encode_83(name, &short)) return .name_too_long;
    if (!state.mounted) return .no_disk;

    // Locate the directory slot: the existing same-name entry (freed first)
    // or the first free slot (0x00 / 0xE5).
    var slots: [max_root_slots]SlotRef = undefined;
    const n = collect_root_slots(&slots);
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
        var c: u32 = 2;
        while (c < state.geo.total_clusters and got < needed) : (c += 1) {
            if (fat_entry(c) == 0) {
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
    return state.geo.esp_lba + state.geo.data_start + (@as(u64, cluster) - state.geo.root_cluster) * state.geo.spc;
}

fn fat_lba() u64 {
    return state.geo.esp_lba + state.geo.reserved;
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

/// Collect the 32-byte slot references of every root-directory entry,
/// following the root cluster chain (bounded). Stops at the first 0x00 slot
/// (end of directory marker) or when the slot window fills.
fn collect_root_slots(out: []SlotRef) usize {
    var count: usize = 0;
    var cur = state.geo.root_cluster;
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

/// Find a root entry by name: matches the 8.3-encoded short name OR the
/// display name, case-insensitively. Returns its slot (the caller can then
/// read or overwrite the entry) plus the decoded entry.
fn find_slot(name: []const u8) ?Found {
    var short: [11]u8 = undefined;
    const has_short = encode_83(name, &short);
    var slots: [max_root_slots]SlotRef = undefined;
    const n = collect_root_slots(&slots);
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
    try std.testing.expectEqual(@as(u64, 2048), g.esp_lba);
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

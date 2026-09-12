//! VirelaiOS M50 TS5 (issue #1139, ADR 0024 D8/D10): the secret-class store.
//!
//! `SECRETS.TXT` on the host share is the secret-class counterpart of
//! `SETTINGS.TXT`: the SAME bounded key/value engine semantics
//! (`max_key_len` = 32, `max_val_len` = 64, `#v1` header — 64 chars hold a
//! 32-byte key or Ed25519 seed in hex exactly), with `max_secret_entries` =
//! 8 and a DISTINCT file. Unlike settings, the FILE itself is secret-class:
//! it is denied through the file ABI and the monitor `vf` seam for every
//! actor (D8), and the ONLY in-guest reader is `sys_secret_get` (slot 70),
//! which returns the calling principal's entries into caller memory.
//!
//! ## Line format
//!
//! One entry per line: `key<TAB>uid<TAB>value`. The `uid` scopes each entry
//! to a principal (ADR 0024 D1); `sys_secret_get` returns only the caller's
//! entries (today every EL0 process is `uid_user`; `uid_system` is the
//! kernel's authority and is served to system-principal processes only).
//! Malformed lines are SKIPPED (the file is host-provisioned and the file
//! ABI cannot read it; a bad host line is a provisioning error, not guest
//! reachable). A table at the 8-entry cap refuses further entries (never
//! eviction).
//!
//! ## Secret class BY CONSTRUCTION (not only hand-seeded OWNERS.TXT)
//!
//! The file ABI denial in `trust.check` keys off the metadata table. TS2
//! seeded the class through `OWNERS.TXT`; TS5 must guarantee it even when
//! no hand-written `OWNERS.TXT` names `SECRETS.TXT`. `init_from_share()`
//! therefore calls `trust.ensure_secret_file()` BEFORE it reads a single
//! byte: the class is registered by construction, and if the (bounded,
//! 64-entry) metadata table is so full that the class cannot be registered,
//! the store REFUSES to load (fail closed — an unclassified `SECRETS.TXT`
//! would be an ordinary 0644 file the file ABI could read).
//!
//! ## Never-logged contract (D8 acceptance)
//!
//! Secret VALUES must never appear in the serial transcript, shell history,
//! env, monitor `settings`/`vf` output, `sys_procs` snapshots, crash
//! tombstones, or syscall strace. The monitor may print secret NAMES only.
//! This module exposes names only through `entry_at`; the `sys_secret_get`
//! handler copies values into caller memory through uaccess and is excluded
//! from strace in `syscall.dispatch`. There is deliberately NO `sys_secret_set`
//! (provisioning is host-side; a non-echoing set path is deferred per D8).
//!
//! Boot default unchanged: `init_from_share()` is a no-op when no host
//! channel or no `SECRETS.TXT` exists; nothing reads a secret at boot on a
//! default share, and no boot transcript line is emitted.

const std = @import("std");
const virtio_file = @import("virtio_file.zig");
const trust = @import("trust.zig");
const process = @import("process.zig");

pub const filename = "SECRETS.TXT";

/// ADR 0024 D8: the secret store bounds. A 64-char value holds a 32-byte
/// key or Ed25519 seed in hex exactly.
pub const max_key_len: usize = 32;
pub const max_val_len: usize = 64;
pub const max_secret_entries: usize = 8;

/// The share payload bound: 8 entries × (1 + 32 + 1 + 10 + 1 + 64 + 1)
/// plus the `#v1\n` header, with headroom.
pub const file_max: usize = 1024;

pub const Entry = struct {
    uid: u32 = process.uid_user,
    key: [max_key_len]u8 = [_]u8{0} ** max_key_len,
    key_len: u8 = 0,
    val: [max_val_len]u8 = [_]u8{0} ** max_val_len,
    val_len: u8 = 0,
};

/// `load` outcome. `full` means the file carried more valid entries than
/// the 8-entry cap (what fit was kept, never evicted).
pub const LoadResult = enum { ok, full };

/// The `sys_secret_get` wire record (ADR 0007 slot 70): fixed-size so the
/// userland parser needs no heap. uid + key_len + val_len + key + val.
pub const record_bytes: usize = 4 + 4 + 4 + max_key_len + max_val_len;
pub const SecretRecord = extern struct {
    uid: u32,
    key_len: u32,
    val_len: u32,
    key: [max_key_len]u8,
    val: [max_val_len]u8,
};

/// Fixed BSS scratch for the share read (no allocation; the syscall and
/// boot paths run without a large stack frame).
var scratch: [file_max]u8 = undefined;

var entries: [max_secret_entries]Entry = [_]Entry{.{}} ** max_secret_entries;
var entry_count: usize = 0;
var initialized: bool = false;

pub fn init() void {
    entries = [_]Entry{.{}} ** max_secret_entries;
    entry_count = 0;
    initialized = true;
}

pub fn ensure_init() void {
    if (!initialized) init();
}

pub fn count() usize {
    ensure_init();
    return entry_count;
}

/// The store is empty (the class may still be registered; the path is
/// denied regardless of whether any entry exists).
pub fn empty() bool {
    ensure_init();
    return entry_count == 0;
}

/// Read-only access to one entry's key NAME (never the value) for the
/// monitor `secrets` command and host tests.
pub fn entry_at(i: usize) ?struct { key: []const u8, uid: u32 } {
    ensure_init();
    if (i >= entry_count) return null;
    const e = &entries[i];
    return .{ .key = e.key[0..e.key_len], .uid = e.uid };
}

/// The number of entries owned by `uid` (the `sys_secret_get` filter).
pub fn count_for_uid(uid: u32) usize {
    ensure_init();
    var n: usize = 0;
    for (entries[0..entry_count]) |*e| {
        if (e.uid == uid) n += 1;
    }
    return n;
}

fn set_internal(uid: u32, key: []const u8, val: []const u8) SetResult {
    if (key.len == 0 or key.len > max_key_len) return .invalid_key;
    if (val.len == 0 or val.len > max_val_len) return .invalid_value;
    for (entries[0..entry_count]) |*e| {
        if (e.uid == uid and std.mem.eql(u8, e.key[0..e.key_len], key)) {
            @memcpy(e.val[0..val.len], val);
            e.val_len = @intCast(val.len);
            return .ok;
        }
    }
    if (entry_count >= max_secret_entries) return .table_full;
    var e = &entries[entry_count];
    e.uid = uid;
    @memcpy(e.key[0..key.len], key);
    e.key_len = @intCast(key.len);
    @memcpy(e.val[0..val.len], val);
    e.val_len = @intCast(val.len);
    entry_count += 1;
    return .ok;
}

pub const SetResult = enum { ok, invalid_key, invalid_value, table_full };

/// Parse a `#v1\n` + one `key<TAB>uid<TAB>value` line per entry payload.
/// Malformed lines are skipped (host-provisioning errors are not guest
/// reachable). A VALID line that finds the 8-entry table full is `full`
/// (refused, never eviction). A non-`#v1` schema refuses the WHOLE file
/// (fail closed — a differently-schemed `SECRETS.TXT` is never partially
/// trusted). Returns `ok` even with zero valid entries.
pub fn parse(text: []const u8) LoadResult {
    init();
    var seen_header = false;
    var overflow = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        if (!seen_header) {
            seen_header = true;
            if (std.mem.eql(u8, line, "#v1")) continue;
            return .ok; // unknown schema: refuse the whole file (already empty)
        }
        if (parseLine(line) == .table_full) overflow = true;
    }
    return if (overflow) .full else .ok;
}

fn parseLine(line: []const u8) SetResult {
    var fields: [3][]const u8 = .{ "", "", "" };
    var nfields: usize = 0;
    var it = std.mem.splitScalar(u8, line, '\t');
    while (it.next()) |f| {
        if (nfields < 3) fields[nfields] = f;
        nfields += 1;
    }
    if (nfields != 3) return .invalid_value;
    if (fields[1].len == 0) return .invalid_value;
    var uid: u32 = 0;
    for (fields[1]) |c| {
        if (c < '0' or c > '9') return .invalid_value;
        uid = uid * 10 + @as(u32, c - '0');
    }
    return set_internal(uid, fields[0], fields[2]);
}

/// Serialize the store as `#v1\n` + one `key<TAB>uid<TAB>value` line per
/// entry. Returns bytes written (0 when `out` is too small even for the
/// header).
pub fn serialize(out: []u8) usize {
    ensure_init();
    const header = "#v1\n";
    if (header.len > out.len) return 0;
    @memcpy(out[0..header.len], header);
    var pos: usize = header.len;
    for (entries[0..entry_count]) |*e| {
        const line_len = e.key_len + 1 + digitsOf(e.uid) + 1 + e.val_len + 1;
        if (pos + line_len > out.len) break;
        @memcpy(out[pos .. pos + e.key_len], e.key[0..e.key_len]);
        pos += e.key_len;
        out[pos] = '\t';
        pos += 1;
        var ubuf: [10]u8 = undefined;
        const ulen = std.fmt.bufPrint(&ubuf, "{d}", .{e.uid}) catch unreachable;
        @memcpy(out[pos .. pos + ulen.len], ulen);
        pos += ulen.len;
        out[pos] = '\t';
        pos += 1;
        @memcpy(out[pos .. pos + e.val_len], e.val[0..e.val_len]);
        pos += e.val_len;
        out[pos] = '\n';
        pos += 1;
    }
    return pos;
}

fn digitsOf(v: u32) usize {
    var n: usize = 1;
    var t: u32 = v;
    while (t >= 10) : (t /= 10) n += 1;
    return n;
}

/// Marshal the CALLING principal's entries into a fixed `SecretRecord`
/// array (the `sys_secret_get` wire shape). Returns the number of records
/// filled; 0 when the principal owns nothing. Values travel ONLY through
/// caller memory; nothing here is ever logged.
pub fn records_for_uid(uid: u32, out: *[max_secret_entries]SecretRecord) usize {
    ensure_init();
    var n: usize = 0;
    for (entries[0..entry_count]) |*e| {
        if (e.uid != uid) continue;
        if (n >= max_secret_entries) break;
        out[n].uid = e.uid;
        out[n].key_len = e.key_len;
        out[n].val_len = e.val_len;
        @memset(&out[n].key, 0);
        @memset(&out[n].val, 0);
        @memcpy(out[n].key[0..e.key_len], e.key[0..e.key_len]);
        @memcpy(out[n].val[0..e.val_len], e.val[0..e.val_len]);
        n += 1;
    }
    return n;
}

/// Boot + gate path: read `SECRETS.TXT` from the host share and parse it.
/// The secret class is registered BY CONSTRUCTION (`trust.ensure_secret_file`)
/// BEFORE the read; if the bounded metadata table cannot hold the class the
/// store refuses to load (fail closed). Returns true only when a file was
/// read and parsed; a default share (no file) is a silent no-op, and no boot
/// transcript line is emitted (boot-default-unchanged).
pub fn init_from_share() bool {
    init();
    if (!virtio_file.available()) return false;
    if (!trust.ensure_secret_file()) return false; // class must hold first
    const n = virtio_file.read_whole(filename, &scratch) orelse return false;
    _ = parse(scratch[0..n]);
    return true;
}

/// Serialize the store back to `SECRETS.TXT` on the share. There is no
/// guest path that calls this today (no `sys_secret_set`, per D8); it exists
/// for the host-side provisioning loop and round-trip verification.
pub fn save_to_share() bool {
    ensure_init();
    if (!virtio_file.available()) return false;
    if (!trust.ensure_secret_file()) return false;
    var buf: [file_max]u8 = undefined;
    const len = serialize(&buf);
    return virtio_file.write_whole(filename, buf[0..len]) == virtio_file.st_ok;
}

// ---------------------------------------------------------------------------
// Host tests (pure; no syscalls, no filesystem)
// ---------------------------------------------------------------------------

test "secret: defaults and the two principals" {
    init();
    try std.testing.expect(empty());
    try std.testing.expectEqual(@as(usize, 0), count());
    try std.testing.expectEqual(@as(usize, 0), count_for_uid(process.uid_user));
    try std.testing.expectEqual(@as(usize, 0), count_for_uid(process.uid_system));
}

test "secret: set/parse bounds — 32/64 field caps and 8-entry store cap" {
    init();
    var key: [max_key_len + 1]u8 = [_]u8{'k'} ** (max_key_len + 1);
    var val: [max_val_len + 1]u8 = [_]u8{'v'} ** (max_val_len + 1);
    try std.testing.expectEqual(SetResult.invalid_key, set_internal(process.uid_user, key[0..], "v"));
    try std.testing.expectEqual(SetResult.invalid_value, set_internal(process.uid_user, "k", val[0..]));
    // A 64-char value (a 32-byte Ed25519 seed in hex exactly) is accepted.
    const seed = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try std.testing.expectEqual(SetResult.ok, set_internal(process.uid_user, "netkey", seed));
    // The 8-entry cap: 7 more distinct entries fill the table, the 9th is
    // refused, never evicts.
    var i: usize = 0;
    while (i < max_secret_entries - 1) : (i += 1) {
        var nb: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&nb, "key{d}", .{i}) catch unreachable;
        try std.testing.expectEqual(SetResult.ok, set_internal(process.uid_user, name, "v"));
    }
    try std.testing.expectEqual(SetResult.table_full, set_internal(process.uid_user, "overflow", "v"));
    try std.testing.expectEqual(@as(usize, max_secret_entries), count());
    // The pre-existing entries were NOT evicted.
    var recs: [max_secret_entries]SecretRecord = undefined;
    try std.testing.expectEqual(@as(usize, max_secret_entries), records_for_uid(process.uid_user, &recs));
}

test "secret: round-trip parse/serialize preserves values per uid" {
    const src = "#v1\nnetkey\t1000\t0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\naudkey\t0\t000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f\n";
    try std.testing.expectEqual(LoadResult.ok, parse(src));
    try std.testing.expectEqual(@as(usize, 2), count());
    var buf: [file_max]u8 = undefined;
    const n = serialize(&buf);
    try std.testing.expect(n > 0);
    const out = buf[0..n];
    try std.testing.expect(std.mem.startsWith(u8, out, "#v1\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "netkey\t1000\t0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "audkey\t0\t000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f\n") != null);
    // Re-loading the serialized form reproduces the same per-uid filter.
    try std.testing.expectEqual(LoadResult.ok, parse(out));
    var recs: [max_secret_entries]SecretRecord = undefined;
    try std.testing.expectEqual(@as(usize, 1), records_for_uid(process.uid_user, &recs));
    try std.testing.expectEqualStrings("netkey", recs[0].key[0..recs[0].key_len]);
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", recs[0].val[0..recs[0].val_len]);
    try std.testing.expectEqual(@as(usize, 1), records_for_uid(process.uid_system, &recs));
    try std.testing.expectEqualStrings("audkey", recs[0].key[0..recs[0].key_len]);
    // A third principal owns nothing.
    try std.testing.expectEqual(@as(usize, 0), records_for_uid(2000, &recs));
}

test "secret: sys_secret_get wire records are fixed-size and value-carrying" {
    init();
    const seed = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
    try std.testing.expectEqual(SetResult.ok, set_internal(process.uid_user, "seed", seed));
    var recs: [max_secret_entries]SecretRecord = undefined;
    try std.testing.expectEqual(@as(usize, 1), records_for_uid(process.uid_user, &recs));
    try std.testing.expectEqual(@as(u32, 4), recs[0].key_len);
    try std.testing.expectEqual(@as(u32, 64), recs[0].val_len);
    try std.testing.expectEqual(process.uid_user, recs[0].uid);
    try std.testing.expect(std.mem.eql(u8, "seed", recs[0].key[0..4]));
    try std.testing.expect(std.mem.eql(u8, seed, recs[0].val[0..64]));
}

test "secret: malformed lines are skipped; unknown schema refuses the file" {
    init();
    // Bad line shapes (missing field, bad uid) are skipped; the valid
    // entry survives. No cap was hit, so the load is `ok` (not `full`).
    const src = "#v1\ngood\t1000\tsomevalue\nmalformed-no-tabs\nbaduid\tzzz\tvalue\n";
    try std.testing.expectEqual(LoadResult.ok, parse(src));
    try std.testing.expectEqual(@as(usize, 1), count());
    var recs: [max_secret_entries]SecretRecord = undefined;
    try std.testing.expectEqual(@as(usize, 1), records_for_uid(process.uid_user, &recs));
    try std.testing.expectEqualStrings("good", recs[0].key[0..recs[0].key_len]);

    // A 9th VALID entry is the cap refusal: `.full`, never eviction.
    init();
    var body: [1024]u8 = undefined;
    var pos: usize = 0;
    @memcpy(body[0..4], "#v1\n");
    pos = 4;
    var i: usize = 0;
    while (i < 9) : (i += 1) {
        const line = std.fmt.bufPrint(body[pos..], "k{d}\t1000\tv\n", .{i}) catch unreachable;
        pos += line.len;
    }
    try std.testing.expectEqual(LoadResult.full, parse(body[0..pos]));
    try std.testing.expectEqual(@as(usize, max_secret_entries), count());

    // A non-#v1 schema refuses the WHOLE file (fail closed).
    init();
    const v2 = "#v2\nnetkey\t1000\tvalue\n";
    try std.testing.expectEqual(LoadResult.ok, parse(v2));
    try std.testing.expect(empty());
}

test "secret: the 8-entry cap counts the table, not one principal" {
    init();
    var i: usize = 0;
    while (i < max_secret_entries) : (i += 1) {
        var nb: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&nb, "k{d}", .{i}) catch unreachable;
        // Alternate owners; the cap is on the table, not per uid.
        const owner: u32 = if (i % 2 == 0) process.uid_user else process.uid_system;
        try std.testing.expectEqual(SetResult.ok, set_internal(owner, name, "v"));
    }
    try std.testing.expectEqual(@as(usize, max_secret_entries), count());
    var recs: [max_secret_entries]SecretRecord = undefined;
    try std.testing.expectEqual(@as(usize, 4), records_for_uid(process.uid_user, &recs));
    try std.testing.expectEqual(@as(usize, 4), records_for_uid(process.uid_system, &recs));
}

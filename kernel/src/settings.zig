//! DipshitOS persistent settings engine (Milestone 8 Card U8, claim 2649).
//!
//! Provides in-memory key-value configuration backed by `SETTINGS.TXT` on
//! the second FAT32 partition (`DATA` partition, Linux-FS type GUID).
//!
//! Keys supported:
//!   - `hostname`: system host identifier (default: "dipshit")
//!   - `prompt`: interactive shell prompt string (default: "dipshit> ")
//!   - `theme`: UI visual color accent (default: "default")
//!   - `scrollback`: terminal scrollback buffer lines (default: "1000")
//!
//! Boot contract:
//!   On kernel boot, after block-device arming, `settings.init_from_disk(ops)`
//!   mounts the DATA partition, reads `SETTINGS.TXT` if present, parses
//!   the key-values, and re-arms the ESP window so normal command operations
//!   proceed from the ESP.
//!
//! Persistence:
//!   `settings set <key> <value>` persists immediately to the DATA partition
//!   by updating in-memory state, writing `SETTINGS.TXT`, and restoring the
//!   active partition.
//!
//! No libc, no POSIX, bounded BSS storage, no heap allocation.

const std = @import("std");
const fat = @import("fat.zig");
const esp = @import("esp.zig");

pub const filename = "SETTINGS.TXT";

pub const max_key_len: usize = 32;
pub const max_val_len: usize = 64;
pub const max_entries: usize = 16;

pub const Entry = struct {
    key: [max_key_len]u8 = [_]u8{0} ** max_key_len,
    key_len: usize = 0,
    val: [max_val_len]u8 = [_]u8{0} ** max_val_len,
    val_len: usize = 0,
};

pub const SetResult = enum {
    ok,
    invalid_key,
    invalid_value,
    table_full,
};

var entries: [max_entries]Entry = undefined;
var entry_count: usize = 0;
var initialized: bool = false;

/// Populate default settings table.
pub fn init() void {
    entry_count = 0;
    _ = set_internal("hostname", "dipshit");
    _ = set_internal("prompt", "dipshit> ");
    _ = set_internal("theme", "default");
    _ = set_internal("scrollback", "1000");
    initialized = true;
}

pub fn ensure_init() void {
    if (!initialized) init();
}

/// Reset settings to built-in defaults.
pub fn reset() void {
    init();
}

/// Count of current configuration entries.
pub fn count() usize {
    ensure_init();
    return entry_count;
}

/// Retrieve an entry by index for listing.
pub fn entry_at(i: usize) ?struct { key: []const u8, val: []const u8 } {
    ensure_init();
    if (i >= entry_count) return null;
    const e = &entries[i];
    return .{
        .key = e.key[0..e.key_len],
        .val = e.val[0..e.val_len],
    };
}

/// Retrieve configuration value for key.
pub fn get(key: []const u8) ?[]const u8 {
    ensure_init();
    for (entries[0..entry_count]) |*e| {
        if (std.mem.eql(u8, e.key[0..e.key_len], key)) {
            return e.val[0..e.val_len];
        }
    }
    return null;
}

/// Dynamic helper for shell prompt string.
pub fn get_prompt() []const u8 {
    return get("prompt") orelse "dipshit> ";
}

/// Dynamic helper for system hostname.
pub fn get_hostname() []const u8 {
    return get("hostname") orelse "dipshit";
}

fn set_internal(key: []const u8, val: []const u8) SetResult {
    if (key.len == 0 or key.len > max_key_len) return .invalid_key;
    if (val.len > max_val_len) return .invalid_value;

    for (entries[0..entry_count]) |*e| {
        if (std.mem.eql(u8, e.key[0..e.key_len], key)) {
            @memcpy(e.val[0..val.len], val);
            e.val_len = val.len;
            return .ok;
        }
    }

    if (entry_count >= max_entries) return .table_full;
    var e = &entries[entry_count];
    @memcpy(e.key[0..key.len], key);
    e.key_len = key.len;
    @memcpy(e.val[0..val.len], val);
    e.val_len = val.len;
    entry_count += 1;
    return .ok;
}

/// Set a configuration key-value pair in memory.
pub fn set(key: []const u8, val: []const u8) SetResult {
    ensure_init();
    return set_internal(key, val);
}

/// Parse a single `key=value` line into settings.
pub fn parse_line(line: []const u8) bool {
    ensure_init();
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return false;
    const key = std.mem.trim(u8, line[0..eq], " \t");
    const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
    if (key.len == 0) return false;
    return set_internal(key, val) == .ok;
}

/// Serialize in-memory settings table into a newline-separated buffer.
pub fn serialize(out: []u8) usize {
    ensure_init();
    var pos: usize = 0;
    for (entries[0..entry_count]) |*e| {
        const line_len = e.key_len + 1 + e.val_len + 1;
        if (pos + line_len > out.len) break;
        @memcpy(out[pos .. pos + e.key_len], e.key[0..e.key_len]);
        pos += e.key_len;
        out[pos] = '=';
        pos += 1;
        @memcpy(out[pos .. pos + e.val_len], e.val[0..e.val_len]);
        pos += e.val_len;
        out[pos] = '\n';
        pos += 1;
    }
    return pos;
}

/// Load configuration from `SETTINGS.TXT` on the DATA partition.
pub fn load_from_disk(ops: ?fat.DiskOps) bool {
    ensure_init();
    if (ops == null) return false;

    if (fat.mount_data(ops) != .ok) return false;
    var file_buf: [2048]u8 = undefined;
    const n = fat.read_file(filename, &file_buf);
    if (n == null) {
        _ = esp.set_disk(ops);
        return false;
    }

    var pos: usize = 0;
    const bytes = file_buf[0..n.?];
    while (pos < bytes.len) {
        var end = pos;
        while (end < bytes.len and bytes[end] != '\n') : (end += 1) {}
        const line = std.mem.trim(u8, bytes[pos..end], " \r\t");
        if (line.len > 0 and line[0] != '#') {
            _ = parse_line(line);
        }
        pos = end + 1;
    }

    _ = esp.set_disk(ops);
    return true;
}

/// Persist current in-memory configuration to `SETTINGS.TXT` on DATA partition.
pub fn save_to_disk(ops: ?fat.DiskOps) bool {
    ensure_init();
    if (ops == null) return false;

    const is_data_active = std.mem.eql(u8, esp.volume(), "data");

    if (fat.mount_data(ops) != .ok) return false;
    var buf: [2048]u8 = undefined;
    const len = serialize(&buf);
    const wr = fat.write_file(filename, buf[0..len]);

    if (is_data_active) {
        _ = fat.mount_data(ops);
        esp.resnapshot();
    } else {
        _ = esp.set_disk(ops);
    }
    return wr == .ok;
}

/// Initializer called during kernel boot: resets defaults then attempts disk load.
pub fn init_from_disk(ops: ?fat.DiskOps) void {
    init();
    if (ops != null) {
        _ = load_from_disk(ops);
    }
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "settings: default initialization and getters" {
    init();
    try std.testing.expectEqualStrings("dipshit", get_hostname());
    try std.testing.expectEqualStrings("dipshit> ", get_prompt());
    try std.testing.expectEqualStrings("default", get("theme").?);
    try std.testing.expectEqualStrings("1000", get("scrollback").?);
}

test "settings: set and update existing keys" {
    init();
    try std.testing.expectEqual(SetResult.ok, set("hostname", "my-box"));
    try std.testing.expectEqualStrings("my-box", get_hostname());

    try std.testing.expectEqual(SetResult.ok, set("prompt", "custom# "));
    try std.testing.expectEqualStrings("custom# ", get_prompt());

    try std.testing.expectEqual(SetResult.ok, set("newkey", "newval"));
    try std.testing.expectEqualStrings("newval", get("newkey").?);
}

test "settings: line parser" {
    init();
    try std.testing.expect(parse_line("hostname=testbox"));
    try std.testing.expectEqualStrings("testbox", get_hostname());

    try std.testing.expect(parse_line("prompt = myprompt> "));
    try std.testing.expectEqualStrings("myprompt>", get_prompt());

    try std.testing.expect(!parse_line("no_equals_here"));
}

test "settings: serialization round trip" {
    init();
    try std.testing.expectEqual(SetResult.ok, set("hostname", "roundtrip-host"));
    try std.testing.expectEqual(SetResult.ok, set("prompt", "rt> "));

    var buf: [512]u8 = undefined;
    const len = serialize(&buf);
    try std.testing.expect(len > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "hostname=roundtrip-host\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "prompt=rt> \n") != null);
}

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
//!
//! Version contract (Arc5 issue #247):
//!   SETTINGS.TXT carries a version header on the first line: `#v<N>\n`.
//!   The current schema version is `current_version` (= 1).
//!   - v0 (no header): legacy format, loaded then migrated to current.
//!   - v1: versioned format with `#v1` header.
//!   - newer: refused with honest degradation (compiled defaults used).
//!   Migration steps live in `migrate()`. Each step adds missing keys
//!   with defaults and removes obsolete keys. Serial logs what changed.
//!   To increment: bump `current_version`, add a migration step in
//!   `migrate()`, and document the schema change here.
//!
//! Schema (keys, types, defaults, valid values):
//!   hostname   string  "dipshit"     1..32 chars, system host identifier
//!   prompt     string  "dipshit> "   1..64 chars, interactive shell prompt
//!   theme      string  "dark"        "dark"|"light"|"amber", UI color accent
//!   scrollback string  "1000"        positive integer, terminal scrollback lines
//!   color      string  "on"          "on"|"off", ANSI terminal colors in shell

const std = @import("std");
const fat = @import("fat.zig");
const esp = @import("esp.zig");

pub const filename = "SETTINGS.TXT";

/// Current schema version. Increment when keys are added/removed/renamed.
/// The version header in SETTINGS.TXT is `#v<N>` on the first line.
pub const current_version: u32 = 1;

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
    _ = set_internal("theme", "dark");
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

/// M18 T5: whether ANSI terminal colors are enabled.
pub fn get_color() bool {
    const val = get("color") orelse return true; // on by default
    return std.mem.eql(u8, val, "on") or std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
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

const driving_award = @import("driving_award.zig");
const text = @import("text.zig");

/// Set a configuration key-value pair in memory.
pub fn set(key: []const u8, val: []const u8) SetResult {
    ensure_init();
    const result = set_internal(key, val);
    // Step 7 (Issue #207): when theme is set, update the compositor's theme_id.
    if (result == .ok and std.mem.eql(u8, key, "theme")) {
        apply_theme(val);
    }
    // M20-U11 (claim 5127): debug_font is the text layer's dev setting.
    if (result == .ok and std.mem.eql(u8, key, "debug_font")) {
        apply_debug_font(val);
    }
    return result;
}

/// Apply the debug_font key to the framebuffer text layer.
fn apply_debug_font(val: []const u8) void {
    text.debug_font = std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "on") or std.mem.eql(u8, val, "1");
}

/// Apply a theme by name, updating driving_award.theme_id.
fn apply_theme(name: []const u8) void {
    if (std.mem.eql(u8, name, "dark") or std.mem.eql(u8, name, "default")) {
        driving_award.theme_id = 0;
    } else if (std.mem.eql(u8, name, "light")) {
        driving_award.theme_id = 1;
    } else if (std.mem.eql(u8, name, "amber")) {
        driving_award.theme_id = 2;
    }
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
/// The first line is the version header: `#v<N>\n`.
pub fn serialize(out: []u8) usize {
    ensure_init();
    // Write version header (comptime-known string)
    const header = comptime blk: {
        const v = current_version;
        break :blk if (v < 10) "#v" ++ &[_]u8{'0' + v} ++ "\n" else if (v < 100) "#v" ++ &[_]u8{ '0' + v / 10, '0' + v % 10 } ++ "\n" else "#v100\n";
    };
    if (header.len > out.len) return 0;
    @memcpy(out[0..header.len], header);
    var pos: usize = header.len;
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
/// Handles versioned (v1+) and legacy (no version header) files.
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
    var file_version: u32 = 0; // v0 = no header (legacy)
    const bytes = file_buf[0..n.?];

    // Parse first line: check for version header
    if (bytes.len > 0) {
        var end: usize = 0;
        while (end < bytes.len and bytes[end] != '\n') : (end += 1) {}
        const first_line = std.mem.trim(u8, bytes[0..end], " \r\t");
        if (std.mem.startsWith(u8, first_line, "#v")) {
            // Parse version number after #v
            const version_str = first_line[2..];
            file_version = 0;
            for (version_str) |c| {
                if (c >= '0' and c <= '9') {
                    file_version = file_version * 10 + @as(u32, c - '0');
                } else {
                    break;
                }
            }
            pos = end + 1; // skip version line
        }
        // If no #v prefix, file_version stays 0 (legacy v0 format)
    }

    // Handle version-specific loading
    if (file_version > current_version) {
        // Newer version than we support — refuse, use compiled defaults
        // (honest degradation per issue #247)
        _ = esp.set_disk(ops);
        return false;
    }

    // Parse key=value lines (skip comment lines starting with #)
    while (pos < bytes.len) {
        var end = pos;
        while (end < bytes.len and bytes[end] != '\n') : (end += 1) {}
        const line = std.mem.trim(u8, bytes[pos..end], " \r\t");
        if (line.len > 0 and line[0] != '#') {
            _ = parse_line(line);
        }
        pos = end + 1;
    }

    // Run migration if needed (v0 -> v1 adds missing keys with defaults)
    if (file_version < current_version) {
        migrate(file_version);
    }

    _ = esp.set_disk(ops);
    return true;
}

/// Migrate from one version to the current version.
/// Each migration step adds missing keys with defaults and removes obsolete ones.
/// Logs changes to serial for debugging.
fn migrate(from_version: u32) void {
    // v0 -> v1: no new keys added in v1; this is the schema documentation
    // milestone. Future migrations will add keys here.
    if (from_version < 1) {
        // v0 was the original format without version header.
        // No key changes needed — the schema is stable.
    }
    // Future: if (from_version < 2) { migrate_v1_to_v2(); }
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
    try std.testing.expectEqualStrings("dark", get("theme").?);
    try std.testing.expectEqualStrings("1000", get("scrollback").?);
}

test "settings: debug_font applies to the text layer (M20-U11)" {
    init();
    defer _ = set("debug_font", "false");
    try std.testing.expect(!text.debug_font);
    try std.testing.expectEqual(SetResult.ok, set("debug_font", "true"));
    try std.testing.expect(text.debug_font);
    try std.testing.expectEqual(SetResult.ok, set("debug_font", "off"));
    try std.testing.expect(!text.debug_font);
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
    // Version header must be the first line
    try std.testing.expect(std.mem.startsWith(u8, buf[0..len], "#v1\n"));
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "hostname=roundtrip-host\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "prompt=rt> \n") != null);
}

test "settings: version header is present" {
    init();
    var buf: [512]u8 = undefined;
    const len = serialize(&buf);
    try std.testing.expect(len > 3);
    try std.testing.expectEqual(@as(u8, '#'), buf[0]);
    try std.testing.expectEqual(@as(u8, 'v'), buf[1]);
    try std.testing.expectEqual(@as(u8, '1'), buf[2]);
    try std.testing.expectEqual(@as(u8, '\n'), buf[3]);
}

test "settings: current_version constant" {
    try std.testing.expect(current_version >= 1);
    try std.testing.expect(current_version <= 100);
}

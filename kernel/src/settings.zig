//! VirelaiOS persistent settings engine (Milestone 8 Card U8, claim 2649).
//!
//! Provides in-memory key-value configuration backed by `SETTINGS.TXT` on
//! the second FAT32 partition (`DATA` partition, Linux-FS type GUID).
//!
//! Keys supported:
//!   - `hostname`: system host identifier (default: "virelai")
//!   - `prompt`: interactive shell prompt string (default: "virelai> ")
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
//!   hostname   string  "virelai"     1..32 chars, system host identifier
//!   prompt     string  "virelai> "   1..64 chars, interactive shell prompt
//!   theme      string  "dark"        "dark"|"light"|"amber", UI color accent
//!   scrollback string  "1000"        positive integer, terminal scrollback lines
//!   color      string  "on"          "on"|"off", ANSI terminal colors in shell

const std = @import("std");
const fat = @import("fat.zig");
const esp = @import("esp.zig");
// M34 HF5 (issue #739): the host-share persistence path.
const virtio_file = @import("virtio_file.zig");

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
    _ = set_internal("hostname", "virelai");
    _ = set_internal("prompt", "virelai> ");
    _ = set_internal("theme", "dark");
    _ = set_internal("scrollback", "1000");
    _ = set_internal("focus_follows_mouse", "off");
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
    return get("prompt") orelse "virelai> ";
}

/// Dynamic helper for system hostname.
pub fn get_hostname() []const u8 {
    return get("hostname") orelse "virelai";
}

/// M18 T5: whether ANSI terminal colors are enabled.
pub fn get_color() bool {
    const val = get("color") orelse return true; // on by default
    return std.mem.eql(u8, val, "on") or std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
}

/// M27 G13 (#456): whether focus follows mouse pointer.
pub fn get_focus_follows_mouse() bool {
    const val = get("focus_follows_mouse") orelse return false;
    return std.mem.eql(u8, val, "on") or std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
}

// ---------------------------------------------------------------------------
// Theme & Font Settings API (M27 G20 #463, G21 #464)
// ---------------------------------------------------------------------------

pub const ThemeColors = struct {
    bg: u32,
    fg: u32,
    accent: u32,
    border: u32,
    title_bg: u32,
    title_fg: u32,
    @"error": u32,
    success: u32,
};

/// Retrieve active theme identifier: 0=dark, 1=light, 2=amber.
pub fn get_theme_id() u8 {
    const val = get("theme") orelse "dark";
    if (std.mem.eql(u8, val, "light")) return 1;
    if (std.mem.eql(u8, val, "amber")) return 2;
    return 0; // dark / default
}

/// Set active theme by ID: 0=dark, 1=light, 2=amber.
pub fn set_theme_id(id: u8) void {
    const name: []const u8 = switch (id) {
        1 => "light",
        2 => "amber",
        else => "dark",
    };
    _ = set("theme", name);
}

/// Get the active theme color palette for UI rendering.
pub fn get_theme_colors() ThemeColors {
    return switch (get_theme_id()) {
        1 => .{ // Light
            .bg = 0xf1f5f9,
            .fg = 0x0f172a,
            .accent = 0x2563eb,
            .border = 0xcbd5e1,
            .title_bg = 0xe2e8f0,
            .title_fg = 0x0f172a,
            .@"error" = 0xdc2626,
            .success = 0x16a34a,
        },
        2 => .{ // Amber
            .bg = 0x1a1000,
            .fg = 0xffcc00,
            .accent = 0xff8800,
            .border = 0x5a4000,
            .title_bg = 0x3a2800,
            .title_fg = 0xffcc00,
            .@"error" = 0xff4444,
            .success = 0x88cc00,
        },
        else => .{ // Dark (0)
            .bg = 0x182026,
            .fg = 0xffffff,
            .accent = 0x3b82f6,
            .border = 0x334155,
            .title_bg = 0x222d35,
            .title_fg = 0xffffff,
            .@"error" = 0xef4444,
            .success = 0x22c55e,
        },
    };
}

/// Retrieve terminal font size identifier: 0=8x8 (small), 1=16x16 (medium), 2=24x24 (large).
pub fn get_font_size() u8 {
    const val = get("font_size") orelse return 0;
    if (std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "medium") or std.mem.eql(u8, val, "16x16")) return 1;
    if (std.mem.eql(u8, val, "2") or std.mem.eql(u8, val, "large") or std.mem.eql(u8, val, "24x24")) return 2;
    return 0; // 0 = 8x8 / small
}

/// Set terminal font size by identifier: 0=8x8, 1=16x16, 2=24x24.
pub fn set_font_size(size: u8) void {
    const val: []const u8 = switch (size) {
        1 => "medium",
        2 => "large",
        else => "small",
    };
    _ = set("font_size", val);
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
    // M20-U1 (claim 5127): font_size persists the terminal font choice.
    if (result == .ok and std.mem.eql(u8, key, "font_size")) {
        apply_font_size(val);
    }
    // M27 G13 (#456): focus_follows_mouse setting
    if (result == .ok and std.mem.eql(u8, key, "focus_follows_mouse")) {
        apply_focus_follows_mouse(val);
    }
    return result;
}

fn apply_focus_follows_mouse(val: []const u8) void {
    const is_on = std.mem.eql(u8, val, "on") or std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true");
    driving_award.focus_follows_mouse = is_on;
}

/// Apply the font_size key to the framebuffer text layer.
fn apply_font_size(val: []const u8) void {
    const size: ?text.FontSize = if (std.mem.eql(u8, val, "small") or std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "8x8"))
        .small
    else if (std.mem.eql(u8, val, "medium") or std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "16x16"))
        .medium
    else if (std.mem.eql(u8, val, "large") or std.mem.eql(u8, val, "2") or std.mem.eql(u8, val, "24x24"))
        .large
    else
        null;
    if (size) |s| text.set_font_size(s);
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

/// Parse + apply a SETTINGS.TXT payload (versioned v1+ / legacy v0),
/// shared by the DATA and host-share loaders. Returns false when a NEWER
/// schema version is refused (honest degradation per issue #247).
fn apply_bytes(bytes: []const u8) bool {
    var pos: usize = 0;
    var file_version: u32 = 0; // v0 = no header (legacy)

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
        // Newer version than we support — refuse, use compiled defaults.
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
    return true;
}

/// M34 HF5 (issue #739): load settings from the HOST SHARE when the file
/// channel is armed (the migration copies /data/SETTINGS.TXT over, so the
/// share wins on the first share boot). No-op without a channel — the
/// DATA loader above stays the fallback (dual path until HF6).
pub fn load_from_share() bool {
    ensure_init();
    if (!virtio_file.available()) return false;
    var file_buf: [2048]u8 = undefined;
    const n = virtio_file.read_whole(filename, &file_buf) orelse return false;
    return apply_bytes(file_buf[0..n]);
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

    const ok = apply_bytes(file_buf[0..n.?]);
    _ = esp.set_disk(ops);
    return ok;
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
    // M34 HF5 (issue #739): the HOST SHARE is the persistence home when
    // the channel is armed (write_whole = open/create + truncate +
    // write + close, host-verified on disk by the gate). DATA fallback
    // otherwise (dual path until HF6).
    if (virtio_file.available()) {
        var buf: [2048]u8 = undefined;
        const len = serialize(&buf);
        return virtio_file.write_whole(filename, buf[0..len]) == virtio_file.st_ok;
    }
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
    try std.testing.expectEqualStrings("virelai", get_hostname());
    try std.testing.expectEqualStrings("virelai> ", get_prompt());
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

test "settings: theme colors and IDs (M27 G20)" {
    init();
    try std.testing.expectEqual(@as(u8, 0), get_theme_id());
    const dark_colors = get_theme_colors();
    try std.testing.expectEqual(@as(u32, 0x182026), dark_colors.bg);
    try std.testing.expectEqual(@as(u32, 0xef4444), dark_colors.@"error");

    set_theme_id(1); // Light
    try std.testing.expectEqual(@as(u8, 1), get_theme_id());
    const light_colors = get_theme_colors();
    try std.testing.expectEqual(@as(u32, 0xf1f5f9), light_colors.bg);
    try std.testing.expectEqual(@as(u32, 0xdc2626), light_colors.@"error");

    set_theme_id(2); // Amber
    try std.testing.expectEqual(@as(u8, 2), get_theme_id());
    const amber_colors = get_theme_colors();
    try std.testing.expectEqual(@as(u32, 0x1a1000), amber_colors.bg);
    try std.testing.expectEqual(@as(u32, 0xff4444), amber_colors.@"error");

    set_theme_id(0); // Reset to dark
    try std.testing.expectEqual(@as(u8, 0), get_theme_id());
}

test "settings: font size getters and setters (M27 G21)" {
    init();
    try std.testing.expectEqual(@as(u8, 0), get_font_size());

    set_font_size(1);
    try std.testing.expectEqual(@as(u8, 1), get_font_size());
    try std.testing.expectEqualStrings("medium", get("font_size").?);

    set_font_size(2);
    try std.testing.expectEqual(@as(u8, 2), get_font_size());
    try std.testing.expectEqualStrings("large", get("font_size").?);

    set_font_size(0);
    try std.testing.expectEqual(@as(u8, 0), get_font_size());
    try std.testing.expectEqualStrings("small", get("font_size").?);
}

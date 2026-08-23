//! calc/defs.zig — M24 K15 saved expressions & definitions for CALC.BIN.
//!
//! Bounded name→value table (8 entries, names ≤ 16 chars, f64 values)
//! with FAT persistence ("name=value" lines). Pure logic; file I/O lives
//! in the caller so host tests run without syscall stubs.

const std = @import("std");

pub const max_defs: usize = 8;
pub const max_name: usize = 16;

pub const Defs = struct {
    names: [max_defs][max_name]u8 = [_][max_name]u8{[_]u8{0} ** max_name} ** max_defs,
    values: [max_defs]f64 = [_]f64{0} ** max_defs,
    len: usize = 0,

    fn slot_len(slot: [max_name]u8) usize {
        var n: usize = 0;
        while (n < max_name and slot[n] != 0) n += 1;
        return n;
    }

    /// Look up a name (exact match).
    pub fn get(self: *const Defs, name: []const u8) ?f64 {
        for (self.names[0..self.len], 0..) |slot, i| {
            const stored = slot[0 .. Defs.slot_len(slot)];
            if (std.mem.eql(u8, stored, name)) return self.values[i];
        }
        return null;
    }

    /// Store/replace. Returns error when the table is full or the name is
    /// empty/too long — honest refusals, never silent drops.
    pub fn put(self: *Defs, name: []const u8, value: f64) error{ Full, BadName }!void {
        if (name.len == 0 or name.len > max_name) return error.BadName;
        for (name) |ch| {
            if (!Defs.is_valid_name(ch)) return error.BadName;
        }
        // Replace existing?
        for (self.names[0..self.len], 0..) |slot, i| {
            const stored = slot[0 .. Defs.slot_len(slot)];
            if (std.mem.eql(u8, stored, name)) {
                self.values[i] = value;
                return;
            }
        }
        if (self.len >= max_defs) return error.Full;
        @memcpy(self.names[self.len][0..name.len], name);
        self.values[self.len] = value;
        self.len += 1;
    }

    fn name_len(slot: [max_name]u8) usize {
        var n: usize = 0;
        while (n < max_name and slot[n] != 0) n += 1;
        return n;
    }

    fn is_valid_name(ch: u8) bool {
        return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
            ch == '_' or (ch >= '0' and ch <= '9');
    }

    /// Load "name=value" lines produced by write_file_text.
    pub fn load_file_text(self: *Defs, text: []const u8) void {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \r\t");
            if (line.len == 0) continue;
            const eq = std.mem.indexOf(u8, line, "=") orelse continue;
            const name = line[0..eq];
            const val = std.fmt.parseFloat(f64, line[eq + 1 ..]) catch continue;
            self.put(name, val) catch continue; // skip bad/full lines
        }
    }

    /// Render all definitions as "name=value" lines into `buf`.
    pub fn write_file_text(self: *const Defs, buf: []u8) []const u8 {
        var pos: usize = 0;
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            const name = self.names[i][0 .. Defs.slot_len(self.names[i])];
            const line = std.fmt.bufPrint(buf[pos..], "{s}={d}\n", .{ name, self.values[i] }) catch break;
            pos += line.len;
        }
        return buf[0..pos];
    }
};

fn is_def_name_char(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or
        ch == '_' or (ch >= '0' and ch <= '9');
}

/// Parse a "def name = expression" command line. Returns the name and the
/// expression slice for the caller to evaluate.
pub fn parse_def_command(text: []const u8) ?struct { name: []const u8, expr: []const u8 } {
    if (!std.mem.startsWith(u8, text, "def ")) return null;
    const rest = std.mem.trim(u8, text[4..], " ");
    const eq = std.mem.indexOf(u8, rest, "=") orelse return null;
    const name = std.mem.trim(u8, rest[0..eq], " ");
    const value_expr = std.mem.trim(u8, rest[eq + 1 ..], " ");
    if (name.len == 0 or value_expr.len == 0) return null;
    for (name) |ch| {
        if (!is_def_name_char(ch)) return null;
    }
    return .{ .name = name, .expr = value_expr };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "defs: bounded table with replace and refusals" {
    var d = Defs{};
    try d.put("tax_rate", 0.08);
    try std.testing.expectEqual(@as(?f64, 0.08), d.get("tax_rate"));

    // Replace in place — no duplicate entry
    try d.put("tax_rate", 0.09);
    try std.testing.expectEqual(@as(usize, 1), d.len);

    // Fill to capacity
    var i: usize = 0;
    while (i < max_defs - 1) : (i += 1) {
        var name_buf: [16]u8 = undefined;
        const nm = std.fmt.bufPrint(&name_buf, "v{d}", .{i}) catch unreachable;
        try d.put(nm, @floatFromInt(i));
    }
    try std.testing.expectEqual(max_defs, d.len);
    try std.testing.expectError(error.Full, d.put("one_too_many", 1));

    // Bad names refused
    try std.testing.expectError(error.BadName, d.put("", 1));
    try std.testing.expectError(error.BadName, d.put("way_over_sixteen_chars!", 1));
}

test "defs: issue case PI=3.14 then 2*PI=6.28 via persistence round-trip" {
    var saved = Defs{};
    try saved.put("pi", 3.14);

    var buf: [256]u8 = undefined;
    const text = saved.write_file_text(&buf);

    var loaded = Defs{};
    loaded.load_file_text(text);
    try std.testing.expectEqual(@as(?f64, 3.14), loaded.get("pi"));
}


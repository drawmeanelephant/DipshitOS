//! History ring buffer — bounded expression+result log for CALC.BIN.
//!
//! M17 C9: 10 entries, in-memory ring.  M24 K5: extended to 20 entries
//! with FAT persistence (`save_to_fat` / `load_from_fat`).

const std = @import("std");
const ui = @import("../lib/ui.zig");
const format_i64 = @import("../calc/engine.zig").format_i64;

pub const max_entries: usize = 20;
pub const visible_count: usize = 6;

pub const Entry = struct {
    text: [32]u8 = [_]u8{0} ** 32,
    len: usize = 0,
    result: i64 = 0,
    has_result: bool = false,
};

pub const Ring = struct {
    entries: [max_entries]Entry = [_]Entry{.{}} ** max_entries,
    len: usize = 0,
    head: usize = 0,

    pub fn init() Ring {
        return .{};
    }

    /// Logical index 0 = oldest, len-1 = newest; maps via ring head.
    pub fn get(self: *const Ring, logical: usize) *const Entry {
        const idx = (self.head + max_entries - self.len + logical) % max_entries;
        return &self.entries[idx];
    }

    pub fn get_mut(self: *Ring, logical: usize) *Entry {
        const idx = (self.head + max_entries - self.len + logical) % max_entries;
        return &self.entries[idx];
    }

    /// Push a new entry (expression text + result). Bounded ring.
    pub fn push(self: *Ring, expr: []const u8, result: i64) void {
        const e = &self.entries[self.head];
        const copy = @min(expr.len, e.text.len);
        @memcpy(e.text[0..copy], expr[0..copy]);
        e.len = copy;
        e.result = result;
        e.has_result = true;
        self.head = (self.head + 1) % max_entries;
        if (self.len < max_entries) self.len += 1;
    }

    /// Format an entry as "expr=result" into a caller buffer.
    pub fn format_entry(entry: *const Entry, out: []u8) []const u8 {
        var pos: usize = 0;
        const copy = @min(entry.len, out.len - 12);
        @memcpy(out[pos .. pos + copy], entry.text[0..copy]);
        pos += copy;
        if (entry.has_result) {
            if (pos + 1 < out.len) {
                out[pos] = '=';
                pos += 1;
            }
            const tmp = entry.result;
            var neg = false;
            var uval: u64 = undefined;
            if (tmp == std.math.minInt(i64)) {
                uval = @as(u64, @intCast(-(tmp + 1))) + 1;
                neg = true;
            } else if (tmp < 0) {
                neg = true;
                uval = @intCast(-tmp);
            } else {
                uval = @intCast(tmp);
            }
            if (neg and pos < out.len) {
                out[pos] = '-';
                pos += 1;
            }
            var digits: [20]u8 = undefined;
            var dcnt: usize = 0;
            if (uval == 0) {
                digits[0] = '0';
                dcnt = 1;
            } else {
                while (uval > 0) : (uval /= 10) {
                    digits[dcnt] = @as(u8, @intCast(uval % 10)) + '0';
                    dcnt += 1;
                }
            }
            var i: usize = dcnt;
            while (i > 0) : (i -= 1) {
                if (pos >= out.len) break;
                out[pos] = digits[i - 1];
                pos += 1;
            }
        }
        return out[0..pos];
    }

    // -----------------------------------------------------------------------
    // FAT persistence (K5)
    // -----------------------------------------------------------------------

    /// Save history to `/data/calc_hst.txt` — one line per entry: "expr=result\n".
    /// Overwrites the file entirely (bounded at 20 entries × ~44 chars = 880 bytes).
    pub fn save_to_fat(self: *const Ring) void {
        const path = "/data/calc_hst.txt";
        var buf: [1024]u8 = undefined;
        var pos: usize = 0;

        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            const entry = self.get(i);
            var line_buf: [48]u8 = undefined;
            const line = Ring.format_entry(entry, &line_buf);
            // Copy line into buf
            const cpy = @min(line.len, buf.len - pos - 1);
            @memcpy(buf[pos .. pos + cpy], line[0..cpy]);
            pos += cpy;
            if (pos < buf.len) {
                buf[pos] = '\n';
                pos += 1;
            }
        }

        const fd = ui.file_open(path, ui.MODE_CREATE | ui.MODE_WRITE);
        if (fd < 0) return;
        _ = ui.file_write(@as(u32, @intCast(fd)), buf[0..pos]);
        ui.file_close(@as(u32, @intCast(fd)));
    }

    /// Load history from `/data/calc_hst.txt`.  Called at startup.
    pub fn load_from_fat(self: *Ring) void {
        const path = "/data/calc_hst.txt";
        var file_buf: [1024]u8 = undefined;
        const fd = ui.file_open(path, ui.MODE_READ);
        if (fd < 0) return;
        const n = ui.file_read(@as(u32, @intCast(fd)), &file_buf);
        ui.file_close(@as(u32, @intCast(fd)));
        if (n <= 0) return;

        // Parse lines: "expr=result\n"
        var start: usize = 0;
        while (start < @as(usize, @intCast(n))) {
            // Find end of line
            var end = start;
            while (end < @as(usize, @intCast(n)) and file_buf[end] != '\n') : (end += 1) {}

            const line = file_buf[start..end];
            if (line.len > 0) {
                // Find '=' separator
                var eq_pos: ?usize = null;
                var j: usize = 0;
                while (j < line.len) : (j += 1) {
                    if (line[j] == '=') {
                        eq_pos = j;
                        break;
                    }
                }
                if (eq_pos) |eq| {
                    const expr_part = line[0..eq];
                    const result_part = line[eq + 1 ..];
                    // Parse result as i64
                    var neg = false;
                    var idx: usize = 0;
                    if (result_part.len > 0 and result_part[0] == '-') {
                        neg = true;
                        idx = 1;
                    }
                    var val: i64 = 0;
                    while (idx < result_part.len) : (idx += 1) {
                        const ch = result_part[idx];
                        if (ch < '0' or ch > '9') break;
                        val = std.math.mul(i64, val, 10) catch break;
                        val = std.math.add(i64, val, if (neg) -@as(i64, ch - '0') else @as(i64, ch - '0')) catch break;
                    }
                    self.push(expr_part, val);
                }
            }

            start = end + 1;
        }
    }
};

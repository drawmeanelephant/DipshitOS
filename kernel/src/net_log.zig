//! DipshitOS kernel network event log ring buffer (M26 N15 — issue #442).
//!
//! Maintains a bounded in-memory ring buffer (128 entries) of network events:
//! - DHCP state transitions (discover, offer, request, bound, renew, expired)
//! - TCP connections (connect, established, closed, reset, error)
//! - ARP resolutions (request, resolved, conflict)
//! - Link state changes & packet anomalies

const std = @import("std");

pub const max_entries: usize = 128;
pub const max_text_len: usize = 48;

pub const LogEntry = struct {
    timestamp: u64,
    text: [max_text_len]u8,
    text_len: u8,

    pub fn getText(self: *const LogEntry) []const u8 {
        return self.text[0..self.text_len];
    }
};

pub var entries: [max_entries]LogEntry = undefined;
pub var head: usize = 0;
pub var total_logged: u64 = 0;
pub var initialized: bool = false;

pub fn init() void {
    head = 0;
    total_logged = 0;
    initialized = true;
}

pub fn log(msg: []const u8) void {
    const len: u8 = @intCast(@min(msg.len, max_text_len));
    var entry = LogEntry{
        .timestamp = total_logged,
        .text = undefined,
        .text_len = len,
    };
    @memcpy(entry.text[0..len], msg[0..len]);

    entries[head] = entry;
    head = (head + 1) % max_entries;
    total_logged += 1;
}

/// Truncating formatted log: overlong events are cut at max_text_len.
/// Formatted into an oversized staging buffer, then clamped — a bare
/// `catch buf[0..]` around a same-sized bufPrint would log uninitialized
/// tail bytes.
pub fn log_fmt(comptime fmt: []const u8, args: anytype) void {
    var big: [512]u8 = undefined;
    const full = std.fmt.bufPrint(&big, fmt, args) catch big[0..big.len];
    const len = @min(full.len, max_text_len);
    log(full[0..len]);
}

pub fn get_count() usize {
    if (total_logged < max_entries) {
        return @intCast(total_logged);
    }
    return max_entries;
}

/// Retrieve the i-th oldest logged entry in current window (0 <= i < get_count())
pub fn get_entry(i: usize) ?LogEntry {
    const cnt = get_count();
    if (i >= cnt) return null;
    const start = if (total_logged >= max_entries) head else 0;
    const idx = (start + i) % max_entries;
    return entries[idx];
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "net_log: append and retrieve" {
    init();
    try std.testing.expectEqual(@as(usize, 0), get_count());

    log("DHCP: DISCOVER sent");
    log("DHCP: OFFER received from 10.0.0.2");
    log("DHCP: BOUND ip=10.0.0.1 gw=10.0.0.2");

    try std.testing.expectEqual(@as(usize, 3), get_count());

    const e0 = get_entry(0).?;
    try std.testing.expectEqualStrings("DHCP: DISCOVER sent", e0.getText());

    const e2 = get_entry(2).?;
    try std.testing.expectEqualStrings("DHCP: BOUND ip=10.0.0.1 gw=10.0.0.2", e2.getText());
}

test "net_log: ring buffer wrap around" {
    init();
    var i: usize = 0;
    while (i < 130) : (i += 1) {
        log_fmt("event {d}", .{i});
    }

    try std.testing.expectEqual(@as(usize, max_entries), get_count());
    const first = get_entry(0).?;
    try std.testing.expectEqualStrings("event 2", first.getText());
    const last = get_entry(max_entries - 1).?;
    try std.testing.expectEqualStrings("event 129", last.getText());
}

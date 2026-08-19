//! DipshitOS milestone-fourteen (card S1, claim 2611): the shared text
//! clipboard.
//!
//! ONE bounded, kernel-global clipboard buffer — pure BSS, zero heap, no
//! allocation, no per-process ownership. This is a SHARED user service:
//! any process may read what any other process wrote (a clipboard's whole
//! point), and the EL1h monitor/terminal can reach the same buffer. The
//! syscall layer owns validation and the uaccess copies; this module is
//! pure storage (the `mailbox.zig` pattern) and knows nothing about tasks
//! or scheduling.
//!
//! `set` truncates to `clip_max` (documented — the syscall returns the
//! stored length so a caller can see the truncation); `clear` empties it;
//! `contents` returns the stored slice; `length` reports the stored size.
//! A zero-length `set` is a clear.

const std = @import("std");

/// The bounded clipboard capacity. 512 bytes matches NOTEPAD's own text
/// buffer, so a whole-document copy never truncates, while staying fixed
/// BSS (no allocation).
pub const clip_max: usize = 512;

var data: [clip_max]u8 = [_]u8{0} ** clip_max;
var len: usize = 0;

/// Reset the clipboard (boot + host tests).
pub fn init() void {
    len = 0;
}

/// Store `bytes` (truncated to `clip_max`). A zero-length slice clears.
pub fn set(bytes: []const u8) void {
    const n = @min(bytes.len, clip_max);
    if (n > 0) @memcpy(data[0..n], bytes[0..n]);
    len = n;
}

/// Empty the clipboard.
pub fn clear() void {
    len = 0;
}

/// The stored bytes (empty when nothing is held). The slice stays valid
/// until the next `set`/`clear`/`init` (a command's snapshot use).
pub fn contents() []const u8 {
    return data[0..len];
}

/// The stored byte count.
pub fn length() usize {
    return len;
}

// ---------------------------------------------------------------------------
// Tests (host-side; the live cross-process flow is proven on VZ by
// tools/verify-live-clipboard.sh, class B)
// ---------------------------------------------------------------------------

test "clipboard: set/get round-trips bytes and reports length" {
    init();
    try std.testing.expectEqual(@as(usize, 0), length());
    set("hello");
    try std.testing.expectEqual(@as(usize, 5), length());
    try std.testing.expectEqualStrings("hello", contents());
}

test "clipboard: set truncates at clip_max and empty set clears" {
    init();
    set("x" ** clip_max);
    try std.testing.expectEqual(@as(usize, clip_max), length());
    // One more byte than the bound: the stored copy stops at clip_max.
    set("y" ** (clip_max + 1));
    try std.testing.expectEqual(@as(usize, clip_max), length());
    try std.testing.expectEqualStrings("y" ** clip_max, contents());
    // Zero-length set clears.
    set("");
    try std.testing.expectEqual(@as(usize, 0), length());
    try std.testing.expectEqualStrings("", contents());
}

test "clipboard: clear and init empty the buffer" {
    init();
    set("abc");
    clear();
    try std.testing.expectEqual(@as(usize, 0), length());
    set("def");
    init();
    try std.testing.expectEqual(@as(usize, 0), length());
}

test "clipboard: overwriting replaces, never appends" {
    init();
    set("first");
    set("second");
    try std.testing.expectEqualStrings("second", contents());
    try std.testing.expectEqual(@as(usize, 6), length());
}

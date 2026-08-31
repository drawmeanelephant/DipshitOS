//! VirelaiOS crash tombstone engine (Arc5 issue #243).
//!
//! Writes crash information to `/data/crash/<pid>-<name>.txt` when a process
//! exits with status 139 (guard page fault) or other non-zero unexpected
//! exits. Bounded: max 8 tombstones, drop-oldest on overflow.
//!
//! Tombstone contents:
//!   - Process name, PID, exit status
//!   - Fault address (if status 139)
//!   - Last 512 bytes of serial output (from the console ring buffer)
//!   - Timestamp (tick count)
//!
//! No libc, no POSIX, bounded BSS storage, no heap allocation.

const std = @import("std");
const symbol = @import("symbol.zig");
const fat = @import("fat.zig");
const esp = @import("esp.zig");
const timer = @import("timer.zig");
const console = @import("console.zig");

/// Maximum number of tombstones to keep (drop-oldest on overflow).
pub const max_tombstones: usize = 8;

/// Directory for crash tombstones on the DATA partition.
pub const crash_dir = "/data/crash";

/// Maximum size of a tombstone file content.
pub const tombstone_max_bytes: usize = 1024;

/// A single tombstone record.
pub const Tombstone = struct {
    pid: u64,
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: usize = 0,
    exit_status: u64,
    fault_addr: u64 = 0,
    /// Faulting PC (ELR) — the code address used for symbol resolution.
    pc: u64 = 0,
    tick: u64,
    serial_snapshot: [512]u8 = [_]u8{0} ** 512,
    serial_len: usize = 0,
    /// "(in name+0xoffset)" note resolved via the kernel symbol table
    /// (M22 D3, issue #326). Empty when nothing matched.
    sym_note: [96]u8 = [_]u8{0} ** 96,
    sym_note_len: usize = 0,
};

/// Ring buffer of tombstones (drop-oldest on overflow).
var tombstones: [max_tombstones]Tombstone = undefined;
var tombstone_head: usize = 0;
var tombstone_count: usize = 0;

/// Initialize the tombstone subsystem.
pub fn init() void {
    tombstone_head = 0;
    tombstone_count = 0;
}

/// Record a tombstone for a crashed process.
/// `name` is the process name (e.g. "GUARD.BIN").
/// `pid` is the process ID.
/// `status` is the exit status (139 for guard page fault).
/// `fault_addr` is the fault address (only meaningful for status 139).
/// `serial_snapshot` is the last 512 bytes of serial output.
/// `serial_len` is the actual length of the snapshot.
pub fn record(
    name: []const u8,
    pid: u64,
    status: u64,
    fault_addr: u64,
    pc: u64,
    serial_snapshot: []const u8,
    serial_len: usize,
) void {
    // Drop oldest if full
    if (tombstone_count == max_tombstones) {
        tombstone_head = (tombstone_head + 1) % max_tombstones;
        tombstone_count -= 1;
    }

    const idx = (tombstone_head + tombstone_count) % max_tombstones;
    var t = &tombstones[idx];
    t.* = .{
        .pid = pid,
        .exit_status = status,
        .fault_addr = fault_addr,
        .pc = pc,
        .tick = timer.ticks,
    };

    // M22 D3 (issue #326): name the faulting code. The PC anchors CODE
    // symbols (BRK faults carry far=0); fall back to the fault address for
    // data aborts whose PC sits outside every known range.
    if (status == 139) { // reserved_fault_status (kept literal: scheduler owns the name)
        const m = if (pc != 0) symbol.lookup(pc) else null;
        const chosen = m orelse symbol.lookup(fault_addr);
        if (chosen) |hit| {
            const note = "(in ";
            @memcpy(t.sym_note[0..note.len], note);
            var npos = note.len;
            const take_name = @min(hit.name.len, t.sym_note.len - npos - 24);
            @memcpy(t.sym_note[npos..][0..take_name], hit.name[0..take_name]);
            npos += take_name;
            const mid = "+0x";
            @memcpy(t.sym_note[npos..][0..mid.len], mid);
            npos += mid.len;
            npos += write_hex(t.sym_note[npos..], hit.offset);
            if (npos < t.sym_note.len) {
                t.sym_note[npos] = ')';
                npos += 1;
            }
            t.sym_note_len = npos;
        }
    }

    // Copy name (truncate to 31 chars + NUL)
    const name_len = @min(name.len, 31);
    @memcpy(t.name[0..name_len], name[0..name_len]);
    t.name_len = name_len;

    // Copy serial snapshot
    const snap_len = @min(serial_snapshot.len, serial_len, 512);
    @memcpy(t.serial_snapshot[0..snap_len], serial_snapshot[0..snap_len]);
    t.serial_len = snap_len;

    tombstone_count += 1;
}

/// Get the number of recorded tombstones.
pub fn count() usize {
    return tombstone_count;
}

/// Get a tombstone by index (0 = oldest).
pub fn get(index: usize) ?*const Tombstone {
    if (index >= tombstone_count) return null;
    const actual_idx = (tombstone_head + index) % max_tombstones;
    return &tombstones[actual_idx];
}

/// Format a tombstone into a buffer for writing to disk.
/// Returns the number of bytes written.
pub fn format_tombstone(t: *const Tombstone, out: []u8) usize {
    var pos: usize = 0;

    // Header
    const header = "VirelaiOS Crash Tombstone\n========================\n";
    if (header.len <= out.len) {
        @memcpy(out[0..header.len], header);
        pos = header.len;
    }

    // Process info
    pos += write_line(out[pos..], "Process: ");
    pos += write_bytes(out[pos..], t.name[0..t.name_len]);
    pos += write_line(out[pos..], "\n");

    pos += write_line(out[pos..], "PID: ");
    pos += write_u64(out[pos..], t.pid);
    pos += write_line(out[pos..], "\n");

    pos += write_line(out[pos..], "Exit Status: ");
    pos += write_u64(out[pos..], t.exit_status);
    pos += write_line(out[pos..], "\n");

    if (t.exit_status == 139) {
        pos += write_line(out[pos..], "Fault Address: 0x");
        pos += write_hex(out[pos..], t.fault_addr);
        pos += write_line(out[pos..], "\n");
    }

    pos += write_line(out[pos..], "Tick: ");
    pos += write_u64(out[pos..], t.tick);
    pos += write_line(out[pos..], "\n");

    if (t.sym_note_len > 0) {
        pos += write_line(out[pos..], "Symbol: ");
        pos += write_bytes(out[pos..], t.sym_note[0..t.sym_note_len]);
        pos += write_line(out[pos..], "\n");
    }

    // Serial snapshot
    if (t.serial_len > 0) {
        pos += write_line(out[pos..], "\n--- Last Serial Output ---\n");
        const snap = t.serial_snapshot[0..t.serial_len];
        for (snap) |c| {
            if (pos < out.len) {
                out[pos] = c;
                pos += 1;
            }
        }
        pos += write_line(out[pos..], "\n--- End Serial Output ---\n");
    }

    return pos;
}

/// Write a tombstone to the DATA partition.
/// Returns true on success.
pub fn write_to_disk(t: *const Tombstone, ops: ?fat.DiskOps) bool {
    if (ops == null) return false;

    // Mount DATA partition
    if (fat.mount_data(ops) != .ok) return false;

    // Format filename: /data/crash/<pid>-<name>.txt
    var filename_buf: [64]u8 = undefined;
    var pos: usize = 0;

    // /data/crash/
    const prefix = "/data/crash/";
    @memcpy(filename_buf[0..prefix.len], prefix);
    pos = prefix.len;

    // PID
    pos += write_u64(filename_buf[pos..], t.pid);

    // -
    if (pos < filename_buf.len) {
        filename_buf[pos] = '-';
        pos += 1;
    }

    // Name
    for (t.name[0..t.name_len]) |c| {
        if (pos < filename_buf.len and c != 0) {
            filename_buf[pos] = c;
            pos += 1;
        }
    }

    // .txt
    const suffix = ".txt";
    if (pos + suffix.len <= filename_buf.len) {
        @memcpy(filename_buf[pos..][0..suffix.len], suffix);
        pos += suffix.len;
    }

    const filename = filename_buf[0..pos];

    // Format tombstone content
    var content_buf: [tombstone_max_bytes]u8 = undefined;
    const content_len = format_tombstone(t, &content_buf);

    // Write file
    const result = fat.write_file(filename, content_buf[0..content_len]);

    // Restore ESP window
    _ = esp.set_disk(ops);

    return result == .ok;
}

/// List tombstone filenames for the crash monitor command.
/// Returns the number of tombstones listed.
pub fn list_to_console(con: console.Console) usize {
    var listed: usize = 0;
    var i: usize = 0;
    while (i < tombstone_count) : (i += 1) {
        if (get(i)) |t| {
            // Print: <index>: PID=<pid> <name> status=<status> tick=<tick>
            con.puts("  ");
            con.print_u64(i);
            con.puts(": PID=");
            con.print_u64(t.pid);
            con.puts(" ");
            con.puts(t.name[0..t.name_len]);
            con.puts(" status=");
            con.print_u64(t.exit_status);
            con.puts(" tick=");
            con.print_u64(t.tick);
            if (t.sym_note_len > 0) {
                con.puts(" ");
                con.puts(t.sym_note[0..t.sym_note_len]);
            }
            con.puts("\n");
            listed += 1;
        }
    }
    return listed;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn write_line(out: []u8, s: []const u8) usize {
    const len = @min(s.len, out.len);
    @memcpy(out[0..len], s[0..len]);
    return len;
}

fn write_bytes(out: []u8, s: []const u8) usize {
    const len = @min(s.len, out.len);
    @memcpy(out[0..len], s[0..len]);
    return len;
}

fn write_u64(out: []u8, val: u64) usize {
    if (val == 0) {
        if (out.len > 0) out[0] = '0';
        return 1;
    }
    var buf: [20]u8 = undefined;
    var v = val;
    var len: usize = 0;
    while (v > 0) : (len += 1) {
        buf[len] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
    // Reverse and copy
    var i: usize = 0;
    while (i < len and i < out.len) : (i += 1) {
        out[i] = buf[len - 1 - i];
    }
    return @min(len, out.len);
}

fn write_hex(out: []u8, val: u64) usize {
    const hex_chars = "0123456789abcdef";
    if (val == 0) {
        if (out.len > 0) out[0] = '0';
        return 1;
    }
    var buf: [16]u8 = undefined;
    var v = val;
    var len: usize = 0;
    while (v > 0) : (len += 1) {
        buf[len] = hex_chars[v & 0xf];
        v >>= 4;
    }
    // Reverse and copy
    var i: usize = 0;
    while (i < len and i < out.len) : (i += 1) {
        out[i] = buf[len - 1 - i];
    }
    return @min(len, out.len);
}

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------

test "tombstone: record and retrieve" {
    init();
    try std.testing.expectEqual(@as(usize, 0), count());

    record("TEST.BIN", 1, 139, 0x12345, 0, "", 0);
    try std.testing.expectEqual(@as(usize, 1), count());

    const t = get(0).?;
    try std.testing.expectEqual(@as(u64, 1), t.pid);
    try std.testing.expectEqual(@as(u64, 139), t.exit_status);
    try std.testing.expectEqual(@as(u64, 0x12345), t.fault_addr);
    try std.testing.expectEqualStrings("TEST.BIN", t.name[0..t.name_len]);
}

test "tombstone: drop-oldest overflow" {
    init();
    for (0..9) |i| {
        const name = [_]u8{ 'A', @as(u8, '0' + @as(u8, @intCast(i % 10))) };
        record(&name, i, 1, 0, 0, "", 0);
    }
    // Should have max_tombstones (8), oldest (PID 0) dropped
    try std.testing.expectEqual(@as(usize, max_tombstones), count());
    const oldest = get(0).?;
    try std.testing.expectEqual(@as(u64, 1), oldest.pid); // PID 0 was dropped
}

test "tombstone: format includes header" {
    init();
    record("CRASH.BIN", 42, 139, 0xDEAD, 0x400010, "hello", 5);

    var buf: [tombstone_max_bytes]u8 = undefined;
    const len = format_tombstone(get(0).?, &buf);

    try std.testing.expect(len > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "VirelaiOS Crash Tombstone") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "CRASH.BIN") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "PID: 42") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "Exit Status: 139") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "Fault Address: 0x") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..len], "hello") != null);
}

test "tombstone: crash inside a known symbol carries the note" {
    init();
    const sym = @import("symbol.zig");
    sym.reset();
    _ = sym.add("crasher", 0x40000c, 20);

    // BRK-style fault: far=0 but PC lands inside "crasher".
    record("CRASH.ELF", 3, 139, 0, 0x400010, "", 0);
    const t = get(0).?;
    try std.testing.expect(t.sym_note_len > 0);
    try std.testing.expectEqualStrings("(in crasher+0x4)", t.sym_note[0..t.sym_note_len]);

    // The note flows into the formatted report.
    var buf: [tombstone_max_bytes]u8 = undefined;
    const len = format_tombstone(get(0).?, &buf);
    const report = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, report, "(in crasher+0x4)") != null);

    // Data-abort style: pc outside any range falls back to fault_addr.
    sym.reset();
    _ = sym.add("guard_zone", 0x500000, 64);
    record("GUARD.BIN", 4, 139, 0x500010, 0x400abc, "", 0);
    const t2 = get(count() - 1).?;
    try std.testing.expectEqualStrings("(in guard_zone+0x10)", t2.sym_note[0..t2.sym_note_len]);
}

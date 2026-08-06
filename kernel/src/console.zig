//! Dipshit Monitor console abstraction (Milestone 1.5, commands & personality).
//!
//! A tiny, transport-agnostic console interface. The command layer never
//! knows whether bytes eventually reach a PL011, a 16550, a virtio-console,
//! or a host-side test mock: it only holds a `Console` value with a
//! function-pointer vtable and an opaque context pointer.
//!
//! Kernel wiring: the later Console & Shell Core stream supplies an adapter
//! over the milestone-two polled TX `uart_*` console (ADR 0004 D4).
//! Host tests: `MockConsole` captures output into a bounded buffer.
//!
//! No libc, no POSIX, no allocation, no dynamic registration, no global
//! mutable state. All formatting is byte-streamed so output stays bounded.

const std = @import("std");

/// Value-type console handle: `ctx` plus a stateless function-pointer vtable.
/// Every method below degrades to `write`, so a transport only has to
/// provide one function (plus a no-op-friendly `flush`).
pub const Console = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Append `bytes` to the console. A bounded transport drops the tail
        /// (and may flag overflow) rather than blocking forever.
        write: *const fn (ctx: *anyopaque, bytes: []const u8) void,
        /// Push any buffered output; a no-op for polled byte-at-a-time TX.
        flush: *const fn (ctx: *anyopaque) void,
    };

    pub fn write(self: Console, bytes: []const u8) void {
        self.vtable.write(self.ctx, bytes);
    }

    pub fn putc(self: Console, byte: u8) void {
        const one = [1]u8{byte};
        self.write(&one);
    }

    pub fn puts(self: Console, text: []const u8) void {
        self.write(text);
    }

    pub fn print_line(self: Console, text: []const u8) void {
        self.write(text);
        self.write("\n");
    }

    pub fn flush(self: Console) void {
        self.vtable.flush(self.ctx);
    }

    /// "0x" followed by exactly 16 lowercase hex digits. This matches the
    /// milestone-two kernel's own `uart_hex` format (kernel/src/main.zig),
    /// so monitor output and kernel probe output stay visually consistent.
    pub fn print_hex(self: Console, value: u64) void {
        self.write("0x");
        var shift: u6 = 60;
        while (true) : (shift -= 4) {
            const digit: u8 = @intCast((value >> shift) & 0xf);
            self.putc(if (digit < 10) '0' + digit else 'a' + digit - 10);
            if (shift == 0) break;
        }
    }

    /// "0x" followed by minimal lowercase hex digits ("0x0" for zero).
    /// Used by the `hex` shell utility for human-readable output.
    pub fn print_hex_min(self: Console, value: u64) void {
        self.write("0x");
        var started = false;
        var shift: u6 = 60;
        while (true) : (shift -= 4) {
            const digit: u8 = @intCast((value >> shift) & 0xf);
            if (digit != 0 or started or shift == 0) {
                self.putc(if (digit < 10) '0' + digit else 'a' + digit - 10);
                started = true;
            }
            if (shift == 0) break;
        }
    }

    /// Decimal digits with no leading zeros ("0" for zero).
    pub fn print_u64(self: Console, value: u64) void {
        var buffer: [20]u8 = undefined;
        var index: usize = buffer.len;
        var v = value;
        if (v == 0) {
            self.putc('0');
            return;
        }
        while (v != 0) : (v /= 10) {
            index -= 1;
            buffer[index] = '0' + @as(u8, @intCast(v % 10));
        }
        self.write(buffer[index..]);
    }
};

/// Bounded capture console for host-side tests.
/// `MockConsole(4096)` captures into a fixed 4096-byte buffer. Writes that
/// do not fit are truncated at the buffer boundary and set `overflowed`;
/// they never wrap, block, or crash. This is also how the monitor's
/// output-budget behavior is exercised without a real serial device.
pub fn MockConsole(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        pub const vtable = Console.VTable{
            .write = writeFn,
            .flush = flushFn,
        };

        buffer: [capacity]u8 = undefined,
        len: usize = 0,
        overflowed: bool = false,
        flush_count: usize = 0,

        pub fn console(self: *Self) Console {
            return .{ .ctx = self, .vtable = &vtable };
        }

        /// Captured bytes in write order (possibly truncated at overflow).
        pub fn contents(self: *const Self) []const u8 {
            return self.buffer[0..self.len];
        }

        pub fn reset(self: *Self) void {
            self.len = 0;
            self.overflowed = false;
            self.flush_count = 0;
        }

        fn writeFn(ctx: *anyopaque, bytes: []const u8) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const available = capacity - self.len;
            if (available == 0) {
                self.overflowed = true;
                return;
            }
            const n = @min(bytes.len, available);
            @memcpy(self.buffer[self.len..][0..n], bytes[0..n]);
            self.len += n;
            if (n < bytes.len) self.overflowed = true;
        }

        fn flushFn(ctx: *anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            self.flush_count += 1;
        }
    };
}

test "console: mock captures writes in order" {
    var mock = MockConsole(64){};
    const con = mock.console();
    con.puts("ab");
    con.putc('c');
    con.print_line("de");
    try std.testing.expectEqualStrings("abcde\n", mock.contents());
    try std.testing.expect(!mock.overflowed);
}

test "console: reset clears capture and flags" {
    var mock = MockConsole(64){};
    mock.console().putc('x');
    mock.console().flush();
    try std.testing.expectEqualStrings("x", mock.contents());
    try std.testing.expectEqual(@as(usize, 1), mock.flush_count);
    mock.reset();
    try std.testing.expectEqualStrings("", mock.contents());
    try std.testing.expectEqual(@as(usize, 0), mock.flush_count);
    try std.testing.expect(!mock.overflowed);
}

test "console: overflow truncates, flags, and never wraps" {
    var mock = MockConsole(8){};
    mock.console().puts("hello world"); // 11 bytes into 8
    try std.testing.expectEqualStrings("hello wo", mock.contents());
    try std.testing.expect(mock.overflowed);
    mock.console().puts("more"); // dropped: buffer is full
    try std.testing.expectEqualStrings("hello wo", mock.contents());
    try std.testing.expect(mock.overflowed);
    mock.reset();
    try std.testing.expect(!mock.overflowed);
    try std.testing.expectEqualStrings("", mock.contents());
}

test "console: zero-capacity mock flags every write" {
    var mock = MockConsole(0){};
    mock.console().puts("x");
    try std.testing.expect(mock.overflowed);
}

test "console: print_hex prints fixed 16 lowercase digits" {
    var mock = MockConsole(64){};
    mock.console().print_hex(0x324b5344);
    try std.testing.expectEqualStrings("0x00000000324b5344", mock.contents());
    mock.reset();
    mock.console().print_hex(0);
    try std.testing.expectEqualStrings("0x0000000000000000", mock.contents());
    mock.reset();
    mock.console().print_hex(std.math.maxInt(u64));
    try std.testing.expectEqualStrings("0xffffffffffffffff", mock.contents());
}

test "console: print_hex_min prints minimal lowercase hex" {
    var mock = MockConsole(64){};
    mock.console().print_hex_min(0);
    try std.testing.expectEqualStrings("0x0", mock.contents());
    mock.reset();
    mock.console().print_hex_min(0xff);
    try std.testing.expectEqualStrings("0xff", mock.contents());
    mock.reset();
    mock.console().print_hex_min(0x324b5344);
    try std.testing.expectEqualStrings("0x324b5344", mock.contents());
    mock.reset();
    mock.console().print_hex_min(std.math.maxInt(u64));
    try std.testing.expectEqualStrings("0xffffffffffffffff", mock.contents());
}

test "console: print_u64 prints decimal without leading zeros" {
    var mock = MockConsole(64){};
    mock.console().print_u64(0);
    try std.testing.expectEqualStrings("0", mock.contents());
    mock.reset();
    mock.console().print_u64(1);
    try std.testing.expectEqualStrings("1", mock.contents());
    mock.reset();
    mock.console().print_u64(42);
    try std.testing.expectEqualStrings("42", mock.contents());
    mock.reset();
    mock.console().print_u64(123456789);
    try std.testing.expectEqualStrings("123456789", mock.contents());
    mock.reset();
    mock.console().print_u64(std.math.maxInt(u64));
    try std.testing.expectEqualStrings("18446744073709551615", mock.contents());
}

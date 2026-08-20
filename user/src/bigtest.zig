//! DipshitOS M16 C1 big image proof — BIGTEST.BIN (claim 3900).
//!
//! Headless class-B proof for the multi-segment DSK2 image: a program larger
//! than 16 KiB that uses writable globals and zeroed BSS. It prints markers
//! so the live gate can grep them, proves global RW and BSS zero, and exits.

const ui = @import("lib/ui.zig");

// Large rodata to make image >16 KiB (RX segment, filesz)
// Use `export` and volatile access to prevent dead-strip.
// Zig ReleaseSmall may otherwise constant-fold the array away.
export var large_ro: [20000]u8 = [_]u8{0xAB} ** 20000;

// Writable data — small but must be RW
export var large_data: [2000]u8 = [_]u8{0xCD} ** 2000;

// Also a scalar global to test RW
var global_counter: u64 = 0x12345678;

// BSS — 4 KiB zeroed (memsz > filesz tail is zero)
var bss_buf: [4096]u8 = [_]u8{0} ** 4096;

fn write_str(s: []const u8) void {
    ui.write_console(s);
}

fn append_str(buf: []u8, pos: usize, s: []const u8) usize {
    @memcpy(buf[pos..][0..s.len], s);
    return pos + s.len;
}

fn fmt_u64(buf: []u8, v: u64) []const u8 {
    var val = v;
    var i: usize = buf.len;
    if (val == 0) {
        i -= 1;
        buf[i] = '0';
        return buf[i..];
    }
    while (val > 0) : (val /= 10) {
        i -= 1;
        buf[i] = @intCast('0' + (val % 10));
    }
    return buf[i..];
}

pub export fn _start() callconv(.c) noreturn {
    // Touch large_ro via volatile + checksum loop to force retention
    var sum: usize = 0;
    var ri: usize = 0;
    while (ri < large_ro.len) : (ri += 1) {
        sum += @as(*volatile u8, @ptrCast(&large_ro[ri])).*;
    }
    if (sum == 0) write_str("bigtest: ro sum zero?!\n");
    write_str("bigtest: start\n");

    // Prove BSS is zeroed
    var bss_ok: bool = true;
    var idx: usize = 0;
    while (idx < bss_buf.len) : (idx += 1) {
        if (bss_buf[idx] != 0) {
            bss_ok = false;
            break;
        }
    }
    if (bss_ok) {
        write_str("bigtest: bss zero ok\n");
    } else {
        write_str("bigtest: bss zero FAIL\n");
        ui.exit_process(1);
    }

    // Prove global writable
    if (global_counter != 0x12345678) {
        write_str("bigtest: global init FAIL\n");
        ui.exit_process(2);
    }
    global_counter += 1;
    if (global_counter != 0x12345679) {
        write_str("bigtest: global write FAIL\n");
        ui.exit_process(3);
    }
    write_str("bigtest: global rw ok\n");

    // Prove large_data writable and initialized (full scan)
    var data_ok = true;
    ri = 0;
    while (ri < large_data.len) : (ri += 1) {
        if (@as(*volatile u8, @ptrCast(&large_data[ri])).* != 0xCD) {
            data_ok = false;
            break;
        }
    }
    if (!data_ok) {
        write_str("bigtest: large_data init FAIL\n");
        ui.exit_process(4);
    }
    @as(*volatile u8, @ptrCast(&large_data[0])).* = 0x42;
    @as(*volatile u8, @ptrCast(&large_data[1999])).* = 0x43;
    if (large_data[0] != 0x42 or large_data[1999] != 0x43) {
        write_str("bigtest: large_data write FAIL\n");
        ui.exit_process(5);
    }
    write_str("bigtest: large_data rw ok\n");

    // Prove large_ro readable (RX) via volatile loop
    var ro_ok = true;
    ri = 0;
    while (ri < large_ro.len) : (ri += 1) {
        if (@as(*volatile u8, @ptrCast(&large_ro[ri])).* != 0xAB) {
            ro_ok = false;
            break;
        }
    }
    if (!ro_ok) {
        write_str("bigtest: large_ro init FAIL\n");
        ui.exit_process(7);
    }
    write_str("bigtest: large_ro ok\n");

    // Prove BSS writable
    bss_buf[0] = 0x99;
    bss_buf[4095] = 0x88;
    if (bss_buf[0] != 0x99 or bss_buf[4095] != 0x88) {
        write_str("bigtest: bss write FAIL\n");
        ui.exit_process(6);
    }
    write_str("bigtest: bss write ok\n");

    // Prove we can write large_data via sys_write path (copy_in from data)
    var ibuf: [64]u8 = undefined;
    var pos: usize = 0;
    pos = append_str(&ibuf, pos, "bigtest: large_data[0]=");
    pos = append_str(&ibuf, pos, fmt_u64(ibuf[pos..], large_data[0]));
    ibuf[pos] = '\n';
    pos += 1;
    ui.write_console(ibuf[0..pos]);

    write_str("bigtest: done\n");
    ui.exit_process(42);
}

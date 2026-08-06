//! DipshitOS boot application (the loader).
//!
//! A minimal AArch64 UEFI application. It prints a fixed two-line message to
//! the UEFI Simple Text Output protocol (ConOut), writes the same two lines
//! to `\BOOTED.TXT` on the ESP (execution evidence -- Apple's VZ firmware
//! routes no console text anywhere visible), then -- milestone one -- loads
//! the separate kernel image `\KERNEL.BIN` from the ESP via the UEFI Simple
//! File System protocol, allocates memory with Boot Services
//! (AllocatePages, EfiLoaderCode so the pages are executable), copies the
//! image CONTENT there -- the 24-byte DSK1 header is parsed but NOT loaded
//! into RAM, so the kernel's content sits at base+0 where its PC-relative
//! addressing (ADR and ADRP) resolves correctly; see ADR 0002 -- flushes
//! the data cache and invalidates the instruction cache (the same
//! maintenance the firmware's LoadImage performs), and jumps to the
//! kernel's entry point. The kernel writes its own evidence
//! (`\KERNEL.TXT`) and returns; the loader then returns to the firmware
//! (EFI_SUCCESS). The loader also writes `\LOADER.TXT` (loader-observed
//! placement of the kernel) and `\MEMMAP.TXT` (the EFI memory map) as
//! host-observable evidence.
//!
//! Kernel image format v1 and the handoff ABI are documented in
//! docs/decisions/0002-kernel-handoff.md. Still pure UEFI services
//! throughout: no libc, no POSIX, no filesystem driver of our own.
//!
//! Zig 0.16.0 adjustment: older Zig examples exported `efi_main` with
//! `callconv(.win64)`. Zig 0.16's `std.start` for the `uefi` OS target
//! instead exports `EfiMain` (callconv(.c), which on AArch64 is AAPCS64) and
//! calls our `pub fn main() void`. It installs the firmware-provided EFI
//! System Table into `std.os.uefi.system_table` before main runs; that is
//! where we read ConOut and Boot Services from.

const std = @import("std");
const uefi = std.os.uefi;

/// Convert a comptime ASCII string into a null-terminated UTF-16LE array as
/// required by the EFI APIs. (All of our strings are pure ASCII.)
fn utf16z(comptime s: []const u8) [s.len + 1:0]u16 {
    var buf: [s.len + 1:0]u16 = undefined;
    for (s, 0..) |c, i| buf[i] = c;
    buf[s.len] = 0;
    return buf;
}

const line_banner = utf16z("DIPSHITOS BOOTLOADER\r\n");
const line_confirm = utf16z("firmware has agreed to cooperate\r\n");
const line_loading = utf16z("loading kernel from \\KERNEL.BIN\r\n");
const line_jumping = utf16z("jumping to kernel entry point\r\n");
const line_rc_ok = utf16z("kernel handoff complete (rc=0)\r\n");
const line_rc_bad = utf16z("kernel returned nonzero rc\r\n");
const marker_path = utf16z("\\BOOTED.TXT");
const marker_text = "DIPSHITOS BOOTLOADER\nfirmware has agreed to cooperate\n";
// Loader trace: where the kernel image landed, written before the jump. The
// kernel writes its own observed base into KERNEL.TXT; the two must match
// (cross-check of the handoff ABI).
const loader_trace_path = utf16z("\\LOADER.TXT");
// EFI memory map evidence (types and attributes of every region).
const memmap_path = utf16z("\\MEMMAP.TXT");
const rc_path = utf16z("\\RC.TXT");

// Kernel image format v1 (docs/decisions/0002-kernel-handoff.md):
//   u32 magic = 0x314B5344 ("DSK1"), u32 flags = 0,
//   u64 entry_offset (from image base), u64 image_size (total file size),
//   then loadable content.
const kernel_path = utf16z("\\KERNEL.BIN");
const kernel_magic: u32 = 0x314B5344;
const kernel_header_size: usize = 24;
const kernel_max_size: u64 = 16 * 1024 * 1024; // sanity cap for this milestone

pub fn main() void {
    const st = uefi.system_table;

    // 1. Primary action: print via the UEFI Simple Text Output protocol.
    if (st.con_out) |con_out| {
        _ = con_out.outputString(&line_banner) catch {};
        _ = con_out.outputString(&line_confirm) catch {};
    }

    // 2. Evidence: write the same message to \BOOTED.TXT on the ESP using
    //    the firmware's Simple File System protocol. Best effort only.
    write_marker(st);

    // 3. Milestone one: load \KERNEL.BIN and transfer control to it.
    load_and_enter_kernel(st);

    // Wait safely for a short while (a pure, memory-free busy loop) so any
    // text stays visible, then fall through and return to the firmware.
    wait_a_moment();
}

/// Locate the volume the firmware loaded us from, open \BOOTED.TXT and write
/// the confirmation text. Uses only UEFI Boot Services + File protocols.
/// Any failure is silently ignored: the app must run even if the firmware
/// provides no writable filesystem.
fn write_marker(st: *const uefi.tables.SystemTable) void {
    const boot_services = st.boot_services orelse return;

    const loaded_image = (boot_services.handleProtocol(uefi.protocol.LoadedImage, uefi.handle) catch null) orelse return;
    const device_handle = loaded_image.device_handle orelse return;

    const fs = (boot_services.handleProtocol(uefi.protocol.SimpleFileSystem, device_handle) catch null) orelse return;
    const root = fs.openVolume() catch return;
    defer root.close() catch {};

    const marker = root.open(&marker_path, .read_write_create, .{}) catch return;
    defer marker.close() catch {};

    _ = marker.write(marker_text) catch {};
    marker.flush() catch {};
}

/// Milestone one: read \KERNEL.BIN from the ESP, allocate pages with Boot
/// Services, copy the image there, make the instruction stream see it, and
/// jump to its entry point (handoff ABI: x0 = image base, x1 = image size,
/// x2 = System Table, x3 = open root directory; the kernel returns a u64
/// status). Best effort: if anything is missing or malformed, the loader
/// quietly returns to the firmware.
fn load_and_enter_kernel(st: *const uefi.tables.SystemTable) void {
    const boot_services = st.boot_services orelse return;

    // Evidence: dump the EFI memory map (types + attributes) to \MEMMAP.TXT.
    dump_memory_map(st);

    const loaded_image = (boot_services.handleProtocol(uefi.protocol.LoadedImage, uefi.handle) catch null) orelse return;
    const device_handle = loaded_image.device_handle orelse return;

    const fs = (boot_services.handleProtocol(uefi.protocol.SimpleFileSystem, device_handle) catch null) orelse return;
    const root = fs.openVolume() catch return;
    defer root.close() catch {};

    const kernel_file = root.open(&kernel_path, .read, .{}) catch return;
    defer kernel_file.close() catch {};

    // 1. Read the 24-byte format header from the start of the file.
    var header: [kernel_header_size]u8 = undefined;
    if (kernel_file.read(&header) catch return < kernel_header_size) return;

    const magic = std.mem.readInt(u32, header[0..4], .little);
    const entry_offset = std.mem.readInt(u64, header[8..16], .little);
    const image_size = std.mem.readInt(u64, header[16..24], .little);
    if (magic != kernel_magic) return;
    if (image_size < kernel_header_size or image_size > kernel_max_size) return;
    // The entry is file-relative (includes the header) and must land inside
    // the loadable content; anything else means a malformed image.
    if (entry_offset < kernel_header_size) return;
    if (entry_offset >= image_size) return;

    // 2. Allocate exactly enough pages (Boot Services, any free region).
    //    AllocatePages returns 4K-aligned pages -- the base alignment that
    //    the kernel's PC-relative addressing relies on. We use
    //    EfiLoaderCode (not EfiLoaderData) because firmware may map
    //    non-code memory types as execute-never, and we are about to jump
    //    to this memory. Real UEFI bootloaders do the same.
    const pages_needed: usize = @intCast((image_size + 4095) / 4096);
    const pages = boot_services.allocatePages(.any, .loader_code, pages_needed) catch return;
    const dst: [*]u8 = @ptrCast(pages.ptr);
    const base: u64 = @intFromPtr(dst);

    // 3. Read the CONTENT (image_size - 24 header bytes) into the allocation
    //    at offset 0. The 24-byte DSK1 header is parsed but NOT loaded into
    //    RAM: the kernel is linked with VMA 0 == content start, so placing
    //    the content at base+0 makes every PC-relative reference (both ADR
    //    and ADRP+ADD) resolve to the right byte. Loading the file verbatim
    //    (content at base+24) is what caused the KERNEL.TXT scramble: ADR
    //    refs stayed correct because the +24 rides inside the PC, but
    //    ADRP+ADD refs compute (PC page) + VMA offset and silently drop the
    //    +24, reading the kernel's own .rodata 24 bytes early (see ADR
    //    0002, known issue [resolved]).
    if (image_size <= kernel_header_size) return; // no loadable content
    const content_size: usize = @intCast(image_size - kernel_header_size);
    kernel_file.setPosition(kernel_header_size) catch return;
    const dst_slice = dst[0..content_size];
    var filled: usize = 0;
    while (filled < content_size) {
        const got = kernel_file.read(dst_slice[filled..]) catch return;
        if (got == 0) return; // short read: image truncated
        filled += got;
    }

    if (st.con_out) |con_out| {
        _ = con_out.outputString(&line_loading) catch {};
        _ = con_out.outputString(&line_jumping) catch {};
    }

    // 3b. Loader trace: record base/size/entry on the ESP before the jump.
    write_loader_trace(root, &header, dst, base, image_size, entry_offset);

    // 3c. The content bytes were written by data accesses; make the
    //     instruction stream see them (clean D-cache to PoU, invalidate
    //     I-cache, DSB, ISB -- the same maintenance the firmware's LoadImage
    //     performs before transferring control to a loaded image).
    //     Per-byte iteration so no cache-line-size assumption is made; the
    //     kernel image is tiny.
    flush_to_pou(dst, content_size);

    // 4. Jump. The kernel runs on our stack and keeps using Boot Services;
    //    when it returns, we return to the firmware. entry_offset is
    //    file-relative (includes the 24-byte header); with the content at
    //    base+0 the in-RAM entry is base + (entry_offset - 24).
    const EntryFn = *const fn (
        base: u64,
        size: u64,
        st: *const uefi.tables.SystemTable,
        root: *uefi.protocol.File,
    ) callconv(.c) u64;
    const entry: EntryFn = @ptrFromInt(base + (entry_offset - kernel_header_size));
    const rc = entry(base, image_size, st, root);
    write_rc(root, rc);

    if (st.con_out) |con_out| {
        _ = con_out.outputString(if (rc == 0) &line_rc_ok else &line_rc_bad) catch {};
    }
}

/// Write \MEMMAP.TXT: one line per EFI memory map descriptor with its type,
/// physical start, page count, and key attributes (xp/wb/ro). Host-visible
/// evidence of the memory layout the kernel handoff runs in. Best effort.
fn dump_memory_map(st: *const uefi.tables.SystemTable) void {
    const boot_services = st.boot_services orelse return;
    const info = boot_services.getMemoryMapInfo() catch return;
    // info.len is the descriptor COUNT; the pool must hold len*desc_size
    // bytes. Allocate with margin: the allocatePool call itself can grow the
    // map (a pool allocation may split a descriptor), so an exact-size
    // buffer risks EFI_BUFFER_TOO_SMALL on the second call.
    const bytes_needed = info.len * info.descriptor_size + 64 * info.descriptor_size;
    const buf = boot_services.allocatePool(.loader_data, bytes_needed) catch return;
    defer boot_services.freePool(buf.ptr) catch {};
    const mm = boot_services.getMemoryMap(buf) catch return;

    const loaded_image = (boot_services.handleProtocol(uefi.protocol.LoadedImage, uefi.handle) catch null) orelse return;
    const device_handle = loaded_image.device_handle orelse return;
    const fs = (boot_services.handleProtocol(uefi.protocol.SimpleFileSystem, device_handle) catch null) orelse return;
    const vol = fs.openVolume() catch return;
    defer vol.close() catch {};
    const f = vol.open(&memmap_path, .read_write_create, .{}) catch return;
    defer f.close() catch {};

    // Header with map metadata, then one line per descriptor. The std
    // iterator walks with the firmware-reported descriptor_size stride.
    var header: [96]u8 = undefined;
    var hn: usize = 0;
    hn += copy_into(header[hn..], "DIPSHITOS MEMORY MAP\n");
    hn += copy_into(header[hn..], "descriptors=");
    hn += append_hex(header[hn..], mm.info.len);
    hn += copy_into(header[hn..], " descriptor_size=");
    hn += append_hex(header[hn..], mm.info.descriptor_size);
    hn += copy_into(header[hn..], "\n");
    _ = f.write(header[0..hn]) catch {};

    var it = mm.iterator();
    while (it.next()) |desc| {
        // One line per descriptor; the buffer is sized for the longest line.
        var line: [160]u8 = undefined;
        var n: usize = 0;
        n += copy_into(line[n..], "  ");
        n += copy_into(line[n..], @tagName(desc.type));
        n += copy_into(line[n..], " phys=");
        n += append_hex(line[n..], desc.physical_start);
        n += copy_into(line[n..], " pages=");
        n += append_hex(line[n..], desc.number_of_pages);
        n += copy_into(line[n..], " xp=");
        line[n] = if (desc.attribute.xp) '1' else '0';
        n += 1;
        n += copy_into(line[n..], " wb=");
        line[n] = if (desc.attribute.wb) '1' else '0';
        n += 1;
        n += copy_into(line[n..], " ro=");
        line[n] = if (desc.attribute.ro) '1' else '0';
        n += 1;
        n += copy_into(line[n..], "\n");
        _ = f.write(line[0..n]) catch {};
    }
    f.flush() catch {};
}

/// Write \LOADER.TXT: loader-observed kernel placement (base, size, entry
/// offset), the DSK1 header fields as read from the file (first8/second8),
/// and the first 8 bytes that landed at the image base in RAM (ram_first8;
/// with the content at base+0 these are the kernel's first instructions).
/// Best effort, like the other marker writes.
fn write_loader_trace(root: *uefi.protocol.File, header: *const [kernel_header_size]u8, dst: [*]const u8, base: u64, size: u64, entry_offset: u64) void {
    const trace = root.open(&loader_trace_path, .read_write_create, .{}) catch return;
    defer trace.close() catch {};

    var content: [320]u8 = undefined;
    var n: usize = 0;
    n += copy_into(content[n..], "DIPSHITOS LOADER\n");
    n += copy_into(content[n..], "kernel image loaded\n");
    n += copy_into(content[n..], "base=");
    n += append_hex(content[n..], base);
    n += copy_into(content[n..], " size=");
    n += append_hex(content[n..], size);
    n += copy_into(content[n..], " entry_offset=");
    n += append_hex(content[n..], entry_offset);
    n += copy_into(content[n..], " first8=");
    n += append_hex(content[n..], std.mem.readInt(u64, header[0..8], .little));
    n += copy_into(content[n..], " second8=");
    n += append_hex(content[n..], std.mem.readInt(u64, header[8..16], .little));
    n += copy_into(content[n..], " ram_first8=");
    n += append_hex(content[n..], std.mem.readInt(u64, dst[0..8], .little));
    n += copy_into(content[n..], "\n");

    _ = trace.write(content[0..n]) catch {};
    trace.flush() catch {};
}

/// Make code written by data accesses visible to instruction fetches over
/// [base, base+len): clean data cache to the point of unification, then
/// invalidate the instruction cache, synchronize (DSB ISH), and sync the
/// pipeline (ISB). Per-byte iteration so no cache-line-size is assumed; the
/// kernel image is tiny.
fn flush_to_pou(base: [*]const u8, len: usize) void {
    var i: usize = 0;
    while (i < len) : (i += 1) {
        asm volatile ("dc cvau, %[addr]"
            :
            : [addr] "r" (@intFromPtr(base + i)),
        );
    }
    asm volatile ("dsb ish" ::: .{ .memory = true });
    i = 0;
    while (i < len) : (i += 1) {
        asm volatile ("ic ivau, %[addr]"
            :
            : [addr] "r" (@intFromPtr(base + i)),
        );
    }
    asm volatile ("dsb ish" ::: .{ .memory = true });
    asm volatile ("isb" ::: .{ .memory = true });
}

/// Record the kernel's return code in \RC.TXT (host-observable proof that
/// control returned from the kernel). Best effort.
fn write_rc(root: *uefi.protocol.File, rc: u64) void {
    const f = root.open(&rc_path, .read_write_create, .{}) catch return;
    defer f.close() catch {};
    var content: [48]u8 = undefined;
    var n: usize = 0;
    n += copy_into(content[n..], "kernel_rc=");
    n += append_hex(content[n..], rc);
    n += copy_into(content[n..], "\n");
    _ = f.write(content[0..n]) catch {};
    f.flush() catch {};
}

fn copy_into(dst: []u8, src: []const u8) usize {
    @memcpy(dst[0..src.len], src);
    return src.len;
}

/// Write "0x" + 16 lowercase hex digits of `value` into `buf` and return the
/// number of bytes written (18). Never aliases `buf` back onto itself.
fn append_hex(buf: []u8, value: u64) usize {
    buf[0] = '0';
    buf[1] = 'x';
    var v = value;
    var i: usize = 15;
    while (true) : (i -= 1) {
        const d: u8 = @intCast(v & 0xf);
        buf[2 + i] = if (d < 10) '0' + d else 'a' + (d - 10);
        v >>= 4;
        if (i == 0) break;
    }
    return 18;
}

fn wait_a_moment() void {
    var i: u64 = 0;
    while (i < 1_500_000_000) : (i += 1) {
        // The volatile asm prevents the optimizer from eliminating the loop.
        // (Zig 0.16 clobber syntax: a struct literal of clobber flags.)
        asm volatile ("" ::: .{ .memory = true });
    }
}

//! oliver-native.zig — oliver (a real Zig HTML tool) as a NATIVE AArch64 ELF
//! app on VirelaiOS: `exec OLIVER.ELF <in.txt> <out.html>`.
//!
//! This is oliver's own library source (vendored from oliver commit
//! 3f05bacb188ab28ad797430c82d9ee20080c5ed6), calling the real
//! `oliver.parse` + `oliver.html.render` entry points. Only the host-side
//! edges are replaced, with the seams that already exist:
//!
//!   * entry     : `_start(argc, argv)` — argc in x0, argv block VA in x1
//!                 (card 3e: 8 slots of 32 bytes, NUL-terminated)
//!   * syscalls  : user/src/lib/zc.zig — the proven freestanding svc shim
//!                 (slot 23/24/25/26 file, 63 mmap, 1 write, 3 exit)
//!   * memory    : anonymous sys_mmap (M29): the input buffer is mapped
//!                 MAP_POPULATE because the KERNEL copies file bytes into it
//!                 (zc.mmap's documented reason); the render arena and output
//!                 buffer are mapped demand-paged (no POPULATE) so the guest
//!                 page-fault path backs them lazily.
//!   * allocator : std.heap.ArenaAllocator over a FixedBufferAllocator on the
//!                 demand-paged mapping — no libc, no page_allocator.
//!
//! Exit status is the number of HTML bytes written (the wc/filerocks
//! discipline: a distinct, checkable number) so a host-side assert can pin it.
//!
//! Arguments: `OLIVER.BIN <in> <out>`, each falling back to its default
//! (MD.TXT / OLIVER.HTML) when absent. A name starting with '/' is taken as a
//! full guest path; a bare name gets the /host/ prefix. Raw-ELF exec delivers
//! NO argv (kernel/src/exec.zig returns `.no_args_room` for that shape), so the
//! same source ships both ways: OLIVER.ELF (argv null → defaults) and
//! OLIVER.BIN, a DSK1 flat image whose argv block is packed into the text
//! page's slack (#1188).
//!
//! Failure exits are distinct so a live gate can tell them apart:
//! 2 bad path, 31 open, 32 read, 33 input over cap, 34 out-open, 35 write,
//! 36 mmap(populate), 37 mmap(demand), 38 stalled write, 41 parse, 42 render.

const std = @import("std");
const zc = @import("zc");
const oliver = @import("oliver");

const argv_slot_bytes = 32;
const argv_slots = 8;

/// Kernel file staging cap (wasm-import-contract §5.1 mirrors it; the native
/// slot 24/25 dispatch takes the same bounded extent).
const io_chunk: usize = 2048;

const in_cap: usize = 128 * 1024;
const out_cap: usize = 64 * 1024;
const heap_cap: usize = 4 * 1024 * 1024;

const MODE_READ: u32 = 0x1;
const MODE_WRITE: u32 = 0x2;
const MODE_CREATE: u32 = 0x4;

const exit_mmap_populate: u64 = 36;
const exit_mmap_demand: u64 = 37;
const exit_stalled_write: u64 = 38;

/// A negative svc return is the kernel's errno, never a mapped address: using
/// it as a pointer faults on the first store with a wild VA, and the fault
/// looks like an app bug rather than an OOM. Check before returning.
fn checkedMmap(len: u64, flags: u64, code: u64) [*]u8 {
    const va: u64 = asm volatile ("svc #0"
        : [ret] "={x0}" (-> u64),
        : [num] "{x8}" (@as(u64, 63)),
          [a0] "{x0}" (@as(u64, 0)),
          [a1] "{x1}" (len),
          [a2] "{x2}" (@as(u64, 3)), // PROT_READ | PROT_WRITE
          [a3] "{x3}" (flags),
    );
    if (@as(i64, @bitCast(va)) < 0) zc.exit(code);
    return @as([*]u8, @ptrFromInt(va));
}

/// Eager mapping (MAP_POPULATE): the KERNEL copies file bytes into it, so its
/// pages must exist up front. Same slot-63 ABI as `zc.mmap`, with the return
/// checked.
fn mmapPopulate(len: u64) [*]u8 {
    return checkedMmap(len, 0x8022, exit_mmap_populate);
}

/// Anonymous RW private mapping, demand-paged (no MAP_POPULATE) — the M29
/// seam `zc.mmap` cannot express (it always sets MAP_POPULATE), with the
/// return checked.
fn mmapDemand(len: u64) [*]u8 {
    return checkedMmap(len, 0x22, exit_mmap_demand); // MAP_PRIVATE | MAP_ANONYMOUS
}

fn openPath(prefix: []const u8, name: []const u8, flags: u32) u64 {
    // A name that already names a full guest path (`/host/other.txt`) is used
    // verbatim — that is what makes an argv-supplied path useful rather than
    // share-relative-only.
    if (name.len > 0 and name[0] == '/') return zc.file_open(name, flags);
    var buf: [80]u8 = undefined;
    if (prefix.len + name.len > buf.len) zc.exit(2);
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len .. prefix.len + name.len], name);
    return zc.file_open(buf[0 .. prefix.len + name.len], flags);
}

/// Read the whole file at `/host/<name>` into `dst`; returns the byte count.
/// A file that EXACTLY fills `dst` is legal (the buffer is the whole input,
/// and nothing said the file must be shorter than it); only a file with bytes
/// left over is over-cap, detected by probing one byte past the fill.
fn readHostFile(name: []const u8, dst: []u8) usize {
    const fd = openPath("/host/", name, MODE_READ);
    if (@as(i64, @bitCast(fd)) < 0) zc.exit(31);
    var n: usize = 0;
    while (n < dst.len) {
        const want = @min(io_chunk, dst.len - n);
        const r = zc.file_read(fd, dst[n..].ptr, want);
        if (@as(i64, @bitCast(r)) < 0) zc.exit(32);
        if (r == 0) break;
        n += @intCast(r);
    }
    if (n == dst.len) {
        var probe: [1]u8 = undefined;
        const r = zc.file_read(fd, &probe, probe.len);
        if (@as(i64, @bitCast(r)) < 0) zc.exit(32);
        if (r > 0) zc.exit(33); // more bytes than the cap holds
    }
    zc.file_close(fd);
    return n;
}

/// Write `bytes` to `/host/<name>`, chunked under the kernel's io staging cap.
fn writeHostFile(name: []const u8, bytes: []const u8) usize {
    const fd = openPath("/host/", name, MODE_WRITE | MODE_CREATE);
    if (@as(i64, @bitCast(fd)) < 0) zc.exit(34);
    var off: usize = 0;
    while (off < bytes.len) {
        const n = @min(io_chunk, bytes.len - off);
        const r = zc.file_write(fd, bytes[off..].ptr, n);
        if (@as(i64, @bitCast(r)) < 0) zc.exit(35);
        // A 0-byte write makes no progress: without this the loop spins
        // forever on a full/short store instead of failing loudly.
        if (r == 0) zc.exit(exit_stalled_write);
        off += @intCast(r);
    }
    zc.file_close(fd);
    return off;
}

/// One argument, or `fallback` when absent.
///
/// NOTE (exec.zig, card 3e): the loader hands argv to DSK1/DSK3 images only —
/// a raw ELF `exec` returns `.no_args_room`, so `exec OLIVER.ELF` always
/// arrives with argc == 0 and a NULL block. The defaults below are that
/// path; `exec OLIVER.BIN <in> <out>` (the flat DSK1 image built from this
/// same source) arrives with the argv block packed into its text page.
fn arg(argv: ?[*]const [argv_slot_bytes]u8, argc: usize, i: usize, fallback: []const u8) []const u8 {
    const slots = argv orelse return fallback;
    if (i >= argc) return fallback;
    const len = std.mem.indexOfScalar(u8, &slots[i], 0) orelse argv_slot_bytes;
    if (len == 0) return fallback;
    return slots[i][0..len];
}

pub export fn _start(argc: usize, argv: ?[*]const [argv_slot_bytes]u8) callconv(.c) noreturn {
    const n_args: usize = if (argv == null) 0 else @min(argc, argv_slots);
    const in_name = arg(argv, n_args, 0, "MD.TXT");
    const out_name = arg(argv, n_args, 1, "OLIVER.HTML");

    // Report the arguments as RECEIVED, before any file op: a live gate asserts
    // this line, so a loader that silently dropped argv (or an app that ignored
    // it) shows up as `argc=0` rather than as a mysterious missing output file.
    // Printed first so it survives a later failure.
    var hdr_buf: [192]u8 = undefined;
    const hdr = std.fmt.bufPrint(&hdr_buf, "oliver: argc={d} in={s} out={s}\n", .{ n_args, in_name, out_name }) catch "oliver: argv\n";
    zc.print(hdr);

    // Input buffer: MAP_POPULATE — the kernel copies file bytes into it.
    const in_buf: []u8 = mmapPopulate(in_cap)[0..in_cap];
    const n_in = readHostFile(in_name, in_buf);

    // Heap + output: demand-paged (no POPULATE).
    const heap: []u8 = mmapDemand(heap_cap)[0..heap_cap];
    const out_buf: []u8 = mmapDemand(out_cap)[0..out_cap];

    var fba = std.heap.FixedBufferAllocator.init(heap);
    var arena = std.heap.ArenaAllocator.init(fba.allocator());
    const alloc = arena.allocator();

    var result = oliver.parse(alloc, in_buf[0..n_in], .markdown, .{}) catch zc.exit(41);
    defer result.deinit();

    var w = std.Io.Writer.fixed(out_buf);
    oliver.html.render(alloc, &w, &result.document, .{}) catch zc.exit(42);

    const html = w.buffered();
    const written = writeHostFile(out_name, html);

    var msg_buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "oliver: wrote {d} bytes\n", .{written}) catch "oliver: wrote\n";
    zc.print(msg);
    zc.exit(written);
}

//! VirelaiOS HTTPS client — FETCHS.BIN (cards TLS13-C8/C11).
//!
//! The first guest consumer of the in-tree TLS 1.3 client (ADR 0029). It
//! connects to a host over the kernel's TCP seam, completes a 1-RTT handshake
//! against a **vendored** root set, sends one HTTP/1.0 GET, and streams the
//! response body to the console.
//!
//! Three seams meet here and each has its own file:
//!   * `lib/tls/stream.zig` — the kernel's one-slot 192-byte, no-reassembly
//!     TCP buffer bridged to the client's byte-stream transport;
//!   * `lib/tls/vendored_roots.zig` — the root set, a static blob rather than
//!     a per-connection fetch (ADR 0029 D5);
//!   * `rng` (slot 64) for entropy and `ui.sys_time()` (slot 66) for the
//!     validity clock, because a certificate check without a clock cannot
//!     tell "not yet valid" from "valid".
//!
//! Usage:
//!   exec FETCHS.BIN [ipv4 [port [server-name [method [pathfile [outfile [bodyfile]]]]]]]
//! Defaults to 10.0.0.2:443 as `leaf.example.com`, GET /. Extra argv slots
//! (issue #1337) are optional so live-tls13's three-arg GET stays identical:
//! method is GET or POST, pathfile/bodyfile are share paths whose contents
//! are the request-target and POST body, and outfile receives the HTTP
//! response (headers+body) instead of dumping it on the console. The target
//! is a parameter rather than a constant because the live gate dials a
//! responder on a high port, and a hardcoded 443 would need the runner to
//! run as root. The rules live in `lib/tls/target.zig`, which is `ui`-free
//! and host-tested.
//!
//! DSK3 segmented: the trust store and the adapter accumulator are static
//! .bss, which the flat ESP layout cannot express.

const std = @import("std");
const ui = @import("ui");
const rng = @import("rng");
const tls_client = @import("lib/tls/client.zig");
const tls_stream = @import("lib/tls/stream.zig");
const trust_store = @import("lib/tls/trust_store.zig");
const roots = @import("lib/tls/vendored_roots.zig");
const target_mod = @import("lib/tls/target.zig");

pub const exit_status: u32 = 42;
pub const exit_usage: u32 = 64;
pub const exit_connect: u32 = 1;
pub const exit_roots: u32 = 2;
pub const exit_handshake: u32 = 3;
pub const exit_io: u32 = 4;

/// The adapter accumulator. Bounded and static (ADR 0013 D3.1): 4 KiB is two
/// maximum-size TLS records, comfortably more than the kernel's 192-byte slot.
var seam_acc: [4096]u8 = undefined;
/// The trust store: the guest default of 64 anchors (ADR 0029 D5).
var store: trust_store.TrustStore = .{};
/// The resolved server name, copied out of the argv block so it outlives it.
var name_buf: [128]u8 = undefined;
/// Last CSPRNG result and the high-water mark of bytes obtained, reported when
/// a handshake fails.
var entropy_last: i64 = 0;
var entropy_bytes: usize = 0;

/// The connection state. These are file-scope, not locals, and that is not
/// house style — it is a hard requirement. The user stack is 32 KiB
/// (`scheduler.task_stack_size`) while `Client` alone is ~87 KiB, so a stack
/// local overflows the stack during the very first prologue store: the guest
/// dies with a data abort at entry+0x40 and nothing prints at all. Static
/// storage is the same reason the trust store lives in .bss.
var seam: tls_stream.Stream = undefined;
var client: tls_client.Client(trust_store.TrustStore) = undefined;

/// Optional HTTP extras (#1337). Default is GET / with the body printed to
/// the console — the live-tls13 shape. POST body and the request-target live
/// in share files because an argv slot is 31 bytes and a git path is not.
var req_method: []const u8 = "GET";
var req_path: []const u8 = "/";
var req_host: []const u8 = target_mod.default_name;
var req_body: []const u8 = &.{};
var out_path: []const u8 = &.{};
var method_store: [8]u8 = undefined;
var path_store: [256]u8 = undefined;
var outfile_store: [64]u8 = undefined;
// POST body cap: git-upload-pack want/done for a single-want clone. A
// larger want-list would need a bigger .bss slot; argv cannot carry it.
var body_store: [8192]u8 = undefined;
var hdr_store: [512]u8 = undefined;
/// One TLS 1.3 application record is at most 2^14 bytes. `Client.read`
/// copies a whole record and drops the tail if `out` is smaller, so this
/// buffer has to be a full record — a 1 KiB stack buf truncated a ~2 KiB
/// git-upload-pack response at 1024 bytes and the pack parser saw garbage.
var read_store: [16384]u8 = undefined;
var out_fd: i64 = -1;

/// Decimal-print a signed value to the console. Two inputs cannot be exercised
/// by a host test -- the guest's wall clock and its CSPRNG -- and when a
/// handshake that works on the host fails here, they are the first things to
/// suspect. This makes both visible in the serial log.
fn printNum(label: []const u8, v: i64) void {
    ui.write_console(label);
    var buf: [24]u8 = undefined;
    var n: usize = 0;
    var u: u64 = if (v < 0) @intCast(-v) else @intCast(v);
    if (v < 0) {
        buf[0] = '-';
        n = 1;
    }
    var digits: [20]u8 = undefined;
    var d: usize = 0;
    if (u == 0) {
        digits[0] = '0';
        d = 1;
    } else {
        while (u > 0) : (u /= 10) {
            digits[d] = '0' + @as(u8, @intCast(u % 10));
            d += 1;
        }
    }
    var i: usize = d;
    while (i > 0) {
        i -= 1;
        buf[n] = digits[i];
        n += 1;
    }
    buf[n] = '\n';
    n += 1;
    ui.write_console(buf[0..n]);
}

fn entropy(out: []u8) void {
    var off: usize = 0;
    while (off < out.len) {
        const n = rng.getrandom(out[off..]);
        entropy_last = n;
        if (n <= 0) break;
        off += @intCast(n);
    }
    if (off > entropy_bytes) entropy_bytes = off;
}

/// Load the vendored blob: repeated `u16 length || DER`. Returns the count.
/// A malformed entry stops the load rather than being skipped silently.
fn loadRoots() usize {
    var count: usize = 0;
    var off: usize = 0;
    while (off + 2 <= roots.blob.len) {
        const len = std.mem.readInt(u16, roots.blob[off..][0..2], .big);
        off += 2;
        if (len == 0 or off + len > roots.blob.len) break;
        store.addRoot(roots.blob[off..][0..len]) catch break;
        off += len;
        count += 1;
    }
    store.setVersion(roots.version);
    return count;
}

/// The kernel packs argv as 32-byte NUL-terminated slots.
fn cliArg(block: [*]u8, i: usize) []const u8 {
    const slot = block + i * 32;
    var len: usize = 0;
    while (len < 32 and slot[len] != 0) len += 1;
    return slot[0..len];
}

fn usage() void {
    ui.write_console("FETCHS.BIN - VirelaiOS HTTPS client (TLS 1.3)\n" ++
        "usage: exec FETCHS.BIN [ipv4 [port [server-name [method [pathfile [outfile [bodyfile]]]]]]]\n" ++
        "  ipv4         numeric IPv4 literal (default 10.0.0.2)\n" ++
        "  port         decimal 1..65535 (default 443)\n" ++
        "  server-name  the name the peer certificate must match\n" ++
        "               (default leaf.example.com)\n" ++
        "  method       GET or POST (default GET)\n" ++
        "  pathfile     share file whose contents are the request-target\n" ++
        "  outfile      share file for the HTTP response (else console)\n" ++
        "  bodyfile     share file whose contents are the POST body\n");
}

fn copyArg(src: []const u8, dest: []u8) ?[]const u8 {
    if (src.len == 0 or src.len > dest.len) return null;
    @memcpy(dest[0..src.len], src);
    return dest[0..src.len];
}

/// Read a whole share file into dest. Returns the byte count, or null on
/// open/read failure. When `trim_nl` is set, trailing CR/LF is stripped so
/// a pathfile can be a single edited line. POST bodies are binary pkt-line
/// and must not be trimmed.
fn readShareFile(path: []const u8, dest: []u8, trim_nl: bool) ?usize {
    const fd = ui.file_open(path, ui.MODE_READ);
    if (fd < 0) return null;
    defer ui.file_close(@intCast(fd));
    var n: usize = 0;
    while (n < dest.len) {
        const r = ui.file_read(@intCast(fd), dest[n..]);
        if (r <= 0) break;
        n += @intCast(r);
    }
    if (trim_nl) {
        while (n > 0 and (dest[n - 1] == '\n' or dest[n - 1] == '\r')) n -= 1;
    }
    return n;
}

pub export fn _start(argc: u64, argv_va: u64) callconv(.c) noreturn {
    if (argc == 0 or argv_va == 0) {
        usage();
        ui.exit_process(exit_usage);
    }
    const block: [*]u8 = @ptrFromInt(argv_va);
    var args_buf: [8][]const u8 = undefined;
    var args_len: usize = 0;
    // The argv shapes disagree, and the kernel source is the authority:
    // exec.zig's DSK1/DSK3 paths set `argc = args.len` and pack slot 0 with the
    // FIRST USER ARGUMENT (`pack_args(args, ...)`), while the ELF path sets
    // `argc = 1 + args.len` with `argv_list[0] = name`. Assuming either one
    // unconditionally silently shifts every argument by one — which is exactly
    // how this first read `24533` as an IPv4 literal and reported "bad target".
    // Skip a leading slot only when it actually is the program name.
    var i: usize = 0;
    if (argc > 0 and std.mem.eql(u8, cliArg(block, 0), "FETCHS.BIN")) i = 1;
    while (i < argc and args_len < args_buf.len) : (i += 1) {
        args_buf[args_len] = cliArg(block, i);
        args_len += 1;
    }

    const target = target_mod.resolve(args_buf[0..args_len], &name_buf) orelse {
        ui.write_console("fetchs: bad target\n");
        usage();
        ui.exit_process(exit_usage);
    };
    req_host = target.name;
    if (!parseHTTP(args_buf[0..args_len])) {
        ui.write_console("fetchs: bad request\n");
        usage();
        ui.exit_process(exit_usage);
    }
    ui.write_console("fetchs: target set\n");
    printNum("fetchs: clock ", ui.sys_time());
    serve(target);
}

/// argv[3..] is optional: METHOD PATHFILE OUTFILE BODYFILE. Missing slots
/// keep GET / and console output so a three-arg live-tls13 exec is unchanged.
noinline fn parseHTTP(args: []const []const u8) bool {
    if (args.len < 4) return true;
    const m = copyArg(args[3], &method_store) orelse return false;
    if (!std.mem.eql(u8, m, "GET") and !std.mem.eql(u8, m, "POST")) return false;
    req_method = m;
    if (args.len >= 5 and args[4].len > 0) {
        const n = readShareFile(args[4], &path_store, true) orelse return false;
        if (n == 0 or path_store[0] != '/') return false;
        req_path = path_store[0..n];
    }
    if (args.len >= 6 and args[5].len > 0) {
        const p = copyArg(args[5], &outfile_store) orelse return false;
        out_path = p;
    }
    if (args.len >= 7 and args[6].len > 0) {
        const n = readShareFile(args[6], &body_store, false) orelse return false;
        req_body = body_store[0..n];
    }
    return true;
}

/// The session proper, deliberately `noinline` and deliberately not part of
/// `_start`. Zig's result-location and inlining rules would otherwise fuse the
/// whole call graph into the entry function's frame; measured, that frame came
/// to 81,264 bytes against a 32 KiB user stack, and the guest died on the
/// prologue store before printing anything at all. A hard call boundary keeps
/// each frame's cost visible and bounded.
noinline fn serve(target: target_mod.Target) noreturn {
    if (loadRoots() == 0) {
        ui.write_console("fetchs: no usable roots\n");
        ui.exit_process(exit_roots);
    }
    ui.write_console("fetchs: roots loaded\n");

    const now = ui.sys_time();
    if (now <= 0) {
        // Without a clock the validity window cannot be judged, and guessing
        // would defeat the check rather than perform it.
        ui.write_console("fetchs: no wall clock\n");
        ui.exit_process(exit_io);
    }

    if (ui.tcp_connect(target.ip, target.port) < 0) {
        ui.write_console("fetchs: connect failed\n");
        ui.exit_process(exit_connect);
    }
    ui.write_console("fetchs: connected\n");

    seam = tls_stream.Stream.init(tls_stream.sysOps(), &seam_acc);
    client = tls_client.Client(trust_store.TrustStore).init(seam.transport(), .{
        .host = target.name,
        .store = &store,
        .now = now,
        .entropy = entropy,
    });

    if (!phaseHandshake()) {
        // Read AFTER the attempt: client.zig asks for entropy inside the
        // handshake (client.zig:221-223), so printing before it reported the
        // initial 0 and read like a dead CSPRNG. It was a diagnostic
        // reporting its own initial value, and it cost a run to find out.
        printNum("fetchs: entropy ", entropy_last);
        printNum("fetchs: entropy-bytes ", @intCast(entropy_bytes));
        ui.write_console("fetchs: handshake failed\n");
        seam.close();
        ui.exit_process(exit_handshake);
    }
    ui.write_console("fetchs: handshake ok\n");
    ui.write_console("fetchs: TLS1.3 TLS_AES_128_GCM_SHA256\n");
    ui.write_console("fetchs: method ");
    ui.write_console(req_method);
    ui.write_console("\n");
    ui.write_console("fetchs: path ");
    ui.write_console(req_path);
    ui.write_console("\n");

    if (!phaseRequest()) {
        ui.write_console("fetchs: send failed\n");
        seam.close();
        ui.exit_process(exit_io);
    }
    ui.write_console("fetchs: request sent\n");

    if (phaseRead() == 0) {
        ui.write_console("fetchs: empty response\n");
        seam.close();
        ui.exit_process(exit_io);
    }
    ui.write_console("\nfetchs: body complete\n");
    seam.close();
    ui.exit_process(exit_status);
}

/// Each protocol phase sits behind its own hard call boundary. Zig otherwise
/// fuses the entire call graph into one frame: measured, the consumer body came
/// to 79 KiB against a 32 KiB guest stack. Splitting does not by itself make
/// the client fit -- that is the open finding -- but it turns one opaque
/// 79 KiB number into per-phase numbers a decision can be made from.
noinline fn phaseHandshake() bool {
    client.handshake() catch |e| {
        // Name the error. "handshake failed" is a verdict, not a diagnosis:
        // the client's error set distinguishes a bad record from a rejected
        // certificate from an unexpected message, and only one of those is a
        // reason to look at the TLS code.
        ui.write_console("fetchs: handshake error ");
        ui.write_console(@errorName(e));
        ui.write_console("\n");
        return false;
    };
    return true;
}

noinline fn phaseRequest() bool {
    const hdr = if (std.mem.eql(u8, req_method, "POST"))
        std.fmt.bufPrint(&hdr_store, "POST {s} HTTP/1.0\r\nHost: {s}\r\n" ++
            "Content-Type: application/x-git-upload-pack-request\r\n" ++
            "Content-Length: {d}\r\nConnection: close\r\n\r\n", .{ req_path, req_host, req_body.len })
    else
        std.fmt.bufPrint(&hdr_store, "GET {s} HTTP/1.0\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{ req_path, req_host });
    const header = hdr catch return false;
    client.write(header) catch return false;
    if (req_body.len > 0) {
        client.write(req_body) catch return false;
    }
    return true;
}

noinline fn phaseRead() usize {
    if (out_path.len > 0) {
        out_fd = ui.file_open(out_path, ui.MODE_WRITE | ui.MODE_CREATE);
        if (out_fd < 0) return 0;
        _ = ui.file_truncate(@intCast(out_fd), 0);
    }
    defer {
        if (out_fd >= 0) {
            ui.file_close(@intCast(out_fd));
            out_fd = -1;
        }
    }
    var total: usize = 0;
    var rounds: usize = 0;
    while (rounds < 256) : (rounds += 1) {
        const n = client.read(&read_store) catch break;
        if (n == 0) break;
        total += n;
        if (out_fd >= 0) {
            var off: usize = 0;
            while (off < n) {
                const chunk = @min(n - off, 2048);
                const w = ui.file_write(@intCast(out_fd), read_store[off..][0..chunk]);
                if (w <= 0) break;
                off += @intCast(w);
            }
        } else {
            ui.write_console(read_store[0..n]);
        }
    }
    printNum("fetchs: wrote ", @intCast(total));
    return total;
}

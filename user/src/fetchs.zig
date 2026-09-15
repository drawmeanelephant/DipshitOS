//! VirelaiOS HTTPS client — FETCHS.BIN (cards TLS13-C7/C8).
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
//! DSK3 segmented: the trust store and the adapter accumulator are static
//! .bss, which the flat ESP layout cannot express.

const std = @import("std");
const ui = @import("ui");
const rng = @import("rng");
const tls_client = @import("lib/tls/client.zig");
const tls_stream = @import("lib/tls/stream.zig");
const trust_store = @import("lib/tls/trust_store.zig");
const roots = @import("lib/tls/vendored_roots.zig");

/// The host gateway, the same destination `fetch.zig` and `download.zig` use.
pub const default_ip: u32 = 0x0a000002;
pub const default_port: u16 = 443;
/// The name the gateway's certificate must match (SNI + hostname check).
pub const host_name: []const u8 = "leaf.example.com";

pub const exit_status: u32 = 42;
pub const exit_connect: u32 = 1;
pub const exit_roots: u32 = 2;
pub const exit_handshake: u32 = 3;
pub const exit_io: u32 = 4;

/// The adapter accumulator. Bounded and static (ADR 0013 D3.1): 4 KiB is two
/// maximum-size TLS records, comfortably more than the kernel's 192-byte slot.
var seam_acc: [4096]u8 = undefined;
/// The trust store: the guest default of 64 anchors (ADR 0029 D5).
var store: trust_store.TrustStore = .{};

fn entropy(out: []u8) void {
    var off: usize = 0;
    while (off < out.len) {
        const n = rng.getrandom(out[off..]);
        if (n <= 0) break;
        off += @intCast(n);
    }
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

pub export fn _start() callconv(.c) noreturn {
    if (loadRoots() == 0) {
        ui.write_console("fetchs: no usable roots\n");
        ui.exit_process(exit_roots);
        return;
    }
    ui.write_console("fetchs: roots loaded\n");

    if (ui.tcp_connect(default_ip, default_port) < 0) {
        ui.write_console("fetchs: connect failed\n");
        ui.exit_process(exit_connect);
        return;
    }
    ui.write_console("fetchs: connected\n");

    var seam = tls_stream.Stream.init(tls_stream.sysOps(), &seam_acc);
    var client = tls_client.Client(trust_store.TrustStore).init(seam.transport(), .{
        .host = host_name,
        .store = &store,
        .now = ui.sys_time(),
        .entropy = entropy,
    });

    client.handshake() catch {
        ui.write_console("fetchs: handshake failed\n");
        seam.close();
        ui.exit_process(exit_handshake);
        return;
    };
    ui.write_console("fetchs: handshake ok\n");
    ui.write_console("fetchs: TLS1.3 TLS_AES_128_GCM_SHA256\n");

    const request = "GET / HTTP/1.0\r\nConnection: close\r\n\r\n";
    client.write(request) catch {
        ui.write_console("fetchs: send failed\n");
        seam.close();
        ui.exit_process(exit_io);
        return;
    };
    ui.write_console("fetchs: request sent\n");

    var buf: [1024]u8 = undefined;
    var total: usize = 0;
    var rounds: usize = 0;
    while (rounds < 64) : (rounds += 1) {
        const n = client.read(&buf) catch break;
        if (n == 0) break;
        total += n;
        ui.write_console(buf[0..n]);
    }
    ui.write_console("\nfetchs: body complete\n");
    seam.close();
    ui.exit_process(exit_status);
}

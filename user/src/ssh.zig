//! SSH.BIN — M51 SSH4 (#1171, ADR 0025 D1/D2/D6/D7/D8): the VirelaiOS SSH-2
//! client.
//!
//! `SSH.BIN [user@]host[:port] [command ...]`
//!
//! Dials **out** over the kernel's bounded TCP seam (slots 30–33), runs the
//! SSH2 KEX (`lib/ssh/kex.zig`: `curve25519-sha256` + `ssh-ed25519` +
//! `chacha20-poly1305@openssh.com`), authenticates with the pinned host key
//! and the TS5 Ed25519 seed (`lib/ssh/userauth.zig`), then opens a session
//! channel (`lib/ssh/channel.zig`) through the encrypted packet transport
//! (`lib/ssh/transport.zig`, the piece SSH3 deferred):
//!
//!   * `exec <command>` is the acceptance-critical one-shot path: remote
//!     stdout/stderr stream to the console and the process exits with the
//!     remote `exit-status` (255 when the peer sends none, OpenSSH-style);
//!   * no command selects `shell`: an optional `pty-req` plus `shell`, with
//!     local keystrokes read from the controlling terminal (`/dev/tty` via
//!     the existing file ABI + slot 67 attach — **no new kernel surface**)
//!     and pumped as `CHANNEL_DATA`. If no terminal is available the mode
//!     fails closed with `exit_tty`.
//!
//! Language and boot-default rules: SSH lives entirely in userland on the
//! M47 primitives (ADR 0023 D2), the kernel gains no slot here, and no SSH
//! code is on the boot path. The host is a numeric IPv4 literal — DNS is a
//! documented later slice (see `docs/ssh-scoping.md`).
//!
//! Every observable line is emitted in ONE `sys_write` (`ui.write_console`)
//! so markers cannot interleave on an SMP heartbeat; the seed never appears
//! in any output.

const std = @import("std");
const ui = @import("ui");
const stream = @import("lib/ssh/stream.zig");
const kex = @import("lib/ssh/kex.zig");
const userauth = @import("lib/ssh/userauth.zig");
const channel = @import("lib/ssh/channel.zig");
const transport = @import("lib/ssh/transport.zig");
const cli = @import("lib/ssh/cli.zig");
const rng = @import("rng");

/// Exit statuses. 0 is also the common remote-`exec` success and 255 the
/// OpenSSH-style "connection failed" status; local failure stages are the
/// documented distinct codes 1..10 and never collide by accident:
/// 1 usage, 2 TCP connect, 3 KEX, 4 host-key pin, 5 userauth, 6 channel,
/// 7 request/reply, 8 transport/protocol, 9 no-rekey bound, 10 no local tty.
pub const exit_ok: u32 = 0;
pub const exit_usage: u32 = 1;
pub const exit_connect: u32 = 2;
pub const exit_kex: u32 = 3;
pub const exit_pin: u32 = 4;
pub const exit_auth: u32 = 5;
pub const exit_channel: u32 = 6;
pub const exit_request: u32 = 7;
pub const exit_transport: u32 = 8;
pub const exit_bound: u32 = 9;
pub const exit_tty: u32 = 10;
pub const exit_no_status: u32 = 255;

/// The channel open advertised window/packet cap and the buffers. The
/// stream buffer is `packet.max_total` plus the 16 AEAD tag bytes (the tag
/// rides outside the RFC 4253 total — see transport.zig).
pub const msg_max: usize = 40960;
pub const ch_tx_max: usize = 4096;
pub const eof_marker = "ssh: eof\n";

var rx_buf: [stream.capacity + transport.tag_len]u8 align(16) = undefined;
var tx_buf: [stream.capacity + transport.tag_len]u8 align(16) = undefined;
var msg_buf: [msg_max]u8 align(16) = undefined;
var ch_tx_buf: [ch_tx_max]u8 align(16) = undefined;
var cmd_buf: [cli.cmd_max]u8 = undefined;

var g_stream: stream.Stream = undefined;
var g_wire: transport.Transport = undefined;
var g_channel: channel.Channel = undefined;
/// The last encrypted-transport failure a seam adapter flattened to -1;
/// the stage marker reports it honestly instead of "transport error".
var g_wire_err: ?transport.Error = null;

// ---------------------------------------------------------------------------
// Serial markers (single-write, SMP-heartbeat safe) and errors
// ---------------------------------------------------------------------------

fn marker(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    ui.write_console(s);
}

fn failStage(stage: []const u8, rc: u32) noreturn {
    marker("ssh: fail stage={s} rc={d}\n", .{ stage, rc });
    g_stream.fail();
    ui.exit_process(rc);
}

/// Map a seam error to (stage, exit status), reporting the recorded
/// encrypted-transport failure when one caused it. Never returns.
fn failFrom(stage: []const u8, rc_if_plain: u32, e: anyerror) noreturn {
    if (g_wire_err) |we| {
        switch (we) {
            error.NoRekey => {
                marker("ssh: bound max_bytes={d} max_packets={d}\n", .{
                    g_wire.limits.max_bytes, g_wire.limits.max_packets,
                });
                failStage("bound", exit_bound);
            },
            error.PeerDisconnect => {
                marker("ssh: peer-disconnect reason={d} desc={s}\n", .{
                    g_wire.peer_reason, g_wire.peer_desc[0..g_wire.peer_desc_len],
                });
                failStage("disconnect", exit_transport);
            },
            error.Entropy => failStage("entropy", exit_transport),
            error.Overlong, error.BadPacket, error.Overflow, error.BadLength, error.BadPadding, error.ShortPacket => failStage("protocol", exit_transport),
            error.Transport => failStage("transport", exit_transport),
        }
    }
    _ = &e;
    failStage(stage, rc_if_plain);
}

fn uaError(e: anyerror) u32 {
    return switch (e) {
        error.MissingHostPin, error.HostKeyMismatch, error.BadPinFile, error.BadPinLine => exit_pin,
        error.MissingCredential, error.BadCredential, error.ServiceRejected, error.NoSupportedAuth, error.AuthRejected => exit_auth,
        else => exit_transport,
    };
}

// ---------------------------------------------------------------------------
// The encrypted transport seam adapters (userauth/channel Transport shape)
// ---------------------------------------------------------------------------

fn wireSend(payload: []const u8) i64 {
    g_wire.sendPayload(payload) catch |e| {
        g_wire_err = e;
        return -1;
    };
    return @intCast(payload.len);
}

fn wireRecv(out: []u8) i64 {
    const p = g_wire.recvPayload(out) catch |e| {
        g_wire_err = e;
        return -1;
    };
    if (p) |bytes| return @intCast(bytes.len);
    ui.yield_task();
    return 0;
}

fn uaTransport() userauth.Transport {
    return .{ .send_fn = wireSend, .recv_fn = wireRecv };
}

fn channelTransport() channel.Transport {
    return .{ .send_fn = wireSend, .recv_fn = wireRecv };
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

fn cliArg(block: [*]u8, i: usize) []const u8 {
    const slot = block + i * 32;
    var len: usize = 0;
    while (len < 32 and slot[len] != 0) len += 1;
    return slot[0..len];
}

fn printHelp() void {
    ui.write_console("SSH.BIN - VirelaiOS SSH client (M51 SSH4)\n" ++
        "usage: exec SSH.BIN [user@]host[:port] [command ...]\n" ++
        "       exec SSH.BIN -h   show this help\n" ++
        "  host      numeric IPv4 literal (DNS is a later slice)\n" ++
        "  user      default virelai; port default 22\n" ++
        "  command   one-shot remote exec; omitted = interactive shell\n" ++
        "  pins      SSH/KNOWN_HOSTS; key: TS5 ssh-user-ed25519\n" ++
        "exit statuses: 0 ok / remote status, 1 usage, 2 connect, 3 kex,\n" ++
        "               4 host pin, 5 auth, 6 channel, 7 request,\n" ++
        "               8 transport, 9 no-rekey bound, 10 no tty,\n" ++
        "               255 remote exec sent no exit-status\n");
}

// ---------------------------------------------------------------------------
// Local terminal for the interactive shell mode.
//
// There is no console-read helper in `lib/ui.zig`, but the existing surface
// is sufficient and needs NO kernel change: open `/dev/tty` through the file
// ABI (slots 23/24/26) and attach the serial front-end with slot 67, then
// poll the raw input queue (the `SH.BIN` pattern). The bytes are forwarded
// as CHANNEL_DATA; the remote pty echoes them back.
// ---------------------------------------------------------------------------

const LocalTty = struct {
    fd: i32 = -1,

    fn open() ?LocalTty {
        const r = ui.abi.file_open("/dev/tty", ui.abi.MODE_READ | ui.abi.MODE_WRITE);
        if (r < 0) return null;
        if (ui.abi.tty_attach(1) != 0) { // selector 1 = the serial console
            ui.abi.file_close(@intCast(r));
            return null;
        }
        return .{ .fd = @intCast(r) };
    }

    fn read(self: *LocalTty, buf: []u8) i64 {
        return ui.abi.file_read(@intCast(self.fd), buf);
    }

    fn write(self: *LocalTty, bytes: []const u8) void {
        _ = ui.abi.file_write(@intCast(self.fd), bytes);
    }

    fn close(self: *LocalTty) void {
        if (self.fd >= 0) {
            _ = ui.abi.tty_attach(0); // detach the front-end
            ui.abi.file_close(@intCast(self.fd));
        }
        self.fd = -1;
    }
};

// ---------------------------------------------------------------------------
// One-shot exec: pump the channel until close, then exit with the status
// ---------------------------------------------------------------------------

fn pumpChannel(session: ?*LocalTty, interactive: bool) noreturn {
    const tty_session = session;
    var local: [128]u8 = undefined;
    var shell_ready = !interactive;
    var status: ?u32 = null;

    while (true) {
        const maybe_ev = if (interactive)
            g_channel.poll() catch |e| failFrom("channel", exit_transport, e)
        else
            g_channel.next() catch |e| failFrom("channel", exit_transport, e);

        if (maybe_ev) |ev| switch (ev) {
            .data => |d| {
                if (tty_session) |s| s.write(d) else ui.write_console(d);
            },
            .extended => |x| {
                // One stream on the serial console: tag stderr so the remote
                // error output stays distinguishable from stdout.
                marker("[stderr] ", .{});
                if (tty_session) |s| s.write(x.bytes) else ui.write_console(x.bytes);
            },
            .exit_status => |st| {
                status = st;
                marker("ssh: exit-status={d}\n", .{st});
            },
            .exit_signal => |sig| marker("ssh: exit-signal={s}\n", .{sig}),
            .eof => ui.write_console(eof_marker),
            .close => break,
            .reply => |r| {
                if (!r.ok) {
                    // `pty-req` is optional (RFC 4254 §6.2): a server that
                    // declines it can still run a shell without a pty.
                    if (r.request == .pty) {
                        ui.write_console("ssh: pty-declined\n");
                    } else {
                        marker("ssh: reply request={s} ok=false\n", .{@tagName(r.request)});
                        g_channel.sendClose() catch {};
                        failStage("request", exit_request);
                    }
                }
                if (r.request == .shell) shell_ready = true;
            },
            .window_adjust, .ignored => {},
        };

        if (interactive) {
            if (shell_ready) {
                if (tty_session) |s| {
                    const n = s.read(&local);
                    if (n > 0) {
                        const take: usize = @intCast(n);
                        g_channel.sendData(local[0..take]) catch |e|
                            failFrom("channel", exit_transport, e);
                    }
                }
            }
            ui.yield_task();
        }
    }

    if (interactive) {
        if (tty_session) |s| s.close();
        marker("ssh: bye rc=0\n", .{});
        ui.exit_process(exit_ok);
    }
    const rc = status orelse exit_no_status;
    marker("ssh: bye rc={d}\n", .{rc});
    ui.exit_process(rc);
}

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------

pub export fn _start(argc: u64, argv_va: u64) callconv(.c) noreturn {
    if (argc == 0 or argv_va == 0) {
        printHelp();
        ui.exit_process(exit_usage);
    }
    const block: [*]u8 = @ptrFromInt(argv_va);
    var args_buf: [24][]const u8 = undefined;
    var args_len: usize = 0;
    var i: usize = 0;
    while (i < argc and args_len < args_buf.len) : (i += 1) {
        const s = cliArg(block, i);
        if (std.mem.eql(u8, s, "-h") or std.mem.eql(u8, s, "--help")) {
            printHelp();
            ui.exit_process(exit_ok);
        }
        args_buf[args_len] = s;
        args_len += 1;
    }

    const target = cli.parse(args_buf[0..args_len], &cmd_buf) orelse {
        ui.write_console("ssh: usage: exec SSH.BIN [user@]host[:port] [command ...]\n");
        ui.exit_process(exit_usage);
    };

    marker("ssh: target user={s} host={s} port={d} mode={s}\n", .{
        target.user, target.host, target.port, if (target.cmd != null) "exec" else "shell",
    });

    // 1. Dial out (slots 30–33 through the stream adapter's production ops).
    if (ui.tcp_connect(target.ip, target.port) < 0) {
        marker("ssh: fail stage=connect rc={d}\n", .{exit_connect});
        ui.exit_process(exit_connect);
    }
    ui.write_console("ssh: connected\n");
    g_stream = stream.Stream.init(&rx_buf, stream.sysOps());

    // 2. KEX (`curve25519-sha256` + `ssh-ed25519` + the OpenSSH AEAD).
    var scratch: kex.Scratch = undefined;
    var k = kex.Kex.init(&g_stream, kex.sysEntropy(), &scratch);
    const res = k.run() catch |e| {
        marker("ssh: kex-error {s}\n", .{@errorName(e)});
        failStage("kex", exit_kex);
    };
    marker("ssh: kex-ok\n", .{});

    // 3. Encrypted packet transport over the same stream, seeded with the
    //    continuing post-NEWKEYS sequence numbers (never reset).
    g_wire = transport.Transport.init(
        &g_stream,
        .{ .fill_fn = rng.getrandom },
        &tx_buf,
        &res.send.key,
        res.send.seq,
        &res.recv.key,
        res.recv.seq,
    );
    g_wire_err = null;

    // 4. Host pin + userauth.
    var ua = userauth.Userauth.init(userauth.Userauth.sysSource(), userauth.Userauth.sysPins(), uaTransport());
    const session = userauth.Session{ .h = res.h, .session_id = res.session_id, .host_key = res.host_key };
    const auth_target = userauth.Target{ .user = target.user, .host = target.host, .port = target.port };
    const auth = ua.run(&session, &auth_target) catch |e| {
        marker("ssh: auth-error {s}\n", .{@errorName(e)});
        failFrom("auth", uaError(e), e);
    };
    marker("ssh: pin-ok\n", .{});
    marker("ssh: auth-ok method={s}\n", .{@tagName(auth)});

    // 5. Session channel.
    g_channel = channel.Channel.init(channelTransport(), &msg_buf, &ch_tx_buf, 0);
    g_channel.open() catch |e| {
        marker("ssh: channel-error {s}\n", .{@errorName(e)});
        failFrom("channel", exit_channel, e);
    };
    marker("ssh: channel-open remote={d}\n", .{g_channel.remote_id});

    // 6a. One-shot exec.
    if (target.cmd) |cmd| {
        g_channel.requestExec(cmd) catch |e| failFrom("request", exit_request, e);
        pumpChannel(null, false);
    }

    // 6b. Interactive shell: pty-req (optional) then shell; local input is
    //     the controlling terminal's raw queue (slot 67 + /dev/tty).
    var session_tty = LocalTty.open() orelse {
        marker("ssh: fail stage=tty rc={d}\n", .{exit_tty});
        g_stream.fail();
        ui.exit_process(exit_tty);
    };
    g_channel.requestPty("xterm", 80, 24, 0, 0, "") catch |e| failFrom("request", exit_request, e);
    g_channel.requestShell() catch |e| failFrom("request", exit_request, e);
    pumpChannel(&session_tty, true);
}

test "ssh: mode and exit-status constants stay distinct" {
    const codes = [_]u32{ exit_ok, exit_usage, exit_connect, exit_kex, exit_pin, exit_auth, exit_channel, exit_request, exit_transport, exit_bound, exit_tty };
    for (codes, 0..) |a, i| {
        for (codes[i + 1 ..]) |b| try std.testing.expect(a != b);
    }
    try std.testing.expectEqual(@as(u32, 255), exit_no_status);
}

//! TERM.BIN — the M45 card SH6 userland shell in a TABWM window
//! (issue #1082, ADR 0020 Amendment A, ADR 0021 D2/A3).
//!
//! The window front-end owner: it opens a `.user` window, opens `/dev/tty`,
//! attaches the window as the terminal's front-end (`sys_tty_attach(2, id)`),
//! and runs the shared shell core (`lib/shell.zig` + `lib/tty.zig`) over the
//! terminal fd. **It draws no pixels itself** — the kernel drains the
//! terminal's output ring into a bounded grid and renders that grid into the
//! bound window (A4); window keys are encoded by the kernel and pushed into
//! the terminal's input queue (A5). Closing the window auto-detaches (A6).
//!
//! This is the same core as `SH.BIN`, a different presentation: `SH.BIN` owns
//! the serial console front-end, `TERM.BIN` owns a window. Markers go to the
//! raw console in SINGLE writes (SMP-heartbeat safe) so a class-B gate can
//! observe attach, submitted lines, and exit while the shell's own output
//! (prompt + echo) travels through the window.

const std = @import("std");
const ui = @import("lib/ui.zig");
const abi = @import("lib/ui/abi.zig");
const tty = @import("lib/tty.zig");
const shell_mod = @import("lib/shell.zig");
// M46 RC3b (#1104): the shared `net [port] [secret] [allow-ip]` parser.
const netargs = @import("lib/netargs.zig");
// M49 SD2 (#1129): the shared startup order (STARTUP.SH then PROFILE.SH).
const startup = @import("lib/startup.zig");
// M49 SD3 (#1130): the shared built-in tool multicall.
const toolbox = @import("lib/toolbox.zig");

pub const ready_marker: []const u8 = "term: ready\n";
pub const attached_marker: []const u8 = "term: attached\n";
pub const line_marker: []const u8 = "term: line ";
pub const done_marker: []const u8 = "term: done";
pub const bye_marker: []const u8 = "term: bye\n";
/// M49 SD1 (#1128): the window presentation's `monitor` escape marker.
pub const monitor_marker: []const u8 = "term: monitor\n";
pub const exit_status: u64 = 71;

/// The terminal window's geometry (a bounded, centred, scanout-safe rect).
pub const win_x: u32 = 64;
pub const win_y: u32 = 48;
pub const win_w: u32 = 640;
pub const win_h: u32 = 400;

/// All heavy state is BSS, not the task stack (the established shell shape).
var g_shell: shell_mod.Shell = undefined;
var g_editor: tty.LineEditor = undefined;
var g_entries: [16]abi.DirEntry = undefined;
var g_listing: [16][]const u8 = undefined;

fn historyCount(ctx: ?*anyopaque) usize {
    _ = ctx;
    return g_editor.hist_count;
}

fn historyEntry(ctx: ?*anyopaque, i: usize) ?[]const u8 {
    _ = ctx;
    if (i >= g_editor.hist_count) return null;
    return g_editor.history[i][0..g_editor.hist_len[i]];
}

/// M50 TS1 (#1135): the calling process's principal via slot 68, for the
/// `whoami`/`id` builtins. The kernel assigns it; nothing here can change it.
/// Mirrors the `SH.BIN` glue (`user/src/sh.zig`) so identity is consistent
/// across both shell presentations.
fn principalGet(ctx: ?*anyopaque) ?shell_mod.Principal {
    _ = ctx;
    const p = abi.principal() orelse return null;
    return .{ .uid = p.uid, .caps = p.caps };
}

fn dirNameLen(name: *const [32]u8) usize {
    var n: usize = 0;
    while (n < name.len and name[n] != 0) n += 1;
    return n;
}

/// Snapshot the host share's filenames (best effort; the shell's resolution
/// is the candidate list, so the 16-entry cap cannot hide an image).
fn refreshListing() []const []const u8 {
    const n = abi.dir_list("", &g_entries);
    if (n <= 0) return g_listing[0..0];
    const count: usize = @intCast(@min(n, g_listing.len));
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const len = dirNameLen(&g_entries[i].name);
        g_listing[i] = g_entries[i].name[0..len];
    }
    return g_listing[0..count];
}

/// Try each candidate filename in order; return the child's exit status, or
/// 127 when no candidate loads.
fn runExternal(req: *const shell_mod.RunRequest) u8 {
    var i: usize = 0;
    while (i < req.count) : (i += 1) {
        const pid = abi.exec_program(req.at(i));
        if (pid >= 0) {
            const st = abi.wait_process(@intCast(pid));
            if (st < 0) return 0;
            return @intCast(st & 0xff);
        }
    }
    return 127;
}

fn bye(session: *tty.Session, status: u8) noreturn {
    session.detach();
    session.close();
    ui.write_console(bye_marker);
    ui.exit_process(status);
}

/// M49 SD1 (#1128): `monitor` from the window shell releases the terminal
/// and closes the window process (the kernel auto-detaches on owner exit).
fn exitToMonitor(session: *tty.Session) noreturn {
    session.detach();
    session.close();
    ui.write_console(monitor_marker);
    ui.exit_process(0);
}

fn runSource(session: *tty.Session, path: []const u8, depth: u32) void {
    if (depth > 4) return;
    const opened = abi.file_open(path, abi.MODE_READ);
    if (opened < 0) {
        session.write("term: cannot source\n");
        g_shell.last_status = 1;
        return;
    }
    const fd: u32 = @intCast(opened);
    var data: [2048]u8 = undefined;
    const got = abi.file_read(fd, &data);
    abi.file_close(fd);
    if (got <= 0) return;
    const len: usize = @intCast(got);
    var start: usize = 0;
    var i: usize = 0;
    while (i <= len) : (i += 1) {
        if (i == len or data[i] == '\n' or data[i] == '\r') {
            if (i > start) runLine(session, data[start..i], depth + 1);
            start = i + 1;
        }
    }
}

/// Run one line through the shared core (`lib/shell.zig`): builtins, external
/// apps (foreground `sys_wait`), functions, and `source`.
fn runLine(session: *tty.Session, raw: []const u8, depth: u32) void {
    if (depth > 8) return;
    var line = raw;
    while (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) line = line[1..];
    while (line.len > 0 and (line[line.len - 1] == ' ' or line[line.len - 1] == '\t')) line = line[0 .. line.len - 1];
    if (line.len == 0) return;

    if (shell_mod.Shell.isFuncDef(line)) {
        if (g_shell.defineFuncLine(line)) {
            session.write("fn: ok\n");
        } else {
            session.write("fn: bad definition\n");
            g_shell.last_status = 1;
        }
        return;
    }

    switch (g_shell.execute(line, refreshListing())) {
        .none => {},
        .print => session.write(g_shell.outSlice()),
        .run => |req| g_shell.last_status = runExternal(&req),
        .source => |req| runSource(session, req.path.slice(), depth),
        .call => |idx| {
            const f = &g_shell.funcs.funcs[idx];
            var i: usize = 0;
            while (i < f.body_count) : (i += 1) runLine(session, f.command(i), depth + 1);
        },
        .exit => |status| bye(session, status),
        .monitor => exitToMonitor(session),
        .set_editor => |m| {
            // M49 SD4 (#1131): the same keymap selection as SH.BIN.
            g_editor.mode = if (m == .vi) .vi else .emacs;
            g_editor.vi_state = .insert;
        },
        .tool => |req| {
            // M49 SD3 (#1130): tools run through the same capture path.
            _ = runTool(req);
            session.write(g_shell.outSlice());
        },
    }
}

// ---------------------------------------------------------------------------
// M49 SD3 (#1130): the tool multicall over the host share (window glue).
// ---------------------------------------------------------------------------

var g_tool_in: []const u8 = &.{};
var g_tool_pos: usize = 0;

fn toolStdinRead(ctx: ?*anyopaque, buf: []u8) usize {
    _ = ctx;
    if (g_tool_pos >= g_tool_in.len) return 0;
    const n = @min(buf.len, g_tool_in.len - g_tool_pos);
    @memcpy(buf[0..n], g_tool_in[g_tool_pos..][0..n]);
    g_tool_pos += n;
    return n;
}

fn toolWrite(ctx: ?*anyopaque, bytes: []const u8) void {
    _ = ctx;
    g_shell.appendOut(bytes);
}

fn toolOpen(ctx: ?*anyopaque, name: []const u8) u64 {
    _ = ctx;
    const r = abi.file_open(name, abi.MODE_READ);
    if (r < 0) return 0;
    // Handles are encoded +1 so a valid fd 0 is not mistaken for "absent".
    return @intCast(r + 1);
}

fn toolRead(ctx: ?*anyopaque, handle: u64, buf: []u8) usize {
    _ = ctx;
    const n = abi.file_read(@intCast(handle - 1), buf);
    if (n <= 0) return 0;
    return @intCast(n);
}

fn toolClose(ctx: ?*anyopaque, handle: u64) void {
    _ = ctx;
    abi.file_close(@intCast(handle - 1));
}

fn toolStat(ctx: ?*anyopaque, name: []const u8) u8 {
    _ = ctx;
    const r = abi.file_open(name, abi.MODE_READ);
    if (r < 0) return 0;
    abi.file_close(@intCast(r));
    return 1;
}

fn runTool(req: shell_mod.ToolRequest) u8 {
    g_tool_in = g_shell.stdin;
    g_tool_pos = 0;
    var ptrs: [shell_mod.tool_arg_max][]const u8 = undefined;
    const n = @min(req.count, shell_mod.tool_arg_max);
    var i: usize = 0;
    while (i < n) : (i += 1) ptrs[i] = req.at(i);
    const host = toolbox.Host{
        .open_fn = toolOpen,
        .read_fn = toolRead,
        .close_fn = toolClose,
        .stat_fn = toolStat,
    };
    const out = toolbox.Writer{ .write_fn = toolWrite };
    const stdin = toolbox.Stream{ .read_fn = toolStdinRead };
    return toolbox.run(req.tool, ptrs[0..n], stdin, host, out);
}

/// M49 SD2 (#1129): the SAME startup order as `SH.BIN` — `STARTUP.SH` then
/// the optional host-share `PROFILE.SH` — so the serial and window
/// presentations cannot drift. The prompt stays presentation-local
/// (`term> `), overridden by `STARTUP.SH`/`PROFILE.SH` like any `prompt`
/// call.
fn runStartup(session: *tty.Session) void {
    startup.runAll(startupFiles(), session, startupLine);
}

fn startupLine(ctx: ?*anyopaque, line: []const u8) void {
    const session: *tty.Session = @ptrCast(@alignCast(ctx.?));
    runLine(session, line, 0);
}

fn startupFiles() startup.Files {
    return .{ .open_fn = startupOpen, .read_fn = startupRead, .close_fn = startupClose };
}

fn startupOpen(ctx: ?*anyopaque, path: []const u8) i64 {
    _ = ctx;
    const r = abi.file_open(path, abi.MODE_READ);
    if (r < 0) return -1;
    return @intCast(r);
}

fn startupRead(ctx: ?*anyopaque, handle: u32, buf: []u8) i64 {
    _ = ctx;
    return abi.file_read(handle, buf);
}

fn startupClose(ctx: ?*anyopaque, handle: u32) void {
    _ = ctx;
    abi.file_close(handle);
}

pub export fn _start(argc: u64, argv_va: u64) callconv(.c) noreturn {
    ui.write_console(ready_marker);

    g_shell = shell_mod.Shell.init();
    _ = g_shell.prompt.set("term> ");
    g_shell.history = .{ .count_fn = historyCount, .entry_fn = historyEntry };
    // M50 TS1 (#1135): `whoami`/`id` read the caller's principal through
    // slot 68 (same wiring as SH.BIN).
    g_shell.principal = .{ .get_fn = principalGet };
    g_editor = .{};

    var session = tty.Session.open() orelse {
        ui.write_console("term: no /dev/tty\n");
        ui.exit_process(1);
    };
    // M46 RC3b (#1104): `TERM.BIN net [port] [secret] [allow-ip]` attaches the
    // net front-end (ADR 0020 Amendment B, auth per ADR 0022 D3/D4) instead of
    // the window; the default (no args) is the window front-end, unchanged.
    // Net mode needs no window, so it attaches before any window is opened.
    if (netargs.parse(argc, argv_va)) |na| {
        if (!session.attachNetAuth(na.port, na.secret, na.allow_ip)) {
            session.close();
            ui.write_console("term: net attach failed\n");
            ui.exit_process(2);
        }
        var rb: [48]u8 = undefined;
        const rm = std.fmt.bufPrint(&rb, "term: remote on {d}\n", .{na.port}) catch "term: remote\n";
        ui.write_console(rm);
    } else {
        // The `.user` window this process owns and renders through (A2/A3).
        const opened = abi.win_open(win_x, win_y, win_w, win_h);
        if (opened < 0) {
            session.close();
            ui.write_console("term: no window\n");
            ui.exit_process(3);
        }
        const win_id: u8 = @intCast(opened);
        if (!session.attachWindow(win_id)) {
            abi.win_close(win_id);
            session.close();
            ui.write_console("term: attach failed\n");
            ui.exit_process(2);
        }
        ui.write_console(attached_marker);
    }

    const out = session.output();
    // M49 SD4 (#1131): the window grid has a bounded scrollback, so Ctrl-L
    // clears it too (`ESC [ 3 J`); request bracketed paste from the WM
    // input seam.
    g_editor.clear_scrollback = true;
    session.write(tty.paste_enable);
    // M49 SD2 (#1129): unified startup before the first prompt.
    runStartup(&session);
    session.write(g_shell.promptSlice());

    var buf: [64]u8 = undefined;
    while (true) {
        const n = session.read(&buf);
        if (n <= 0) {
            ui.yield_task();
            continue;
        }
        const len: usize = @intCast(n);
        var i: usize = 0;
        while (i < len) : (i += 1) {
            switch (g_editor.feed(out, buf[i])) {
                .submitted => {
                    // Marker + content in ONE write (SMP-heartbeat safe).
                    var msg: [tty.max_line + 32]u8 = undefined;
                    const m = std.fmt.bufPrint(&msg, "{s}{s}\n", .{ line_marker, g_editor.line() }) catch line_marker;
                    ui.write_console(m);
                    runLine(&session, g_editor.line(), 0);
                    // One line, one write: the command's exit status (the
                    // builtin output itself travels through the window).
                    var done: [32]u8 = undefined;
                    const d = std.fmt.bufPrint(&done, "{s} status={d}\n", .{ done_marker, g_shell.last_status }) catch "term: done\n";
                    ui.write_console(d);
                    g_editor.next_line();
                    session.write(g_shell.promptSlice());
                },
                .cancelled => session.write(g_shell.promptSlice()),
                .repaint => {
                    session.write(g_shell.promptSlice());
                    g_editor.reprint(out);
                },
                .continued => {},
                .eof => bye(&session, @intCast(exit_status)),
                .none => {},
            }
        }
    }
}

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

pub const ready_marker: []const u8 = "term: ready\n";
pub const attached_marker: []const u8 = "term: attached\n";
pub const line_marker: []const u8 = "term: line ";
pub const done_marker: []const u8 = "term: done";
pub const bye_marker: []const u8 = "term: bye\n";
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
    }
}

pub export fn _start(argc: u64, argv_va: u64) callconv(.c) noreturn {
    ui.write_console(ready_marker);

    g_shell = shell_mod.Shell.init();
    _ = g_shell.prompt.set("term> ");
    g_shell.history = .{ .count_fn = historyCount, .entry_fn = historyEntry };
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
                .eof => bye(&session, @intCast(exit_status)),
                .none => {},
            }
        }
    }
}

//! SH.BIN — the M45 card SH2 userland shell (issue #1078, ADR 0021 D2/D3).
//!
//! The EL0 shell process on the terminal seam: open `/dev/tty`, attach the
//! serial front-end, prompt, read lines through the SH1 line editor, and
//! dispatch them through the pure `lib/shell.zig` core. This file is the
//! thin glue — it owns the syscalls (exec/wait, file read for `source`, the
//! terminal fd) and nothing else.
//!
//! External commands are resolved by trying the candidate names the core
//! computes (`foo` -> `foo.BIN`/`foo.ELF` -> `FOO.BIN`/`FOO.ELF`), and run
//! in the FOREGROUND with `sys_wait`, so `$?` gets the child's status.
//! Markers are emitted in single writes (SMP-heartbeat safe).
//!
//! Scope is SH2: no pipes/redirection/globs (SH4), no control flow or
//! command substitution (SH5), no completion/Ctrl-R (SH3).

const std = @import("std");
const ui = @import("lib/ui.zig");
const abi = @import("lib/ui/abi.zig");
const tty = @import("lib/tty.zig");
const shell_mod = @import("lib/shell.zig");

pub const ready_marker: []const u8 = "sh: ready\n";
pub const attached_marker: []const u8 = "sh: attached\n";
pub const bye_marker: []const u8 = "sh: bye\n";
pub const exit_status: u64 = 70;

/// All heavy state is BSS, not the task stack (the kernel learned this with
/// its own shell: a bounded editor/history ring plus tables is large).
var g_shell: shell_mod.Shell = undefined;
var g_editor: tty.LineEditor = undefined;
var g_session: tty.Session = undefined;
var g_entries: [16]abi.DirEntry = undefined;
var g_listing: [16][]const u8 = undefined;
var g_complete: shell_mod.CompletionSet = undefined;

fn historyCount(ctx: ?*anyopaque) usize {
    _ = ctx;
    return g_editor.hist_count;
}

fn historyEntry(ctx: ?*anyopaque, i: usize) ?[]const u8 {
    _ = ctx;
    if (i >= g_editor.hist_count) return null;
    return g_editor.history[i][0..g_editor.hist_len[i]];
}

/// Tab completion source for the SH1 editor: builtins + aliases + share apps
/// in command position, share files in argument position (SH3).
fn shellComplete(line: []const u8, cursor: usize, index: usize) ?tty.CompletionMatch {
    if (cursor > line.len) return null;
    var start = cursor;
    while (start > 0 and line[start - 1] != ' ' and line[start - 1] != '\t') start -= 1;
    const prefix = line[start..cursor];
    if (prefix.len == 0) return null;
    var is_cmd = true;
    var j = start;
    while (j > 0) : (j -= 1) {
        const c = line[j - 1];
        if (c == ';' or c == '|' or c == '&') break;
        if (c != ' ' and c != '\t') {
            is_cmd = false;
            break;
        }
    }
    const n = shell_mod.complete(prefix, is_cmd, &g_shell.aliases, refreshListing(), &g_complete);
    if (n == 0) return null;
    return .{
        .replace_start = start,
        .text = g_complete.at(index % n),
        .match_count = n,
        .has_trailing_space = (n == 1),
    };
}

fn dirNameLen(name: *const [32]u8) usize {
    var n: usize = 0;
    while (n < name.len and name[n] != 0) n += 1;
    return n;
}

/// Snapshot the host share's filenames (best effort — capped at the kernel
/// seam's 16-entry dir_list window; resolution does not depend on it).
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

fn dispatch(line: []const u8, depth: u32) void {
    switch (g_shell.execute(line, refreshListing())) {
        .none => {},
        .print => g_session.write(g_shell.outSlice()),
        .run => |req| g_shell.last_status = runExternal(&req),
        .source => |req| runSource(req.path.slice(), depth),
        .exit => |status| {
            g_session.detach();
            g_session.close();
            ui.write_console(bye_marker);
            ui.exit_process(status);
        },
    }
}

fn runSource(path: []const u8, depth: u32) void {
    if (depth > 4) return;
    const opened = abi.file_open(path, abi.MODE_READ);
    if (opened < 0) {
        g_session.write("source: cannot open ");
        g_session.write(path);
        g_session.write("\n");
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
            if (i > start) dispatch(data[start..i], depth + 1);
            start = i + 1;
        }
    }
}

pub export fn _start() callconv(.c) noreturn {
    ui.write_console(ready_marker);

    g_shell = shell_mod.Shell.init();
    g_shell.history = .{ .count_fn = historyCount, .entry_fn = historyEntry };
    g_editor = .{ .completer = shellComplete };

    g_session = tty.Session.open() orelse {
        ui.write_console("sh: no /dev/tty\n");
        ui.exit_process(1);
    };
    if (!g_session.attach(.serial)) {
        ui.write_console("sh: attach failed\n");
        g_session.close();
        ui.exit_process(2);
    }
    ui.write_console(attached_marker);

    const out = g_session.output();
    g_session.write(g_shell.promptSlice());

    var buf: [64]u8 = undefined;
    while (true) {
        const n = g_session.read(&buf);
        if (n <= 0) {
            ui.yield_task();
            continue;
        }
        const len: usize = @intCast(n);
        var i: usize = 0;
        while (i < len) : (i += 1) {
            switch (g_editor.feed(out, buf[i])) {
                .submitted => {
                    dispatch(g_editor.line(), 0);
                    g_editor.next_line();
                    g_session.write(g_shell.promptSlice());
                },
                .cancelled => g_session.write(g_shell.promptSlice()),
                .repaint => {
                    g_session.write(g_shell.promptSlice());
                    g_editor.reprint(out);
                },
                .eof => {
                    g_session.detach();
                    g_session.close();
                    ui.write_console(bye_marker);
                    ui.exit_process(exit_status);
                },
                .none => {},
            }
        }
    }
}

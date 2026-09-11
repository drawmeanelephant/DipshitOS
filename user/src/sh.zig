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
//! SH3 adds Tab completion + Ctrl+R reverse-i-search; SH4 adds `|`, `>`,
//! `>>`, `<` and glob expansion. The execution bound for SH4: pipes and
//! redirection capture BUILTIN output (externals write fd 1 directly); globs
//! expand against the share listing. No control flow or command substitution
//! yet (SH5).
//!
//! M49 SD2 (#1129): startup is the shared `lib/startup.zig` order —
//! `STARTUP.SH` then the optional `PROFILE.SH` from the host share.

const std = @import("std");
const ui = @import("lib/ui.zig");
const abi = @import("lib/ui/abi.zig");
const tty = @import("lib/tty.zig");
const shell_mod = @import("lib/shell.zig");
const pipe = @import("lib/pipe.zig");
const script = @import("lib/script.zig");
const netargs = @import("lib/netargs.zig");
const startup = @import("lib/startup.zig");
const toolbox = @import("lib/toolbox.zig");

pub const ready_marker: []const u8 = "sh: ready\n";
pub const attached_marker: []const u8 = "sh: attached\n";
pub const bye_marker: []const u8 = "sh: bye\n";
/// M49 SD1 (#1128): the `monitor` escape hands the raw console back to the
/// kernel monitor — distinct from `exit` so a class-B gate can observe it.
pub const monitor_marker: []const u8 = "sh: monitor\n";
pub const exit_status: u64 = 70;
/// SH7 (#1083): the default TCP port when `exec SH.BIN net` gives no port.
pub const default_net_port: u16 = netargs.default_port;
/// M46 RC3 (#1111): the shared `net [port] [secret] [allow-ip]` parser.
pub const NetArgs = netargs.Args;
pub const parseNetArgs = netargs.parse;
/// M49 SD2 (#1129): the unified shell startup files (`STARTUP.SH` then the
/// optional host-share `PROFILE.SH`), shared with `TERM.BIN`.
pub const startup_path: []const u8 = startup.startup_path;
pub const profile_path: []const u8 = startup.profile_path;
/// SH8: the kernel settings file (for the `prompt` key).
pub const settings_path: []const u8 = "SETTINGS.TXT";

/// All heavy state is BSS, not the task stack (the kernel learned this with
/// its own shell: a bounded editor/history ring plus tables is large).
var g_shell: shell_mod.Shell = undefined;
var g_editor: tty.LineEditor = undefined;
var g_session: tty.Session = undefined;
var g_entries: [16]abi.DirEntry = undefined;
var g_listing: [16][]const u8 = undefined;
var g_complete: shell_mod.CompletionSet = undefined;
/// Scratch for a pipeline's stdin / a `<` redirect's file contents.
var g_io_buf: [4096]u8 = undefined;
/// Scratch for a line rebuilt after `$( )` substitution.
var g_subst_buf: [1024]u8 = undefined;

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
    const n = shell_mod.complete(prefix, is_cmd, &g_shell.aliases, &g_shell.env, refreshListing(), &g_complete);
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

fn exitShell(status: u8) noreturn {
    g_session.detach();
    g_session.close();
    ui.write_console(bye_marker);
    ui.exit_process(status);
}

/// M49 SD1 (#1128, ADR 0021 D1): `monitor` releases the terminal — detach
/// the serial front-end, close `/dev/tty`, exit — so the kernel monitor's
/// `login_console_relinquished` observes the detach and takes the raw
/// console back. `shell=sh` is not a one-way door.
fn exitToMonitor() noreturn {
    g_session.detach();
    g_session.close();
    ui.write_console(monitor_marker);
    ui.exit_process(0);
}

/// Perform one core action.
fn performAction(action: shell_mod.Action, depth: u32) void {
    switch (action) {
        .none => {},
        .print => g_session.write(g_shell.outSlice()),
        .run => |req| g_shell.last_status = runExternal(&req),
        .source => |req| runSource(req.path.slice(), depth),
        .call => |idx| runFunction(idx, depth),
        .exit => |status| exitShell(status),
        .monitor => exitToMonitor(),
        .set_editor => |m| {
            // M49 SD4 (#1131): mirror the shell's keymap selection onto the
            // shared editor.
            g_editor.mode = if (m == .vi) .vi else .emacs;
            g_editor.vi_state = .insert;
        },
        .tool => |req| {
            // M49 SD3 (#1130): run then flush the captured output (the
            // pipeline/redirect `capture` path reads the same buffer).
            g_shell.last_status = runTool(req);
            g_session.write(g_shell.outSlice());
        },
    }
}

/// Run a function body (already arg-bound by the core).
fn runFunction(idx: usize, depth: u32) void {
    const f = &g_shell.funcs.funcs[idx];
    var i: usize = 0;
    while (i < f.body_count) : (i += 1) runLine(f.command(i), depth + 1);
}

fn runSimple(line: []const u8, stdin: []const u8, depth: u32) void {
    g_shell.setStdin(stdin);
    performAction(g_shell.execute(line, refreshListing()), depth);
}

/// Run a command with its stdout captured (a builtin `print`). External
/// apps write fd 1 directly and cannot be captured yet — they run through
/// with a bound notice. Function calls run through uncaptured. Returns a
/// slice into `g_shell.out` valid until the next execute.
fn capture(line: []const u8, depth: u32) []const u8 {
    g_shell.setStdin(&.{});
    switch (g_shell.execute(line, refreshListing())) {
        .print => return g_shell.outSlice(),
        .none => return &.{},
        .run => |req| {
            g_shell.last_status = runExternal(&req);
            g_session.write("sh: cannot capture an external app's output yet\n");
            return &.{};
        },
        .source => |req| {
            runSource(req.path.slice(), depth);
            return &.{};
        },
        .call => |idx| {
            runFunction(idx, depth);
            return &.{};
        },
        .exit => |status| exitShell(status),
        .monitor => exitToMonitor(),
        .set_editor => |m| {
            g_editor.mode = if (m == .vi) .vi else .emacs;
            g_editor.vi_state = .insert;
            return &.{};
        },
        .tool => |req| {
            _ = runTool(req);
            return g_shell.outSlice();
        },
    }
}

fn drainPipe() void {
    var tmp: [64]u8 = undefined;
    while (true) {
        const n = abi.pipe_read(&tmp);
        if (n <= 0) break;
    }
}

// ---------------------------------------------------------------------------
// M49 SD3 (#1130): the built-in tool multicall (lib/toolbox.zig) over the
// host share. Output goes through the shell's capture buffer, so pipes and
// redirection see tool output exactly like builtin `print` output.
// ---------------------------------------------------------------------------

/// The tool stdin cursor (the shell's bound stdin slice for this call).
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
    // The file ABI exposes no directory bit, so `-f`/`-e` treat an
    // openable name as a regular file (documented bound).
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

/// M49 SD3 (#1130): run one bounded `case` arm (the first pattern that
/// matches wins; no arm is a success).
fn runCase(c: script.Case, depth: u32) void {
    var subj_buf: [shell_mod.line_max]u8 = undefined;
    const subject = shell_mod.expandVars(c.subject, &subj_buf, &g_shell.env, g_shell.last_status);
    var i: usize = 0;
    while (i < c.count) : (i += 1) {
        if (script.caseMatch(c.arms[i].pattern, subject)) {
            _ = runBody(c.arms[i].body, depth);
            return;
        }
    }
    g_shell.last_status = 0;
}

/// `left | right`: capture the left command's output (SH4 bound: builtins),
/// push it through the kernel pipe (slots 56/57), then run the right command
/// with that content as its stdin.
fn runPipeline(left: []const u8, right: []const u8, depth: u32) void {
    drainPipe();
    const captured = capture(left, depth);
    var off: usize = 0;
    while (off < captured.len) {
        const n = abi.pipe_write(captured[off..]);
        if (n <= 0) break;
        off += @intCast(n);
    }
    var total: usize = 0;
    while (total < g_io_buf.len) {
        const n = abi.pipe_read(g_io_buf[total..]);
        if (n <= 0) break;
        total += @intCast(n);
    }
    runSimple(right, g_io_buf[0..total], depth);
    g_shell.setStdin(&.{});
}

/// `cmd > file` / `cmd >> file`: capture the command's output and write it
/// to the share (append rides MODE_APPEND, the host-owned cursor).
fn runRedirectOut(left: []const u8, file: []const u8, op: pipe.RedirectOp, depth: u32) void {
    const captured = capture(left, depth);
    const flags: u32 = abi.MODE_WRITE | abi.MODE_CREATE |
        (if (op == .stdout_append) abi.MODE_APPEND else 0);
    const opened = abi.file_open(file, flags);
    if (opened < 0) {
        g_session.write("sh: cannot open ");
        g_session.write(file);
        g_session.write("\n");
        g_shell.last_status = 1;
        return;
    }
    const fd: u32 = @intCast(opened);
    var off: usize = 0;
    while (off < captured.len) {
        const n = abi.file_write(fd, captured[off..]);
        if (n <= 0) break;
        off += @intCast(n);
    }
    abi.file_close(fd);
    g_shell.last_status = 0;
}

/// `cmd < file`: read the file into the command's stdin.
fn runRedirectIn(left: []const u8, file: []const u8, depth: u32) void {
    const opened = abi.file_open(file, abi.MODE_READ);
    if (opened < 0) {
        g_session.write("sh: cannot open ");
        g_session.write(file);
        g_session.write("\n");
        g_shell.last_status = 1;
        return;
    }
    const fd: u32 = @intCast(opened);
    var total: usize = 0;
    while (total < g_io_buf.len) {
        const n = abi.file_read(fd, g_io_buf[total..]);
        if (n <= 0) break;
        total += @intCast(n);
    }
    abi.file_close(fd);
    runSimple(left, g_io_buf[0..total], depth);
    g_shell.setStdin(&.{});
}

/// Run a `;`-separated body. Returns true when a `break` was signaled.
fn runBody(body: []const u8, depth: u32) bool {
    var cmds: [16][]const u8 = undefined;
    const n = script.splitCommands(body, &cmds);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        runLine(cmds[i], depth);
        if (g_shell.loop_break) return true;
        if (g_shell.loop_continue) return false; // end this iteration
    }
    return false;
}

fn runChain(chain: script.Chain, depth: u32) void {
    var idx: usize = 0;
    while (idx < chain.seg_count) : (idx += 1) {
        const should_run = if (idx == 0) true else switch (chain.ops[idx - 1]) {
            .seq => true,
            .run_and => g_shell.last_status == 0,
            .run_or => g_shell.last_status != 0,
        };
        if (!should_run) continue;
        if (chain.segs[idx].len == 0) continue;
        runLine(chain.segs[idx], depth);
    }
}

/// Substitute the first `$(cmd)` with the captured output of `cmd`.
fn commandSubst(raw: []const u8, depth: u32) []const u8 {
    const c = script.locateCommandSubst(raw) orelse return raw;
    const captured = capture(c.inner, depth);
    var end = captured.len;
    while (end > 0 and (captured[end - 1] == '\n' or captured[end - 1] == '\r')) end -= 1;
    const trimmed = captured[0..end];
    var op: usize = 0;
    const pn = @min(c.prefix.len, g_subst_buf.len);
    @memcpy(g_subst_buf[0..pn], c.prefix[0..pn]);
    op += pn;
    const tn = @min(trimmed.len, g_subst_buf.len - op);
    @memcpy(g_subst_buf[op..][0..tn], trimmed[0..tn]);
    op += tn;
    const sn = @min(c.suffix.len, g_subst_buf.len - op);
    @memcpy(g_subst_buf[op..][0..sn], c.suffix[0..sn]);
    op += sn;
    return g_subst_buf[0..op];
}

/// The M19 4-level dispatch: pipeline, then redirection, then a simple
/// command.
fn runSegment(line: []const u8, stdin: []const u8, depth: u32) void {
    switch (pipe.pipeSplit(line)) {
        .multiple => {
            g_session.write("sh: only one pipe per line\n");
            g_shell.last_status = 2;
            return;
        },
        .split => |sp| {
            runPipeline(sp.left, sp.right, depth);
            return;
        },
        .none => {},
    }
    if (pipe.redirectSplit(line)) |rs| {
        switch (rs.op) {
            .stdin_file => runRedirectIn(rs.left, rs.right, depth),
            .stdout_overwrite, .stdout_append => runRedirectOut(rs.left, rs.right, rs.op, depth),
        }
        return;
    }
    runSimple(line, stdin, depth);
}

fn runIf(st: script.If, depth: u32) void {
    runLine(st.cond, depth);
    if (g_shell.last_status == 0) {
        _ = runBody(st.then_body, depth);
    } else if (st.has_else) {
        _ = runBody(st.else_body, depth);
    }
}

fn runFor(f: *const script.For, depth: u32) void {
    var i: usize = 0;
    while (i < f.word_count) : (i += 1) {
        _ = g_shell.env.set(f.var_name, f.words[i]);
        g_shell.clearLoopFlags();
        if (runBody(f.body, depth)) break;
    }
    _ = g_shell.env.unset(f.var_name);
    g_shell.clearLoopFlags();
}

fn runWhile(w: script.While, depth: u32) void {
    var iter: usize = 0;
    while (iter < 256) : (iter += 1) {
        g_shell.clearLoopFlags();
        runLine(w.cond, depth);
        if (g_shell.last_status != 0) break;
        if (runBody(w.body, depth)) break;
    }
    g_shell.clearLoopFlags();
}

/// The SH5 line interpreter: function definitions, command substitution,
/// single-line `if`/`for`/`while`, chains, then per-segment dispatch.
fn runLine(raw: []const u8, depth: u32) void {
    if (depth > 8) return;
    const line = script.trim(raw);
    if (line.len == 0) return;

    if (shell_mod.Shell.isFuncDef(line)) {
        if (g_shell.defineFuncLine(line)) {
            g_session.write("fn: ok\n");
        } else {
            g_session.write("fn: bad definition\n");
            g_shell.last_status = 1;
        }
        return;
    }

    // Loop bodies are expanded at execution time, so skip substitution.
    const is_loop = std.mem.startsWith(u8, line, "for") or std.mem.startsWith(u8, line, "while");
    const substituted = if (is_loop) line else commandSubst(line, depth);

    if (script.parseIf(substituted)) |st| {
        runIf(st, depth);
        return;
    }
    var f: script.For = undefined;
    if (script.parseFor(substituted, &f)) {
        runFor(&f, depth);
        return;
    }
    if (script.parseWhile(substituted)) |w| {
        runWhile(w, depth);
        return;
    }
    if (script.parseCase(substituted)) |c| {
        runCase(c, depth);
        return;
    }
    switch (script.chainSplit(substituted)) {
        .too_many => {
            g_session.write("sh: chain too long\n");
            g_shell.last_status = 2;
        },
        .chain => |ch| runChain(ch, depth),
        .none => runSegment(substituted, &.{}, depth),
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
            if (i > start) runLine(data[start..i], depth + 1);
            start = i + 1;
        }
    }
}

/// SH8 (#1084): adopt the `prompt` key from the kernel's SETTINGS.TXT so
/// `settings set prompt ...` drives the login shell too. A missing file or
/// key keeps the shell's own default (`sh> `).
fn applyPromptFromSettings() void {
    const opened = abi.file_open(settings_path, abi.MODE_READ);
    if (opened < 0) return;
    const fd: u32 = @intCast(opened);
    var data: [2048]u8 = undefined;
    const got = abi.file_read(fd, &data);
    abi.file_close(fd);
    if (got <= 0) return;
    const bytes = data[0..@intCast(got)];
    var i: usize = 0;
    while (i < bytes.len) {
        var end = i;
        while (end < bytes.len and bytes[end] != '\n') end += 1;
        const line = bytes[i..end];
        if (std.mem.startsWith(u8, line, "prompt=")) {
            const val = std.mem.trim(u8, line["prompt=".len..], " \r\t");
            if (val.len > 0 and val.len <= shell_mod.prompt_max) _ = g_shell.prompt.set(val);
        }
        i = end + 1;
    }
}

/// M49 SD2 (#1129): run the unified startup order (`STARTUP.SH`, then the
/// optional host-share `PROFILE.SH`) once before the first prompt. The file
/// seam is the existing read-only file ABI; the order/scope lives in the
/// pure, host-tested `lib/startup.zig`.
fn runStartup() void {
    startup.runAll(startupFiles(), null, startupLine);
}

fn startupLine(ctx: ?*anyopaque, line: []const u8) void {
    _ = ctx;
    runLine(line, 0);
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
    g_shell.history = .{ .count_fn = historyCount, .entry_fn = historyEntry };
    g_editor = .{ .completer = shellComplete };
    // SH8 (#1084): the settings `prompt` key drives the login shell too.
    applyPromptFromSettings();

    g_session = tty.Session.open() orelse {
        ui.write_console("sh: no /dev/tty\n");
        ui.exit_process(1);
    };
    // SH7 (#1083, ADR 0020 Amendment B): `SH.BIN net [port] [secret]
    // [allow-ip]` hosts the net front-end; the default (no args) is the
    // serial console, unchanged. M46 RC3 (#1111) adds the optional secret /
    // source-IP allowlist (ADR 0022 D3/D4).
    if (parseNetArgs(argc, argv_va)) |na| {
        if (!g_session.attachNetAuth(na.port, na.secret, na.allow_ip)) {
            ui.write_console("sh: remote attach failed\n");
            g_session.close();
            ui.exit_process(2);
        }
        var rb: [48]u8 = undefined;
        const rm = std.fmt.bufPrint(&rb, "sh: remote on {d}\n", .{na.port}) catch "sh: remote\n";
        ui.write_console(rm);
        if (na.secret.len > 0) ui.write_console("sh: remote auth=secret\n");
        if (na.allow_ip != 0) ui.write_console("sh: remote auth=srcip\n");
    } else {
        if (!g_session.attach(.serial)) {
            ui.write_console("sh: attach failed\n");
            g_session.close();
            ui.exit_process(2);
        }
        ui.write_console(attached_marker);
    }

    const out = g_session.output();
    // M49 SD4 (#1131): request bracketed paste from the front-end; the
    // serial byte seam ignores it, remote/future front-ends can honor it.
    g_session.write(tty.paste_enable);
    // SH8 (#1084): run the login startup script once, before the prompt.
    runStartup();
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
                    runLine(g_editor.line(), 0);
                    g_editor.next_line();
                    g_session.write(g_shell.promptSlice());
                },
                .cancelled => g_session.write(g_shell.promptSlice()),
                .repaint => {
                    g_session.write(g_shell.promptSlice());
                    g_editor.reprint(out);
                },
                .continued => {},
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

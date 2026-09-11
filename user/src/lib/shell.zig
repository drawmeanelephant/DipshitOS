//! VirelaiOS userland shell core (M45 card SH2 — ADR 0021 D2/D3, issue
//! #1078).
//!
//! The pure half of `SH.BIN`: tokenizing, `$VAR`/`$?` expansion, the bounded
//! environment and alias tables, the shell-local cwd, builtin classification,
//! PATH-like candidate resolution, and the line interpreter. It performs no
//! syscalls and holds no file descriptors — `execute` returns an `Action`
//! (`print` / `run` / `source` / `exit`) that the thin EL0 glue in
//! `user/src/sh.zig` performs. That split makes the whole shell surface
//! host-testable.
//!
//! Shape ported from the M19 kernel shell (`kernel/src/tokenizer.zig`,
//! `shell_handle_expanded` in `kernel/src/shell.zig`) but scoped to SH2: no
//! pipes/redirection/globs (SH4), no control flow or command substitution
//! (SH5), no tab completion or Ctrl-R (SH3).

const std = @import("std");

pub const max_args: usize = 16;
pub const line_max: usize = 256;
pub const env_max: usize = 24;
pub const env_name_max: usize = 32;
pub const env_val_max: usize = 128;
pub const alias_max: usize = 16;
pub const path_max: usize = 64;
pub const cwd_max: usize = 128;
pub const prompt_max: usize = 64;
pub const out_max: usize = 2048;
pub const name_max: usize = 64;
pub const max_candidates: usize = 6;

/// A bounded byte string with inline storage. All table cells are this shape
/// so the shell stays allocation-free (fixed BSS in the guest).
pub fn Buf(comptime N: usize) type {
    return struct {
        bytes: [N]u8 = [_]u8{0} ** N,
        len: usize = 0,

        const Self = @This();

        pub fn set(self: *Self, s: []const u8) void {
            const n = @min(s.len, N);
            @memcpy(self.bytes[0..n], s[0..n]);
            self.len = n;
        }

        pub fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }

        pub fn eql(self: *const Self, s: []const u8) bool {
            return std.mem.eql(u8, self.slice(), s);
        }
    };
}

pub const Name = Buf(env_name_max);
pub const Value = Buf(env_val_max);
pub const Path = Buf(path_max);
pub const Program = Buf(name_max);

// ---------------------------------------------------------------------------
// Tokenizer (ported from kernel/src/tokenizer.zig, minus the SH4 glob hook).
// ---------------------------------------------------------------------------

pub const TokenizeResult = struct {
    argv: [max_args + 1][]const u8 = undefined,
    count: usize = 0,
    too_many: bool = false,
    unbalanced_quote: bool = false,
};

/// Split one line into at most `max_args + 1` argument slices. Contiguous
/// runs point into `line`; quoted/escaped joins point into `scratch` (which
/// must outlive every use of the returned slices and never needs to be
/// larger than the line). Quoting/escape semantics match the M19 tokenizer.
pub fn tokenize(line: []const u8, scratch: []u8) TokenizeResult {
    var result: TokenizeResult = .{};
    var index: usize = 0;
    var spos: usize = 0;
    while (index < line.len) {
        if (isSpace(line[index])) {
            index += 1;
            continue;
        }
        if (result.count >= max_args + 1) {
            result.too_many = true;
            break;
        }
        const arg_i = result.count;
        const buf_start = spos;
        var in_single = false;
        var in_double = false;
        while (index < line.len) {
            const c = line[index];
            if (in_single) {
                if (c == '\'') {
                    in_single = false;
                } else {
                    if (spos < scratch.len) scratch[spos] = c;
                    spos += 1;
                }
                index += 1;
                continue;
            }
            if (in_double) {
                if (c == '"') {
                    in_double = false;
                    index += 1;
                    continue;
                }
                if (c == '\\' and index + 1 < line.len) {
                    const n = line[index + 1];
                    switch (n) {
                        '"', '\\', '$' => {
                            if (spos < scratch.len) scratch[spos] = n;
                            spos += 1;
                        },
                        'n' => {
                            if (spos < scratch.len) scratch[spos] = '\n';
                            spos += 1;
                        },
                        't' => {
                            if (spos < scratch.len) scratch[spos] = '\t';
                            spos += 1;
                        },
                        else => {
                            if (spos + 1 < scratch.len) {
                                scratch[spos] = '\\';
                                scratch[spos + 1] = n;
                            }
                            spos += 2;
                        },
                    }
                    index += 2;
                    continue;
                }
                if (spos < scratch.len) scratch[spos] = c;
                spos += 1;
                index += 1;
                continue;
            }
            if (isSpace(c)) break;
            if (c == '\'') {
                in_single = true;
                index += 1;
                continue;
            }
            if (c == '"') {
                in_double = true;
                index += 1;
                continue;
            }
            if (c == '\\') {
                if (index + 1 < line.len) {
                    if (spos < scratch.len) scratch[spos] = line[index + 1];
                    spos += 1;
                    index += 2;
                } else {
                    if (spos < scratch.len) scratch[spos] = '\\';
                    spos += 1;
                    index += 1;
                }
                continue;
            }
            if (spos < scratch.len) scratch[spos] = c;
            spos += 1;
            index += 1;
        }
        if (in_single or in_double) result.unbalanced_quote = true;
        result.argv[arg_i] = scratch[buf_start..@min(spos, scratch.len)];
        result.count += 1;
    }
    return result;
}

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}

// ---------------------------------------------------------------------------
// Environment and aliases.
// ---------------------------------------------------------------------------

pub const EnvEntry = struct {
    name: Name = .{},
    val: Value = .{},
    exported: bool = false,
};

pub const Env = struct {
    entries: [env_max]EnvEntry = [_]EnvEntry{.{}} ** env_max,
    count: usize = 0,

    pub fn get(self: *const Env, name: []const u8) ?[]const u8 {
        for (self.entries[0..self.count]) |*e| {
            if (e.name.eql(name)) return e.val.slice();
        }
        return null;
    }

    /// Set (or create) a variable. Returns false when the table is full and
    /// the name is new.
    pub fn set(self: *Env, name: []const u8, val: []const u8) bool {
        if (name.len == 0 or name.len > env_name_max) return false;
        for (self.entries[0..self.count]) |*e| {
            if (e.name.eql(name)) {
                e.val.set(val);
                return true;
            }
        }
        if (self.count >= env_max) return false;
        const e = &self.entries[self.count];
        e.name.set(name);
        e.val.set(val);
        e.exported = false;
        self.count += 1;
        return true;
    }

    pub fn setExported(self: *Env, name: []const u8, val: []const u8, exported: bool) bool {
        if (!self.set(name, val)) return false;
        for (self.entries[0..self.count]) |*e| {
            if (e.name.eql(name)) e.exported = exported;
        }
        return true;
    }

    /// Remove a variable. Returns true if it existed.
    pub fn unset(self: *Env, name: []const u8) bool {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.entries[i].name.eql(name)) {
                var j = i;
                while (j + 1 < self.count) : (j += 1) self.entries[j] = self.entries[j + 1];
                self.count -= 1;
                return true;
            }
        }
        return false;
    }
};

pub const AliasTable = struct {
    names: [alias_max]Name = [_]Name{.{}} ** alias_max,
    vals: [alias_max]Value = [_]Value{.{}} ** alias_max,
    count: usize = 0,

    pub fn get(self: *const AliasTable, name: []const u8) ?[]const u8 {
        for (self.names[0..self.count], 0..) |*n, i| {
            if (n.eql(name)) return self.vals[i].slice();
        }
        return null;
    }

    pub fn set(self: *AliasTable, name: []const u8, val: []const u8) bool {
        if (name.len == 0) return false;
        for (self.names[0..self.count], 0..) |*n, i| {
            if (n.eql(name)) {
                self.vals[i].set(val);
                return true;
            }
        }
        if (self.count >= alias_max) return false;
        self.names[self.count].set(name);
        self.vals[self.count].set(val);
        self.count += 1;
        return true;
    }

    pub fn unset(self: *AliasTable, name: []const u8) bool {
        var i: usize = 0;
        while (i < self.count) : (i += 1) {
            if (self.names[i].eql(name)) {
                var j = i;
                while (j + 1 < self.count) : (j += 1) {
                    self.names[j] = self.names[j + 1];
                    self.vals[j] = self.vals[j + 1];
                }
                self.count -= 1;
                return true;
            }
        }
        return false;
    }
};

/// The shell's view of the line editor's history ring (SH1 owns the store;
/// the `history` builtin only reads it). Index 0 = newest.
pub const HistoryView = struct {
    ctx: ?*anyopaque = null,
    count_fn: ?*const fn (?*anyopaque) usize = null,
    entry_fn: ?*const fn (?*anyopaque, usize) ?[]const u8 = null,

    pub fn count(self: HistoryView) usize {
        return if (self.count_fn) |f| f(self.ctx) else 0;
    }

    pub fn entry(self: HistoryView, i: usize) ?[]const u8 {
        return if (self.entry_fn) |f| f(self.ctx, i) else null;
    }
};

// ---------------------------------------------------------------------------
// Variable expansion.
// ---------------------------------------------------------------------------

/// Expand `$VAR`, `${VAR}` and `$?` in `line` into `out`. Single quotes
/// protect everything; a backslash pair outside single quotes passes through
/// untouched for the tokenizer to consume (so `\$VAR` is literal).
pub fn expandVars(line: []const u8, out: []u8, env: *const Env, last_status: u8) []u8 {
    var opos: usize = 0;
    var i: usize = 0;
    var in_single = false;
    while (i < line.len and opos < out.len) : (i += 1) {
        if (line[i] == '\'') {
            in_single = !in_single;
            out[opos] = '\'';
            opos += 1;
            continue;
        }
        if (!in_single and line[i] == '\\' and i + 1 < line.len) {
            out[opos] = '\\';
            opos += 1;
            if (opos < out.len) {
                out[opos] = line[i + 1];
                opos += 1;
            }
            i += 1;
            continue;
        }
        if (!in_single and line[i] == '$' and i + 1 < line.len and line[i + 1] == '?') {
            var num: [3]u8 = undefined;
            var nlen: usize = 0;
            var v = last_status;
            if (v == 0) {
                num[0] = '0';
                nlen = 1;
            } else {
                while (v > 0) {
                    num[nlen] = '0' + v % 10;
                    nlen += 1;
                    v /= 10;
                }
            }
            var d = nlen;
            while (d > 0 and opos < out.len) : (d -= 1) {
                out[opos] = num[d - 1];
                opos += 1;
            }
            i += 1;
            continue;
        }
        if (!in_single and line[i] == '$' and i + 1 < line.len) {
            var ns: usize = i + 1;
            var braced = false;
            if (line[ns] == '{') {
                braced = true;
                ns += 1;
            }
            const name_start = ns;
            while (ns < line.len and (std.ascii.isAlphanumeric(line[ns]) or line[ns] == '_')) ns += 1;
            const vname = line[name_start..ns];
            if (vname.len > 0) {
                if (env.get(vname)) |val| {
                    for (val) |b| {
                        if (opos < out.len) {
                            out[opos] = b;
                            opos += 1;
                        }
                    }
                }
                if (braced and ns < line.len and line[ns] == '}') ns += 1;
                i = ns - 1;
                continue;
            }
        }
        if (opos < out.len) {
            out[opos] = line[i];
            opos += 1;
        }
    }
    return out[0..opos];
}

// ---------------------------------------------------------------------------
// Paths and external-command resolution.
// ---------------------------------------------------------------------------

/// Normalize `cwd` + `arg` into an absolute, `.`/`..`-collapsed path.
pub fn normalizePath(cwd: []const u8, arg: []const u8, out: []u8) []u8 {
    var tmp: [path_max * 2]u8 = undefined;
    var tl: usize = 0;
    if (arg.len == 0 or arg[0] != '/') {
        const n = @min(cwd.len, tmp.len);
        @memcpy(tmp[0..n], cwd[0..n]);
        tl = n;
        if (tl < tmp.len) {
            tmp[tl] = '/';
            tl += 1;
        }
    }
    const an = @min(arg.len, tmp.len - tl);
    @memcpy(tmp[tl..][0..an], arg[0..an]);
    tl += an;

    const Part = struct { s: usize, e: usize };
    var parts: [path_max]Part = undefined;
    var depth: usize = 0;
    var i: usize = 0;
    while (i < tl) {
        while (i < tl and tmp[i] == '/') i += 1;
        if (i >= tl) break;
        const s = i;
        while (i < tl and tmp[i] != '/') i += 1;
        const comp = tmp[s..i];
        if (std.mem.eql(u8, comp, ".")) continue;
        if (std.mem.eql(u8, comp, "..")) {
            if (depth > 0) depth -= 1;
            continue;
        }
        if (depth < parts.len) {
            parts[depth] = .{ .s = s, .e = i };
            depth += 1;
        }
    }

    var o: usize = 0;
    if (depth == 0) {
        if (o < out.len) {
            out[o] = '/';
            o += 1;
        }
        return out[0..o];
    }
    for (parts[0..depth]) |p| {
        if (o < out.len) {
            out[o] = '/';
            o += 1;
        }
        const cl = @min(p.e - p.s, out.len - o);
        @memcpy(out[o..][0..cl], tmp[p.s..p.e][0..cl]);
        o += cl;
    }
    return out[0..o];
}

fn upperInto(dst: []u8, src: []const u8) []u8 {
    const n = @min(dst.len, src.len);
    for (src[0..n], 0..) |c, i| dst[i] = std.ascii.toUpper(c);
    return dst[0..n];
}

fn addExt(base: []const u8, ext: []const u8, out: *[max_candidates]Program, n: *usize) void {
    if (n.* >= max_candidates) return;
    var p = Program{};
    const bl = @min(base.len, p.bytes.len);
    @memcpy(p.bytes[0..bl], base[0..bl]);
    const el = @min(ext.len, p.bytes.len - bl);
    @memcpy(p.bytes[bl..][0..el], ext[0..el]);
    p.len = bl + el;
    out[n.*] = p;
    n.* += 1;
}

/// The ordered candidate filenames for an external command `verb`: a verb
/// that already names an image is used as-is; otherwise `.BIN`/`.ELF` are
/// tried for the verb, then for its ASCII-uppercase form, then the bare
/// names. The guest loader is case-sensitive, so both cases are offered.
pub fn candidates(verb: []const u8, out: *[max_candidates]Program) usize {
    var n: usize = 0;
    if (std.mem.endsWith(u8, verb, ".BIN") or std.mem.endsWith(u8, verb, ".ELF") or
        std.mem.endsWith(u8, verb, ".SO"))
    {
        out[0].set(verb);
        return 1;
    }
    addExt(verb, ".BIN", out, &n);
    addExt(verb, ".ELF", out, &n);
    var up: Program = .{};
    var upbuf: [name_max]u8 = undefined;
    const up_slice = upperInto(&upbuf, verb);
    up.set(up_slice);
    addExt(up.slice(), ".BIN", out, &n);
    addExt(up.slice(), ".ELF", out, &n);
    out[n].set(verb);
    n += 1;
    out[n].set(up.slice());
    n += 1;
    return n;
}

// ---------------------------------------------------------------------------
// The interpreter.
// ---------------------------------------------------------------------------

pub const Builtin = enum {
    echo,
    pwd,
    cd,
    exit,
    env,
    set,
    unset,
    export_,
    printenv,
    alias,
    unalias,
    history,
    prompt,
    type_,
    which,
    true_,
    false_,
    help,
    source,
    jobs,
    fg,
};

/// Builtin lookup by verb (the system command boundary, ADR 0021 D3).
pub fn classify(verb: []const u8) ?Builtin {
    const table = .{
        .{ "echo", Builtin.echo },         .{ "pwd", Builtin.pwd },
        .{ "cd", Builtin.cd },             .{ "exit", Builtin.exit },
        .{ "env", Builtin.env },           .{ "set", Builtin.set },
        .{ "unset", Builtin.unset },       .{ "export", Builtin.export_ },
        .{ "printenv", Builtin.printenv }, .{ "alias", Builtin.alias },
        .{ "unalias", Builtin.unalias },   .{ "history", Builtin.history },
        .{ "prompt", Builtin.prompt },     .{ "type", Builtin.type_ },
        .{ "which", Builtin.which },       .{ "true", Builtin.true_ },
        .{ "false", Builtin.false_ },      .{ "help", Builtin.help },
        .{ "source", Builtin.source },     .{ ".", Builtin.source },
        .{ "jobs", Builtin.jobs },         .{ "fg", Builtin.fg },
    };
    inline for (table) |row| {
        if (std.mem.eql(u8, verb, row[0])) return row[1];
    }
    return null;
}

pub const RunRequest = struct {
    candidates: [max_candidates]Program = [_]Program{.{}} ** max_candidates,
    count: usize = 0,

    pub fn at(self: *const RunRequest, i: usize) []const u8 {
        return self.candidates[i].slice();
    }
};

pub const SourceRequest = struct {
    path: Path = .{},
};

pub const Action = union(enum) {
    /// Nothing to do (state changed in place).
    none,
    /// Write `Shell.outSlice()` to the terminal.
    print,
    /// Run an external program; the glue tries each candidate in order.
    run: RunRequest,
    /// Read `path` and execute its lines.
    source: SourceRequest,
    /// Leave the shell with this status.
    exit: u8,
};

pub const Shell = struct {
    env: Env = .{},
    aliases: AliasTable = .{},
    cwd: Path = .{},
    prompt: Buf(prompt_max) = .{},
    last_status: u8 = 0,
    out: Buf(out_max) = .{},
    history: HistoryView = .{},

    expand_buf: [line_max * 2]u8 = undefined,
    scratch: [line_max * 2]u8 = undefined,

    pub fn init() Shell {
        var s = Shell{};
        s.cwd.set("/");
        s.prompt.set("sh> ");
        return s;
    }

    pub fn outSlice(self: *const Shell) []const u8 {
        return self.out.slice();
    }

    pub fn promptSlice(self: *const Shell) []const u8 {
        return self.prompt.slice();
    }

    pub fn cwdSlice(self: *const Shell) []const u8 {
        return self.cwd.slice();
    }

    fn emit(self: *Shell, text: []const u8) void {
        const room = out_max - self.out.len;
        const n = @min(text.len, room);
        @memcpy(self.out.bytes[self.out.len..][0..n], text[0..n]);
        self.out.len += n;
    }

    fn emitLine(self: *Shell, text: []const u8) void {
        self.emit(text);
        self.emit("\n");
    }

    fn emitNum(self: *Shell, v: u64) void {
        var buf: [20]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch return;
        self.emit(s);
    }

    /// Execute one line. `listing` is the host-share filename snapshot the
    /// glue gathered (used by `type`/`which`); resolution itself is the
    /// candidate list so the 16-entry dir_list cap cannot hide an image.
    pub fn execute(self: *Shell, line: []const u8, listing: []const []const u8) Action {
        self.out.len = 0;
        const expanded = expandVars(line, &self.expand_buf, &self.env, self.last_status);
        var tk = tokenize(expanded, &self.scratch);
        if (tk.too_many) {
            self.emitLine("sh: too many arguments");
            self.last_status = 2;
            return .print;
        }
        if (tk.count == 0) return .none;
        var argv = tk.argv[0..tk.count];

        // Alias expansion in command position (one level, bounded). `tk2`
        // lives to the end of this call so the argv slices stay valid.
        var tk2: TokenizeResult = undefined;
        if (self.aliases.get(argv[0])) |val| {
            var joined: [line_max * 2]u8 = undefined;
            var jl: usize = 0;
            const vl = @min(val.len, joined.len);
            @memcpy(joined[0..vl], val[0..vl]);
            jl = vl;
            for (argv[1..]) |a| {
                if (jl < joined.len) {
                    joined[jl] = ' ';
                    jl += 1;
                }
                const al = @min(a.len, joined.len - jl);
                @memcpy(joined[jl..][0..al], a[0..al]);
                jl += al;
            }
            tk2 = tokenize(joined[0..jl], &self.scratch);
            if (tk2.count == 0) return .none;
            argv = tk2.argv[0..tk2.count];
        }

        if (classify(argv[0])) |b| return self.runBuiltin(b, argv, listing);
        return runExternal(argv[0]);
    }

    fn runExternal(verb: []const u8) Action {
        var req = RunRequest{};
        req.count = candidates(verb, &req.candidates);
        // `verb` may have been an alias-expanded slice into scratch; the
        // request carries owned copies only.
        return .{ .run = req };
    }

    fn runBuiltin(self: *Shell, b: Builtin, argv: []const []const u8, listing: []const []const u8) Action {
        switch (b) {
            .echo => {
                var first = true;
                for (argv[1..]) |a| {
                    if (!first) self.emit(" ");
                    first = false;
                    self.emit(a);
                }
                self.emitLine("");
                self.last_status = 0;
                return .print;
            },
            .pwd => {
                self.emitLine(self.cwd.slice());
                self.last_status = 0;
                return .print;
            },
            .cd => {
                const target = if (argv.len >= 2) argv[1] else "/";
                var nb: [cwd_max]u8 = undefined;
                const np = normalizePath(self.cwd.slice(), target, &nb);
                self.cwd.set(np);
                _ = self.env.setExported("PWD", self.cwd.slice(), true);
                self.last_status = 0;
                return .none;
            },
            .exit => {
                var status: u8 = self.last_status;
                if (argv.len >= 2) {
                    status = std.fmt.parseInt(u8, argv[1], 10) catch self.last_status;
                }
                return .{ .exit = status };
            },
            .env, .printenv, .set, .export_ => {
                // `set`/`export` with no argument list (that is the M19
                // shape); a NAME=VALUE argument mutates the table.
                if (argv.len >= 2 and (b == .set or b == .export_)) {
                    const arg = argv[1];
                    const eq = std.mem.indexOfScalar(u8, arg, '=') orelse arg.len;
                    const name = arg[0..eq];
                    const val = if (eq < arg.len) arg[eq + 1 ..] else "";
                    const exported = b == .export_;
                    if (!self.env.setExported(name, val, exported)) {
                        self.emitLine("sh: env table full");
                        self.last_status = 1;
                        return .print;
                    }
                    self.last_status = 0;
                    return .none;
                }
                for (self.env.entries[0..self.env.count]) |*e| {
                    self.emit(e.name.slice());
                    self.emit("=");
                    self.emitLine(e.val.slice());
                }
                self.last_status = 0;
                return .print;
            },
            .unset => {
                if (argv.len < 2) {
                    self.emitLine("unset: usage: unset VAR");
                    self.last_status = 1;
                } else {
                    _ = self.env.unset(argv[1]);
                    self.last_status = 0;
                }
                return .print;
            },
            .alias => {
                if (argv.len < 2) {
                    for (self.aliases.names[0..self.aliases.count], 0..) |*n, i| {
                        self.emit(n.slice());
                        self.emit("=");
                        self.emitLine(self.aliases.vals[i].slice());
                    }
                    self.last_status = 0;
                    return .print;
                }
                const arg = argv[1];
                const eq = std.mem.indexOfScalar(u8, arg, '=') orelse arg.len;
                if (eq == 0 or eq >= arg.len) {
                    self.emitLine("alias: usage: alias NAME=VALUE");
                    self.last_status = 1;
                    return .print;
                }
                var valbuf: [env_val_max]u8 = undefined;
                var vp: usize = 0;
                const seed = arg[eq + 1 ..];
                const sn = @min(seed.len, valbuf.len);
                @memcpy(valbuf[0..sn], seed[0..sn]);
                vp = sn;
                for (argv[2..]) |a| {
                    if (vp < valbuf.len) {
                        valbuf[vp] = ' ';
                        vp += 1;
                    }
                    const an = @min(a.len, valbuf.len - vp);
                    @memcpy(valbuf[vp..][0..an], a[0..an]);
                    vp += an;
                }
                _ = self.aliases.set(arg[0..eq], valbuf[0..vp]);
                self.emitLine("alias: ok");
                self.last_status = 0;
                return .print;
            },
            .unalias => {
                if (argv.len < 2) {
                    self.emitLine("unalias: usage: unalias NAME");
                    self.last_status = 1;
                } else if (!self.aliases.unset(argv[1])) {
                    self.emit("unalias: ");
                    self.emit(argv[1]);
                    self.emitLine(": no such alias");
                    self.last_status = 1;
                } else {
                    self.last_status = 0;
                }
                return .print;
            },
            .history => {
                const count = self.history.count();
                var i: usize = 0;
                while (i < count) : (i += 1) {
                    const entry = self.history.entry(i) orelse continue;
                    self.emit("  ");
                    self.emitNum(@intCast(count - i));
                    self.emit("  ");
                    self.emitLine(entry);
                }
                self.last_status = 0;
                return .print;
            },
            .prompt => {
                if (argv.len < 2) {
                    self.emitLine("prompt: usage: prompt NEW_PROMPT");
                    self.last_status = 1;
                } else {
                    self.prompt.set(argv[1]);
                    self.last_status = 0;
                }
                return .print;
            },
            .type_, .which => {
                if (argv.len < 2) {
                    self.emitLine("type: usage: type NAME");
                    self.last_status = 1;
                    return .print;
                }
                const name = argv[1];
                if (classify(name)) |_| {
                    self.emit(name);
                    self.emitLine(": shell builtin");
                    self.last_status = 0;
                    return .print;
                }
                var cands: [max_candidates]Program = undefined;
                const n = candidates(name, &cands);
                const first = if (n > 0) cands[0].slice() else name;
                var present = false;
                for (listing) |entry| {
                    if (std.mem.eql(u8, entry, first)) present = true;
                }
                self.emit(name);
                self.emit(": ");
                self.emit(first);
                self.emitLine(if (present) " (present)" else " (external)");
                self.last_status = 0;
                return .print;
            },
            .true_ => {
                self.last_status = 0;
                return .none;
            },
            .false_ => {
                self.last_status = 1;
                return .none;
            },
            .help => {
                self.emitLine("builtins: echo pwd cd exit env set unset export printenv alias unalias history prompt type which true false help source jobs fg");
                self.last_status = 0;
                return .print;
            },
            .source => {
                if (argv.len < 2) {
                    self.emitLine("source: usage: source FILE");
                    self.last_status = 1;
                    return .print;
                }
                var req = SourceRequest{};
                req.path.set(argv[1]);
                return .{ .source = req };
            },
            .jobs => {
                self.emitLine("jobs: no background jobs");
                self.last_status = 0;
                return .print;
            },
            .fg => {
                self.emitLine("fg: no background jobs");
                self.last_status = 1;
                return .print;
            },
        }
    }
};

// ---------------------------------------------------------------------------
// Host tests (pure; no syscalls)
// ---------------------------------------------------------------------------

test "shell: tokenize quoted/joined/escaped arguments" {
    var scratch: [256]u8 = undefined;
    const r1 = tokenize("echo \"elephant business\"", &scratch);
    try std.testing.expectEqual(@as(usize, 2), r1.count);
    try std.testing.expectEqualStrings("elephant business", r1.argv[1]);
    const r2 = tokenize("echo ab\"cd ef\"gh", &scratch);
    try std.testing.expectEqualStrings("abcd efgh", r2.argv[1]);
    const r3 = tokenize("echo a\\ b", &scratch);
    try std.testing.expectEqualStrings("a b", r3.argv[1]);
    const r4 = tokenize("echo 'a;b|c'", &scratch);
    try std.testing.expectEqualStrings("a;b|c", r4.argv[1]);
    const r5 = tokenize("echo 'unterminated", &scratch);
    try std.testing.expect(r5.unbalanced_quote);
}

test "shell: tokenize collapses whitespace and bounds tokens" {
    var scratch: [256]u8 = undefined;
    const r = tokenize("  echo   a    b  ", &scratch);
    try std.testing.expectEqual(@as(usize, 3), r.count);
    try std.testing.expectEqualStrings("b", r.argv[2]);
    var line: [512]u8 = undefined;
    var n: usize = 0;
    var t: usize = 0;
    while (t < max_args + 2) : (t += 1) {
        if (t > 0) {
            line[n] = ' ';
            n += 1;
        }
        line[n] = 'a';
        n += 1;
    }
    const r2 = tokenize(line[0..n], &scratch);
    try std.testing.expect(r2.too_many);
}

test "shell: expandVars substitutes $VAR, ${VAR}, $? and honors quoting" {
    var env = Env{};
    _ = env.set("HOME", "/data");
    _ = env.set("X", "42");
    var out: [128]u8 = undefined;
    try std.testing.expectEqualStrings("/data/x", expandVars("$HOME/x", &out, &env, 0));
    try std.testing.expectEqualStrings("42!", expandVars("${X}!", &out, &env, 0));
    try std.testing.expectEqualStrings("7", expandVars("$?", &out, &env, 7));
    // Single quotes protect; backslash passes the pair through to tokenize.
    try std.testing.expectEqualStrings("'$HOME'", expandVars("'$HOME'", &out, &env, 0));
    try std.testing.expectEqualStrings("\\$HOME", expandVars("\\$HOME", &out, &env, 0));
    // Unknown variables expand to empty.
    try std.testing.expectEqualStrings("", expandVars("$NOPE", &out, &env, 0));
}

test "shell: environment table set/get/unset/export and bounds" {
    var env = Env{};
    _ = env.set("A", "1");
    _ = env.set("B", "2");
    try std.testing.expectEqualStrings("1", env.get("A").?);
    _ = env.set("A", "11");
    try std.testing.expectEqualStrings("11", env.get("A").?);
    try std.testing.expect(env.unset("A"));
    try std.testing.expect(env.get("A") == null);
    try std.testing.expect(!env.unset("A"));
    _ = env.setExported("E", "v", true);
    for (env.entries[0..env.count]) |*e| {
        if (e.name.eql("E")) try std.testing.expect(e.exported);
    }
    var i: usize = 0;
    while (i < env_max) : (i += 1) {
        var nm: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&nm, "K{d}", .{i}) catch unreachable;
        _ = env.set(s, "x");
    }
    try std.testing.expectEqual(env_max, env.count);
    try std.testing.expect(!env.set("OVERFLOW", "x"));
}

test "shell: alias table set/get/unset" {
    var al = AliasTable{};
    try std.testing.expect(al.set("ll", "echo list"));
    try std.testing.expectEqualStrings("echo list", al.get("ll").?);
    try std.testing.expect(al.set("ll", "echo long"));
    try std.testing.expectEqualStrings("echo long", al.get("ll").?);
    try std.testing.expect(al.unset("ll"));
    try std.testing.expect(al.get("ll") == null);
    try std.testing.expect(!al.unset("nope"));
}

test "shell: normalizePath handles relative, absolute, dot and dotdot" {
    var out: [cwd_max]u8 = undefined;
    try std.testing.expectEqualStrings("/", normalizePath("/", "/", &out));
    try std.testing.expectEqualStrings("/data", normalizePath("/", "/data", &out));
    try std.testing.expectEqualStrings("/data/sub", normalizePath("/data", "sub", &out));
    try std.testing.expectEqualStrings("/data", normalizePath("/data/sub", "..", &out));
    try std.testing.expectEqualStrings("/", normalizePath("/data", "..", &out));
    try std.testing.expectEqualStrings("/a/c", normalizePath("/a/b", "../c", &out));
    try std.testing.expectEqualStrings("/a/b", normalizePath("/a/b", "./", &out));
    try std.testing.expectEqualStrings("/", normalizePath("/a/b", "../../..", &out));
}

test "shell: candidates order favors .BIN/.ELF then uppercase" {
    var out: [max_candidates]Program = undefined;
    const n = candidates("status43", &out);
    try std.testing.expectEqual(@as(usize, 6), n);
    try std.testing.expectEqualStrings("status43.BIN", out[0].slice());
    try std.testing.expectEqualStrings("status43.ELF", out[1].slice());
    try std.testing.expectEqualStrings("STATUS43.BIN", out[2].slice());
    try std.testing.expectEqualStrings("STATUS43.ELF", out[3].slice());
    try std.testing.expectEqualStrings("status43", out[4].slice());
    try std.testing.expectEqualStrings("STATUS43", out[5].slice());
    // An explicit image name is used as-is.
    const n2 = candidates("PS.BIN", &out);
    try std.testing.expectEqual(@as(usize, 1), n2);
    try std.testing.expectEqualStrings("PS.BIN", out[0].slice());
}

test "shell: classify maps the builtin boundary" {
    try std.testing.expectEqual(Builtin.cd, classify("cd").?);
    try std.testing.expectEqual(Builtin.export_, classify("export").?);
    try std.testing.expectEqual(Builtin.true_, classify("true").?);
    try std.testing.expectEqual(Builtin.source, classify(".").?);
    try std.testing.expect(classify("PS.BIN") == null);
    try std.testing.expect(classify("status43") == null);
}

fn execLine(s: *Shell, line: []const u8) Action {
    return s.execute(line, &.{});
}

test "shell: echo joins arguments and sets success" {
    var s = Shell.init();
    const a = execLine(&s, "echo hello world");
    try std.testing.expect(a == .print);
    try std.testing.expectEqualStrings("hello world\n", s.outSlice());
    try std.testing.expectEqual(@as(u8, 0), s.last_status);
}

test "shell: pwd/cd track the shell-local cwd" {
    var s = Shell.init();
    _ = execLine(&s, "cd /data");
    const a = execLine(&s, "pwd");
    try std.testing.expect(a == .print);
    try std.testing.expectEqualStrings("/data\n", s.outSlice());
    _ = execLine(&s, "cd ..");
    _ = execLine(&s, "pwd");
    try std.testing.expectEqualStrings("/\n", s.outSlice());
    // PWD is exported for children.
    try std.testing.expectEqualStrings("/", s.env.get("PWD").?);
}

test "shell: env/set/unset/export/printenv mutate and list" {
    var s = Shell.init();
    _ = execLine(&s, "set FOO=bar");
    try std.testing.expectEqualStrings("bar", s.env.get("FOO").?);
    _ = execLine(&s, "export BAZ=qux");
    try std.testing.expectEqualStrings("qux", s.env.get("BAZ").?);
    _ = execLine(&s, "env");
    const listed = s.outSlice();
    try std.testing.expect(std.mem.indexOf(u8, listed, "FOO=bar") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "BAZ=qux") != null);
    _ = execLine(&s, "unset FOO");
    try std.testing.expect(s.env.get("FOO") == null);
}

test "shell: alias stores, lists, expands and unaliases" {
    var s = Shell.init();
    _ = execLine(&s, "alias hi=echo hello");
    try std.testing.expectEqualStrings("alias: ok\n", s.outSlice());
    try std.testing.expectEqualStrings("echo hello", s.aliases.get("hi").?);
    // Command-position alias expansion.
    const b = execLine(&s, "hi world");
    try std.testing.expect(b == .print);
    try std.testing.expectEqualStrings("hello world\n", s.outSlice());
    _ = execLine(&s, "alias");
    try std.testing.expect(std.mem.indexOf(u8, s.outSlice(), "hi=echo hello") != null);
    _ = execLine(&s, "unalias hi");
    try std.testing.expect(s.aliases.get("hi") == null);
}

test "shell: true/false set the exit status and exit carries it" {
    var s = Shell.init();
    _ = execLine(&s, "false");
    try std.testing.expectEqual(@as(u8, 1), s.last_status);
    _ = execLine(&s, "true");
    try std.testing.expectEqual(@as(u8, 0), s.last_status);
    _ = execLine(&s, "false");
    const a = execLine(&s, "exit");
    try std.testing.expect(a == .exit);
    try std.testing.expectEqual(@as(u8, 1), a.exit);
    // `$?` sees the status.
    _ = execLine(&s, "echo $?");
    try std.testing.expectEqualStrings("1\n", s.outSlice());
}

test "shell: prompt/type/help report their builtin state" {
    var s = Shell.init();
    _ = execLine(&s, "prompt 'sh# '");
    try std.testing.expectEqualStrings("sh# ", s.promptSlice());
    _ = execLine(&s, "type cd");
    try std.testing.expect(std.mem.indexOf(u8, s.outSlice(), "shell builtin") != null);
    _ = execLine(&s, "help");
    try std.testing.expect(std.mem.indexOf(u8, s.outSlice(), "builtins:") != null);
}

const test_history_lines = [_][]const u8{ "second", "first" };

fn testHistoryCount(ctx: ?*anyopaque) usize {
    _ = ctx;
    return test_history_lines.len;
}

fn testHistoryEntry(ctx: ?*anyopaque, i: usize) ?[]const u8 {
    _ = ctx;
    if (i >= test_history_lines.len) return null;
    return test_history_lines[i];
}

test "shell: history reads the injected editor view newest-first" {
    var s = Shell.init();
    s.history = .{ .count_fn = testHistoryCount, .entry_fn = testHistoryEntry };
    _ = execLine(&s, "history");
    try std.testing.expect(std.mem.indexOf(u8, s.outSlice(), "second") != null);
    try std.testing.expect(std.mem.indexOf(u8, s.outSlice(), "first") != null);
}

test "shell: external command returns an ordered run request" {
    var s = Shell.init();
    const a = execLine(&s, "status43");
    try std.testing.expect(a == .run);
    try std.testing.expectEqual(@as(usize, 6), a.run.count);
    try std.testing.expectEqualStrings("status43.BIN", a.run.at(0));
    try std.testing.expectEqualStrings("STATUS43.BIN", a.run.at(2));
}

test "shell: source returns the path to execute, jobs/fg are honest" {
    var s = Shell.init();
    const a = execLine(&s, "source /scripts/init.sh");
    try std.testing.expect(a == .source);
    try std.testing.expectEqualStrings("/scripts/init.sh", a.source.path.slice());
    _ = execLine(&s, "jobs");
    try std.testing.expect(std.mem.indexOf(u8, s.outSlice(), "no background jobs") != null);
}

test "shell: type consults the share listing when available" {
    var s = Shell.init();
    const listing = [_][]const u8{ "PS.BIN", "STATUS43.BIN" };
    const a = s.execute("type STATUS43.BIN", &listing);
    try std.testing.expect(a == .print);
    try std.testing.expect(std.mem.indexOf(u8, s.outSlice(), "(present)") != null);
    _ = s.execute("type NOPE.BIN", &listing);
    try std.testing.expect(std.mem.indexOf(u8, s.outSlice(), "(external)") != null);
}

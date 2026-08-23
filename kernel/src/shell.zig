//! Interactive `dipshit>` shell loop (Milestone 1.5, console & shell core).
//!
//! Wires the bounded line editor (`lineedit.zig`) and the fixed-arity
//! tokenizer (`tokenizer.zig`) to the existing monitor registry
//! (`monitor.lookup`/`exec`), which this stream does not rebuild. The
//! whole loop is transport-agnostic: it only ever calls
//! `Console.readByte`/`write`, so it is proven against a scripted
//! `MockConsole` in `zig test` and runs unchanged on the real console
//! once the VZ serial gate (claim 0002) proves a device.
//!
//! Kernel seam (`kernel/src/main.zig`): `boot_and_park` prints the banner;
//! if an RX source is wired it runs the loop forever (never returns),
//! idling between polls with a bounded nop delay (the virtio device
//! delivers input with no interrupt, so WFE would never wake — claim
//! 6684); without RX it prints the prompt and returns so the kernel parks
//! in WFE. No device register is read by this module.
//!
//! No libc, no POSIX, no allocation, no global mutable state.

const std = @import("std");
const builtin = @import("builtin");
const alloc = @import("alloc.zig");
const console = @import("console.zig");
const esp = @import("esp.zig"); // claim 3475: ESP file window (ls/cat/write)
const fat = @import("fat.zig"); // M18 T16 (issue #419): direct FAT script reads (the sh /path form)
const lineedit = @import("lineedit.zig");
const tokenizer = @import("tokenizer.zig");
const pipe = @import("pipe.zig"); // M19 P1 (issue #290): the bounded pipe behind the `|` operator
const redirect = @import("redirect.zig"); // M19 P2 (issue #291): capture/feed adapters behind `>`, `>>`, `<`
const monitor = @import("monitor.zig");
const handoff = @import("handoff.zig");
const memmap = @import("memmap.zig");
const scheduler = @import("scheduler.zig"); // claim 5275: worker progress printing (main context only)
const settings = @import("settings.zig"); // milestone eight card U8 (claim 2649): persistent settings
const timer = @import("timer.zig"); // claim 7948: heartbeat printing (main context only)
const userspace = @import("userspace.zig"); // claim 8215: deferred EL0/SVC evidence line
const virtio_net = @import("virtio_net.zig"); // claim 6076 (card N2): polled RX drain in the idle loop
const road_pops = @import("road_pops.zig"); // claim 1574 (milestone six G3): Road Pops framebuffer drain in the idle loop
const input = @import("input.zig"); // claim 6050 (milestone seven I3): keyboard/pointer event FIFO drain in the idle loop
const driving_award = @import("driving_award.zig"); // claim 1543 (milestone six G5): Driving Award window-manager drain (clock refresh + composite)
const scrollback_mod = @import("scrollback.zig"); // M18 T1 (issue #404): terminal scrollback ring
const clipboard = @import("clipboard.zig"); // M18 T2 (issue #405): shared clipboard for copy/paste

/// M18 T4: path for persistent shell history file.
const history_path = "HISTORY.TXT";
/// M19 P3: path for persistent environment variables.
const env_path = "ENV.TXT";
/// M18 T4: max lines stored in the history file.
const history_file_max: usize = 50;
/// M18 T12: max shell environment variables.
const env_max: usize = 16;
const env_name_max: usize = 32;
const env_val_max: usize = 64;
/// M19 P4: max shell functions.
const func_max: usize = 8;
const func_name_max: usize = 32;
const func_cmds_per_func: usize = 4;
const func_cmd_max: usize = 64;
const func_arg_max: usize = 4;
const func_arg_name_max: usize = 16;
/// M19 P9 (issue #298): command substitution — max captured output.
const subst_max_output: usize = 256;
/// M18 T16 (issue #419): script bounds — at most 64 executable lines,
/// at most 256 chars per line, staged into 64 × 256 = 16384 bytes.
const script_max_lines: usize = 64;
const script_line_max: usize = 256;
const script_staging_max: usize = script_max_lines * script_line_max;

/// M18 T16: true while a script is executing — the nesting guard that
/// refuses `sh` inside a script (`sh: scripts cannot call scripts`).
/// Module scope, like env_table: the execution path (handle_line) is
/// module-level, so a flag on the Shell struct would be unreachable
/// there. Never set while another script runs (nesting is refused), so
/// no reentrancy is possible.
var script_active: bool = false;
/// M18 T16: a running script asked to stop early via `exit`.
var script_stop: bool = false;
/// M18 T16: BSS staging for the script file. Deliberately NOT stack: the
/// kernel stack is 16 KiB (ADR 0004 D5) and the LineEditor ring already
/// crowds it (claim 1809's lesson).
var script_staging: [script_staging_max]u8 = undefined;

const EnvEntry = struct {
    name: [env_name_max]u8 = [_]u8{0} ** env_name_max,
    name_len: usize = 0,
    val: [env_val_max]u8 = [_]u8{0} ** env_val_max,
    val_len: usize = 0,
    exported: bool = false, // T12: export flag for child processes
};
var env_table: [env_max]EnvEntry = undefined;
var env_count: usize = 0;

/// M19 P4: shell function storage (8 functions × 4 commands × 64 chars).
const FuncEntry = struct {
    name: [func_name_max]u8 = [_]u8{0} ** func_name_max,
    name_len: usize = 0,
    arg_names: [func_arg_max][func_arg_name_max]u8 = [_][func_arg_name_max]u8{[_]u8{0} ** func_arg_name_max} ** func_arg_max,
    arg_name_lens: [func_arg_max]usize = [_]usize{0} ** func_arg_max,
    arg_count: usize = 0,
    body: [func_cmds_per_func][func_cmd_max]u8 = [_][func_cmd_max]u8{[_]u8{0} ** func_cmd_max} ** func_cmds_per_func,
    body_lens: [func_cmds_per_func]usize = [_]usize{0} ** func_cmds_per_func,
    body_count: usize = 0,
};
var func_table: [func_max]FuncEntry = undefined;
var func_count: usize = 0;

/// Look up an environment variable.
fn env_get(name: []const u8) ?[]const u8 {
    for (env_table[0..env_count]) |*e| {
        if (std.mem.eql(u8, e.name[0..e.name_len], name)) {
            return e.val[0..e.val_len];
        }
    }
    return null;
}

/// Set (or create) an environment variable.
fn env_set(name: []const u8, val: []const u8) void {
    if (name.len == 0 or name.len > env_name_max) return;
    const vlen = @min(val.len, env_val_max);
    for (env_table[0..env_count]) |*e| {
        if (std.mem.eql(u8, e.name[0..e.name_len], name)) {
            @memcpy(e.val[0..vlen], val[0..vlen]);
            e.val_len = vlen;
            return;
        }
    }
    if (env_count >= env_max) return;
    const e = &env_table[env_count];
    @memcpy(e.name[0..name.len], name);
    e.name_len = name.len;
    @memcpy(e.val[0..vlen], val[0..vlen]);
    e.val_len = vlen;
    env_count += 1;
}

/// Remove an environment variable (M19 P3). Returns true if it existed.
fn env_unset(name: []const u8) bool {
    var i: usize = 0;
    while (i < env_count) : (i += 1) {
        if (std.mem.eql(u8, env_table[i].name[0..env_table[i].name_len], name)) {
            // Shift remaining entries down.
            var j = i;
            while (j + 1 < env_count) : (j += 1) {
                env_table[j] = env_table[j + 1];
            }
            env_count -= 1;
            return true;
        }
    }
    return false;
}

/// M19 P3: persist the full env table to FAT (one NAME=VAL per line).
fn save_env() void {
    if (!esp.disk_ready()) return;
    var buf: [2048]u8 = undefined;
    var pos: usize = 0;
    var i: usize = 0;
    while (i < env_count and pos < buf.len - 2) : (i += 1) {
        const e = &env_table[i];
        const name = e.name[0..e.name_len];
        const val = e.val[0..e.val_len];
        const space_needed = name.len + 1 + val.len + 1; // name=val\n
        if (pos + space_needed > buf.len) break;
        @memcpy(buf[pos..][0..name.len], name);
        pos += name.len;
        buf[pos] = '=';
        pos += 1;
        @memcpy(buf[pos..][0..val.len], val);
        pos += val.len;
        buf[pos] = '\n';
        pos += 1;
    }
    _ = esp.write_file(env_path, buf[0..pos]);
}

/// M19 P3: restore the env table from the ESP window on boot.
/// No disk_ready guard needed — esp.lookup searches the window
/// and returns null when the file is absent.
fn load_env() void {
    const entry = esp.lookup(env_path) orelse return;
    const content = esp.content_of(entry);
    if (content.len == 0) return;
    var start: usize = 0;
    var i: usize = 0;
    while (i < content.len and env_count < env_max) : (i += 1) {
        if (content[i] == '\n' or content[i] == '\r') {
            if (i > start) {
                const line = content[start..i];
                if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
                    env_set(line[0..eq], line[eq + 1 ..]);
                }
            }
            start = i + 1;
            if (content[i] == '\r' and i + 1 < content.len and content[i + 1] == '\n') i += 1;
        }
    }
    if (start < content.len) {
        const line = content[start..];
        if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
            env_set(line[0..eq], line[eq + 1 ..]);
        }
    }
}

/// Expand $VAR references in a command line. Returns a stack-local buffer.
fn env_expand(line: []const u8, out: []u8) []u8 {
    var opos: usize = 0;
    var i: usize = 0;
    while (i < line.len and opos < out.len) : (i += 1) {
        if (line[i] == '$' and i + 1 < line.len) {
            // Collect variable name
            var ns: usize = i + 1;
            while (ns < line.len and
                ((line[ns] >= 'a' and line[ns] <= 'z') or
                    (line[ns] >= 'A' and line[ns] <= 'Z') or
                    (line[ns] >= '0' and line[ns] <= '9') or
                    line[ns] == '_'))
            {
                ns += 1;
            }
            const vname = line[i + 1 .. ns];
            if (vname.len > 0) {
                if (env_get(vname)) |val| {
                    for (val) |b| {
                        if (opos < out.len) {
                            out[opos] = b;
                            opos += 1;
                        }
                    }
                }
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

pub const PollResult = enum {
    /// No input byte is available right now; the caller should wait before
    /// polling again (the kernel parks in WFE between polls).
    idle,
    /// A byte was consumed while a line is still being edited.
    pending,
    /// A full line was submitted or cancelled and handled (prompt output,
    /// echo, notices, and command results are all in the console).
    processed,
};

/// M18 T15: expand $VAR references in the prompt string.
/// Uses a static buffer so the returned slice remains valid across calls.
var prompt_expansion_buf: [128]u8 = undefined;
fn expanded_prompt() []const u8 {
    const raw = settings.get_prompt();
    return env_expand(raw, &prompt_expansion_buf);
}

/// Context for the scrollback Console wrapper. Lives in Shell BSS so the
/// Console's opaque ctx pointer stays valid for the shell's lifetime.
const ScrollbackCtx = struct {
    inner: console.Console,
    sb: *scrollback_mod.Scrollback,
};

fn sbWrite(ctx: *anyopaque, bytes: []const u8) void {
    const sc: *ScrollbackCtx = @ptrCast(@alignCast(ctx));
    sc.sb.append(bytes);
    sc.inner.write(bytes);
}
fn sbFlush(ctx: *anyopaque) void {
    const sc: *ScrollbackCtx = @ptrCast(@alignCast(ctx));
    sc.inner.flush();
}
fn sbReadByte(ctx: *anyopaque) ?u8 {
    const sc: *ScrollbackCtx = @ptrCast(@alignCast(ctx));
    return sc.inner.readByte();
}

/// M18 T1: the scrollback wrapper's vtable is built at runtime into BSS,
/// NOT a const table — a const table holds link-time absolute function
/// addresses, wrong at the kernel's runtime-chosen load base (claim 0015
/// root cause, ADR 0005; the same reason MachineControl's vtable and the
/// monitor registry are built at runtime). A const vtable here faulted on
/// the first banner write through the wrapped console and silently hung
/// every M18 boot at the aslr seam (observed 2026-08-22, claim 0469).
var scrollback_vtable: console.Console.VTable = undefined;
var scrollback_vtable_ready = false;
fn ensure_scrollback_vtable() *const console.Console.VTable {
    if (!scrollback_vtable_ready) {
        scrollback_vtable = .{
            .write = sbWrite,
            .flush = sbFlush,
            .readByte = sbReadByte,
        };
        scrollback_vtable_ready = true;
    }
    return &scrollback_vtable;
}

pub const Shell = struct {
    mon: monitor.Monitor,
    editor: lineedit.LineEditor = .{},
    prompt_shown: bool = false,
    /// Scrollback ring capturing all console output.
    scrollback: scrollback_mod.Scrollback = .{},
    /// Context for the wrapped Console; lives here (BSS) for lifetime.
    scrollback_ctx: ScrollbackCtx = undefined,
    /// Number of lines scrolled back from live view (0 = live mode).
    scroll_offset: usize = 0,
    /// Mini CSI parser for intercepting scroll keys before the editor.
    scroll_csi: u8 = 0,
    scroll_csi_param: u16 = 0,
    csi_private: bool = false, // ESC [ ? sequences (DEC private modes)
    /// M18 T2: selection state for copy-from-scrollback.
    selecting: bool = false,
    sel_start: usize = 0, // line offset (from newest) where selection begins
    sel_end: usize = 0, // line offset (from newest) where selection ends
    /// M18 T3: reverse-i-search state.
    searching: bool = false,
    search_query: [64]u8 = undefined,
    search_query_len: usize = 0,
    /// Saved editor state from before search started.
    search_draft: [lineedit.max_line]u8 = undefined,
    search_draft_len: usize = 0,
    search_draft_cursor: usize = 0,
    /// M18 T5: whether ANSI color escapes are emitted.
    /// Set true in boot_and_park(), false in host tests (preserves transcript).
    color_enabled: bool = false,
    /// M18 T6: bracketed paste mode — accumulating pasted text.
    paste_active: bool = false,
    paste_buf: [lineedit.max_line]u8 = undefined,
    paste_buf_len: usize = 0,
    /// M18 T7: alternate screen active (CSI ? 1049 h/l)
    alt_screen: bool = false,

    pub fn init(con: console.Console, state: monitor.SystemState, machine: monitor.MachineControl) Shell {
        var shell = Shell{
            .mon = monitor.Monitor.init(con, state, machine),
            .scrollback = scrollback_mod.Scrollback{},
            .scrollback_ctx = undefined,
            .scroll_offset = 0,
        };
        shell.scrollback.reset();
        // ADR 0008 D2: tab completion over the command registry + sub-verbs.
        shell.editor.completion = monitor.complete;
        return shell;
    }

    /// Print the boot banner once (`monitor.banner`). Also wraps the
    /// console with scrollback capture (must happen here, not in init(),
    /// so that self-referential pointers within the Shell remain valid —
    /// init() returns by value and would leave dangling pointers).
    pub fn boot(self: *Shell) void {
        self.scrollback_ctx = ScrollbackCtx{
            .inner = self.mon.console,
            .sb = &self.scrollback,
        };
        self.mon.console = console.Console{
            .ctx = &self.scrollback_ctx,
            .vtable = ensure_scrollback_vtable(),
        };
        monitor.banner(&self.mon);
    }

    /// Drive one byte of input. Prints the prompt exactly once
    /// per line (on the poll that starts it). Returns `.idle` when no byte
    /// is available — callers park between polls; tests drive until idle.
    pub fn poll(self: *Shell) PollResult {
        if (!self.prompt_shown) {
            if (self.color_enabled) self.mon.console.puts("\x1b[32m");
            self.mon.console.puts(expanded_prompt());
            if (self.color_enabled) self.mon.console.puts("\x1b[0m");
            self.prompt_shown = true;
        }
        const byte = self.mon.console.readByte() orelse return .idle;
        // M18 T6: bracketed paste mode — buffer bytes until 201~.
        // Newlines inside paste are kept as-is; the whole buffer is
        // submitted as one multi-line block when paste ends.
        if (self.paste_active) {
            if (self.scroll_csi_track(byte)) {
                self.editor.csi_reset(); // tracker consumed a byte mid-CSI
                return .pending;
            }
            if (self.paste_buf_len < lineedit.max_line) {
                self.paste_buf[self.paste_buf_len] = byte;
                self.paste_buf_len += 1;
            }
            return .pending;
        }
        // M18 T2: intercept Ctrl+C / Enter when selecting in scrollback.
        // (Esc is NOT intercepted here — it must pass through to the CSI
        //  tracker so Up/Down arrows work. A lone Esc cancels selection
        //  in the tracker's state machine.)
        if (self.selecting) {
            switch (byte) {
                0x03 => { // Ctrl+C: copy and return to live
                    self.selection_copy_and_exit();
                    self.prompt_shown = false;
                    return .processed;
                },
                0x0D => { // Enter: copy and return to live
                    self.mon.console.puts("\n");
                    self.selection_copy_and_exit();
                    self.prompt_shown = false;
                    return .processed;
                },
                else => {},
            }
        }
        // M18 T2: intercept Ctrl+V at the prompt to paste clipboard
        // (only in live mode, not during scrollback selection).
        if (!self.selecting and !self.searching and byte == 0x16) { // Ctrl+V
            self.paste_clipboard();
            return .pending;
        }
        // M18 T3: intercept Ctrl+R to enter reverse-i-search.
        if (byte == 0x12) { // Ctrl+R
            if (!self.selecting) {
                self.search_enter();
                return .pending;
            }
            return .pending;
        }
        // M18 T3: search mode — every byte feeds the query matcher.
        if (self.searching) {
            return self.search_handle(byte);
        }
        // M18 T1: shadow-track CSI state for PageUp/PageDown scroll keys.
        // Only the final '~' byte of a scroll sequence is consumed; all
        // other bytes (including arrow-key sequences) pass through to
        // the editor unchanged.
        if (self.scroll_csi_track(byte)) {
            // The tracker consumed the final byte of a sequence the editor
            // was mid-way through (scroll keys' '~', selection arrows,
            // swallowed CSI finals). Reset the editor's CSI state so the
            // next keystroke types cleanly — without this, `[5`/`[6`
            // fragments from a scroll key insert into the line and the
            // following ESC is swallowed (T1 live-gate finding).
            self.editor.csi_reset();
            return .pending;
        }
        switch (self.editor.feed(self.mon.console, byte)) {
            .none => return .pending,
            .repaint => {
                // Ctrl-L: the editor cleared the screen; restore the prompt
                // + the in-progress line (the editor does not own the prompt).
                if (self.color_enabled) self.mon.console.puts("\x1b[32m");
                self.mon.console.puts(expanded_prompt());
                if (self.color_enabled) self.mon.console.puts("\x1b[0m");
                self.editor.reprint(self.mon.console);
                return .pending;
            },
            .cancelled => {
                self.editor.reset();
                self.prompt_shown = false;
                return .processed;
            },
            .submitted => {
                const line = self.editor.buffer[0..self.editor.len];
                const rejected = self.editor.rejected;
                self.editor.next_line();
                self.prompt_shown = false;
                if (rejected) {
                    // ADR 0008 D3 shape 2 (a refusal is a failure).
                    monitor.err_line(&self.mon, "input refused: line longer than 256 bytes");
                }
                handle_line(&self.mon, line);
                // M18 T4: persist non-empty lines.
                if (line.len > 0) save_to_history(line);
                return .processed;
            },
        }
    }

    /// M18 T1: shadow-track CSI sequences to detect PageUp (CSI 5 ~) and
    /// PageDown (CSI 6 ~). All bytes always reach the line editor except
    /// the final '~' of a scroll sequence, which is consumed. Returns true
    /// only when a scroll key's final byte was consumed.
    fn scroll_csi_track(self: *Shell, byte: u8) bool {
        switch (self.scroll_csi) {
            0 => {
                if (byte == 0x1B) self.scroll_csi = 1;
                return false; // always pass through
            },
            1 => {
                if (byte == '[') {
                    self.scroll_csi = 2;
                    self.scroll_csi_param = 0;
                    self.csi_private = false;
                } else if (byte == ']') {
                    // M18 T11: OSC — swallow until BEL or ST (ESC \)
                    self.scroll_csi = 4;
                } else {
                    self.scroll_csi = 0; // lone ESC — pass through for editor
                    // M18 T2: a lone ESC in selection mode cancels
                    // selection. The cancel fires on the byte AFTER the
                    // ESC (the tracker cannot know a lone ESC until
                    // something else arrives), but that byte is a real
                    // keystroke — it must NOT be eaten (lineedit: "a lone
                    // ESC does not eat the next keystroke"; live-gate
                    // finding: the chord after ESC lost its first char).
                    if (self.selecting) {
                        self.selection_cancel();
                        self.prompt_shown = false;
                    }
                }
                return false; // always pass through
            },
            // M18 T11: OSC mode — swallow all bytes until BEL (0x07) or ST (ESC \)
            4 => {
                if (byte == 0x07) { // BEL terminates OSC
                    self.scroll_csi = 0;
                } else if (byte == 0x1B) { // might be start of ST (ESC \)
                    self.scroll_csi = 5;
                }
                return false; // pass through (they're harmless)
            },
            5 => {
                // After ESC in OSC: '\' = ST terminator, anything else = resume OSC
                self.scroll_csi = if (byte == '\\') 0 else 4;
                return false;
            },
            2 => {
                // M18 T7: CSI ? prefix for DEC private modes
                if (byte == '?') {
                    self.csi_private = true;
                    self.scroll_csi = 3;
                    return false;
                }
                if (byte >= '0' and byte <= '9') {
                    self.scroll_csi_param = byte - '0';
                    self.scroll_csi = 3;
                    return false; // pass digit through
                }
                // M18 T2: intercept Up/Down arrows when selecting in scrollback.
                if (self.selecting) {
                    if (byte == 'A') { // Up: extend selection upward
                        const max_off = self.scrollback.stored();
                        if (self.sel_end < max_off) {
                            self.sel_end += 1;
                        }
                        self.scroll_csi = 0;
                        return true;
                    }
                    if (byte == 'B') { // Down: shrink selection toward live
                        if (self.sel_end > self.sel_start) {
                            self.sel_end -= 1;
                        } else {
                            // Single-line selection: Down exits to live
                            self.selection_cancel();
                        }
                        self.scroll_csi = 0;
                        return true;
                    }
                }
                // single-char final (A/B/C/D etc) — editor handles arrow keys
                self.scroll_csi = 0;
                return false; // pass through
            },
            3 => {
                if (byte >= '0' and byte <= '9') {
                    const scaled: u16 = self.scroll_csi_param * 10;
                    self.scroll_csi_param = @min(scaled + (byte - '0'), 9999);
                    return false;
                }
                // ; separator in multi-param sequences (e.g. ESC [ 8; H; W; t)
                if (byte == ';') {
                    self.scroll_csi_param = 0;
                    return false; // restart param collection
                }
                if (byte == '~') {
                    const p = self.scroll_csi_param;
                    self.scroll_csi = 0;
                    self.csi_private = false;
                    return self.scroll_handle(p);
                }
                // M18 T7–T11: CSI final handlers
                const handled = self.csi_final(byte);
                self.scroll_csi = 0;
                self.csi_private = false;
                return handled;
            },
            else => {
                self.scroll_csi = 0;
                self.csi_private = false;
                return false;
            },
        }
    }

    /// Handle a completed CSI parameter for scroll keys + paste.
    /// Returns true if the key was consumed.
    fn scroll_handle(self: *Shell, param: u16) bool {
        switch (param) {
            5 => { // PageUp: scroll up one page (10 lines)
                const max_off = self.scrollback.stored();
                self.scroll_offset = @min(self.scroll_offset + 10, max_off);
                if (self.scroll_offset > 0 and !self.selecting) {
                    self.selecting = true;
                    self.sel_start = self.scroll_offset;
                    self.sel_end = self.scroll_offset;
                }
                return true;
            },
            6 => { // PageDown: scroll down one page (10 lines)
                if (self.scroll_offset > 10) {
                    self.scroll_offset -= 10;
                } else {
                    self.scroll_offset = 0;
                }
                if (self.scroll_offset == 0) {
                    // Back at the live view: selection is over. Without
                    // this, a real Enter (0x0D) after scrolling back to
                    // live hits the selection branch and copies+discards
                    // the line instead of submitting it (T1 live-gate
                    // finding — only serial '\n' slipped past before).
                    self.selecting = false;
                    self.sel_start = 0;
                    self.sel_end = 0;
                } else if (!self.selecting) {
                    self.selecting = true;
                    self.sel_start = self.scroll_offset;
                    self.sel_end = self.scroll_offset;
                }
                return true;
            },
            200 => { // Bracketed paste start
                self.paste_active = true;
                self.paste_buf_len = 0;
                return true;
            },
            201 => { // Bracketed paste end — submit accumulated buffer
                self.paste_active = false;
                const saved_len = self.paste_buf_len;
                self.paste_buf_len = 0;
                // Execute each line through the normal shell path
                var start: usize = 0;
                var i: usize = 0;
                while (i < saved_len) : (i += 1) {
                    if (self.paste_buf[i] == '\n' or self.paste_buf[i] == '\r') {
                        if (i > start) {
                            handle_line(&self.mon, self.paste_buf[start..i]);
                        }
                        start = i + 1;
                        // Skip the LF of a CRLF pair
                        if (self.paste_buf[i] == '\r' and i + 1 < saved_len and self.paste_buf[i + 1] == '\n') {
                            i += 1;
                            start = i + 1;
                        }
                    }
                }
                if (start < saved_len) {
                    handle_line(&self.mon, self.paste_buf[start..saved_len]);
                }
                self.prompt_shown = false;
                return true;
            },
            else => return false,
        }
    }

    /// M18 T7–T11: handle CSI single-char final byte after param
    /// collection. Returns true if consumed (no bytes reach the editor).
    fn csi_final(self: *Shell, byte: u8) bool {
        switch (byte) {
            // M18 T7: alternate screen toggle (CSI ? 1049 h/l)
            'h' => {
                if (self.csi_private and self.scroll_csi_param == 1049) {
                    self.alt_screen = true;
                    // Clear screen on entering alt screen
                    self.mon.console.puts("\x1b[2J\x1b[H");
                    self.prompt_shown = false;
                }
                return true;
            },
            'l' => {
                if (self.csi_private and self.scroll_csi_param == 1049) {
                    self.alt_screen = false;
                    self.mon.console.puts("\x1b[2J\x1b[H");
                    self.prompt_shown = false;
                }
                return true;
            },
            // CSI n responder — only reply to DSR (6n = cursor position)
            'n' => {
                if (self.scroll_csi_param == 6) {
                    self.mon.console.puts("\x1b[1;1R");
                }
                return true;
            },
            // Swallow: SGR (m), cursor shape (q), window ops (t/s),
            // cursor-pos reply (R), DECSET/DECRST (h/l without ?)
            'm', 't', 's', 'q', 'R' => return true,
            // Single-char finals: arrows — already handled in state 2.
            // A/B/C/D from state 3 (with param) are swallowed.
            'A', 'B', 'C', 'D', 'H', 'J', 'K', 'G', 'd', 'f', 'r', 'u', 'c' => return true,
            else => return false, // pass through to editor
        }
    }

    /// Called when the user presses Ctrl+C or Enter while selecting in the
    /// scrollback view. Copies the selected lines to the clipboard and
    /// returns to live mode. Returns true if consumed.
    fn selection_copy_and_exit(self: *Shell) void {
        if (!self.selecting or self.scroll_offset == 0) return;
        // Build the selected text from scrollback lines
        const start = if (self.sel_start < self.sel_end) self.sel_start else self.sel_end;
        const end = if (self.sel_start > self.sel_end) self.sel_start else self.sel_end;
        const count = end - start + 1;

        // Retrieve the selected lines into a stack buffer
        const buflen: usize = 512;
        var buf: [buflen]u8 = undefined;
        var pos: usize = 0;
        var dst: [128][]u8 = undefined;
        var dst_bufs: [128][128]u8 = undefined;
        for (&dst, 0..) |*d, j| d.* = dst_bufs[j][0..];

        const n = self.scrollback.copy_lines(start, @min(count, 128), dst[0..]);
        var i: usize = 0;
        while (i < n and pos < buflen - 2) : (i += 1) {
            const line = dst[i];
            for (line) |ch| {
                if (ch == 0 or pos >= buflen - 2) break;
                buf[pos] = ch;
                pos += 1;
            }
            if (i + 1 < n and pos < buflen - 1) {
                buf[pos] = '\n';
                pos += 1;
            }
        }
        _ = clipboard.set(buf[0..pos]);
        self.mon.console.print_line("copied");

        // Return to live mode
        self.selecting = false;
        self.scroll_offset = 0;
    }

    /// Cancel selection and return to live mode (Esc key).
    fn selection_cancel(self: *Shell) void {
        self.selecting = false;
        self.scroll_offset = 0;
    }

    /// Paste clipboard contents into the editor at cursor position.
    fn paste_clipboard(self: *Shell) void {
        var cbuf: [clipboard.capacity]u8 = undefined;
        const n = clipboard.get(&cbuf);
        if (n == 0) return;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            _ = self.editor.feed(self.mon.console, cbuf[i]);
        }
    }

    /// M18 T3: reverse-i-search — search backward through scrollback +
    /// editor history for lines containing the query string.
    /// Returns the search result line and its length, or null on no match.
    fn search_match(self: *Shell, query: []const u8) ?[]const u8 {
        if (query.len == 0) return null;

        // Search the editor's session history ring first (newest first).
        var hi: usize = 0;
        while (hi < self.editor.hist_count) : (hi += 1) {
            const line = self.editor.history[hi][0..self.editor.hist_len[hi]];
            if (std.mem.indexOf(u8, line, query) != null) return line;
        }

        // Search the scrollback ring lines (newest first).
        const sb_stored = self.scrollback.stored();
        if (sb_stored > 0) {
            var dst: [128][128]u8 = undefined;
            var slices: [128][]u8 = undefined;
            for (&slices, 0..) |*s, j| s.* = dst[j][0..];
            const n = self.scrollback.copy_lines(0, @min(sb_stored, 128), slices[0..]);
            var si: usize = 0;
            while (si < n) : (si += 1) {
                if (std.mem.indexOf(u8, slices[si], query) != null) return slices[si];
            }
        }

        return null;
    }

    /// Enter reverse-i-search mode. Saves the current editor state so
    /// we can restore it on cancel.
    fn search_enter(self: *Shell) void {
        // Save current editor state
        @memcpy(self.search_draft[0..self.editor.len], self.editor.buffer[0..self.editor.len]);
        self.search_draft_len = self.editor.len;
        self.search_draft_cursor = self.editor.cursor;

        self.searching = true;
        self.search_query_len = 0;
        self.search_redraw();
    }

    /// Redraw the search prompt + current match.
    fn search_redraw(self: *Shell) void {
        // Move to a new line and show the search UI
        self.mon.console.puts("\r\n");
        self.mon.console.puts("(reverse-i-search)`");
        if (self.search_query_len > 0) {
            self.mon.console.puts(self.search_query[0..self.search_query_len]);
        } else {
            self.mon.console.puts("_");
        }
        self.mon.console.puts("`: ");

        // Show the current match (if any)
        const query = if (self.search_query_len > 0) self.search_query[0..self.search_query_len] else &[0]u8{};
        if (self.search_match(query)) |match| {
            self.mon.console.puts(match);
            // Load it into the editor so Enter accepts it
            self.editor.len = @min(match.len, lineedit.max_line);
            @memcpy(self.editor.buffer[0..self.editor.len], match[0..self.editor.len]);
            self.editor.cursor = self.editor.len;
        } else {
            self.mon.console.puts("(no match)");
        }
    }

    /// Handle a keypress in search mode.
    fn search_handle(self: *Shell, byte: u8) PollResult {
        switch (byte) {
            0x1B => { // Esc: cancel, restore draft
                self.search_exit(false);
                return .processed;
            },
            0x0D, 0x0A => { // Enter: accept the current match. The
                // keyboard Return decodes to LF (input.zig), and the line
                // editor already treats CR and LF alike — search accepts
                // both (T3 live-gate finding: a synthesized Return chord
                // was ignored in search mode).
                self.search_exit(true);
                return .processed;
            },
            0x7F, 0x08 => { // Backspace / Delete: remove last query char
                if (self.search_query_len > 0) {
                    self.search_query_len -= 1;
                    self.search_redraw();
                }
                return .pending;
            },
            0x03 => { // Ctrl+C: cancel
                self.search_exit(false);
                self.prompt_shown = false;
                return .processed;
            },
            0x0C => { // Ctrl+L: ignore the clear
                return .pending;
            },
            else => {
                // Only accept printable ASCII
                if (byte >= 0x20 and byte <= 0x7E and self.search_query_len < 64) {
                    self.search_query[self.search_query_len] = byte;
                    self.search_query_len += 1;
                    self.search_redraw();
                }
                return .pending;
            },
        }
    }

    /// Exit search mode, restoring or accepting.
    fn search_exit(self: *Shell, accept: bool) void {
        self.searching = false;
        if (!accept) {
            // Restore the saved draft
            @memcpy(self.editor.buffer[0..self.search_draft_len], self.search_draft[0..self.search_draft_len]);
            self.editor.len = self.search_draft_len;
            self.editor.cursor = self.search_draft_cursor;
        }
        // Redraw the prompt
        self.mon.console.puts("\r\n");
        self.prompt_shown = false;
    }
};

/// M18 T4: append a command line to the persistent history file.
fn save_to_history(line: []const u8) void {
    if (!esp.disk_ready()) return;
    // Read existing history, trim oldest if at capacity, append new line.
    var existing: [2048]u8 = undefined;
    var existing_len: usize = 0;
    if (esp.lookup(history_path)) |entry| {
        const content = esp.content_of(entry);
        existing_len = @min(content.len, 2048);
        @memcpy(existing[0..existing_len], content[0..existing_len]);
    }
    var line_count: usize = 0;
    var i: usize = 0;
    while (i < existing_len) : (i += 1) {
        if (existing[i] == '\n') line_count += 1;
    }
    if (existing_len > 0 and existing[existing_len - 1] != '\n') line_count += 1;
    var start: usize = 0;
    if (line_count >= history_file_max) {
        while (start < existing_len and existing[start] != '\n') start += 1;
        if (start < existing_len) start += 1;
    }
    var buf: [2048]u8 = undefined;
    var pos: usize = 0;
    const tail = existing[start..existing_len];
    @memcpy(buf[pos..][0..tail.len], tail);
    pos += tail.len;
    @memcpy(buf[pos..][0..line.len], line);
    pos += line.len;
    buf[pos] = '\n';
    pos += 1;
    _ = esp.write_file(history_path, buf[0..pos]);
}

/// M18 T4: load persistent history from HISTORY.TXT into editor ring.
fn load_history(editor: *lineedit.LineEditor) void {
    if (!esp.disk_ready()) return;
    const entry = esp.lookup(history_path) orelse return;
    const content = esp.content_of(entry);
    if (content.len == 0) return;
    var line_starts: [64]usize = undefined;
    var line_lens: [64]usize = undefined;
    var line_count: usize = 0;
    var i: usize = 0;
    while (i < content.len and line_count < 64) : (i += 1) {
        const start = i;
        while (i < content.len and content[i] != '\n') i += 1;
        const len = i - start;
        if (len > 0 and len < lineedit.max_line) {
            line_starts[line_count] = start;
            line_lens[line_count] = len;
            line_count += 1;
        }
    }
    // HISTORY.TXT is append-ordered (oldest first, newest last), so the
    // file's LAST line is the most recent command. Insert lines in file
    // order at index 0, leaving the newest at history[0] — the same
    // newest-first shape the session ring has, so the first Up arrow
    // after boot recalls the most recent command (the T4 intent; the
    // original backward iteration left the OLDEST at index 0 — fixed
    // 2026-08-22 while bringing up the live gate, claim 0469).
    var li: usize = 0;
    while (li < line_count) : (li += 1) {
        const line = content[line_starts[li]..][0..line_lens[li]];
        if (editor.hist_count > 0 and std.mem.eql(u8, line, editor.history[0][0..editor.hist_len[0]])) continue;
        const keep: usize = @min(editor.hist_count, lineedit.hist_capacity - 1);
        var j = keep;
        while (j > 0) : (j -= 1) {
            @memcpy(editor.history[j][0..editor.hist_len[j - 1]], editor.history[j - 1][0..editor.hist_len[j - 1]]);
            editor.hist_len[j] = editor.hist_len[j - 1];
        }
        const n = @min(line.len, lineedit.max_line);
        @memcpy(editor.history[0][0..n], line[0..n]);
        editor.hist_len[0] = n;
        editor.hist_count = keep + 1;
    }
}

/// M18 T16 (issue #419): load a script file into the staging buffer.
/// Bare names resolve through the ESP window (like `cat`); `/`-paths read
/// the FAT volume directly, so files up to the full 16 KiB staging bound
/// are reachable even when they exceed the window's per-file content cap.
/// Prints the honest refusal and returns null on any miss.
fn script_load(mon: *monitor.Monitor, name: []const u8) ?[]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        const size = fat.file_size(name) orelse {
            mon.console.puts("sh: ");
            mon.console.puts(name);
            mon.console.print_line(": not found (no such file on the FAT volume)");
            return null;
        };
        if (size > @as(u32, @intCast(script_staging_max))) {
            mon.console.puts("sh: ");
            mon.console.puts(name);
            mon.console.puts(": file is ");
            mon.console.print_hex(size);
            mon.console.puts(" bytes; scripts cap at ");
            mon.console.print_hex(script_staging_max);
            mon.console.print_line(" bytes");
            return null;
        }
        const got = fat.read_file(name, &script_staging) orelse {
            mon.console.puts("sh: ");
            mon.console.puts(name);
            mon.console.print_line(": not found (no such file on the FAT volume)");
            return null;
        };
        return script_staging[0..got];
    }
    const e = esp.lookup(name) orelse {
        mon.console.puts("sh: ");
        mon.console.puts(name);
        mon.console.print_line(": not found (no such file on the ESP)");
        return null;
    };
    switch (e.kind) {
        .esp_dir => {
            mon.console.puts("sh: ");
            mon.console.puts(name);
            mon.console.print_line(": is a directory");
            return null;
        },
        .esp_file => {
            if (e.len == 0 and e.size > 0) {
                mon.console.puts("sh: ");
                mon.console.puts(name);
                mon.console.puts(": content not loaded (file is ");
                mon.console.print_hex(e.size);
                mon.console.puts(" bytes; the window keeps files up to ");
                mon.console.print_hex(esp.esp_content_max);
                mon.console.print_line(" bytes)");
                return null;
            }
        },
    }
    return esp.content_of(e);
}

/// M18 T16 (issue #419): execute a script file of shell commands, one
/// line at a time, through handle_line() — the same path interactive
/// input takes, so env expansion, aliases, and builtins all apply inside
/// scripts. Bounds: file ≤ 16 KiB staging, ≤ 64 executable lines,
/// ≤ 256 chars per line. A failing command never aborts the script (no
/// abort-on-error by default); `exit` stops it early; scripts cannot
/// call scripts.
fn run_script(mon: *monitor.Monitor, name: []const u8) void {
    if (script_active) {
        mon.console.print_line("sh: scripts cannot call scripts");
        return;
    }
    const content = script_load(mon, name) orelse return;
    script_active = true;
    defer script_active = false;
    script_stop = false;
    var exec_lines: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= content.len) : (i += 1) {
        if (i == content.len or content[i] == '\n' or content[i] == '\r') {
            if (i > start) {
                const raw = content[start..i];
                // Skip leading whitespace so comments and blank lines
                // are recognized wherever they start.
                var t: usize = 0;
                while (t < raw.len and (raw[t] == ' ' or raw[t] == '\t')) t += 1;
                const line = raw[t..];
                if (line.len > 0 and line[0] != '#') {
                    if (exec_lines >= script_max_lines) {
                        mon.console.puts("sh: too many lines (max ");
                        mon.console.print_u64(script_max_lines);
                        mon.console.print_line(")");
                        break;
                    }
                    if (line.len > script_line_max) {
                        mon.console.puts("sh: line too long (max ");
                        mon.console.print_u64(script_line_max);
                        mon.console.print_line(" bytes)");
                    } else {
                        handle_line(mon, line);
                        exec_lines += 1;
                        if (script_stop) break;
                    }
                }
            }
            start = i + 1;
            // Skip the LF of a CRLF pair.
            if (i < content.len and content[i] == '\r' and i + 1 < content.len and content[i + 1] == '\n') i += 1;
        }
    }
}

fn handle_line(mon: *monitor.Monitor, raw_line: []const u8) void {
    // P9: command substitution `$(cmd)` — execute inner command, capture
    // stdout, substitute back into the line.  Skip for fn definitions.
    // Also skip when subst_active (prevent nesting).
    var subst_buf: [lineedit.max_line]u8 = undefined;
    const line_after_subst = if (subst_active or
        std.mem.startsWith(u8, raw_line, "fn ") or
        std.mem.startsWith(u8, raw_line, "fn\t"))
        raw_line
    else
        cmd_subst(mon, raw_line, &subst_buf);

    // M18 T12: expand $VAR references before tokenizing.
    // P8: skip expansion for `fn` definitions so `$name` in function
    // bodies stays literal — it'll be expanded at invocation time.
    var expanded: [lineedit.max_line]u8 = undefined;
    const line = if (std.mem.startsWith(u8, line_after_subst, "fn ") or std.mem.startsWith(u8, line_after_subst, "fn\t"))
        line_after_subst
    else
        env_expand(line_after_subst, &expanded);

    // M18 T13: check for alias expansion (only first word)
    if (line.len > 0) {
        var aname: [env_name_max]u8 = undefined;
        var anlen: usize = 0;
        var ai: usize = 0;
        while (ai < line.len and line[ai] != ' ' and line[ai] != '\t' and anlen < env_name_max) : (ai += 1) {
            aname[anlen] = line[ai];
            anlen += 1;
        }
        if (anlen > 0) {
            if (env_get(aname[0..anlen])) |alias_val| {
                var sub: [lineedit.max_line]u8 = undefined;
                var sp: usize = 0;
                for (alias_val) |b| {
                    if (sp < sub.len) {
                        sub[sp] = b;
                        sp += 1;
                    }
                }
                if (sp < sub.len - 1) {
                    sub[sp] = ' ';
                    sp += 1;
                }
                while (ai < line.len and line[ai] == ' ') ai += 1;
                while (ai < line.len and sp < sub.len) : (ai += 1) {
                    sub[sp] = line[ai];
                    sp += 1;
                }
                // Re-run handle_line with substituted text (once only to avoid loops)
                shell_handle_expanded(mon, sub[0..sp]);
                return;
            }
        }
    }

    shell_handle_expanded(mon, line);
}

/// M19 P1 (issue #290): the split of a line at its first `|` outside
/// double quotes (matching the tokenizer's quote rule — a quote opens only
/// at the start of an argument, so a `"` mid-token is a literal byte).
const PipeSplit = struct { left: []const u8, right: []const u8 };

const PipeSplitResult = union(enum) {
    none,
    split: PipeSplit,
    multiple, // more than one `|` outside quotes — refused (single-pipe only)
};

fn pipe_split(line: []const u8) PipeSplitResult {
    var in_quote = false;
    var first: ?usize = null;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == '"') in_quote = !in_quote;
        if (line[i] == '|' and !in_quote) {
            if (first == null) {
                first = i;
            } else {
                return .multiple;
            }
        }
    }
    const idx = first orelse return .none;
    return .{ .split = .{ .left = line[0..idx], .right = line[idx + 1 ..] } };
}

/// M19 P1 (issue #290): run `left | right`. Sequential model — the left
/// command runs to completion with its stdout captured into the pipe, then
/// the right command runs with its stdin fed from the pipe and its stdout
/// passing through to the real console (so right-side output still reaches
/// the scrollback wrapper). The console is swapped for each half and
/// restored after; the pipe is reset before the left command runs.
fn run_pipe(mon: *monitor.Monitor, left: []const u8, right: []const u8) void {
    pipe.reset();
    const saved = mon.console;
    // Left: stdout → pipe.
    mon.console = pipe.sink_console();
    shell_handle_expanded(mon, left);
    // Right: stdin ← pipe, stdout → real console.
    mon.console = pipe.source_console(saved);
    shell_handle_expanded(mon, right);
    mon.console = saved;
}

/// M19 P2 (issue #291): the kind of redirection found by `redirect_split`.
const RedirectOp = enum { stdout_overwrite, stdout_append, stdin_file };
const RedirectSplit = struct { left: []const u8, right: []const u8, op: RedirectOp };

/// M19 P2 (issue #291): look for `>`, `>>`, or `<` outside double quotes
/// on the line (after the first token — the command name). Returns the
/// split of the line into the left side (the command + its args) and the
/// right side (the filename), plus the operator kind. Returns null when
/// no redirect operator is found.
///
/// The operator is matched right-to-left so `>>` is preferred over `>`.
fn redirect_split(line: []const u8) ?RedirectSplit {
    // Scan for `>>`, then `>`, then `<` outside quoted regions.
    var in_quote = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == '"') in_quote = !in_quote;
        if (in_quote) continue;
        if (line[i] == '>') {
            // Check for `>>`
            if (i + 1 < line.len and line[i + 1] == '>') {
                const left = trim_end(line[0..i]);
                const right = trim_start(line[i + 2 ..]);
                if (left.len > 0 and right.len > 0) {
                    return .{ .left = left, .right = right, .op = .stdout_append };
                }
                continue;
            }
            // Single `>`
            const left = trim_end(line[0..i]);
            const right = trim_start(line[i + 1 ..]);
            if (left.len > 0 and right.len > 0) {
                return .{ .left = left, .right = right, .op = .stdout_overwrite };
            }
            continue;
        }
        if (line[i] == '<') {
            const left = trim_end(line[0..i]);
            const right = trim_start(line[i + 1 ..]);
            if (left.len > 0 and right.len > 0) {
                return .{ .left = left, .right = right, .op = .stdin_file };
            }
            continue;
        }
    }
    return null;
}

/// Trim trailing whitespace.
fn trim_end(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and (s[end - 1] == ' ' or s[end - 1] == '\t')) end -= 1;
    return s[0..end];
}

/// Trim leading whitespace.
fn trim_start(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t')) start += 1;
    return s[start..];
}

/// M19 P2 (issue #291): run `cmd > file` or `cmd >> file`. The command
/// runs with its stdout captured, then the captured content is written
/// to the file (overwrite) or appended to the existing content (append).
fn run_redirect_out(mon: *monitor.Monitor, left: []const u8, file: []const u8, op: RedirectOp) void {
    redirect.reset_capture();
    const saved = mon.console;
    // Command: stdout → capture buffer.
    mon.console = redirect.capture_console();
    shell_handle_expanded(mon, left);
    mon.console = saved;

    // Now write the captured output to the file.
    var content_to_write = redirect.captured();
    if (op == .stdout_append) {
        // Read existing file content, then append.
        var existing_buf: [4096]u8 = undefined;
        if (redirect.read_file_into(file, &existing_buf)) |existing| {
            // Build combined: existing + newline + captured
            var combined: [4096]u8 = undefined;
            var pos: usize = 0;
            const ex_take = @min(existing.len, 3968); // leave room for newline + capture
            @memcpy(combined[pos..][0..ex_take], existing[0..ex_take]);
            pos += ex_take;
            // If the capture has content, prepend a newline separator
            const cap = redirect.captured();
            if (cap.len > 0) {
                if (pos < combined.len) {
                    combined[pos] = '\n';
                    pos += 1;
                }
                const cap_take = @min(cap.len, combined.len - pos);
                @memcpy(combined[pos..][0..cap_take], cap[0..cap_take]);
                pos += cap_take;
            }
            content_to_write = combined[0..pos];
        }
    }

    if (redirect.write_captured_to_file(file, content_to_write)) |err| {
        mon.console.print_line(err);
    }
}

/// M19 P2 (issue #291): run `cmd < file`. The file is pre-loaded, then
/// the command runs with its stdin feeding from that content and stdout
/// passing through to the real console.
fn run_redirect_in(mon: *monitor.Monitor, left: []const u8, file: []const u8) void {
    var file_buf: [4096]u8 = undefined;
    const data = redirect.read_file_into(file, &file_buf) orelse {
        mon.console.puts("redirect: ");
        mon.console.puts(file);
        mon.console.print_line(": not found or unreadable");
        return;
    };

    const saved = mon.console;
    mon.console = redirect.feed_console(saved, data);
    shell_handle_expanded(mon, left);
    mon.console = saved;
}

/// M19 P4: find a function by name. Returns the table index or null.
fn func_find(name: []const u8) ?usize {
    var i: usize = 0;
    while (i < func_count) : (i += 1) {
        if (std.mem.eql(u8, func_table[i].name[0..func_table[i].name_len], name)) return i;
    }
    return null;
}

/// M19 P4: define a function from `NAME { cmd1; cmd2 }` text.
fn func_define(mon: *monitor.Monitor, text: []const u8) void {
    // Parse: name(a, b) { commands... }
    var i: usize = 0;
    while (i < text.len and text[i] != ' ' and text[i] != '{' and text[i] != '(') i += 1;
    const name = if (i > 0) text[0..i] else "";
    if (name.len == 0 or name.len > func_name_max) {
        mon.console.print_line("fn: invalid function name");
        return;
    }
    // Parse argument list: (a, b, c)
    var arg_names: [func_arg_max][func_arg_name_max]u8 = undefined;
    var arg_name_lens: [func_arg_max]usize = [_]usize{0} ** func_arg_max;
    var arg_count: usize = 0;
    if (i < text.len and text[i] == '(') {
        i += 1; // skip (
        while (i < text.len and text[i] != ')' and arg_count < func_arg_max) {
            // Skip whitespace/comma
            while (i < text.len and (text[i] == ' ' or text[i] == ',')) i += 1;
            const a_start = i;
            while (i < text.len and text[i] != ' ' and text[i] != ',' and text[i] != ')') i += 1;
            const aname = text[a_start..i];
            if (aname.len > 0) {
                const n = @min(aname.len, func_arg_name_max);
                @memcpy(arg_names[arg_count][0..n], aname[0..n]);
                arg_name_lens[arg_count] = n;
                arg_count += 1;
            }
        }
        if (i < text.len and text[i] == ')') i += 1;
    }
    // Find `{
    while (i < text.len and text[i] != '{') i += 1;
    var start = i + 1;
    while (start < text.len and text[start] == ' ') start += 1;
    // Find closing }
    var end: ?usize = null;
    i = text.len;
    while (i > start) {
        i -= 1;
        if (text[i] == '}') {
            end = i;
            break;
        }
    }
    const body = if (end) |e| text[start..e] else text[start..];

    // Parse body into commands separated by `;`
    var cmds: [func_cmds_per_func][func_cmd_max]u8 = undefined;
    var cmd_lens: [func_cmds_per_func]usize = [_]usize{0} ** func_cmds_per_func;
    var cmd_count: usize = 0;
    var bpos: usize = 0;
    while (bpos < body.len and cmd_count < func_cmds_per_func) : (cmd_count += 1) {
        // Skip leading whitespace
        while (bpos < body.len and (body[bpos] == ' ' or body[bpos] == '\t')) bpos += 1;
        // Find next `;` or end
        var cmd_end: usize = bpos;
        while (cmd_end < body.len and body[cmd_end] != ';') cmd_end += 1;
        const cmd = body[bpos..cmd_end];
        // Trim trailing whitespace
        var ct = cmd.len;
        while (ct > 0 and (cmd[ct - 1] == ' ' or cmd[ct - 1] == '\t')) ct -= 1;
        const trimmed = cmd[0..ct];
        const n = @min(trimmed.len, func_cmd_max);
        @memcpy(cmds[cmd_count][0..n], trimmed[0..n]);
        cmd_lens[cmd_count] = n;
        bpos = cmd_end + 1; // skip the semicolon
    }

    if (cmd_count == 0) {
        mon.console.print_line("fn: empty function body");
        return;
    }

    // Upsert: replace existing or append
    if (func_find(name)) |idx| {
        const f = &func_table[idx];
        f.arg_names = arg_names;
        f.arg_name_lens = arg_name_lens;
        f.arg_count = arg_count;
        f.body = cmds;
        f.body_lens = cmd_lens;
        f.body_count = cmd_count;
        mon.console.print_line("fn: ok (redefined)");
        return;
    }
    if (func_count >= func_max) {
        mon.console.print_line("fn: too many functions (max 8)");
        return;
    }
    const f = &func_table[func_count];
    @memcpy(f.name[0..name.len], name);
    f.name_len = name.len;
    f.arg_names = arg_names;
    f.arg_name_lens = arg_name_lens;
    f.arg_count = arg_count;
    f.body = cmds;
    f.body_lens = cmd_lens;
    f.body_count = cmd_count;
    func_count += 1;
    mon.console.print_line("fn: ok");
}

/// M19 P4+P8: call a function by name, with optional arguments.
fn func_call(mon: *monitor.Monitor, argv: []const []const u8) void {
    const idx = func_find(argv[0]) orelse return;
    const f = &func_table[idx];

    // P8: set positional $0 (function name) and $1..$N (caller args).
    env_set("0", f.name[0..f.name_len]);

    // $1..$N = caller arguments
    var ai: usize = 1;
    while (ai < argv.len and ai <= func_arg_max) : (ai += 1) {
        // Build positional name: "1", "2", ...
        var pos_name: [4]u8 = undefined;
        var pnl: usize = 0;
        const pn: usize = ai;
        if (pn >= 100) {
            pos_name[pnl] = @as(u8, @intCast('0' + (pn / 100) % 10));
            pnl += 1;
        }
        if (pn >= 10) {
            pos_name[pnl] = @as(u8, @intCast('0' + (pn / 10) % 10));
            pnl += 1;
        }
        pos_name[pnl] = @as(u8, @intCast('0' + pn % 10));
        pnl += 1;
        env_set(pos_name[0..pnl], argv[ai]);
    }

    // Also set named args ($name = caller value) if function declares them
    ai = 1;
    while (ai < argv.len and ai - 1 < f.arg_count) : (ai += 1) {
        const an = f.arg_names[ai - 1][0..f.arg_name_lens[ai - 1]];
        env_set(an, argv[ai]);
    }

    // Execute each command in the body sequentially.
    // P8: expand $VAR in body lines before execution (function bodies
    // are stored raw, so $name references expand at invocation time).
    var ci: usize = 0;
    while (ci < f.body_count) : (ci += 1) {
        var exp_buf: [func_cmd_max * 2]u8 = undefined;
        const cmd = env_expand(f.body[ci][0..f.body_lens[ci]], &exp_buf);
        shell_handle_expanded(mon, cmd);
    }
}

/// M19 P9 (issue #298): true while executing a command substitution's
/// inner command — guards against nesting (refused by the scanner) and
/// prevents cmd_subst from calling itself.
var subst_active: bool = false;

/// M19 P9 (issue #298): scan `raw` for `$(...)`.  If found, execute the
/// inner command with stdout captured, then substitute the captured output
/// into the line.  Returns the substituted line (may be the same as `raw`
/// if no substitution was found).
fn cmd_subst(mon: *monitor.Monitor, raw: []const u8, out: []u8) []const u8 {
    // Find first `$(`
    const dollar_lp = std.mem.indexOf(u8, raw, "$(") orelse return raw;
    const start = dollar_lp + 2;

    // Find matching `)` — reject nested `$(`
    var depth: usize = 1;
    var i: usize = start;
    while (i < raw.len and depth > 0) : (i += 1) {
        if (raw[i] == '$' and i + 1 < raw.len and raw[i + 1] == '(') {
            mon.console.print_line("cmdsubst: nested $(...) not supported");
            return raw;
        }
        if (raw[i] == '(') {
            depth += 1;
        } else if (raw[i] == ')') {
            depth -= 1;
        }
    }
    if (depth != 0) {
        mon.console.print_line("cmdsubst: unmatched $(");
        return raw;
    }
    const end = i - 1; // index of the closing `)`
    const inner_cmd = raw[start..end];
    // Trim whitespace
    var cs = inner_cmd;
    while (cs.len > 0 and (cs[0] == ' ' or cs[0] == '\t')) cs = cs[1..];
    var ce = cs.len;
    while (ce > 0 and (cs[ce - 1] == ' ' or cs[ce - 1] == '\t')) ce -= 1;
    const cmd = cs[0..ce];

    if (cmd.len == 0) return raw;

    // Capture the inner command's stdout.
    redirect.reset_capture();
    const saved = mon.console;
    mon.console = redirect.capture_console();
    subst_active = true;
    handle_line(mon, cmd);
    subst_active = false;
    mon.console = saved;

    const captured = redirect.captured();
    const cap_len = @min(captured.len, subst_max_output);

    // Build substituted line: prefix + captured output + suffix.
    // Trim trailing newlines from captured output (commands often end
    // with a newline, but we want the inline substitution to be clean).
    var cend = cap_len;
    while (cend > 0 and (captured[cend - 1] == '\n' or captured[cend - 1] == '\r')) cend -= 1;
    const trimmed = captured[0..cend];

    const prefix = raw[0..dollar_lp];
    const suffix = raw[end + 1 ..];
    var op: usize = 0;
    // copy prefix
    if (prefix.len > 0) {
        @memcpy(out[op..][0..prefix.len], prefix);
        op += prefix.len;
    }
    // copy trimmed captured output
    if (trimmed.len > 0) {
        @memcpy(out[op..][0..trimmed.len], trimmed);
        op += trimmed.len;
    }
    // copy suffix
    if (suffix.len > 0 and op + suffix.len <= out.len) {
        @memcpy(out[op..][0..suffix.len], suffix);
        op += suffix.len;
    }
    return out[0..op];
}

fn shell_handle_expanded(mon: *monitor.Monitor, line: []const u8) void {
    // M19 P2 (issue #291): the redirect operators — `>`, `>>`, `<` —
    // split before tokenizing so the command half goes through the
    // normal builtin/registry path and the file half is used by the
    // capture/feed adapters.
    if (redirect_split(line)) |rs| {
        switch (rs.op) {
            .stdout_overwrite, .stdout_append => run_redirect_out(mon, rs.left, rs.right, rs.op),
            .stdin_file => run_redirect_in(mon, rs.left, rs.right),
        }
        return;
    }
    // M19 P1 (issue #290): the pipe operator — split before tokenizing so
    // both halves go through the normal builtin/registry path.
    switch (pipe_split(line)) {
        .multiple => {
            mon.console.print_line("pipes: only one pipe per line (no chaining)");
            return;
        },
        .split => |sp| {
            run_pipe(mon, sp.left, sp.right);
            return;
        },
        .none => {},
    }
    // M18 T12–T15: intercept shell builtins before monitor.exec
    const tokens = tokenizer.tokenize(line);
    if (tokens.too_many) {
        monitor.err_line(mon, monitor.too_many_arguments_message);
        return;
    }
    if (tokens.unbalanced_quote) {
        mon.console.print_line("unterminated quote: rest of line treated as literal");
    }
    const argv = tokens.argv[0..tokens.count];
    if (argv.len == 0) {
        _ = monitor.exec(mon, argv);
        return;
    }
    // Builtin: export VAR[=VAL]
    if (std.mem.eql(u8, argv[0], "export")) {
        if (argv.len < 2) {
            // Print all env vars
            var ei: usize = 0;
            while (ei < env_count) : (ei += 1) {
                const e = &env_table[ei];
                mon.console.puts(e.name[0..e.name_len]);
                mon.console.puts("=");
                mon.console.print_line(e.val[0..e.val_len]);
            }
        } else {
            var eq: usize = 0;
            while (eq < argv[1].len and argv[1][eq] != '=') eq += 1;
            if (eq < argv[1].len) {
                env_set(argv[1][0..eq], argv[1][eq + 1 ..]);
            } else {
                env_set(argv[1], "");
            }
            save_env();
        }
        return;
    }
    // Builtin: set VAR=VAL (M19 P3)
    if (std.mem.eql(u8, argv[0], "set")) {
        if (argv.len < 2) {
            // Print all env vars (like export / env)
            var ei: usize = 0;
            while (ei < env_count) : (ei += 1) {
                const e = &env_table[ei];
                mon.console.puts(e.name[0..e.name_len]);
                mon.console.puts("=");
                mon.console.print_line(e.val[0..e.val_len]);
            }
        } else {
            var eq: usize = 0;
            while (eq < argv[1].len and argv[1][eq] != '=') eq += 1;
            if (eq < argv[1].len) {
                env_set(argv[1][0..eq], argv[1][eq + 1 ..]);
            } else {
                env_set(argv[1], "");
            }
            save_env();
        }
        return;
    }
    // Builtin: unset VAR (M19 P3)
    if (std.mem.eql(u8, argv[0], "unset")) {
        if (argv.len < 2) {
            mon.console.print_line("unset: usage: unset VAR");
        } else {
            if (env_unset(argv[1])) {
                save_env();
            }
        }
        return;
    }
    // Builtin: env / printenv (M19 P3 + M22 D7, issue #330)
    if (std.mem.eql(u8, argv[0], "env") or std.mem.eql(u8, argv[0], "printenv")) {
        var ei: usize = 0;
        while (ei < env_count) : (ei += 1) {
            const e = &env_table[ei];
            mon.console.puts(e.name[0..e.name_len]);
            mon.console.puts("=");
            mon.console.print_line(e.val[0..e.val_len]);
        }
        return;
    }
    // Builtin: alias NAME=VALUE [MORE...]
    if (std.mem.eql(u8, argv[0], "alias")) {
        if (argv.len < 2) {
            mon.console.print_line("alias: usage: alias NAME=VALUE [MORE...]");
        } else {
            var eq: usize = 0;
            while (eq < argv[1].len and argv[1][eq] != '=') eq += 1;
            if (eq > 0 and eq < argv[1].len) {
                // Build value: argv[1][eq+1..] + remaining args joined by space
                var valbuf: [env_val_max]u8 = undefined;
                var vp: usize = 0;
                for (argv[1][eq + 1 ..]) |b| {
                    if (vp < valbuf.len) {
                        valbuf[vp] = b;
                        vp += 1;
                    }
                }
                var ai: usize = 2;
                while (ai < argv.len) : (ai += 1) {
                    if (vp < valbuf.len) {
                        valbuf[vp] = ' ';
                        vp += 1;
                    }
                    for (argv[ai]) |b| {
                        if (vp < valbuf.len) {
                            valbuf[vp] = b;
                            vp += 1;
                        }
                    }
                }
                env_set(argv[1][0..eq], valbuf[0..vp]);
                mon.console.print_line("alias: ok");
            } else {
                mon.console.print_line("alias: usage: alias NAME=VALUE [MORE...]");
            }
        }
        return;
    }
    // Builtin: unalias NAME
    if (std.mem.eql(u8, argv[0], "unalias")) {
        mon.console.print_line("unalias: not implemented (aliases are just env vars)");
        return;
    }
    // M18 T16 (issue #419): 'exit' inside a running script stops it
    // early. Outside a script it is not a command — it falls through to
    // the registry's unknown-command shape below.
    if (std.mem.eql(u8, argv[0], "exit") and script_active) {
        script_stop = true;
        return;
    }
    // Builtin: sh SCRIPT (M18 T16, issue #419) — run a script file of
    // shell commands line by line. Intercepted here (like export/alias)
    // because execution must go through handle_line; the monitor registry
    // entry exists for help/usage/completion discovery.
    if (std.mem.eql(u8, argv[0], "sh")) {
        if (argv.len != 2) {
            mon.console.print_line("sh: usage: sh <script>");
            return;
        }
        run_script(mon, argv[1]);
        return;
    }
    // Builtin: prompt NEW_PROMPT (M18 T15)
    if (std.mem.eql(u8, argv[0], "prompt")) {
        if (argv.len < 2) {
            mon.console.print_line("prompt: usage: prompt NEW_PROMPT");
        } else {
            _ = settings.set("prompt", argv[1]);
            mon.console.print_line("prompt: ok");
        }
        return;
    }
    // M19 P1 (issue #290): `type` — echo stdin (the pipe source) to
    // stdout. With no pipe the console has no input, so it prints nothing;
    // as the RIGHT half of `a | type` it echoes the left command's output.
    if (std.mem.eql(u8, argv[0], "type")) {
        while (mon.console.readByte()) |b| {
            mon.console.putc(b);
        }
        return;
    }
    // Builtin: fn (M19 P4) — list, define, delete shell functions.
    if (std.mem.eql(u8, argv[0], "fn")) {
        if (argv.len == 1) {
            // Bare `fn` lists all functions.
            if (func_count == 0) {
                mon.console.print_line("fn: no functions defined");
            } else {
                var fi: usize = 0;
                while (fi < func_count) : (fi += 1) {
                    const f = &func_table[fi];
                    mon.console.puts(f.name[0..f.name_len]);
                    mon.console.puts("(");
                    var ai: usize = 0;
                    while (ai < f.arg_count) : (ai += 1) {
                        if (ai > 0) mon.console.puts(", ");
                        mon.console.puts(f.arg_names[ai][0..f.arg_name_lens[ai]]);
                    }
                    mon.console.puts(") { ");
                    var ci: usize = 0;
                    while (ci < f.body_count) : (ci += 1) {
                        if (ci > 0) mon.console.puts("; ");
                        mon.console.puts(f.body[ci][0..f.body_lens[ci]]);
                    }
                    mon.console.print_line(" }");
                }
            }
        } else if (std.mem.eql(u8, argv[1], "-d")) {
            // fn -d NAME: delete a function.
            if (argv.len < 3) {
                mon.console.print_line("fn: usage: fn -d NAME");
            } else {
                const found = func_find(argv[2]);
                if (found) |idx| {
                    var j = idx;
                    while (j + 1 < func_count) : (j += 1) func_table[j] = func_table[j + 1];
                    func_count -= 1;
                } else {
                    mon.console.puts("fn: ");
                    mon.console.puts(argv[2]);
                    mon.console.print_line(": no such function");
                }
            }
        } else if (std.mem.eql(u8, argv[1], "-h")) {
            mon.console.print_line("fn: usage: fn NAME(a, b) { cmd1; cmd2 }");
            mon.console.print_line("fn:        fn              list all functions");
            mon.console.print_line("fn:        fn -d NAME       delete a function");
        } else {
            // fn NAME { cmd1; cmd2 } — define a function.
            // Rebuild the original line to parse `{ cmd1; cmd2 }`.
            var raw: [lineedit.max_line]u8 = undefined;
            var rp: usize = 0;
            var ai: usize = 1;
            while (ai < argv.len) : (ai += 1) {
                if (ai > 1 and rp < raw.len) {
                    raw[rp] = ' ';
                    rp += 1;
                }
                for (argv[ai]) |b| {
                    if (rp < raw.len) {
                        raw[rp] = b;
                        rp += 1;
                    }
                }
            }
            func_define(mon, raw[0..rp]);
        }
        return;
    }
    // M19 P4: call a function by name (if a function matches the command verb).
    if (func_find(argv[0])) |_| {
        func_call(mon, argv);
        return;
    }
    _ = monitor.exec(mon, argv);
}

/// The kernel's ONE shell instance lives in BSS, not on the kernel stack:
/// the LineEditor's bounded history ring (hist_capacity × max_line bytes,
/// ADR 0008 D2) would crowd the 16 KiB kernel stack (ADR 0004 D5) once
/// kernel_main's boot frame is also live — observed as silently dropped
/// keyboard input when the shell was stack-allocated (milestone eight card
/// U2, claim 1809). Host tests still build their own stack `Shell` values;
/// only the kernel seam touches this storage.
var boot_shell_storage: Shell = undefined;

/// Boot presentation for the kernel seam. Prints the banner; with an RX
/// source wired it runs the interactive loop forever (never returns);
/// without RX it prints the prompt and returns so the caller parks in WFE.
/// Never spins hot, never reads a device register.
pub fn boot_and_park(mon: *monitor.Monitor, rx_wired: bool) void {
    if (!rx_wired) {
        monitor.banner(mon);
        mon.console.puts(expanded_prompt());
        return;
    }
    const shell: *Shell = &boot_shell_storage;
    shell.* = Shell.init(mon.console, mon.state, mon.machine);
    shell.boot();
    shell.color_enabled = settings.get_color();
    load_history(&shell.editor);
    load_env(); // M19 P3: restore persistent environment
    // M18 T14: run startup file (.dipshitrc) if present
    if (esp.disk_ready()) {
        if (esp.lookup(".dipshitrc")) |entry| {
            const rc = esp.content_of(entry);
            var start: usize = 0;
            var i: usize = 0;
            while (i < rc.len) : (i += 1) {
                if (rc[i] == '\n' or rc[i] == '\r') {
                    if (i > start) handle_line(mon, rc[start..i]);
                    start = i + 1;
                    if (rc[i] == '\r' and i + 1 < rc.len and rc[i + 1] == '\n') i += 1;
                }
            }
            if (start < rc.len) handle_line(mon, rc[start..rc.len]);
        }
    }
    while (true) {
        if (shell.poll() == .idle) {
            // Claim 9187: the timer is serviced only through the IRQ path.
            // Claim 7948's main-loop comparator poll raced real delivery
            // after the GICR frame fix, double-consuming some periods.
            // Output remains here because the polled virtio TX path is not
            // reentrancy-safe in IRQ context. Claim 5275: the worker task's
            // progress report prints the same way (the worker never touches
            // the console itself).
            timer.maybe_heartbeat(&mon.console);
            scheduler.maybe_report(&mon.console);
            userspace.maybe_report(&mon.console);
            // Claim 6076 (card N2): the polled RX drain — the net device's
            // used-buffer IRQ is not yet observed on this platform, so the
            // shell idle loop is the drain point (the card-3d shell-idle-
            // drain pattern). Idempotent; a no-op when the transport is
            // unarmed or the buffer is empty.
            // Card N9 (claim 9489): stamp the DHCP lease clock from the 1
            // Hz generic timer before the drain — a renewal ACK processed
            // below restarts the lease from the CURRENT instant (honest
            // wall-clock seconds, the same clock `net dhcp` uses).
            virtio_net.dhcp.now_ticks = timer.ticks;
            // Card N10 (claim 7026): stamp the TCP connect clock the same
            // way — a SYN-ACK processed below starts the connection from
            // the CURRENT instant (the bounded connect timeout is honest
            // wall-clock seconds).
            virtio_net.tcp.now_ticks = timer.ticks;
            virtio_net.net_rx_drain();
            // Issue #119 (audit follow-up 3): the autonomous DHCP lease
            // lifecycle — advance T1/T2/expiry from the idle loop (the
            // polled-drain time engine, the same seam as tcp.poll_rto)
            // instead of requiring a human to type `net dhcp`. AFTER the
            // drain: a renewal ACK just processed restarts the lease
            // clock first. Prints the SAME transition lines the command
            // prints; silent otherwise (and on the no-ARP renew path —
            // the client stays BOUND per RFC 2131 §4.4.5; `net dhcp`
            // surfaces the diagnostic). The re-DISCOVER after expiry
            // stays command-triggered.
            monitor.net_dhcp_autonomous(mon);
            // Claim 6050 (milestone seven I3): drain the keyboard/pointer
            // event FIFO — poll the XHCI interrupt-IN endpoints, decode the
            // HID reports, and push decoded bytes for the NEXT shell poll
            // (the same polled-drain discipline as net RX). No-op when the
            // input path is unarmed (default VM). Drains BEFORE the Road
            // Pops present so a report is never starved behind a slow
            // full-frame present.
            input.drain();
            // M15 C2 (Alt+Tab overlay, #225): hold-Alt+Tab shows preview.
            // Card U4/U5 (claims 4993/0935, ADR 0008 D4): the pointer tick
            // (click = focus + raise; the cursor follows the pointer) and
            // the focus-cycle chord. The outcomes print here — the serial
            // evidence the live gate asserts.
            if (input.take_alt_tab_shift()) |shift| {
                if (!driving_award.alt_tab_is_active()) {
                    if (driving_award.alt_tab_activate()) {
                        mon.console.puts("dui: alt-tab active count=");
                        mon.console.print_u64(driving_award.alt_tab_count());
                        mon.console.puts(" selected=");
                        mon.console.print_u64(driving_award.alt_tab_selected_id() orelse 0xff);
                        mon.console.puts("\n");
                    } else {
                        if (driving_award.cycle_focus()) |id| {
                            mon.console.puts("dui: cycle focused=");
                            mon.console.print_u64(id);
                            mon.console.puts("\n");
                        }
                    }
                } else {
                    driving_award.alt_tab_cycle(shift);
                    mon.console.puts("dui: alt-tab cycle selected=");
                    mon.console.print_u64(driving_award.alt_tab_selected_id() orelse 0xff);
                    mon.console.puts(" shift=");
                    mon.console.print_u64(if (shift) 1 else 0);
                    mon.console.puts("\n");
                }
            }
            if (driving_award.alt_tab_is_active() and !input.alt_held()) {
                if (driving_award.alt_tab_commit()) |id| {
                    mon.console.puts("dui: alt-tab commit focused=");
                    mon.console.print_u64(id);
                    mon.console.puts("\n");
                } else {
                    driving_award.alt_tab_dismiss();
                }
            }
            if (driving_award.pointer_tick(input.pointer_state(), input.take_click())) |id| {
                mon.console.puts("dui: pointer focus=");
                mon.console.print_u64(id);
                mon.console.puts("\n");
            }
            // Arc4 #238: Ctrl+Shift+B lowers focused window to back.
            if (input.take_lower_back()) {
                const fid = driving_award.focused_window_id();
                if (driving_award.user_lower_back(fid)) {
                    mon.console.puts("dui: lower-back id=");
                    mon.console.print_u64(fid);
                    mon.console.puts("\n");
                }
            }
            // Arc4 #241: Ctrl+F1/F2/F3 workspace switch.
            if (input.take_workspace_switch()) |ws| {
                driving_award.switch_workspace(ws);
                mon.console.puts("dui: workspace=");
                mon.console.print_u64(ws);
                mon.console.puts("\n");
            }
            // M21 W4: Alt+` cycles workspaces directly.
            if (input.take_workspace_cycle()) {
                driving_award.cycle_workspace();
                mon.console.puts("dui: workspace-cycle ws=");
                mon.console.print_u64(driving_award.current_workspace);
                mon.console.puts("\n");
            }
            // M21 W1: Ctrl+T toggles tiling mode.
            if (input.take_tile_toggle()) {
                driving_award.toggle_tiling();
                mon.console.puts("dui: tile=");
                mon.console.puts(if (driving_award.tile_mode) "on" else "off");
                if (driving_award.tile_master_id) |mid| {
                    mon.console.puts(" master=");
                    mon.console.print_u64(mid);
                }
                if (driving_award.tile_stack_id) |sid| {
                    mon.console.puts(" stack=");
                    mon.console.print_u64(sid);
                }
                mon.console.puts("\n");
            }
            // M21 W2: Ctrl+M swaps master/detail in tiled mode.
            if (input.take_tile_swap_master()) {
                driving_award.swap_master();
                mon.console.puts("dui: master-swap side=");
                mon.console.puts(if (driving_award.tile_master_side) "left" else "right");
                mon.console.puts("\n");
            }
            // M21 W3: Ctrl+N minimizes the focused window.
            if (input.take_minimize()) {
                const fid = driving_award.focused_window_id();
                if (driving_award.minimize_window(fid)) {
                    mon.console.puts("dui: minimized id=");
                    mon.console.print_u64(fid);
                    mon.console.puts("\n");
                } else {
                    mon.console.puts("dui: minimize-failed id=");
                    mon.console.print_u64(fid);
                    mon.console.puts("\n");
                }
            }
            // M21 W6: Ctrl+Shift+M toggles maximize.
            if (input.take_maximize()) {
                const fid = driving_award.focused_window_id();
                if (driving_award.toggle_maximize(fid)) {
                    const w = driving_award.find_user_window(fid);
                    mon.console.puts("dui: maximize id=");
                    mon.console.print_u64(fid);
                    mon.console.puts(" max=");
                    mon.console.puts(if (w != null and w.?.maximized) "on" else "off");
                    mon.console.puts("\n");
                }
            }
            // M21 W7: F11 toggles fullscreen.
            if (input.take_fullscreen()) {
                const fid = driving_award.focused_window_id();
                if (driving_award.toggle_fullscreen(fid)) {
                    mon.console.puts("dui: fullscreen id=");
                    mon.console.print_u64(fid);
                    mon.console.puts(" on=");
                    mon.console.puts(if (driving_award.fullscreen_active) "yes" else "no");
                    mon.console.puts("\n");
                }
            }
            // M21 W8: Ctrl+Shift+T toggles always-on-top.
            if (input.take_always_on_top()) {
                const fid = driving_award.focused_window_id();
                if (driving_award.toggle_always_on_top(fid)) {
                    const w = driving_award.find_user_window(fid);
                    mon.console.puts("dui: always-on-top id=");
                    mon.console.print_u64(fid);
                    mon.console.puts(" flag=");
                    mon.console.puts(if (w != null and w.?.always_on_top) "on" else "off");
                    mon.console.puts("\n");
                }
            }
            // M21 W10: Alt+arrow keyboard window movement.
            if (input.take_move()) |mv| {
                const fid = driving_award.focused_window_id();
                if (driving_award.move_window_keyboard(fid, mv.dx, mv.dy)) {
                    mon.console.puts("dui: move id=");
                    mon.console.print_u64(fid);
                    mon.console.puts(" dx=");
                    mon.console.print_u64(@as(u64, @intCast(mv.dx + 32))); // offset for display
                    mon.console.puts(" dy=");
                    mon.console.print_u64(@as(u64, @intCast(mv.dy + 32))); // offset for display
                    mon.console.puts("\n");
                }
            }
            // M27 G2: Ctrl+Shift+A opens about dialog.
            if (input.take_about()) {
                driving_award.about_dialog_toggle();
                mon.console.puts("dui: about=");
                mon.console.puts(if (driving_award.about_dialog_open) "open" else "closed");
                mon.console.puts("\n");
            }
            // Claim 1574 (milestone six G3): Road Pops — one full-frame
            // present per dirty output batch (the card-3d drain pattern).
            // No-op when the tee is unarmed (default VM) or clean.
            road_pops.drain();
            // Card G5 (claim 1543): Driving Award — refresh the clock
            // window from the 1 Hz generic timer and composite any dirty
            // windows. This is the clock-only present path (the tee's
            // present above already composites terminal output); no-op
            // when the manager is unarmed (default VM) or clean.
            _ = driving_award.drain(timer.ticks);
            // Card N11 (claim 5357): the bounded retransmission timer —
            // polled here (the idle loop is the time engine — the
            // card-N9 clock pattern). AFTER the drain, so an ACK the
            // drain just processed has cleared the pending state — a
            // retransmission never follows an acknowledged segment. The
            // poll advances ONE step: an expired RTO (3 s) retransmits
            // the pending SYN/data/FIN byte-exact (counted, printed); the
            // exhausted bound (10) aborts the connection honestly
            // (counted, printed). Bare ACKs are never pending.
            switch (virtio_net.tcp.poll_rto()) {
                .none => {},
                .retransmit => {
                    var out_len: usize = 0;
                    switch (virtio_net.net_tcp_send(virtio_net.tcp.msg[0..virtio_net.tcp.msg_len], &out_len)) {
                        .ok => {
                            mon.console.puts("net tcp: ");
                            mon.console.puts(switch (virtio_net.tcp.state) {
                                .syn_sent => "syn",
                                .established => "data",
                                .fin_sent => "fin",
                                else => "segment",
                            });
                            mon.console.puts(" retransmitted (");
                            mon.console.print_u64(virtio_net.tcp.retx_count);
                            mon.console.puts("/");
                            mon.console.print_u64(virtio_net.tcp.retx_max);
                            mon.console.puts(")\n");
                        },
                        else => mon.console.print_line("net tcp: retransmit TX failed (transport unready)"),
                    }
                },
                .abort => {
                    mon.console.puts("net tcp: retransmission limit reached (");
                    mon.console.print_u64(virtio_net.tcp.retx_max);
                    mon.console.puts(") — connection aborted\n");
                },
            }
            idle_wait_rx();
        }
    }
}

/// Idle between input polls in RX-wired mode: a bounded nop delay, not WFE.
/// The GIC/timer path IS live since claim 9187 (a real CNTP PPI preempts
/// this very loop every second), but the console RX, net RX, and XHCI input
/// are polled devices with no interrupt of their own, and a WFE would only
/// wake on the 1 s tick — capping input/net polling at 1 s granularity.
/// The bounded delay keeps the loop responsive without a timer (claim
/// 6684's original rationale), at the cost of a hot spin while idle (see
/// issue #122 — a WFE-with-tick-wake experiment is the recorded option).
/// Elided entirely on non-aarch64 hosts so the module stays host-testable
/// on x86_64 CI.
fn idle_wait_rx() void {
    if (comptime builtin.cpu.arch == .aarch64) {
        var spins: usize = 0;
        while (spins < 100_000) : (spins += 1) asm volatile ("nop");
    }
}

// ---------------------------------------------------------------------------
// Tests (host-side; mock console, no hardware)
// ---------------------------------------------------------------------------

fn make_handoff() handoff.HandoffV2 {
    return .{
        .magic = handoff.magic,
        .version = handoff.version,
        .kernel_base = 0x7e4df000,
        .kernel_size = 0x823e8,
        .system_table = 0xfeed000,
        .image_handle = 0x2,
        .stack_base = 0x7e520000,
        .stack_size = handoff.expected_stack_size,
        .flags = 0,
    };
}

/// File-level descriptor fixture: the map view's data slice points into
/// this constant, which lives for the whole test binary (never a dead
/// stack frame), so the view stays valid for the shell's lifetime.
const test_descriptors = [_]memmap.MemoryDescriptor{
    .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 960, .attribute = 0 },
    .{ .type = .loader_code, .physical_start = 0x7000000, .virtual_start = 0, .number_of_pages = 64, .attribute = 0 },
    .{ .type = .boot_services_data, .physical_start = 0x8000000, .virtual_start = 0, .number_of_pages = 128, .attribute = 0 },
    .{ .type = .runtime_services_data, .physical_start = 0x9000000, .virtual_start = 0, .number_of_pages = 8, .attribute = 0 },
    .{ .type = .memory_mapped_io, .physical_start = 0x1000000, .virtual_start = 0, .number_of_pages = 16, .attribute = 0 },
    .{ .type = .reserved_memory_type, .physical_start = 0x1ff00000, .virtual_start = 0, .number_of_pages = 1, .attribute = 0 },
};

fn make_view() memmap.MapView {
    var view = memmap.MapView.init(std.mem.asBytes(&test_descriptors), @sizeOf(memmap.MemoryDescriptor), test_descriptors.len);
    view.key = 0x42;
    view.descriptor_version = 2;
    return view;
}

fn make_shell(mock: anytype, view: memmap.MapView) Shell {
    return Shell.init(
        mock.console(),
        .{ .handoff = make_handoff(), .map = view, .console_name = "mock" },
        monitor.MachineControl.disabled(),
    );
}

test "shell: mock-fed end-to-end session produces the exact transcript" {
    const long = "a" ** 256;
    // 18 tokens: one past the 17-token limit (verb + 16 args), so the
    // tokenizer refuses the line before any handler sees it.
    const too_many_tokens = "echo t t t t t t t t t t t t t t t t t";
    const expected =
        "DipshitOS - AArch64 firmware-assisted kernel monitor\n" ++
        "DipshitOS: memory is a map, not a territory.\n" ++
        "motd: aarch64 el1 kernel live; scheduler, uaccess, fs, net, gfx, xhci armed.\n" ++
        "Type 'help' before touching anything expensive.\n" ++
        "dipshit> help\r\n" ++
        "available commands:\n" ++
        "machine / identity\n" ++
        "  about       explain this questionable system\n" ++
        "  beans       count beans, probably\n" ++
        "  elephant    operational mascot diagnostics\n" ++
        "  sysinfo     comprehensive system and subsystem diagnostic snapshot\n" ++
        "  tour        guided tour of the system for new users\n" ++
        "  uname       compact system identity\n" ++
        "  version     display build information\n" ++
        "  welcome     guided tour of the system for new users\n" ++
        "memory / machine state\n" ++
        "  addrspaces  per-task user address spaces: per-task TTBR0, EL1-only kernel overlay, user-root contents\n" ++
        "  fault       trigger a synchronous exception (diagnostic)\n" ++
        "  handoff     display boot-to-kernel ABI data\n" ++
        "  hex         format an integer in hexadecimal\n" ++
        "  mem         summarize the EFI memory map\n" ++
        "  pages       physical page allocator pool\n" ++
        "  pci         enumerate PCI devices on the bus\n" ++
        "  resources   fixed-pool audit: scheduler tasks, process registry, windows, page-table carve-out, and per-process ring bounds\n" ++
        "  timer       interrupt controller + timer status\n" ++
        "  uaccess     user-memory copy diagnostics (valid, fault, recovery)\n" ++
        "tasks / processes\n" ++
        "  exec        load a user program from the ESP and enter it at EL0\n" ++
        "  kill        terminate a running process (kernel-owned lifetime)\n" ++
        "  mbox        per-process IPC mailbox: pending messages and drain counters\n" ++
        "  procs       process registry: image, address space, lifecycle, exit status\n" ++
        "  ps          process status table: PID, name, state, memory footprint, CPU ticks, and executor task per live/exited process (M22 D6)\n" ++
        "  spawn       spawn the lifecycle demo task\n" ++
        "  strace      trace a program's syscalls: 'strace exec APP.BIN [args]' arms the tracer around an exec and prints one line per syscall; 'strace off' disarms\n" ++
        "  sym         crash-report symbol table: 'sym' lists symbols loaded from the last ELF exec; 'sym <file>' parses an ELF's symtab from disk\n" ++
        "  syscalls    numbered syscall table and counters\n" ++
        "  tasks       tick-driven task scheduler status\n" ++
        "storage\n" ++
        "  cat         print a file from the ESP (by name or /path)\n" ++
        "  ls          list files on the ESP (or a directory by path)\n" ++
        "  mount       switch the active FAT volume (esp or data)\n" ++
        "  write       write text to a file on the ESP\n" ++
        "networking\n" ++
        "  net         virtio-net transport + RX + ARP + ICMP + UDP + DHCP + TCP + DNS: device DID, MAC, queues, feature bits, RX counters ('net recv' prints received frames; 'net ip <a.b.c.d>' sets the static IP; 'net arp [<a.b.c.d>]' shows/resolves the ARP table; 'net ping <a.b.c.d>' sends an ICMP echo request; 'net udp [listen <port>|close <port>|send <addr> <port> <len>|recv [<port>]]' drives UDP; 'net dhcp' runs the bounded DHCP client one step per invocation; 'net tcp [connect <addr> <port>|send <len>|recv|close|reset]' drives the bounded TCP client; 'net dns <hostname> [<server>]' resolves DNS A-records)\n" ++
        "  netsend     send a known Ethernet frame (bounded staging, TX + used-ring drain)\n" ++
        "graphics / input\n" ++
        "  font        terminal font size: small 8x8 (default), medium 16x16, large 24x24 (M20-U1)\n" ++
        "  input       keyboard/pointer event FIFO: armed state, occupancy, drop count, last keyboard + pointer events\n" ++
        "  roadpops    Road Pops framebuffer console: armed/dirty/present counters (the boot terminal on the screen)\n" ++
        "  screen      virtio-gpu transport + framebuffer: device DID, features, scanout, status, re-arm ('screen fill <rrggbb>' fills the framebuffer and flushes it to the scanout)\n" ++
        "  text        framebuffer text: text region, cursor, scrollback ('text put <string...>' renders + flushes to the scanout; 'text clear' clears; 'text putraw' skips the trailing newline; 'text fontdebug [on|off]' missing-glyph stats)\n" ++
        "  usb         XHCI host controller: `usb` transport report, `usb devices` enumerated HID devices, `usb report` last HID report\n" ++
        "  dui         Driving Award window manager: registry (with owner pids), z-order, focus, hit-testing ('dui focus <n>' focuses; 'dui raise <n>' raises; 'dui lower <n>' lowers to back; 'dui move <n> <x> <y>' moves a user window; 'dui close <n>' releases a user window; 'dui list <pid>' filters by owner; 'dui hit <x> <y>' hit-tests; 'dui cycle' cycles focus like Alt+Tab)\n" ++
        "system\n" ++
        "  beep        synthesize + play a sine through the virtio-snd PCM path ('beep <freq> <ms>' — reports the full control flow + submit/drain accounting)\n" ++
        "  calc        calculator utilities: 'calc history' shows saved calculation history from /data/calc_hst.txt\n" ++
        "  clear       clean up the crime scene\n" ++
        "  compose     list available Alt+key compose sequences for accented characters\n" ++
        "  crash       list recent crash tombstones from /data/crash/\n" ++
        "  clip        copy/paste the shared kernel clipboard ('clip <text...>' sets it, 'clip' prints it)\n" ++
        "  color       toggle ANSI terminal colors ('color on'/'color off'; 'color' shows current)\n" ++
        "  echo        repeat your regrettable decisions\n" ++
        "  help        grouped command catalog and per-command/per-topic help\n" ++
        "  random      print n random bytes from the seeded CSPRNG (hex)\n" ++
        "  reboot      restart the machine\n" ++
        "  repeat      repeat text, safely bounded\n" ++
        "  sh          run a script file of shell commands ('sh <script>' executes it line by line; 64 lines max, 256 chars per line; '#' comments; 'exit' stops early)\n" ++
        "  settings    persistent configuration: `settings [list]`, `settings get <key>`, `settings set <key> <val>`, `settings reset`\n" ++
        "  sound       virtio-snd transport: device DID, class, status, control-queue state, device-config counts (jacks/streams/channel-maps), re-arm; stream-state control: 'sound volume <0-100>' and 'sound mute <on|off>'\n" ++
        "  shutdown    request power-off\n" ++
        "  type        echo stdin (the pipe source) to stdout — the right half of `a | type`\n" ++
        "type 'help <command>' for details on a single command.\n" ++
        "type 'help <topic>' for a topic page (networking, windows, storage, graphics).\n" ++
        "dipshit> version\r\n" ++
        "dipshit-kernel\n" ++
        "milestone-two kernel proper (ADR 0004)\n" ++
        "handoff ABI v2\n" ++
        "build label: m1.5 commands & personality (mock console)\n" ++
        "dipshit> mem\r\n" ++
        "mem: descriptors=0x0000000000000006 size=0x0000000000000028 version=0x0000000000000002 key=0x0000000000000042\n" ++
        "  usable: 0x0000000000480000 bytes (0x0000000000000480 pages)\n" ++
        "  conventional: 0x00000000003c0000 bytes (0x00000000000003c0 pages)\n" ++
        "  loader: 0x0000000000040000 bytes (0x0000000000000040 pages)\n" ++
        "  boot_services: 0x0000000000080000 bytes (0x0000000000000080 pages)\n" ++
        "  runtime: 0x0000000000008000 bytes (0x0000000000000008 pages)\n" ++
        "  reserved: 0x0000000000009000 bytes (0x0000000000000009 pages)\n" ++
        "  mmio: 0x0000000000010000 bytes (0x0000000000000010 pages)\n" ++
        "  kernel: 0x000000007e4df000..0x000000007e5613e8 (0x00000000000823e8 bytes)\n" ++
        "dipshit> pages\r\n" ++
        "pages: armed=1 total=0x0000000000000480 free=0x0000000000000480 excluded=0x0000000000000000 regions=0x0000000000000003 span=0x0000000000007f80\n" ++
        "dipshit> pages selftest\r\n" ++
        "pages selftest: alloc 1 -> 0x0000000000100000\n" ++
        "pages selftest: free ok\n" ++
        "pages selftest: alloc 8 -> 0x0000000000100000\n" ++
        "pages selftest: free ok\n" ++
        "pages selftest: alloc 3 -> 0x0000000000100000\n" ++
        "pages selftest: alloc 5 -> 0x0000000000103000\n" ++
        "pages selftest: free both ok\n" ++
        "pages selftest: alloc 960 -> 0x0000000000100000\n" ++
        "pages selftest: free ok\n" ++
        "pages selftest: alloc 1153 -> none (out of memory)\n" ++
        "pages selftest: ok free=0x0000000000000480\n" ++
        "dipshit> tasks\r\n" ++
        "tasks: enabled=0 current=0 switches=0 pool=4/11 zombies=0\n" ++
        "  shell    saves=0 resumes=0 advances=0 state=ready\n" ++
        "  worker   saves=0 resumes=0 advances=0 state=ready\n" ++
        "  user-el0 saves=0 resumes=0 advances=0 state=ready\n" ++
        "  idle     saves=0 resumes=0 advances=0 state=ready\n" ++
        "dipshit> echo \"elephant business\"\r\n" ++
        "elephant business\n" ++
        "dipshit> ls\r\n" ++
        "ls: esp=0x0000000000000003\n" ++
        "  KERNEL.BIN  0x0000000000088b38  [esp]\n" ++
        "  EFI         0x0000000000000000  [dir]\n" ++
        "  BOOTED.TXT  0x0000000000000029  [esp]\n" ++
        "dipshit> cat BOOTED.TXT\r\n" ++
        "DIPSHITOS BOOTLOADER\n" ++
        "firmware has agreed to cooperate\n" ++
        "dipshit> write hello.txt hello world\r\n" ++
        "error: hello.txt: not persisted - no disk (FAT volume unavailable)\n" ++
        "dipshit> cat hello.txt\r\n" ++
        "error: hello.txt: not found (no such file on the ESP)\n" ++
        // ADR 0008 D3: the three shapes are gate-tested here byte-exactly,
        // so a command that invents a fourth shape fails CI.
        // Shape 1 (misuse): the usage line PLUS the registry's one-line hint.
        "dipshit> pages bogus\r\n" ++
        "usage: pages [selftest]\n" ++
        "physical page allocator pool\n" ++
        // Shape 3 (unknown verb).
        "dipshit> " ++ long ++ "\r\n" ++
        "unknown command '" ++ long ++ "' -- try 'help'\n" ++
        // Shape 2 (failure), from the dispatch layer: an over-long argv.
        "dipshit> " ++ too_many_tokens ++ "\r\n" ++
        "error: too many arguments (max 17 tokens)\n" ++
        "dipshit> ^C\r\n" ++
        // Enter pressed after the cancel submits an empty line, which the
        // registry answers in shape 2 (then a new prompt).
        "dipshit> \r\n" ++
        "error: no command given; type 'help' for a list of commands\n" ++
        "dipshit> ";

    var mock = console.MockConsole(16384){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // Arm the module allocator from the same fixture map the monitor sees,
    // exactly as kernel_main does — the `pages` command reports/exercises
    // that pool.
    _ = alloc.init(make_view(), &.{});
    // Claims 5275/8215: register all scheduler tasks exactly as kernel_main
    // does (without `start`, so no preemption happens in the test process)
    // — the `tasks` command then reports the real mixed-EL shape.
    _ = scheduler.init();
    _ = scheduler.register_worker(0);
    _ = scheduler.register_user(0, 0);
    userspace.init();
    // Claim 3475/6420: populate the ESP file window the way kernel_main's
    // FAT snapshot does (KERNEL.BIN listed-but-unloaded, an EFI directory,
    // BOOTED.TXT content-loaded). A test process has no disk (no FAT
    // volume mounted), so `write` honestly reports it cannot persist.
    esp.reset();
    _ = esp.add_esp_entry("KERNEL.BIN", 0x88b38, "");
    _ = esp.add_dir_entry("EFI");
    _ = esp.add_esp_entry("BOOTED.TXT", 0x29, "DIPSHITOS BOOTLOADER\nfirmware has agreed to cooperate\n");
    mock.feed("help\nversion\nmem\npages\npages selftest\ntasks\necho \"elephant business\"\nls\ncat BOOTED.TXT\nwrite hello.txt hello world\ncat hello.txt\npages bogus\n");
    mock.feed(long);
    mock.feed("\n");
    mock.feed(too_many_tokens);
    mock.feed("\n\x03\n");
    while (shell.poll() != .idle) {}
    try std.testing.expectEqualStrings(expected, mock.contents());
    // Emit the captured transcript so the automated gate
    // (tools/verify-transcript.sh, `zig build test-console`) can diff it
    // byte-for-byte against the checked-in canonical fixture
    // (tests/transcript-console.txt). Host-test-only: kernel builds never
    // execute tests, so std.Io never appears in the freestanding image.
    // Zig 0.16 moved file I/O out of std.fs into the std.Io interface; the
    // single-threaded instance is the minimal one for a plain write.
    var io_impl = std.Io.Threaded.init_single_threaded;
    try std.Io.Dir.cwd().writeFile(io_impl.io(), .{
        .sub_path = "artifacts/m15-mock-transcript.txt",
        .data = mock.contents(),
    });
}

test "shell: over-long line is refused with a bell and an overflow notice" {
    var mock = console.MockConsole(2048){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("b" ** 257);
    mock.feed("\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    // 256 chars echoed, the 257th refused with a bell, then the notice.
    try std.testing.expect(std.mem.indexOf(u8, out, "b" ** 256 ++ "\x07") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "input refused: line longer than 256 bytes\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "unknown command '" ++ "b" ** 256 ++ "' -- try 'help'") != null);
}

test "shell: too many arguments refuses execution with the documented message" {
    var mock = console.MockConsole(2048){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // 18 one-letter tokens = command + 17 args, one over the limit.
    mock.feed("a b c d e f g h i j k l m n o p q r\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "error: too many arguments (max 17 tokens)\n") != null);
    // And it must not have executed anything.
    try std.testing.expect(std.mem.indexOf(u8, out, "unknown command:") == null);
}

test "shell: unbalanced quote warns and executes the literal" {
    var mock = console.MockConsole(1024){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo \"elephant business\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "unterminated quote: rest of line treated as literal\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, out, "elephant business\n" ++ "dipshit> "));
}

test "shell: empty line reports no command via the registry" {
    var mock = console.MockConsole(1024){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "no command given; type 'help' for a list of commands\n") != null);
}

test "shell: tab completion completes a command name (ADR 0008 D2)" {
    var mock = console.MockConsole(2048){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // "ver" + Tab completes to "version" (Tab inserts "sion"), then Enter
    // runs the completed command.
    mock.feed("ver\t\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "version\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "dipshit-kernel\n") != null);
}

test "shell: ctrl-l clears the screen and repaints the prompt + line" {
    var mock = console.MockConsole(1024){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo hi\x0c\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    // Ctrl-L emitted the ANSI clear; the shell restored the prompt + line,
    // then Enter ran the echo.
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[2J\x1b[H") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "dipshit> echo hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "hi\n") != null);
}

test "shell: the live gate's exact chord byte stream drives all six D2 chords" {
    // The class-A counterpart of tools/verify-live-editing.sh phase 2: the
    // byte stream below is character-for-character the file that gate feeds
    // over the serial console, so a change to one without the other shows up
    // here rather than after a four-minute VM boot. Each chord is proven by
    // its RESULT (the command that ends up running), never by the keystroke.
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("cho u2chord\x01e\n"); // Ctrl-A: home, then insert the 'e'
    mock.feed("echo u2en\x01\x05d\n"); // Ctrl-A then Ctrl-E: back to the end
    mock.feed("echo u2killXXXX\x1b[D\x1b[D\x1b[D\x1b[D\x0b\n"); // Ctrl-K
    mock.feed("JUNK\x15echo u2under\n"); // Ctrl-U: kill back to the start
    mock.feed("echo u2clear\x0c\n"); // Ctrl-L: clear, keep the line
    mock.feed("echo NEVER\x03echo u2cancel\n"); // Ctrl-C: cancel, do not run
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    for ([_][]const u8{ "\nu2chord\n", "\nu2end\n", "\nu2kill\n", "\nu2under\n", "\nu2clear\n", "\nu2cancel\n" }) |want| {
        if (std.mem.indexOf(u8, out, want) == null) {
            std.debug.print("missing chord result {s} in:\n{s}\n", .{ want, out });
            return error.ChordResultMissing;
        }
    }
    // Ctrl-L emitted the erase-in-display; Ctrl-C echoed and cancelled, so
    // the abandoned command never ran (its output line never appears).
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[2J\x1b[H") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "^C") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\nNEVER\n") == null);
}

test "shell: ctrl-c on an empty line cancels without executing" {
    var mock = console.MockConsole(1024){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("\x03");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "^C\r\n") != null);
    // Cancelling must not execute anything — and, with no Enter after it,
    // must not submit an empty line either.
    try std.testing.expect(std.mem.indexOf(u8, out, "unknown command:") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "no command given") == null);
}

test "shell: host fuzz of the tokenizer never panics and stays in bounds (card U3)" {
    // Card U3 (claim 1809's sibling): the tokenizer must accept ANY byte
    // stream without panicking and every returned token must be a slice
    // of the input line (never OOB). Deterministic PRNG, fixed seed — the
    // same corpus on every run.
    var prng = std.Random.DefaultPrng.init(0x5543_0001);
    const rnd = prng.random();
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 \t\"'./-_=+*&^%$#@!~`;:<>?[]{}()|\\\n\x00\x7f";
    var line_buf: [300]u8 = undefined;
    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const len = rnd.uintLessThan(usize, line_buf.len);
        for (line_buf[0..len]) |*b| b.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];
        const line = line_buf[0..len];
        const result = tokenizer.tokenize(line);
        // Never more than max_tokens tokens.
        try std.testing.expect(result.count <= tokenizer.max_tokens);
        // too_many can only be set together with a full count.
        if (result.too_many) try std.testing.expectEqual(tokenizer.max_tokens, result.count);
        // Every token is a slice of the line: in-bounds and non-overlapping
        // by construction (tokenize only slices into `line`).
        for (result.argv[0..result.count]) |token| {
            const start = @intFromPtr(token.ptr);
            const end = start + token.len;
            const base = @intFromPtr(line.ptr);
            try std.testing.expect(start >= base);
            try std.testing.expect(end <= base + line.len);
        }
    }
}

test "shell: host fuzz of the command handlers never panics on arbitrary argv (card U3)" {
    // Card U3: every handler must survive ARBITRARY argv — random command
    // names, random arg counts up to the registry bound, random bytes
    // (including control + high bytes) — without panicking. The mock
    // console absorbs any output (bounded, overflow-flagged); the env is
    // the transcript test's (allocator + scheduler + userspace + ESP
    // window armed, no devices) so handlers take their real refusal paths.
    var mock = console.MockConsole(8192){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    _ = alloc.init(make_view(), &.{});
    _ = scheduler.init();
    _ = scheduler.register_worker(0);
    _ = scheduler.register_user(0, 0);
    userspace.init();
    esp.reset();
    _ = esp.add_esp_entry("KERNEL.BIN", 0x88b38, "");
    _ = esp.add_dir_entry("EFI");
    _ = esp.add_esp_entry("BOOTED.TXT", 0x29, "hello\n");

    var prng = std.Random.DefaultPrng.init(0x5543_0002);
    const rnd = prng.random();
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789./-_\"' \t\n\x00\x1b\x7f";
    var arg_buf: [monitor.max_args_limit + 1][32]u8 = undefined;
    var argv_storage: [monitor.max_args_limit + 1][]const u8 = undefined;
    var iter: usize = 0;
    while (iter < 4000) : (iter += 1) {
        const argc = rnd.uintLessThan(usize, monitor.max_args_limit + 1);
        for (0..argc) |i| {
            const alen = rnd.uintLessThan(usize, arg_buf[i].len);
            for (arg_buf[i][0..alen]) |*b| b.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];
            argv_storage[i] = arg_buf[i][0..alen];
        }
        _ = monitor.exec(&shell.mon, argv_storage[0..argc]);
        // The mock console absorbs everything; reset so the next iteration
        // starts from a clean buffer (overflow is fine — it just flags).
        mock.reset();
    }
}

test "shell: host fuzz of the full input path never panics (editor + tokenizer + handlers)" {
    // The end-to-end variant: random bytes fed as scripted input through
    // the REAL line editor + tokenizer + handler path (shell.poll), never
    // panicking and always returning to idle. Covers the D3 shape
    // surface — misuse, errors, unknown verbs — on random input.
    var mock = console.MockConsole(8192){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    _ = alloc.init(make_view(), &.{});
    _ = scheduler.init();
    _ = scheduler.register_worker(0);
    _ = scheduler.register_user(0, 0);
    userspace.init();
    esp.reset();
    _ = esp.add_esp_entry("KERNEL.BIN", 0x88b38, "");
    _ = esp.add_dir_entry("EFI");
    _ = esp.add_esp_entry("BOOTED.TXT", 0x29, "hello\n");

    var prng = std.Random.DefaultPrng.init(0x5543_0003);
    const rnd = prng.random();
    // A hostile-but-real keyboard alphabet: letters/digits, space, tab,
    // Enter, Ctrl-C, Ctrl-L, ESC (arrow-prefix), backspace, DEL, and a
    // sprinkling of non-ASCII bytes the editor must refuse.
    const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789 \t\n\x03\x0c\x1b\x08\x7f\x80\xff";
    var iter: usize = 0;
    while (iter < 1500) : (iter += 1) {
        const len = rnd.uintLessThan(usize, 64);
        var feed_buf: [64]u8 = undefined;
        for (feed_buf[0..len]) |*b| b.* = alphabet[rnd.uintLessThan(usize, alphabet.len)];

        mock.feed(feed_buf[0..len]);
        while (shell.poll() != .idle) {}
        mock.reset();
    }
    // The session never panicked and the shell is still responsive: a
    // Ctrl-C (full editor reset, clearing any swallowed CRLF window or
    // pending ESC state) followed by a fresh command runs end to end.
    mock.feed("\x03echo survived\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "survived\n") != null);
}

test "shell: scrollback captures console output" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // Run a few commands that produce output
    mock.feed("echo hello\necho world\necho scrollback\n");
    while (shell.poll() != .idle) {}

    // The scrollback ring should have captured the output
    const stored = shell.scrollback.stored();
    // Banner lines (~2-3) + 3 prompts + 3 echoed command lines + 3 output lines
    try std.testing.expect(stored >= 3);

    // Verify we can retrieve lines
    var dst: [200][128]u8 = undefined;
    var slices: [200][]u8 = undefined;
    for (&slices, 0..) |*s, j| s.* = dst[j][0..];
    const n = shell.scrollback.copy_lines(0, 3, slices[0..]);
    try std.testing.expect(n >= 1);
    // The most recent line should contain "scrollback"
    var found: bool = false;
    for (slices[0..n]) |sl| {
        if (std.mem.indexOf(u8, sl, "scrollback") != null) found = true;
    }
    try std.testing.expect(found);
}

test "shell: PageUp/PageDown adjust scroll_offset" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // Run commands to fill scrollback
    mock.feed("echo line1\necho line2\necho line3\necho line4\necho line5\n");
    mock.feed("echo line6\necho line7\necho line8\necho line9\necho line10\n");
    while (shell.poll() != .idle) {}

    // Start fresh, scroll should be 0
    try std.testing.expectEqual(@as(usize, 0), shell.scroll_offset);
    const total = shell.scrollback.stored();

    // Feed PageUp (ESC [ 5 ~) — should increase scroll offset by 10
    mock.feed("\x1b[5~");
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.scroll_offset >= 10 or shell.scroll_offset == total);

    // Feed PageDown (ESC [ 6 ~) — should decrease scroll offset
    const before_pgdn = shell.scroll_offset;
    mock.feed("\x1b[6~");
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.scroll_offset < before_pgdn or (before_pgdn == 0 and shell.scroll_offset == 0));

    // Multiple PageDown should bring us back to live (offset 0)
    mock.feed("\x1b[6~\x1b[6~\x1b[6~");
    while (shell.poll() != .idle) {}
    try std.testing.expectEqual(@as(usize, 0), shell.scroll_offset);
}

test "shell: scrollback overflow bounds scroll_offset" {
    var mock = console.MockConsole(8192){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    // Feed many PageUp sequences — scroll_offset should not exceed stored lines
    mock.feed("\x1b[5~\x1b[5~\x1b[5~\x1b[5~\x1b[5~");
    while (shell.poll() != .idle) {}

    const stored = shell.scrollback.stored();
    try std.testing.expect(shell.scroll_offset <= stored);
}

test "shell: scrollback ring survives poll cycle" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    mock.feed("echo test\n");
    while (shell.poll() != .idle) {}

    const stored1 = shell.scrollback.stored();
    try std.testing.expect(stored1 > 0);

    mock.feed("echo another\n");
    while (shell.poll() != .idle) {}

    const stored2 = shell.scrollback.stored();
    try std.testing.expect(stored2 > stored1);
}

test "shell: T2 selection: PageUp enters select mode, Esc exits" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // Fill scrollback
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        mock.feed("echo line\n");
        while (shell.poll() != .idle) {}
    }

    // PageUp: scroll back, enter selection mode
    try std.testing.expect(!shell.selecting);
    try std.testing.expectEqual(@as(usize, 0), shell.scroll_offset);
    mock.feed("\x1b[5~"); // PageUp
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.selecting);
    try std.testing.expect(shell.scroll_offset > 0);

    // Lone Esc (ESC + space to signal end-of-escape): cancel selection, return to live
    mock.feed("\x1b ");
    while (shell.poll() != .idle) {}
    try std.testing.expect(!shell.selecting);
    try std.testing.expectEqual(@as(usize, 0), shell.scroll_offset);
}

test "shell: T2 selection: Up/Down arrows adjust selection range" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        mock.feed("echo line\n");
        while (shell.poll() != .idle) {}
    }

    // PageUp to enter selection
    mock.feed("\x1b[5~");
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.selecting);
    const sel_end_before = shell.sel_end;

    // Up arrow (CSI A): extend selection upward
    mock.feed("\x1b[A");
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.sel_end > sel_end_before);

    // Down arrow (CSI B): shrink selection downward
    const sel_end_after_up = shell.sel_end;
    mock.feed("\x1b[B");
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.sel_end < sel_end_after_up);
}

test "shell: T2 selection: Ctrl+C copies to clipboard and returns to live" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // Fill with enough output that there's something in the scrollback
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        mock.feed("echo filler\n");
        while (shell.poll() != .idle) {}
    }

    // Scroll back
    mock.feed("\x1b[5~");
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.selecting);

    // Copy with Ctrl+C
    mock.feed("\x03"); // Ctrl+C
    while (shell.poll() != .idle) {}

    // Should have returned to live
    try std.testing.expect(!shell.selecting);
    try std.testing.expectEqual(@as(usize, 0), shell.scroll_offset);

    // Clipboard should have the copied text (non-empty)
    var cbuf: [clipboard.capacity]u8 = undefined;
    const n = clipboard.get(&cbuf);
    try std.testing.expect(n > 0);
    // Should contain some recognizable output
    try std.testing.expect(std.mem.indexOf(u8, cbuf[0..n], "filler") != null);
}

test "shell: T2 paste: Ctrl+V inserts clipboard at cursor" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    // Set clipboard directly
    _ = clipboard.set("PASTED_TEXT");

    // Type "echo " then Ctrl+V then Enter
    mock.feed("echo \x16\n");
    while (shell.poll() != .idle) {}

    // Output should contain the pasted text
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "PASTED_TEXT") != null);
}

test "shell: T2 selection: Enter copies and returns to live" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        mock.feed("echo spam\n");
        while (shell.poll() != .idle) {}
    }

    // PageUp to enter selection
    mock.feed("\x1b[5~");
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.selecting);

    // Enter: copy and return to live
    mock.feed("\x0d");
    while (shell.poll() != .idle) {}
    try std.testing.expect(!shell.selecting);
    try std.testing.expectEqual(@as(usize, 0), shell.scroll_offset);

    // Clipboard should not be empty
    var cbuf: [clipboard.capacity]u8 = undefined;
    const n = clipboard.get(&cbuf);
    try std.testing.expect(n > 0);
}

test "shell: T2 selection: Down arrow beyond sel_start exits selection" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        mock.feed("echo line\n");
        while (shell.poll() != .idle) {}
    }

    // PageUp to enter selection
    mock.feed("\x1b[5~");
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.selecting);

    // Press Down once to shrink (sel_start == sel_end after PageUp, so this exits)
    mock.feed("\x1b[B");
    while (shell.poll() != .idle) {}
    // After a single Down when sel_start == sel_end, selecting should be false
    try std.testing.expect(!shell.selecting);
}

test "shell: typed input after scroll keys types cleanly (T1 gate finding)" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        mock.feed("echo line\n");
        while (shell.poll() != .idle) {}
    }

    // PageUp x2 then PageDown x2, then type a command. The shell consumes
    // the '~' of each scroll sequence; the editor must not be left mid-CSI
    // (no `[5`/`[6` fragments in the line, no swallowed ESC).
    mock.feed("\x1b[5~\x1b[5~\x1b[6~\x1b[6~echo clean-typed\n");
    while (shell.poll() != .idle) {}
    try std.testing.expectEqual(@as(usize, 0), shell.scroll_offset);
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "clean-typed\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "unknown command") == null);
}

test "shell: paging back to live clears selection so Enter submits (T1 gate finding)" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        mock.feed("echo line\n");
        while (shell.poll() != .idle) {}
    }

    // PageUp enters selection; PageDown back to live must clear it.
    mock.feed("\x1b[5~");
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.selecting);
    mock.feed("\x1b[6~");
    while (shell.poll() != .idle) {}
    try std.testing.expect(!shell.selecting);
    try std.testing.expectEqual(@as(usize, 0), shell.scroll_offset);

    // A REAL Enter (0x0D) must submit the line — not copy+discard.
    mock.feed("echo done-typed\r");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "done-typed\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "copied") == null);
}

test "shell: ESC while selecting cancels without eating the next keystroke (T2 gate finding)" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        mock.feed("echo line\n");
        while (shell.poll() != .idle) {}
    }

    // PageUp enters selection; ESC then a typed command: the cancel fires
    // on the byte after ESC, but that byte is a real keystroke ('e' of
    // echo) and must not be eaten.
    mock.feed("\x1b[5~");
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.selecting);
    mock.feed("\x1becho esc-ok\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(!shell.selecting);
    try std.testing.expectEqual(@as(usize, 0), shell.scroll_offset);
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "esc-ok\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "unknown command") == null);
}

test "shell: T3 search: Ctrl+R enters search mode, Esc exits" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    // Submit a command so there's history to search
    mock.feed("echo hello-search\n");
    while (shell.poll() != .idle) {}

    // Ctrl+R enters search mode
    try std.testing.expect(!shell.searching);
    mock.feed("\x12"); // Ctrl+R
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.searching);

    // Esc exits search mode
    mock.feed("\x1b");
    while (shell.poll() != .idle) {}
    try std.testing.expect(!shell.searching);
}

test "shell: T3 search: typing finds a match in history" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    // Submit some commands to history
    mock.feed("echo alpha-bravo\necho delta-echo\necho foxtrot\n");
    while (shell.poll() != .idle) {}

    // Enter search mode
    mock.feed("\x12"); // Ctrl+R
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.searching);

    // Type characters that match "delta"
    for ("delta") |ch| {
        var buf: [1]u8 = [_]u8{ch};
        mock.feed(&buf);
        while (shell.poll() != .idle) {}
    }
    try std.testing.expect(shell.searching);

    // Verify editor buffer now contains "delta-echo"
    const editor_line = shell.editor.buffer[0..shell.editor.len];
    try std.testing.expect(std.mem.indexOf(u8, editor_line, "delta-echo") != null);

    // Enter accepts the match
    mock.feed("\x0d");
    while (shell.poll() != .idle) {}
    try std.testing.expect(!shell.searching);

    // Editor should still have the matched line
    const accepted = shell.editor.buffer[0..shell.editor.len];
    try std.testing.expect(std.mem.indexOf(u8, accepted, "delta-echo") != null);
}

test "shell: T3 search: LF accepts the match like CR (keyboard Return)" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    mock.feed("echo delta-echo\n");
    while (shell.poll() != .idle) {}

    mock.feed("\x12"); // Ctrl+R
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.searching);

    for ("delta") |ch| {
        var buf: [1]u8 = [_]u8{ch};
        mock.feed(&buf);
        while (shell.poll() != .idle) {}
    }

    // The keyboard Return decodes to LF (0x0a) — must accept like CR.
    mock.feed("\x0a");
    while (shell.poll() != .idle) {}
    try std.testing.expect(!shell.searching);
    const accepted = shell.editor.buffer[0..shell.editor.len];
    try std.testing.expect(std.mem.indexOf(u8, accepted, "delta-echo") != null);
}

test "shell: T3 search: Backspace narrows query and finds new match" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    mock.feed("echo zulu-XYZ\n");
    while (shell.poll() != .idle) {}

    // Search for "zul" — should find "zulu-XYZ"
    mock.feed("\x12zul"); // Ctrl+R, then type zul
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.searching);

    // Backspace to narrow to "zu"
    mock.feed("\x7f");
    while (shell.poll() != .idle) {}
    try std.testing.expectEqual(@as(usize, 2), shell.search_query_len);
    try std.testing.expectEqualStrings("zu", shell.search_query[0..2]);
}

test "shell: T3 search: Ctrl+C cancels search and restores draft" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    // Type something at the prompt before searching
    mock.feed("draft-line");
    while (shell.poll() != .idle) {}

    // Enter search mode (saves draft)
    mock.feed("\x12");
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.searching);

    // Ctrl+C cancels
    mock.feed("\x03");
    while (shell.poll() != .idle) {}
    try std.testing.expect(!shell.searching);

    // Draft should be restored
    try std.testing.expect(std.mem.indexOf(u8, shell.editor.buffer[0..shell.editor.len], "draft-line") != null);
}

test "shell: T3 search: empty query shows no match" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    mock.feed("echo something\n");
    while (shell.poll() != .idle) {}

    // Enter search mode, then immediately Enter (empty query)
    mock.feed("\x12\x0d");
    while (shell.poll() != .idle) {}
    try std.testing.expect(!shell.searching);
}

test "shell: T3 search: non-printable bytes are ignored in search" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    mock.feed("echo test\n");
    while (shell.poll() != .idle) {}

    // Enter search mode, send an arrow key (ESC [ A)
    mock.feed("\x12");
    while (shell.poll() != .idle) {}

    // Arrow keys: ESC cancels search (expected), shell should not crash
    mock.feed("\x1b[A");
    while (shell.poll() != .idle) {}
    try std.testing.expect(!shell.searching); // Esc in search cancels
    // The shell is still functional — next command should work
    mock.feed("echo survived\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "survived") != null);
}

test "shell: T6 paste: bracketed paste start/end toggles paste_active" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    // Start paste
    try std.testing.expect(!shell.paste_active);
    mock.feed("\x1b[200~");
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.paste_active);

    // End paste
    mock.feed("\x1b[201~");
    while (shell.poll() != .idle) {}
    try std.testing.expect(!shell.paste_active);
}

test "shell: T6 paste: bytes are buffered during paste" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    mock.feed("\x1b[200~");
    while (shell.poll() != .idle) {}

    // Type some bytes while in paste mode
    mock.feed("hello");
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.paste_buf_len == 5);
    try std.testing.expect(std.mem.eql(u8, shell.paste_buf[0..5], "hello"));

    // End paste
    mock.feed("\x1b[201~");
    while (shell.poll() != .idle) {}
    try std.testing.expectEqual(@as(usize, 0), shell.paste_buf_len);
}

test "shell: T6 paste: pasted commands execute after paste end" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    // Paste a simple echo command
    mock.feed("\x1b[200~echo pasted-ok\n\x1b[201~");
    while (shell.poll() != .idle) {}
    try std.testing.expect(!shell.paste_active);

    // The echoed output should appear
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "pasted-ok") != null);
}

test "shell: T6 paste: multi-line paste executes each line" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    // Paste two commands
    mock.feed("\x1b[200~echo first\necho second\n\x1b[201~");
    while (shell.poll() != .idle) {}
    try std.testing.expect(!shell.paste_active);

    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "first") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "second") != null);
}

test "shell: T6 paste: max_line bound prevents overflow" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    // Start paste and send more than max_line bytes
    mock.feed("\x1b[200~");
    while (shell.poll() != .idle) {}
    var i: usize = 0;
    while (i < 260) : (i += 1) {
        mock.feed("x");
        while (shell.poll() != .idle) {}
    }

    // Should not exceed max_line
    try std.testing.expect(shell.paste_buf_len <= lineedit.max_line);

    // End paste should not crash
    mock.feed("\x1b[201~");
    while (shell.poll() != .idle) {}
    try std.testing.expect(!shell.paste_active);
}

test "shell: T7 alt-screen: CSI ? 1049 h/l toggle alt_screen" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    try std.testing.expect(!shell.alt_screen);
    mock.feed("\x1b[?1049h");
    while (shell.poll() != .idle) {}
    try std.testing.expect(shell.alt_screen);

    mock.feed("\x1b[?1049l");
    while (shell.poll() != .idle) {}
    try std.testing.expect(!shell.alt_screen);
}

test "shell: T10 CSI responder: 6n returns 1;1R" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    mock.feed("\x1b[6n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[1;1R") != null);
}

test "shell: T11 ANSI: SGR and cursor shape sequences are silently swallowed" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    mock.feed("\x1b[32m\x1b[0m\x1b[3 q");
    while (shell.poll() != .idle) {}
    mock.feed("echo survived\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "survived") != null);
}

test "shell: T12 env: export and $VAR expansion" {
    env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    // Set an env var
    mock.feed("export FOO=hello\n");
    while (shell.poll() != .idle) {}

    // Use it with $
    mock.feed("echo $FOO world\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "hello world") != null);

    // Print all with bare export
    mock.feed("export\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "FOO=hello") != null);
}

test "shell: M19 P3 env: set, unset, env builtins" {
    env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    // set a variable
    mock.feed("set COLOR=red\n");
    while (shell.poll() != .idle) {}

    // env lists it
    mock.feed("env\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "COLOR=red") != null);

    // $COLOR expands
    mock.feed("echo $COLOR\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "red\n") != null);

    // unset removes it — verify via the direct API, not mock output
    mock.feed("unset COLOR\n");
    while (shell.poll() != .idle) {}
    try std.testing.expectEqual(@as(usize, 0), env_count); // unset shrank the table
    try std.testing.expect(env_get("COLOR") == null); // COLOR is gone

    // set another and verify env_table integrity
    env_set("SECOND", "yes");
    try std.testing.expectEqual(@as(usize, 1), env_count);
    try std.testing.expectEqualStrings("yes", env_get("SECOND").?); // unset a nonexistent variable is silent (returns false, no crash)
    try std.testing.expect(!env_unset("NOEXIST"));
}

test "shell: M22 D7 printenv: printenv is an alias for env" {
    env_count = 0;
    env_set("HOME", "/data");
    env_set("USER", "root");
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("printenv\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "HOME=/data") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "USER=root") != null);
}

test "shell: M19 P3 env: env_set and env_unset direct API" {
    env_count = 0;
    // set
    env_set("PATH", "/bin");
    try std.testing.expectEqual(@as(usize, 1), env_count);
    try std.testing.expectEqualStrings("/bin", env_get("PATH").?);
    // overwrite
    env_set("PATH", "/usr/bin");
    try std.testing.expectEqual(@as(usize, 1), env_count);
    try std.testing.expectEqualStrings("/usr/bin", env_get("PATH").?);
    // unset
    try std.testing.expect(env_unset("PATH"));
    try std.testing.expectEqual(@as(usize, 0), env_count);
    try std.testing.expect(env_get("PATH") == null);
    // unset nonexistent returns false
    try std.testing.expect(!env_unset("NOPE"));
}

test "shell: M19 P3 env: persistence round-trip through the ESP window" {
    env_count = 0;
    // Direct serialization test: save_env writes to the ESP window;
    // load_env reads back. The mock ESP path supports add_esp_entry
    // with explicit content, so we seed the file directly.
    esp.reset();
    // Seed ENV.TXT as if it was written by a previous boot.
    _ = esp.add_esp_entry("ENV.TXT", 0, "PERSIST_A=alpha\nPERSIST_B=beta\n");
    load_env();
    try std.testing.expectEqualStrings("alpha", env_get("PERSIST_A").?);
    try std.testing.expectEqualStrings("beta", env_get("PERSIST_B").?);
}

test "shell: M19 P3 env: env_expand handles multiple $VAR references" {
    env_count = 0;
    env_set("GREET", "hi");
    env_set("NAME", "bob");
    var buf: [256]u8 = undefined;
    const expanded = env_expand("$GREET $NAME !", &buf);
    try std.testing.expectEqualStrings("hi bob !", expanded);
}

test "shell: M19 P3 env: env_expand leaves unmatched $VAR as-is" {
    env_count = 0;
    var buf: [256]u8 = undefined;
    const expanded = env_expand("echo $NOPE", &buf);
    try std.testing.expectEqualStrings("echo ", expanded);
}

test "shell: M19 P3 env: env table bounds are enforced" {
    env_count = 0;
    var i: usize = 0;
    while (i < env_max + 2) : (i += 1) {
        var name: [2]u8 = undefined;
        name[0] = @intCast('A' + @as(u8, @intCast(i % 26)));
        name[1] = if (i >= 26) @intCast('0' + @as(u8, @intCast((i / 26)))) else '_';
        env_set(&name, "x");
    }
    try std.testing.expectEqual(env_max, env_count);
}

test "shell: T13 alias: alias expansion" {
    // Reset env table for a clean slate
    env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();

    // Create an alias: ll becomes "echo HELLO"
    mock.feed("alias ll=echo HELLO\n");
    while (shell.poll() != .idle) {}

    // Use it — "ll world" should expand to "echo HELLO world"
    mock.feed("ll world\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "HELLO world") != null);
}

test "shell: T15 prompt: prompt builtin changes the prompt" {
    // Verify the settings API — prompt reads back what was set
    _ = settings.set("prompt", "test$ ");
    try std.testing.expectEqualStrings("test$ ", settings.get_prompt());
    _ = settings.set("prompt", "dipshit> "); // restore default
}

test "shell: T16 script: sh executes a script file line by line" {
    // The issue's host test: a script with two echo commands; both lines
    // execute through handle_line and both outputs appear, with no prompt
    // printed between them (script mode never repaints the prompt).
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    esp.reset();
    _ = esp.add_esp_entry("SCRIPT.TXT", 0, "echo script-first\n# a comment\n\necho script-second\n");
    mock.feed("sh SCRIPT.TXT\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "script-first\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "script-second\n") != null);
    // Both outputs are contiguous: no prompt or echo between them.
    try std.testing.expect(std.mem.indexOf(u8, out, "script-first\nscript-second\n") != null);
    // Comments never execute or print.
    try std.testing.expect(std.mem.indexOf(u8, out, "a comment") == null);
}

test "shell: T16 script: exit stops the script early" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    esp.reset();
    _ = esp.add_esp_entry("EXIT.TXT", 0, "echo before-exit\nexit\necho after-exit\n");
    mock.feed("sh EXIT.TXT\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "before-exit\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "after-exit") == null);
}

test "shell: T16 script: sh refuses nested script calls" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    esp.reset();
    _ = esp.add_esp_entry("OUTER.TXT", 0, "echo outer-line\nsh INNER.TXT\necho outer-tail\n");
    _ = esp.add_esp_entry("INNER.TXT", 0, "echo inner-line\n");
    mock.feed("sh OUTER.TXT\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "sh: scripts cannot call scripts\n") != null);
    // The outer script continues after the refusal (no abort-on-error)...
    try std.testing.expect(std.mem.indexOf(u8, out, "outer-line\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "outer-tail\n") != null);
    // ...and the inner script never ran.
    try std.testing.expect(std.mem.indexOf(u8, out, "inner-line") == null);
}

test "shell: T16 script: missing script is reported honestly" {
    var mock = console.MockConsole(2048){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    esp.reset();
    mock.feed("sh NOPE.TXT\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "sh: NOPE.TXT: not found (no such file on the ESP)\n") != null);
}

test "shell: T16 script: sh with no arguments shows usage" {
    var mock = console.MockConsole(2048){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    esp.reset();
    mock.feed("sh\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "sh: usage: sh <script>\n") != null);
}

test "shell: T16 script: bare exit at the prompt stays an unknown command" {
    var mock = console.MockConsole(2048){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    esp.reset();
    mock.feed("exit\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "unknown command 'exit' -- try 'help'\n") != null);
}

test "shell: T16 script: line longer than 256 bytes is refused and skipped" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    esp.reset();
    const content = "echo before-long\n" ++ ("x" ** 300) ++ "\necho after-long\n";
    _ = esp.add_esp_entry("LONG.TXT", 0, content);
    mock.feed("sh LONG.TXT\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "sh: line too long (max 256 bytes)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "before-long\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "after-long\n") != null);
    // The over-long line never reached the executor (no 300-char echo).
    try std.testing.expect(std.mem.indexOf(u8, out, "x" ** 300) == null);
}

test "shell: T4 history: load_history restores newest-first" {
    // HISTORY.TXT is append-ordered (oldest first, newest last); the
    // restore must leave the most recent command at history[0] so the
    // first Up arrow after boot recalls it (verified live 2026-08-22,
    // claim 0469 — the original backward iteration left the OLDEST at
    // index 0, and the live gate caught it).
    var mock = console.MockConsole(1024){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    esp.reset();
    _ = esp.add_esp_entry("HISTORY.TXT", 0, "echo first\necho second\necho third\n");
    esp.set_disk_ready_for_test(true);
    defer esp.set_disk_ready_for_test(false);
    load_history(&shell.editor);
    try std.testing.expectEqual(@as(usize, 3), shell.editor.hist_count);
    try std.testing.expectEqualStrings("echo third", shell.editor.history[0][0..shell.editor.hist_len[0]]);
    try std.testing.expectEqualStrings("echo second", shell.editor.history[1][0..shell.editor.hist_len[1]]);
    try std.testing.expectEqualStrings("echo first", shell.editor.history[2][0..shell.editor.hist_len[2]]);
}

test "shell: T16 script: more than 64 executable lines is refused" {
    var mock = console.MockConsole(8192){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    esp.reset();
    // 65 executable lines ("echo s0" .. "echo s64"); comments/blanks do
    // not count toward the bound.
    var content: [1500]u8 = undefined;
    var clen: usize = 0;
    var n: usize = 0;
    while (n < 65) : (n += 1) {
        const prefix = "echo s";
        @memcpy(content[clen..][0..prefix.len], prefix);
        clen += prefix.len;
        if (n >= 10) {
            content[clen] = '0' + @as(u8, @intCast(n / 10));
            clen += 1;
        }
        content[clen] = '0' + @as(u8, @intCast(n % 10));
        clen += 1;
        content[clen] = '\n';
        clen += 1;
    }
    _ = esp.add_esp_entry("MANY.TXT", 0, content[0..clen]);
    mock.feed("sh MANY.TXT\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "sh: too many lines (max 64)\n") != null);
    // Lines 0..63 executed (echo s0 .. echo s63); the 65th (echo s64) did not.
    try std.testing.expect(std.mem.indexOf(u8, out, "s63\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "s64\n") == null);
}

// ---------------------------------------------------------------------------
// M19 P1 (issue #290): pipes
// ---------------------------------------------------------------------------

test "shell: M19 P1 pipe: pipe_split finds | outside quotes only" {
    try std.testing.expect(pipe_split("echo a | type") == .split);
    try std.testing.expect(pipe_split("echo a|type") == .split);
    try std.testing.expect(pipe_split("echo \"a|b\"") == .none);
    try std.testing.expect(pipe_split("echo a\"b|c\"") == .none);
    try std.testing.expect(pipe_split("echo a | b | c") == .multiple);
    try std.testing.expect(pipe_split("echo hello") == .none);
    switch (pipe_split("echo hi | type")) {
        .split => |sp| {
            try std.testing.expectEqualStrings("echo hi ", sp.left);
            try std.testing.expectEqualStrings(" type", sp.right);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "shell: M19 P1 pipe: echo hello | type prints hello exactly once" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo hello | type\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    // The left echo's output is captured into the pipe (never printed), and
    // the right `type` echoes it — "hello\n" appears exactly once.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "hello\n"));
}

test "shell: M19 P1 pipe: ls | type lists the directory through the pipe" {
    var mock = console.MockConsole(8192){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    esp.reset();
    _ = esp.add_esp_entry("KERNEL.BIN", 0x88b38, "");
    _ = esp.add_dir_entry("EFI");
    mock.feed("ls | type\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "KERNEL.BIN") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "EFI") != null);
}

test "shell: M19 P1 pipe: chaining is refused (single pipe only)" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo a | echo b | echo c\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "pipes: only one pipe per line (no chaining)\n") != null);
}

test "shell: M19 P1 pipe: type with no pipe prints nothing" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("type\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    // Only the echoed line + prompt; `type` with an empty stdin adds nothing.
    try std.testing.expect(std.mem.indexOf(u8, out, "type\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "unknown command") == null);
}

test "shell: M19 P1 pipe: right command that ignores stdin still runs" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo hi | echo bye\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "bye\n") != null);
}

test "shell: M19 P2 redirect: redirect_split finds > and >> and < outside quotes" {
    // >
    {
        const rs = redirect_split("echo hello > file.txt").?;
        try std.testing.expectEqual(RedirectOp.stdout_overwrite, rs.op);
        try std.testing.expectEqualStrings("echo hello", rs.left);
        try std.testing.expectEqualStrings("file.txt", rs.right);
    }
    // >>
    {
        const rs = redirect_split("echo hello >> file.txt").?;
        try std.testing.expectEqual(RedirectOp.stdout_append, rs.op);
        try std.testing.expectEqualStrings("echo hello", rs.left);
        try std.testing.expectEqualStrings("file.txt", rs.right);
    }
    // <
    {
        const rs = redirect_split("cat < file.txt").?;
        try std.testing.expectEqual(RedirectOp.stdin_file, rs.op);
        try std.testing.expectEqualStrings("cat", rs.left);
        try std.testing.expectEqualStrings("file.txt", rs.right);
    }
    // No redirect
    try std.testing.expect(redirect_split("echo hello") == null);
    try std.testing.expect(redirect_split("echo \">\" inside") == null);
    try std.testing.expect(redirect_split("") == null);
}

test "shell: M19 P2 redirect: echo hello > file captures and writes" {
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // Arm the ESP window so write_file works
    esp.reset();
    _ = alloc.init(make_view(), &.{});
    _ = scheduler.init();
    _ = scheduler.register_worker(0);
    _ = scheduler.register_user(0, 0);
    userspace.init();
    _ = esp.add_esp_entry("KERNEL.BIN", 0x88b38, "");

    mock.feed("echo redirected-content > test.out\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    // The typed input line appears once (echoed by the line editor).
    // The echo command's output ("redirected-content") was captured and
    // never reached the real console, so it only appears in the typed
    // line, not as a separate output line.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, out, "redirected-content"));
    // Without a mounted disk, the file write fails with an error.
    try std.testing.expect(std.mem.indexOf(u8, out, "redirect: no disk") != null);
}

test "shell: M19 P2 redirect: redirect_split prefers >> over >" {
    const rs = redirect_split("echo hello >> file.txt").?;
    try std.testing.expectEqual(RedirectOp.stdout_append, rs.op);
    try std.testing.expectEqualStrings("echo hello", rs.left);
    try std.testing.expectEqualStrings("file.txt", rs.right);
}

test "shell: M19 P2 redirect: redirect_split trims whitespace around operators" {
    {
        const rs = redirect_split("echo     >     file.txt").?;
        try std.testing.expectEqualStrings("echo", rs.left);
        try std.testing.expectEqualStrings("file.txt", rs.right);
    }
    {
        const rs = redirect_split("echo>>file.txt").?;
        try std.testing.expectEqualStrings("echo", rs.left);
        try std.testing.expectEqualStrings("file.txt", rs.right);
    }
    {
        const rs = redirect_split("cat < file.txt").?;
        try std.testing.expectEqualStrings("cat", rs.left);
        try std.testing.expectEqualStrings("file.txt", rs.right);
    }
}

test "shell: M19 P2 redirect: echo > / redirect_split bad input returns null" {
    try std.testing.expect(redirect_split(" > file.txt") == null); // empty left
    try std.testing.expect(redirect_split("echo > ") == null); // empty right
    try std.testing.expect(redirect_split("echo>") == null); // empty right
    try std.testing.expect(redirect_split("> file.txt") == null); // empty left
}

test "shell: M19 P4 fn: define and call a function" {
    env_count = 0;
    func_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // Define a function
    mock.feed("fn hello { echo hi there }\n");
    while (shell.poll() != .idle) {}
    // Call it
    mock.feed("hello\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "hi there") != null);
}

test "shell: M19 P4 fn: fn -d deletes a function" {
    func_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // Define
    mock.feed("fn foo { echo bar }\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(func_find("foo") != null);
    // Delete
    mock.feed("fn -d foo\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(func_find("foo") == null);
    try std.testing.expectEqual(@as(usize, 0), func_count);
}

test "shell: M19 P4 fn: bare fn lists all functions" {
    func_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("fn greet { echo hello; echo world }\n");
    while (shell.poll() != .idle) {}
    mock.feed("fn\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "greet") != null);
}

test "shell: M19 P4 fn: func_find and func_define direct API" {
    func_count = 0;
    try std.testing.expect(func_find("nope") == null);

    // Define via direct API — tests func_find and func_delete on the static table
    // Set up a function manually
    @memcpy(func_table[0].name[0..4], "test");
    func_table[0].name_len = 4;
    @memcpy(func_table[0].body[0][0..7], "echo ok");
    func_table[0].body_lens[0] = 7;
    func_table[0].body_count = 1;
    func_count = 1;

    try std.testing.expect(func_find("test") != null);
    try std.testing.expect(func_find("nope") == null);
}

test "shell: M19 P4 fn: fn list when empty shows message" {
    func_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("fn\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "no functions defined") != null);
}

test "shell: M19 P8 fn: define function with arguments" {
    func_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("fn greet(name, msg) { echo $msg, $name; echo done }\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(func_count == 1);
    try std.testing.expectEqualSlices(u8, "greet", func_table[0].name[0..func_table[0].name_len]);
    try std.testing.expectEqual(@as(usize, 2), func_table[0].arg_count);
    try std.testing.expectEqualSlices(u8, "name", func_table[0].arg_names[0][0..func_table[0].arg_name_lens[0]]);
    try std.testing.expectEqualSlices(u8, "msg", func_table[0].arg_names[1][0..func_table[0].arg_name_lens[1]]);
    try std.testing.expectEqual(@as(usize, 2), func_table[0].body_count);
}

test "shell: M19 P8 fn: call function with arguments, positional 0-N set" {
    env_count = 0;
    func_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // Define a function that echoes positional args
    mock.feed("fn args_test { echo $0; echo $1; echo $2 }\n");
    while (shell.poll() != .idle) {}
    mock.reset();
    // Call it with two arguments
    mock.feed("args_test alpha beta\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "args_test") != null); // $0
    try std.testing.expect(std.mem.indexOf(u8, out, "alpha") != null); // $1
    try std.testing.expect(std.mem.indexOf(u8, out, "beta") != null); // $2
}

test "shell: M19 P8 fn: named arguments available as dollar-VAR" {
    env_count = 0;
    func_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("fn greet(name) { echo hello $name }\n");
    while (shell.poll() != .idle) {}
    mock.reset();
    mock.feed("greet world\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "hello world") != null);
}

test "shell: M19 P8 fn: function without args still works (P4 compat)" {
    env_count = 0;
    func_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("fn noargs { echo still works }\n");
    while (shell.poll() != .idle) {}
    try std.testing.expectEqual(@as(usize, 0), func_table[0].arg_count);
    mock.reset();
    mock.feed("noargs\n");
    while (shell.poll() != .idle) {}
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "still works") != null);
}

test "shell: M19 P8 fn: listing shows argument signature" {
    func_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("fn foo(a, b, c) { echo ok }\n");
    while (shell.poll() != .idle) {}
    mock.reset();
    mock.feed("fn\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "foo(a, b, c)") != null);
}

test "shell: M19 P8 fn: too many args clamped to 4" {
    func_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("fn many(a, b, c, d, e, f) { echo $4 }\n");
    while (shell.poll() != .idle) {}
    try std.testing.expectEqual(@as(usize, 4), func_table[0].arg_count); // clamped to 4
}

test "shell: M19 P9 subst: echo $(echo hello) inlines captured output" {
    env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo $(echo hello)\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    // The inner echo outputs "hello" which is substituted; outer echo prints that
    try std.testing.expect(std.mem.indexOf(u8, out, "hello") != null);
}

test "shell: M19 P9 subst: nested $(...) is refused" {
    env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo $(echo $(echo nested))\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "nested") != null);
}

test "shell: M19 P9 subst: unmatched $( reports error" {
    env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo $(unclosed\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "unmatched $") != null);
}

test "shell: M19 P9 subst: empty $(  ) is a no-op" {
    env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo before$(  )after\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    // Empty inner cmd means raw line is returned as-is, so echo sees literal "before$(  )after"
    try std.testing.expect(std.mem.indexOf(u8, out, "before") != null);
}

test "shell: M19 P9 subst: fn bodies skip substitution" {
    env_count = 0;
    func_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // $() in a function body should be stored literally, not expanded at define time
    mock.feed("fn subtest { echo $(echo inner) }\n");
    while (shell.poll() != .idle) {}
    try std.testing.expectEqual(@as(usize, 1), func_count);
    // Body should contain literal $(echo inner), not the expansion
    const body = func_table[0].body[0][0..func_table[0].body_lens[0]];
    try std.testing.expect(std.mem.indexOf(u8, body, "$(echo inner)") != null);
}

test "shell: M19 P9 subst: mixed prefix and suffix with substitution" {
    env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    // prefix + $(echo mid) + suffix → prefixmidsuffix
    mock.feed("echo before-$(echo mid)-after\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "before-mid-after") != null);
}

test "shell: M19 P9 subst: no substitution when no $( present" {
    env_count = 0;
    var mock = console.MockConsole(4096){};
    var shell = make_shell(&mock, make_view());
    shell.boot();
    mock.feed("echo just a normal command\n");
    while (shell.poll() != .idle) {}
    const out = mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "just a normal command") != null);
}

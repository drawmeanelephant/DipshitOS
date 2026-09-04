//! VirelaiOS ESP user program — DEVCONS.BIN (M22 D14, issue #337, claim 9815).
//!
//! Developer console window: split-screen layout with a log pane (top) and
//! a command prompt (bottom). Commands typed at the prompt execute through
//! sys_exec (slot 28) and their output appears in the log pane.
//!
//! Without sys_dmesg_read (not in M22 ABI budget), the log pane shows
//! boot markers and command output only — honest about the limitation.
//!
//! No libc, no POSIX, no heap; state lives on the task stack.

const std = @import("std");
const ui = @import("lib/ui.zig");

const win_x: u32 = 260;
const win_y: u32 = 24;
const win_w: u32 = 400;
const win_h: u32 = 300;

const log_lines: usize = 20;
const log_line_h: u32 = 12;
const prompt_y: u32 = 250;
const input_max: usize = 64;

var log_buf: [log_lines * 128]u8 = undefined;
var log_lens: [log_lines]u16 = undefined;
var log_head: usize = 0;
var log_count: usize = 0;
var cursor_kind: ui.CursorKind = .arrow; // M37 DQ4: per-region cursor state

/// M37 DQ4: ibeam over the prompt line (text entry), arrow elsewhere.
/// Emits `devcons: cursor=<name>` on change (serial-observable).
fn update_cursor(x: u32, y: u32) void {
    _ = x;
    const kind = ui.cursor_for_region(false, false, y >= prompt_y);
    if (kind != cursor_kind) {
        cursor_kind = kind;
        var buf: [48]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "devcons: cursor={s}\n", .{kind.name()}) catch return;
        ui.write_console(msg);
    }
}

pub export fn _start() callconv(.c) noreturn {
    // M37 DQ4: follow the desktop theme first.
    _ = ui.sync_theme_from_host();
    const win_res = ui.win_open(win_x, win_y, win_w, win_h);
    if (win_res < 0) {
        ui.write_console("devcons: failed to open window\n");
        ui.exit_process(1);
    }
    const win: u32 = @intCast(win_res);
    ui.write_console("devcons: open\n");

    log_append("VirelaiOS Developer Console (M22 D14)");
    log_append("Type commands at the prompt below.");
    log_append("---");
    refresh(win);
    ui.emit_tokens_marker("devcons");
    ui.write_console("devcons: ready\n");
    // M37 DQ4 gate: let the compositor settle (several ticks) so the
    // kind-4 snapshot captures the presented frame, not a stale one.
    ui.sleep_ticks(50);
    ui.write_console("devcons: settled\n");

    var ev: ui.Event = undefined;
    var input_buf: [input_max]u8 = undefined;
    var input_len: usize = 0;

    while (true) {
        if (ui.wait_event(&ev) < 0) break;
        switch (ev.kind) {
            ui.WIN_CLOSE => {
                ui.win_close(win);
                ui.exit_process(0);
            },
            ui.MOUSE_MOVE => {
                // M37 DQ4: cursor tracking only (no click actions).
                update_cursor(ev.arg0, ev.arg1);
            },
            ui.KEY_DOWN => {
                // ADR 0009 event convention (as EDIT.BIN consumes it): arg0 is
                // the raw HID usage (Enter 0x28, Backspace 0x2a), arg1 is the
                // ASCII byte for printable keys. Comparing arg0 against ASCII
                // ranges rejects every printable key (usage 0x07 for 'd'), so
                // the typed-input gate (issue #553) caught this live: the
                // prompt buffered nothing and Enter executed nothing.
                const usage = ev.arg0;
                const ascii = ev.arg1;
                if (usage == 0x28) {
                    // Enter: execute command
                    if (input_len > 0) {
                        execute_command(input_buf[0..input_len]);
                        input_len = 0;
                    }
                    refresh(win);
                } else if (usage == 0x2a) {
                    // Backspace
                    if (input_len > 0) input_len -= 1;
                    refresh(win);
                } else if (ascii >= 0x20 and ascii < 0x7f and input_len < input_max) {
                    input_buf[input_len] = @intCast(ascii);
                    input_len += 1;
                    refresh(win);
                }
            },
            else => {},
        }
    }
    ui.exit_process(0);
}

fn log_append(msg: []const u8) void {
    const idx = (log_head + log_count) % log_lines;
    const start = idx * 128;
    const take = @min(msg.len, 127);
    @memcpy(log_buf[start..][0..take], msg[0..take]);
    log_buf[start + take] = 0;
    log_lens[idx] = @intCast(take);
    if (log_count < log_lines) {
        log_count += 1;
    } else {
        log_head = (log_head + 1) % log_lines;
    }
}

fn execute_command(cmd: []const u8) void {
    var buf: [128]u8 = undefined;
    var n: usize = 0;
    const prefix = "> ";
    @memcpy(buf[0..prefix.len], prefix);
    n = prefix.len;
    const take = @min(cmd.len, buf.len - n - 1);
    @memcpy(buf[n..][0..take], cmd[0..take]);
    n += take;
    buf[n] = 0;
    log_append(buf[0..n]);

    // Execute via sys_exec (slot 28) — the command runs as a child process.
    // Output goes to the serial console (not captured into the log pane
    // without sys_dmesg_read, but the marker proves execution happened).
    const exec_res = ui.exec_program(cmd);
    if (exec_res < 0) {
        log_append("exec: failed");
    } else {
        log_append("exec: ok (output on serial)");
    }
}

fn refresh(win: u32) void {
    // Background
    ui.win_fill(win, 0, 0, win_w, win_h, ui.theme_bg());
    // Title bar
    ui.win_fill(win, 0, 0, win_w, 6, ui.theme_surface());
    ui.draw_text(win, "Developer Console", ui.pad_md, 8, ui.theme_text_muted());

    // Log pane (top section) — M37 DQ4: unified surface (was 0x1a1a2e).
    ui.win_fill(win, 0, 18, win_w, prompt_y - 18, ui.theme_surface());
    var y: u32 = 22;
    var i: usize = 0;
    while (i < log_count and i < log_lines) : (i += 1) {
        const idx = (log_head + i) % log_lines;
        const len = log_lens[idx];
        if (len > 0) {
            const start = idx * 128;
            ui.draw_text_mono(win, log_buf[start..][0..len], ui.pad_md, y, ui.theme_text_primary());
        }
        y += log_line_h;
        if (y + log_line_h > prompt_y - 4) break;
    }

    // Separator
    ui.win_fill(win, 0, prompt_y - 2, win_w, ui.border_w, ui.theme_text_muted());

    // Prompt area
    ui.draw_text(win, "$ ", ui.pad_sm, prompt_y + 4, ui.theme_success());

    // Show a hint about serial output
    ui.draw_text(win, "(output on serial console)", 80, prompt_y + 4, ui.theme_text_muted());

    ui.win_present(win);
}

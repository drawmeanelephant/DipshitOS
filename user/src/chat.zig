//! VirelaiOS Peer-to-Peer Chat — CHAT.BIN (Milestone 12, Card N3, Issue #150).
//!
//! Graphical peer-to-peer messaging application:
//! - Driving Award GUI windowing (`sys_win_open`, `sys_win_present`, `ui.zig`)
//! - UDP network transport (`sys_udp_listen(7777)`, `sys_udp_send`, `sys_udp_recv`)
//! - Micro-widget event loop (keyboard input, send button, message log)

const std = @import("std");
const ui = @import("lib/ui.zig");
const Rect = ui.Rect;
const Button = ui.Button;
const TextInput = ui.TextInput;
const Event = ui.Event;

pub const window_x: u32 = 70;
pub const window_y: u32 = 70;
pub const window_w: u32 = 280;
pub const window_h: u32 = 200;

pub const chat_port: u16 = 7777;
pub const peer_ip: u32 = 0x0a000002; // 10.0.0.2

pub const max_history: usize = 6;
pub const max_msg_len: usize = 32;

pub const ChatMessage = struct {
    sender_is_me: bool = false,
    text: [max_msg_len]u8 = [_]u8{0} ** max_msg_len,
    len: usize = 0,
};

pub const ChatApp = struct {
    history: [max_history]ChatMessage = [_]ChatMessage{.{}} ** max_history,
    history_count: usize = 0,
    input_box: TextInput = TextInput.init(Rect.make(12, 160, 195, 24)),
    send_btn: Button = Button.init(Rect.make(215, 160, 55, 24), "Send"),
    status: [24]u8 = "Listening: 7777\x00\x00\x00\x00\x00\x00\x00\x00\x00".*,
    status_len: usize = 15,

    pub fn init() ChatApp {
        var app = ChatApp{};
        app.input_box.focused = true;
        return app;
    }

    pub fn add_message(self: *ChatApp, is_me: bool, text: []const u8) void {
        if (self.history_count >= max_history) {
            // Shift history up
            var i: usize = 0;
            while (i < max_history - 1) : (i += 1) {
                self.history[i] = self.history[i + 1];
            }
            self.history_count = max_history - 1;
        }

        const slot = &self.history[self.history_count];
        slot.sender_is_me = is_me;
        const copy_len = @min(text.len, max_msg_len);
        @memcpy(slot.text[0..copy_len], text[0..copy_len]);
        slot.len = copy_len;
        self.history_count += 1;
    }

    pub fn send_current_message(self: *ChatApp) bool {
        const text = self.input_box.get_text();
        if (text.len == 0) return false;

        _ = ui.udp_send(peer_ip, chat_port, text);
        self.add_message(true, text);
        self.input_box.clear();
        return true;
    }

    pub fn draw(self: *const ChatApp, win_id: u32) void {
        // Window background
        ui.draw_rect(win_id, Rect.make(0, 0, window_w, window_h), ui.COLOR_BG);

        // Title bar
        const title_rect = Rect.make(0, 0, window_w, 24);
        ui.draw_rect(win_id, title_rect, ui.COLOR_SURFACE);
        ui.draw_rect_outline(win_id, title_rect, 1, ui.COLOR_BORDER);
        ui.draw_text(win_id, "Virelai Chat", 8, 8, ui.COLOR_TEXT_PRIMARY);
        ui.draw_text(win_id, ":7777", 230, 8, ui.COLOR_TEXT_MUTED);

        // Chat message history container
        const hist_rect = Rect.make(10, 32, window_w - 20, 118);
        ui.draw_rect(win_id, hist_rect, ui.COLOR_SURFACE);
        ui.draw_rect_outline(win_id, hist_rect, 1, ui.COLOR_BORDER);

        // Render message history rows
        var row: usize = 0;
        while (row < self.history_count) : (row += 1) {
            const msg = &self.history[row];
            const y = hist_rect.y + 6 + @as(u32, @truncate(row)) * 18;

            if (msg.sender_is_me) {
                ui.draw_text(win_id, "You: ", hist_rect.x + 8, y, ui.COLOR_ACCENT);
                ui.draw_text(win_id, msg.text[0..msg.len], hist_rect.x + 48, y, ui.COLOR_TEXT_PRIMARY);
            } else {
                ui.draw_text(win_id, "Peer:", hist_rect.x + 8, y, ui.COLOR_WARNING);
                ui.draw_text(win_id, msg.text[0..msg.len], hist_rect.x + 56, y, ui.COLOR_TEXT_PRIMARY);
            }
        }

        // Render input text box and send button
        self.input_box.draw(win_id);
        self.send_btn.draw(win_id);
    }

    pub fn handle_event(self: *ChatApp, ev: *const Event) bool {
        if (ev.kind == ui.KEY_DOWN) {
            // Enter key triggers Send
            if (ev.arg1 == '\r' or ev.arg1 == '\n' or ev.arg0 == 0x28) {
                return self.send_current_message();
            }
        }

        var dirty = false;

        // Check Send button click
        if (self.send_btn.handle_event(ev)) {
            dirty = self.send_current_message() or true;
        }

        // Text input event handling
        if (self.input_box.handle_event(ev)) {
            dirty = true;
        }

        return dirty;
    }
};

pub export fn _start() callconv(.c) noreturn {
    ui.write_console("chat: starting\n");

    // 1. Open GUI window
    const win_res = ui.win_open(window_x, window_y, window_w, window_h);
    if (win_res < 0) {
        ui.write_console("chat: failed to open window\n");
        ui.exit_process(1);
    }
    const win = @as(u32, @intCast(win_res));
    ui.write_console("chat: window opened\n");

    // 2. Listen on UDP chat port 7777
    const listen_rc = ui.udp_listen(chat_port);
    if (listen_rc < 0) {
        ui.write_console("chat: failed to listen on port 7777\n");
    } else {
        ui.write_console("chat: listening on port 7777\n");
    }

    var app = ChatApp.init();
    app.draw(win);
    ui.win_present(win);
    ui.write_console("chat: ready\n");

    // 3. Main event & network loop
    var ev: Event = undefined;
    var rx_buf: [ui.datagram_max]u8 = undefined;

    while (true) {
        var dirty = false;

        // Check for incoming UDP datagrams
        const n = ui.udp_recv(chat_port, &rx_buf);
        if (n > 8) {
            const payload_len = @as(usize, @intCast(n - 8));
            const payload = rx_buf[8 .. 8 + payload_len];
            app.add_message(false, payload);
            dirty = true;
            ui.write_console("chat: received message\n");
        }

        // Poll GUI input event
        if (ui.poll_event(&ev) > 0) {
            if (ev.kind == ui.WIN_CLOSE) {
                break;
            }
            if (app.handle_event(&ev)) {
                dirty = true;
            }
        }

        if (dirty) {
            app.draw(win);
            ui.win_present(win);
        }

        ui.yield_task();
    }

    ui.win_close(win);
    ui.write_console("chat: exiting\n");
    ui.exit_process(0);
}

// ---------------------------------------------------------------------------
// Unit Tests
// ---------------------------------------------------------------------------

test "chat: message history model" {
    var app = ChatApp.init();
    try std.testing.expectEqual(@as(usize, 0), app.history_count);

    app.add_message(true, "Hello");
    try std.testing.expectEqual(@as(usize, 1), app.history_count);
    try std.testing.expect(app.history[0].sender_is_me);
    try std.testing.expectEqualStrings("Hello", app.history[0].text[0..app.history[0].len]);

    app.add_message(false, "Hi there");
    try std.testing.expectEqual(@as(usize, 2), app.history_count);
    try std.testing.expect(!app.history[1].sender_is_me);
    try std.testing.expectEqualStrings("Hi there", app.history[1].text[0..app.history[1].len]);
}

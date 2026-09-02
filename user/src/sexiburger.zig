//! VirelaiOS Standalone Sexiburger Component & Demo Application (Milestone 19, #677).
//!
//! A standalone userland program and harness hosting the Sexiburger God Menu component:
//! - Exactly 6 sections (Covenant of Six: System, Apps, Active app, Windows & tabs, Services, Power)
//! - Zero-pixel idle footprint until summoned
//! - Opened by clicking the mascot button or chord (Cmd/Ctrl+B, Alt/Ctrl+Space)
//! - Type-to-filter across all registered commands with Quicksilver abbreviation search
//! - Native 6-layer 6-tentacle mascot rendering

const std = @import("std");
const ui = @import("lib/ui.zig");
const Rect = ui.Rect;
const Button = ui.Button;
const Event = ui.Event;
const action_reg = @import("lib/action_registry.zig");
const sexiburger = @import("lib/sexiburger.zig");
pub const SexiburgerMenu = sexiburger.SexiburgerMenu;
pub const SectionId = sexiburger.SectionId;
pub const Command = sexiburger.Command;
pub const ActionRegistry = sexiburger.ActionRegistry;

pub const window_id: u32 = 7;
pub const window_x: u32 = 32;
pub const window_y: u32 = 32;
pub const window_w: u32 = 512;
pub const window_h: u32 = 384;
pub const exit_status: u32 = 43;

pub const AppState = struct {
    menu: SexiburgerMenu,
    btn_trigger: Button,
    btn_chord_hint: Button,
    last_action_text: [64]u8 = [_]u8{0} ** 64,
    last_action_len: usize = 0,
    action_counter: u32 = 0,

    pub fn init() AppState {
        const menu_rect = Rect.make(12, 36, 488, 316);
        var app = AppState{
            .menu = SexiburgerMenu.init(menu_rect),
            .btn_trigger = Button.init(Rect.make(12, 6, 170, 24), "[*] Sexiburger Menu"),
            .btn_chord_hint = Button.init(Rect.make(190, 6, 160, 24), "Chord: Ctrl+B / Space"),
        };
        app.set_last_action("System ready. Click trigger or press Ctrl+B to open menu.");
        return app;
    }

    pub fn set_last_action(self: *AppState, msg: []const u8) void {
        const copy_len = @min(msg.len, self.last_action_text.len);
        @memcpy(self.last_action_text[0..copy_len], msg[0..copy_len]);
        self.last_action_len = copy_len;
    }

    pub fn get_last_action(self: *const AppState) []const u8 {
        return self.last_action_text[0..self.last_action_len];
    }

    pub fn handle_event(self: *AppState, ev: *const Event) bool {
        // If menu is open, give it first priority
        if (self.menu.is_open()) {
            const consumed = self.menu.handle_event(ev);
            if (self.menu.last_invoked_cmd) |cmd| {
                self.action_counter += 1;
                var buf: [64]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "Invoked: {s} (verb: {s})", .{ cmd.label, cmd.verb }) catch "Invoked command";
                self.set_last_action(msg);
                self.menu.last_invoked_cmd = null;
            }
            return consumed;
        }

        // Check if event summons menu via chord
        if (self.menu.handle_event(ev)) {
            return true;
        }

        // Handle trigger buttons
        if (ev.kind == ui.MOUSE_DOWN or ev.kind == ui.MOUSE_UP or ev.kind == ui.MOUSE_MOVE) {
            if (self.btn_trigger.handle_event(ev)) {
                self.menu.show();
                return true;
            }
            if (self.btn_chord_hint.handle_event(ev)) {
                self.menu.show();
                return true;
            }
        }

        return false;
    }

    pub fn draw(self: *const AppState, win: u32) void {
        // 1. Desktop background canvas
        ui.draw_rect(win, Rect.make(0, 0, window_w, window_h), ui.theme_bg());

        // 2. Top bar chrome
        const bar_rect = Rect.make(0, 0, window_w, 36);
        ui.draw_rect(win, bar_rect, ui.theme_surface());
        ui.draw_rect(win, Rect.make(0, 35, window_w, 1), ui.theme_border());

        // Mascot mini-emblem in top bar
        sexiburger.draw_sexiburger_emblem(win, 16, 8);

        // Buttons
        self.btn_trigger.draw(win);
        self.btn_chord_hint.draw(win);

        // Covenant indicator on top bar right
        ui.draw_text(win, "Covenant: 6/6 Invariant", window_w - 200, 14, ui.theme_accent());

        // 3. Main desktop work area
        const canvas_rect = Rect.make(16, 50, window_w - 32, window_h - 100);
        ui.draw_rect(win, canvas_rect, ui.theme_surface());
        ui.draw_rect_outline(win, canvas_rect, 1, ui.theme_border());

        // Large Mascot Diagnostic Display in center
        sexiburger.draw_sexiburger_emblem(win, 48, 80);
        ui.draw_text(win, "VIRELAIOS GOD MENU: THE SEXIBURGER", 84, 80, ui.theme_accent());
        ui.draw_text(win, "Mascot: Sexipus (6 tentacles, 3/side) wearing a 6-layer burger.", 84, 96, ui.theme_text_primary());
        ui.draw_text(win, "1. System (Crown)  2. Apps (Lettuce)  3. Active App (Tomato)", 84, 112, ui.theme_text_muted());
        ui.draw_text(win, "4. Windows/Tabs (Cheese)  5. Services (Patty)  6. Power (Heel)", 84, 126, ui.theme_text_muted());

        // Mascot ASCII diagnostic block
        const ascii_lines = action_reg.sexiburger_ascii_lines();
        var ascii_y: u32 = 160;
        for (ascii_lines) |line| {
            ui.draw_text(win, line, 48, ascii_y, ui.theme_text_muted());
            ascii_y += 12;
        }

        // 4. Status Bar at bottom
        const status_rect = Rect.make(0, window_h - 28, window_w, 28);
        ui.draw_rect(win, status_rect, ui.theme_surface());
        ui.draw_rect(win, Rect.make(0, window_h - 28, window_w, 1), ui.theme_border());

        ui.draw_text(win, self.get_last_action(), 16, window_h - 18, ui.theme_text_primary());

        // 5. Draw the Sexiburger Menu (Zero-pixel cost if closed; renders overlay if open)
        if (self.menu.is_open()) {
            // Semi-transparent backdrop dimming illusion
            ui.draw_rect(win, Rect.make(0, 36, window_w, window_h - 36), 0x000000);
            self.menu.draw(win);
        }
    }
};

var global_app: AppState = undefined;

pub export fn _start() callconv(.c) noreturn {
    global_app = AppState.init();
    const app = &global_app;

    const win_res = ui.win_open(window_x, window_y, window_w, window_h);
    if (win_res < 0) {
        ui.write_console("sexiburger: win_open failed\n");
        ui.exit_process(1);
    }
    const win = @as(u32, @intCast(win_res));
    ui.write_console("sexiburger: open id=7\n");

    app.draw(win);
    ui.win_present(win);
    ui.write_console("sexiburger: ready\n");

    var ev: Event = undefined;
    while (true) {
        const wait_rc = ui.wait_event(&ev);
        if (wait_rc < 0) break;

        var dirty = false;

        if (ev.kind == ui.WIN_CLOSE) {
            ui.write_console("sexiburger: close\n");
            break;
        }

        dirty = app.handle_event(&ev) or dirty;

        while (ui.poll_event(&ev) > 0) {
            if (ev.kind == ui.WIN_CLOSE) {
                ui.write_console("sexiburger: close\n");
                ui.win_close(win);
                ui.exit_process(exit_status);
            }
            dirty = app.handle_event(&ev) or dirty;
        }

        if (dirty) {
            if (app.menu.open) {
                ui.write_console("sexiburger: menu open\n");
            }
            app.draw(win);
            ui.win_present(win);
        }
    }

    ui.write_console("sexiburger: exiting\n");
    ui.win_close(win);
    ui.exit_process(exit_status);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "sexiburger app: initial state and button trigger" {
    var app = AppState.init();
    try std.testing.expect(!app.menu.is_open());

    // Click trigger button
    const trig_rect = app.btn_trigger.rect;
    var ev_down = Event{
        .kind = ui.MOUSE_DOWN,
        .flags = ui.BTN_LEFT,
        .seq = 1,
        .arg0 = trig_rect.x + 4,
        .arg1 = trig_rect.y + 4,
    };
    _ = app.handle_event(&ev_down);

    var ev_up = Event{
        .kind = ui.MOUSE_UP,
        .flags = ui.BTN_LEFT,
        .seq = 2,
        .arg0 = trig_rect.x + 4,
        .arg1 = trig_rect.y + 4,
    };
    _ = app.handle_event(&ev_up);

    // Menu should now be open
    try std.testing.expect(app.menu.is_open());
}

test "sexiburger app: chord trigger opens menu" {
    var app = AppState.init();
    try std.testing.expect(!app.menu.is_open());

    var ev_chord = Event{
        .kind = ui.KEY_DOWN,
        .flags = ui.MOD_CMD,
        .seq = 1,
        .arg0 = 0x05, // 'b'
        .arg1 = 'b',
    };
    _ = app.handle_event(&ev_chord);
    try std.testing.expect(app.menu.is_open());
}

test "sexiburger app: command invocation updates last action" {
    var app = AppState.init();
    app.menu.show();

    // Type "reboot"
    app.menu.set_search_query("reboot");
    try std.testing.expect(app.menu.filtered_count >= 1);

    // Press Enter to invoke
    var ev_enter = Event{
        .kind = ui.KEY_DOWN,
        .flags = 0,
        .seq = 1,
        .arg0 = 0x28,
        .arg1 = '\r',
    };
    _ = app.handle_event(&ev_enter);

    try std.testing.expect(!app.menu.is_open());
    try std.testing.expectEqual(@as(u32, 1), app.action_counter);
    try std.testing.expect(std.mem.indexOf(u8, app.get_last_action(), "Reboot System") != null);
}

//! Dialog and Empty State / Error Presenter UI widgets (GH #221, Arc1, M27 G10, G22, G23, M41 TS2).
const std = @import("std");
pub const abi = @import("../abi.zig");
pub const theme = @import("../theme.zig");
pub const draw = @import("../draw.zig");

pub const button = @import("button.zig");
pub const text_input = @import("text_input.zig");

const Button = button.Button;
const TextInput = text_input.TextInput;

// ABI types & constants
const Event = abi.Event;
const KEY_DOWN = abi.KEY_DOWN;
const MOUSE_DOWN = abi.MOUSE_DOWN;
const MOUSE_MOVE = abi.MOUSE_MOVE;
const MOUSE_UP = abi.MOUSE_UP;

// Theme tokens & styling
const theme_accent = theme.theme_accent;
const theme_border = theme.theme_border;
const theme_surface = theme.theme_surface;
const theme_text_muted = theme.theme_text_muted;
const theme_text_primary = theme.theme_text_primary;

// Draw operations
const Rect = draw.Rect;
const draw_char = draw.draw_char;
const draw_rect = draw.draw_rect;
const draw_rect_outline = draw.draw_rect_outline;
const draw_text = draw.draw_text;

// ---------------------------------------------------------------------------
// Component: Dialog — modal child window helper (GH #221, Arc1)
// ---------------------------------------------------------------------------

pub const DialogResult = enum {
    none,
    ok,
    cancel,
    button_0,
    button_1,
    button_2,

    pub fn is_ok(self: DialogResult) bool {
        return self == .ok or self == .button_0;
    }

    pub fn is_cancel(self: DialogResult) bool {
        return self == .cancel or self == .button_1;
    }
};

pub const Dialog = struct {
    parent_rect: Rect,
    rect: Rect,
    title: []const u8 = "",
    message: []const u8 = "",
    has_input: bool = false,
    input: TextInput,
    ok_button: Button,
    cancel_button: Button,
    result: DialogResult = .none,
    open: bool = false,

    pub const width: u32 = 300;
    pub const height: u32 = 150;

    fn centered_rect(parent: Rect) Rect {
        const w = width;
        const h = height;
        const cw = @min(w, parent.w);
        const ch = @min(h, parent.h);
        const x = if (parent.w > w) parent.x + (parent.w - w) / 2 else parent.x;
        const y = if (parent.h > h) parent.y + (parent.h - h) / 2 else parent.y;
        return Rect.make(x, y, cw, ch);
    }

    pub fn init(parent_rect: Rect, message: []const u8, has_input: bool) Dialog {
        const r = centered_rect(parent_rect);
        var dlg = Dialog{
            .parent_rect = parent_rect,
            .rect = r,
            .title = "",
            .message = message,
            .has_input = has_input,
            .input = TextInput.init(Rect.make(r.x + 10, r.y + 60, if (r.w > 20) r.w - 20 else 0, 20)),
            .ok_button = Button.init(Rect.make(if (r.w > 140) r.x + r.w - 140 else r.x, r.y + r.h - 30, 60, 20), "OK"),
            .cancel_button = Button.init(Rect.make(if (r.w > 70) r.x + r.w - 70 else r.x, r.y + r.h - 30, 60, 20), "Cancel"),
            .result = .none,
            .open = false,
        };
        dlg.input.focused = has_input;
        return dlg;
    }

    pub fn initWithButtons(parent_rect: Rect, title: []const u8, message: []const u8, buttons: []const []const u8) Dialog {
        const r = centered_rect(parent_rect);
        const btn0 = if (buttons.len > 0) buttons[0] else "OK";
        const btn1 = if (buttons.len > 1) buttons[1] else "Cancel";
        const dlg = Dialog{
            .parent_rect = parent_rect,
            .rect = r,
            .title = title,
            .message = message,
            .has_input = false,
            .input = TextInput.init(Rect.make(r.x + 10, r.y + 60, if (r.w > 20) r.w - 20 else 0, 20)),
            .ok_button = Button.init(Rect.make(if (r.w > 140) r.x + r.w - 140 else r.x, r.y + r.h - 30, 60, 20), btn0),
            .cancel_button = Button.init(Rect.make(if (r.w > 70) r.x + r.w - 70 else r.x, r.y + r.h - 30, 60, 20), btn1),
            .result = .none,
            .open = false,
        };
        return dlg;
    }

    pub fn show(self: *Dialog) void {
        self.open = true;
        self.result = .none;
        self.input.clear();
        self.input.focused = self.has_input;
        // Reset button states
        self.ok_button.state = .idle;
        self.cancel_button.state = .idle;
    }

    pub fn dismiss(self: *Dialog, res: DialogResult) void {
        self.open = false;
        self.result = res;
    }

    pub fn is_open(self: *const Dialog) bool {
        return self.open;
    }

    pub fn needs_dim(self: *const Dialog) bool {
        return self.open;
    }

    pub fn get_result(self: *const Dialog) DialogResult {
        return self.result;
    }

    pub fn handle_event(self: *Dialog, ev: *const Event) bool {
        if (!self.open) return false;
        switch (ev.kind) {
            KEY_DOWN => {
                const kc = ev.arg0;
                if (kc == 0x28) { // Enter → OK
                    self.result = .ok;
                    self.open = false;
                    return true;
                }
                if (kc == 0x29) { // Escape → Cancel
                    self.result = .cancel;
                    self.open = false;
                    return true;
                }
                if (self.has_input) {
                    // Delegate typing to TextInput (preserves Enter/Escape handling above)
                    return self.input.handle_event(ev);
                }
                return false;
            },
            MOUSE_DOWN, MOUSE_MOVE, MOUSE_UP => {
                // Forward to buttons to maintain hover/pressed visuals and detect clicks.
                const ok_clicked = self.ok_button.handle_event(ev);
                const cancel_clicked = self.cancel_button.handle_event(ev);
                if (ok_clicked) {
                    self.result = .ok;
                    self.open = false;
                    return true;
                }
                if (cancel_clicked) {
                    self.result = .cancel;
                    self.open = false;
                    return true;
                }
                if (self.has_input and ev.kind == MOUSE_DOWN) {
                    // Give input focus on click inside its rect; also handle click outside to blur.
                    const inside_input = self.input.rect.contains(ev.arg0, ev.arg1);
                    // Let TextInput update its focused flag
                    const changed = self.input.handle_event(ev);
                    if (inside_input or changed) return true;
                }
                // Modal exclusive focus: any click inside dialog consumes, outside also consumes
                // to prevent parent interaction while open (dim overlay).
                if (ev.kind == MOUSE_DOWN and self.rect.contains(ev.arg0, ev.arg1)) return true;
                if (ev.kind == MOUSE_DOWN) {
                    // Click outside dialog but while open → consume (modal) but no dismiss
                    // (unless desired to dismiss on outside click — we keep modal strict)
                    return true;
                }
                if (ev.kind == MOUSE_MOVE and self.rect.contains(ev.arg0, ev.arg1)) return true;
                return false;
            },
            else => return false,
        }
    }

    pub fn draw_dim_overlay(self: *const Dialog, parent_win_id: u32) void {
        if (!self.open) return;
        // Dim parent with a muted overlay — fill parent rect with border color at 50% illusion
        // (solid fill with theme_border, parent content underneath will be dimmed visually).
        draw_rect(parent_win_id, self.parent_rect, 0x000000);
        // Use a semi-transparent illusion: overdraw with theme_surface at reduced intensity
        // For host test, just verify no panic — actual dim is visual.
        draw_rect(parent_win_id, self.parent_rect, theme_border());
    }

    pub fn draw(self: *const Dialog, win_id: u32) void {
        if (!self.open) return;
        // Dialog window background + border
        draw_rect(win_id, self.rect, theme_surface());
        draw_rect_outline(win_id, self.rect, 1, theme_border());
        // Title bar accent strip (8px)
        draw_rect(win_id, Rect.make(self.rect.x, self.rect.y, self.rect.w, 12), theme_accent());
        // Message — support up to 3 lines split by '\n', wrap at ~35 chars.
        var line_y = self.rect.y + 18;
        var msg_start: usize = 0;
        var line_idx: usize = 0;
        while (msg_start < self.message.len and line_idx < 3) : (line_idx += 1) {
            var line_end = msg_start;
            while (line_end < self.message.len and self.message[line_end] != '\n' and line_end - msg_start < 35) : (line_end += 1) {}
            // If we stopped mid-word, try to break at space (optional)
            const line = self.message[msg_start..line_end];
            draw_text(win_id, line, self.rect.x + 10, line_y, theme_text_primary());
            line_y += 10;
            if (line_end < self.message.len and self.message[line_end] == '\n') line_end += 1;
            msg_start = line_end;
            if (msg_start >= self.message.len) break;
        }
        // Optional TextInput
        if (self.has_input) {
            self.input.draw(win_id);
        }
        // Buttons
        self.ok_button.draw(win_id);
        self.cancel_button.draw(win_id);
    }
};

// ---------------------------------------------------------------------------
// Standard Dialog Helper (M27 G10 #453)
// ---------------------------------------------------------------------------

pub const DialogSeverity = enum {
    info,
    warning,
    error_type,
    question,
};

pub const DialogButtons = enum {
    ok,
    ok_cancel,
    yes_no,
    yes_no_cancel,
    save_dont_cancel,
};

/// Helper to configure and present a standardized modal dialog.
pub fn show_dialog(dlg: *Dialog, message: []const u8, has_input: bool) void {
    dlg.message = message;
    dlg.has_input = has_input;
    dlg.show();
}

// ---------------------------------------------------------------------------
// Empty State Presenter (M27 G22 #465)
// ---------------------------------------------------------------------------

/// Draw an empty-state message inside `rect` when a view/list has no items.
pub fn draw_empty_state(win_id: u32, rect: Rect, title: []const u8, subtitle: []const u8) void {
    if (rect.w == 0 or rect.h == 0) return;
    draw_rect(win_id, rect, theme_surface());
    draw_rect_outline(win_id, rect, 1, theme_border());

    const center_y = rect.y + rect.h / 2;
    const title_w = @as(u32, @intCast(title.len)) * 8;
    const title_x = if (rect.w > title_w) rect.x + (rect.w - title_w) / 2 else rect.x + 4;
    const title_y = if (center_y >= 14) center_y - 14 else rect.y + 4;

    draw_text(win_id, title, title_x, title_y, theme_text_primary());

    if (subtitle.len > 0) {
        const sub_w = @as(u32, @intCast(subtitle.len)) * 8;
        const sub_x = if (rect.w > sub_w) rect.x + (rect.w - sub_w) / 2 else rect.x + 4;
        draw_text(win_id, subtitle, sub_x, title_y + 14, theme_text_muted());
    }
}

/// Draw an empty-state message with an icon character (M27 G22 #465).
pub fn draw_empty_state_icon(win_id: u32, rect: Rect, message: []const u8, icon_char: u8) void {
    if (rect.w == 0 or rect.h == 0) return;
    draw_rect(win_id, rect, theme_surface());
    draw_rect_outline(win_id, rect, 1, theme_border());

    const center_y = rect.y + rect.h / 2;
    const icon_x = if (rect.w >= 8) rect.x + (rect.w - 8) / 2 else rect.x + 4;
    const icon_y = if (center_y >= 20) center_y - 16 else rect.y + 4;
    if (icon_char >= 0x20 and icon_char <= 0x7e) {
        draw_char(win_id, icon_char, icon_x, icon_y, theme_text_muted());
    }

    const msg_w = @as(u32, @intCast(message.len)) * 8;
    const msg_x = if (rect.w > msg_w) rect.x + (rect.w - msg_w) / 2 else rect.x + 4;
    const msg_y = icon_y + 14;
    draw_text(win_id, message, msg_x, msg_y, theme_text_muted());
}

// ---------------------------------------------------------------------------
// Error Display Consistency (M27 G23 #466)
// ---------------------------------------------------------------------------

/// Format standard OS error code into a user-friendly message.
pub fn format_error(code: i64, buf: []u8) []const u8 {
    const msg: []const u8 = switch (code) {
        -1 => "Operation not permitted",
        -2 => "File or directory not found",
        -3 => "No such process",
        -4 => "Interrupted system call",
        -5 => "Input/output error",
        -6 => "No such device or address",
        -7 => "Argument list too long",
        -8 => "Exec format error",
        -9 => "Bad file descriptor",
        -12 => "Out of memory",
        -13 => "Permission denied",
        -14 => "Bad memory address",
        -16 => "Device or resource busy",
        -17 => "File already exists",
        -19 => "No such device",
        -20 => "Not a directory",
        -21 => "Is a directory",
        -22 => "Invalid argument",
        -24 => "Too many open files",
        -27 => "File too large",
        -28 => "No space left on device",
        -30 => "Read-only file system",
        -38 => "Function not implemented",
        -110 => "Connection timed out",
        -111 => "Connection refused",
        else => "",
    };
    if (msg.len > 0) {
        const n = @min(msg.len, buf.len);
        @memcpy(buf[0..n], msg[0..n]);
        return buf[0..n];
    }
    return std.fmt.bufPrint(buf, "System error ({d})", .{code}) catch "System error";
}

/// Format error with optional context prefix (e.g. "Save failed: File or directory not found").
pub fn format_error_ctx(buf: []u8, code: i64, context: []const u8) []const u8 {
    var raw_buf: [128]u8 = undefined;
    const err_str = format_error(code, &raw_buf);
    if (context.len == 0) {
        const n = @min(err_str.len, buf.len);
        @memcpy(buf[0..n], err_str[0..n]);
        return buf[0..n];
    }
    return std.fmt.bufPrint(buf, "{s}: {s}", .{ context, err_str }) catch err_str;
}

pub const format_error_with_context = format_error_ctx;

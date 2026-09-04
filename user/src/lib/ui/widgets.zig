//! VirelaiOS Micro-Widget Component Library (M39 UI1).
const std = @import("std");
pub const abi = @import("abi.zig");
pub const theme = @import("theme.zig");
pub const draw = @import("draw.zig");

// Local aliases from abi:
const BTN_LEFT = abi.BTN_LEFT;
const EVENT_TIMER = abi.EVENT_TIMER;
const Event = abi.Event;
const KEY_DOWN = abi.KEY_DOWN;
const MOD_SHIFT = abi.MOD_SHIFT;
const MOUSE_DOWN = abi.MOUSE_DOWN;
const MOUSE_MOVE = abi.MOUSE_MOVE;
const MOUSE_RIGHT_DOWN = abi.MOUSE_RIGHT_DOWN;
const MOUSE_RIGHT_UP = abi.MOUSE_RIGHT_UP;
const MOUSE_UP = abi.MOUSE_UP;
const win_fill = abi.win_fill;

// Local aliases from theme:
const COLOR_TEXT_PRIMARY = theme.COLOR_TEXT_PRIMARY;
const WidgetState = theme.WidgetState;
const border_w = theme.border_w;
const caret_h = theme.caret_h;
const caret_w = theme.caret_w;
const live_color = theme.live_color;
const pad_sm = theme.pad_sm;
const theme_accent = theme.theme_accent;
const theme_bg = theme.theme_bg;
const theme_border = theme.theme_border;
const theme_btn_hover = theme.theme_btn_hover;
const theme_btn_idle = theme.theme_btn_idle;
const theme_btn_pressed = theme.theme_btn_pressed;
const theme_caret = theme.theme_caret;
const theme_on_accent = theme.theme_on_accent;
const theme_surface = theme.theme_surface;
const theme_text_muted = theme.theme_text_muted;
const theme_text_primary = theme.theme_text_primary;
const widget_bg = theme.widget_bg;
const widget_border = theme.widget_border;
const widget_text = theme.widget_text;

// Local aliases from draw:
const Rect = draw.Rect;
const draw_char = draw.draw_char;
const draw_rect = draw.draw_rect;
const draw_rect_outline = draw.draw_rect_outline;
const draw_text = draw.draw_text;
const draw_text_centered = draw.draw_text_centered;
const measure_text = draw.measure_text;

// ---------------------------------------------------------------------------
// Component: Button
// ---------------------------------------------------------------------------

pub const ButtonState = enum {
    idle,
    hover,
    pressed,
    disabled,
    focused,
    normal,
    hovered,

    pub fn to_widget_state(self: ButtonState) WidgetState {
        return switch (self) {
            .idle, .normal => .normal,
            .hover, .hovered => .hover,
            .pressed => .pressed,
            .disabled => .disabled,
            .focused => .focused,
        };
    }
};

pub const Button = struct {
    rect: Rect,
    label: []const u8,
    state: ButtonState = .idle,
    bg_color: ?u32 = null,
    text_color: u32 = 0xffffff,
    is_active: bool = false,

    pub fn init(rect: Rect, label: []const u8) Button {
        return .{
            .rect = rect,
            .label = label,
        };
    }

    pub fn handle_event(self: *Button, ev: *const Event) bool {
        switch (ev.kind) {
            MOUSE_MOVE => {
                const inside = self.rect.contains(ev.arg0, ev.arg1);
                if (inside) {
                    if (self.state == .idle) self.state = .hover;
                } else {
                    self.state = .idle;
                }
                return false;
            },
            MOUSE_DOWN => {
                const inside = self.rect.contains(ev.arg0, ev.arg1);
                if (inside) {
                    self.state = .pressed;
                } else {
                    self.state = .idle;
                }
                return false;
            },
            MOUSE_UP => {
                const was_pressed = (self.state == .pressed);
                const inside = self.rect.contains(ev.arg0, ev.arg1);
                self.state = if (inside) .hover else .idle;
                return was_pressed and inside;
            },
            else => return false,
        }
    }

    pub fn draw(self: *const Button, win_id: u32) void {
        const ws = self.state.to_widget_state();
        // M37 DQ4: legacy frozen COLOR_* resolve live so every app follows
        // the desktop theme with no per-app button churn.
        const bg = if (self.is_active)
            theme_accent()
        else if (self.bg_color) |c|
            live_color(c)
        else
            widget_bg(ws);

        const border = if (self.is_active)
            theme_text_primary()
        else
            widget_border(ws);

        // Default text follows the surface it sits on: text-over-accent on
        // accent fills, theme text otherwise. An explicitly pinned color
        // (anything but the legacy white default) always wins.
        const on_accent_bg = self.is_active or
            (if (self.bg_color) |c| live_color(c) == theme_accent() else false);
        const text_col = if (self.text_color != COLOR_TEXT_PRIMARY)
            self.text_color
        else if (self.state == .disabled)
            widget_text(ws)
        else if (on_accent_bg)
            theme_on_accent()
        else
            widget_text(ws);

        draw_rect(win_id, self.rect, bg);
        draw_rect_outline(win_id, self.rect, border_w, border);
        draw_text_centered(win_id, self.label, self.rect, text_col);
    }
};

// ---------------------------------------------------------------------------
// Component: Label
// ---------------------------------------------------------------------------

pub const Label = struct {
    rect: Rect,
    text: []const u8,
    color: u32 = 0xffffff,
    align_center: bool = false,

    pub fn init(rect: Rect, text: []const u8) Label {
        return .{
            .rect = rect,
            .text = text,
        };
    }

    pub fn draw(self: *const Label, win_id: u32) void {
        // M37 DQ4: the legacy white default resolves live (dark identical).
        const col = if (self.color == COLOR_TEXT_PRIMARY) theme_text_primary() else self.color;
        if (self.align_center) {
            draw_text_centered(win_id, self.text, self.rect, col);
        } else {
            draw_text(win_id, self.text, self.rect.x, self.rect.y + (self.rect.h - 8) / 2, col);
        }
    }
};

// ---------------------------------------------------------------------------
// Component: TextInput
// ---------------------------------------------------------------------------

pub const TextInput = struct {
    rect: Rect,
    buf: [128]u8 = [_]u8{0} ** 128,
    len: usize = 0,
    cursor: usize = 0,
    focused: bool = false,

    pub fn init(rect: Rect) TextInput {
        return .{ .rect = rect };
    }

    pub fn get_text(self: *const TextInput) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn set_text(self: *TextInput, text: []const u8) void {
        const copy_len = @min(text.len, self.buf.len);
        @memcpy(self.buf[0..copy_len], text[0..copy_len]);
        self.len = copy_len;
        self.cursor = copy_len;
    }

    pub fn clear(self: *TextInput) void {
        self.len = 0;
        self.cursor = 0;
    }

    pub fn handle_event(self: *TextInput, ev: *const Event) bool {
        switch (ev.kind) {
            MOUSE_DOWN => {
                const inside = self.rect.contains(ev.arg0, ev.arg1);
                const prev = self.focused;
                self.focused = inside;
                if (inside) {
                    const click_x = ev.arg0;
                    const text_x = self.rect.x + pad_sm;
                    if (click_x <= text_x) {
                        self.cursor = 0;
                    } else {
                        const rel_x = click_x - text_x;
                        const text = self.get_text();
                        var best_cursor: usize = 0;
                        var cur_w: u32 = 0;
                        while (best_cursor < text.len) {
                            const next_w = measure_text(text[0 .. best_cursor + 1]);
                            if (next_w > rel_x) {
                                if (rel_x - cur_w < next_w - rel_x) {
                                    break;
                                } else {
                                    best_cursor += 1;
                                    break;
                                }
                            }
                            cur_w = next_w;
                            best_cursor += 1;
                        }
                        self.cursor = best_cursor;
                    }
                }
                return prev != self.focused;
            },
            KEY_DOWN => {
                if (!self.focused) return false;
                const keycode = ev.arg0;
                const ascii_char = @as(u8, @truncate(ev.arg1));

                // Backspace (ASCII 0x08 or keycode 0x2a)
                if (ascii_char == 0x08 or keycode == 0x2a) {
                    if (self.cursor > 0 and self.len > 0) {
                        var i = self.cursor - 1;
                        while (i < self.len - 1) : (i += 1) {
                            self.buf[i] = self.buf[i + 1];
                        }
                        self.len -= 1;
                        self.cursor -= 1;
                        return true;
                    }
                    return false;
                }

                // Printable character insertion
                if (ascii_char >= 0x20 and ascii_char <= 0x7e) {
                    if (self.len < self.buf.len) {
                        var i = self.len;
                        while (i > self.cursor) : (i -= 1) {
                            self.buf[i] = self.buf[i - 1];
                        }
                        self.buf[self.cursor] = ascii_char;
                        self.len += 1;
                        self.cursor += 1;
                        return true;
                    }
                }
                return false;
            },
            else => return false,
        }
    }

    pub fn draw(self: *const TextInput, win_id: u32) void {
        draw_rect(win_id, self.rect, theme_surface());
        draw_rect_outline(win_id, self.rect, border_w, if (self.focused) theme_accent() else theme_border());

        const text_y = self.rect.y + (self.rect.h - 8) / 2;
        const text_x = self.rect.x + pad_sm;
        draw_text(win_id, self.get_text(), text_x, text_y, theme_text_primary());

        // M37 DQ4 / M38 TT2: caret bar from tokens (proportional metrics aware).
        if (self.focused) {
            const prefix = self.get_text()[0..self.cursor];
            const cursor_x = text_x + measure_text(prefix);
            if (cursor_x + caret_w <= self.rect.x + self.rect.w) {
                win_fill(win_id, cursor_x, text_y, caret_w, caret_h, theme_caret());
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Component: ListView
// ---------------------------------------------------------------------------

pub const ListView = struct {
    rect: Rect,
    row_height: u32 = 14,
    selected_idx: ?usize = null,
    item_count: usize = 0,

    pub fn init(rect: Rect, row_height: u32) ListView {
        return .{
            .rect = rect,
            .row_height = row_height,
        };
    }

    pub fn handle_event(self: *ListView, ev: *const Event) bool {
        switch (ev.kind) {
            MOUSE_DOWN => {
                if (self.rect.contains(ev.arg0, ev.arg1)) {
                    const rel_y = ev.arg1 - self.rect.y;
                    const clicked_row = rel_y / self.row_height;
                    if (clicked_row < self.item_count) {
                        const prev = self.selected_idx;
                        self.selected_idx = clicked_row;
                        return prev != self.selected_idx;
                    }
                }
                return false;
            },
            KEY_DOWN => {
                const keycode = ev.arg0;
                // Up arrow (keycode 0x52)
                if (keycode == 0x52) {
                    if (self.selected_idx) |idx| {
                        if (idx > 0) {
                            self.selected_idx = idx - 1;
                            return true;
                        }
                    } else if (self.item_count > 0) {
                        self.selected_idx = 0;
                        return true;
                    }
                }
                // Down arrow (keycode 0x51)
                if (keycode == 0x51) {
                    if (self.selected_idx) |idx| {
                        if (idx + 1 < self.item_count) {
                            self.selected_idx = idx + 1;
                            return true;
                        }
                    } else if (self.item_count > 0) {
                        self.selected_idx = 0;
                        return true;
                    }
                }
                return false;
            },
            else => return false,
        }
    }

    pub fn draw_row(self: *const ListView, win_id: u32, row: usize, text: []const u8, is_selected: bool) void {
        const row_y = self.rect.y + @as(u32, @intCast(row)) * self.row_height;
        if (row_y + self.row_height > self.rect.y + self.rect.h) return;

        const row_rect = Rect.make(self.rect.x, row_y, self.rect.w, self.row_height);
        const bg = if (is_selected)
            theme_accent()
        else if (row % 2 == 0)
            theme_surface()
        else
            theme_bg();

        draw_rect(win_id, row_rect, bg);
        const text_y = row_rect.y + (if (self.row_height > 12) (self.row_height - 12) / 2 else 0);
        draw_text(win_id, text, row_rect.x + 4, text_y, if (is_selected) theme_on_accent() else theme_text_primary());
    }
};

// ---------------------------------------------------------------------------
// Component: DropDown
// ---------------------------------------------------------------------------

pub const DropDown = struct {
    rect: Rect,
    options: []const []const u8,
    selected: usize = 0,
    open: bool = false,
    hover_idx: ?usize = null,
    row_height: u32 = 16,
    max_visible: u32 = 6,

    pub fn init(rect: Rect, options: []const []const u8) DropDown {
        return .{ .rect = rect, .options = options };
    }

    pub fn selected_text(self: *const DropDown) []const u8 {
        if (self.selected < self.options.len) return self.options[self.selected];
        return "";
    }

    pub fn set_selected_by_name(self: *DropDown, name: []const u8) void {
        for (self.options, 0..) |opt, i| {
            if (eql_str(opt, name)) {
                self.selected = i;
                return;
            }
        }
    }

    fn eql_str(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |ca, cb| {
            if (ca != cb) return false;
        }
        return true;
    }

    fn overlay_rect(self: *const DropDown) Rect {
        const visible = @min(@as(u32, @intCast(self.options.len)), self.max_visible);
        return Rect.make(self.rect.x, self.rect.y + self.rect.h, self.rect.w, visible * self.row_height);
    }

    fn hit_test_overlay(self: *const DropDown, px: u32, py: u32) ?usize {
        if (!self.open) return null;
        const ov = self.overlay_rect();
        if (!ov.contains(px, py)) return null;
        const rel_y = py - ov.y;
        const idx = rel_y / self.row_height;
        if (idx < self.options.len) return idx;
        return null;
    }

    pub fn handle_event(self: *DropDown, ev: *const Event) bool {
        switch (ev.kind) {
            MOUSE_DOWN => {
                if (self.open) {
                    if (self.hit_test_overlay(ev.arg0, ev.arg1)) |idx| {
                        self.selected = idx;
                        self.open = false;
                        self.hover_idx = null;
                        return true;
                    }
                    self.open = false;
                    self.hover_idx = null;
                }
                if (self.rect.contains(ev.arg0, ev.arg1)) {
                    self.open = true;
                    return false;
                }
                return false;
            },
            MOUSE_MOVE => {
                if (self.open) {
                    self.hover_idx = self.hit_test_overlay(ev.arg0, ev.arg1);
                }
                return false;
            },
            KEY_DOWN => {
                if (!self.open) return false;
                const keycode = ev.arg0;
                // Up arrow (0x52)
                if (keycode == 0x52) {
                    if (self.selected > 0) {
                        self.selected -= 1;
                        return true;
                    }
                }
                // Down arrow (0x51)
                if (keycode == 0x51) {
                    if (self.selected + 1 < self.options.len) {
                        self.selected += 1;
                        return true;
                    }
                }
                // Enter (0x28) or Escape (0x29)
                if (keycode == 0x28 or keycode == 0x29) {
                    self.open = false;
                    self.hover_idx = null;
                    return false;
                }
                return false;
            },
            else => return false,
        }
    }

    pub fn draw(self: *const DropDown, win_id: u32) void {
        // Button body.
        const bg = if (self.open) theme_btn_pressed() else theme_btn_idle();
        draw_rect(win_id, self.rect, bg);
        draw_rect_outline(win_id, self.rect, 1, if (self.open) theme_accent() else theme_border());
        draw_text(win_id, self.selected_text(), self.rect.x + 4, self.rect.y + (self.rect.h - 8) / 2, theme_text_primary());
        // Down arrow indicator.
        const ax = self.rect.x + self.rect.w - 12;
        const ay = self.rect.y + (self.rect.h - 4) / 2;
        win_fill(win_id, ax, ay, 6, 2, theme_text_muted());
        win_fill(win_id, ax + 1, ay + 2, 4, 2, theme_text_muted());
        win_fill(win_id, ax + 2, ay + 4, 2, 2, theme_text_muted());

        // Dropdown overlay.
        if (self.open) {
            const ov = self.overlay_rect();
            draw_rect(win_id, ov, theme_surface());
            draw_rect_outline(win_id, ov, 1, theme_border());
            var i: u32 = 0;
            while (i < self.options.len and i < self.max_visible) : (i += 1) {
                const row_y = ov.y + i * self.row_height;
                const row_bg = if (self.hover_idx != null and self.hover_idx.? == i)
                    theme_btn_hover()
                else if (i == self.selected)
                    theme_accent()
                else
                    theme_surface();
                win_fill(win_id, ov.x + 1, row_y, ov.w - 2, self.row_height, row_bg);
                draw_text(win_id, self.options[i], ov.x + 4, row_y + (self.row_height - 8) / 2, theme_text_primary());
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Component: ContextMenu & Menu Builder (GH #228, Arc2 W2, M27 G9 #452)
// ---------------------------------------------------------------------------

pub const CanonicalMenuCategory = enum {
    file,
    edit,
    view,
    help,
};

pub const canonical_menu_bar = [_][]const u8{ "File", "Edit", "View", "Help" };

pub const StandardShortcut = struct {
    pub const save = "Ctrl+S";
    pub const open = "Ctrl+O";
    pub const quit = "Ctrl+Q";
    pub const undo = "Ctrl+Z";
    pub const redo = "Ctrl+Y";
    pub const find = "Ctrl+F";
    pub const help = "Ctrl+H";
    pub const cut = "Ctrl+X";
    pub const copy = "Ctrl+C";
    pub const paste = "Ctrl+V";
    pub const select_all = "Ctrl+A";
    pub const new_file = "Ctrl+N";
};

pub const MenuItemKind = enum {
    action,
    separator,
    header,
};

pub const MenuItemSpec = struct {
    label: []const u8 = "",
    shortcut: []const u8 = "",
    kind: MenuItemKind = .action,
    disabled: bool = false,
    action: ?*const fn () void = null,
};

pub const MenuSection = struct {
    title: []const u8 = "",
    items: []const MenuItemSpec = &[_]MenuItemSpec{},
};

pub const MenuBuilder = struct {
    items: [16]MenuItemSpec = [_]MenuItemSpec{.{}} ** 16,
    count: usize = 0,

    pub fn init() MenuBuilder {
        return .{};
    }

    pub fn add_item(self: *MenuBuilder, label: []const u8, shortcut: []const u8) *MenuBuilder {
        if (self.count < self.items.len) {
            self.items[self.count] = .{ .label = label, .shortcut = shortcut, .kind = .action };
            self.count += 1;
        }
        return self;
    }

    pub fn add_action(self: *MenuBuilder, label: []const u8, shortcut: []const u8, action_fn: ?*const fn () void) *MenuBuilder {
        if (self.count < self.items.len) {
            self.items[self.count] = .{ .label = label, .shortcut = shortcut, .kind = .action, .action = action_fn };
            self.count += 1;
        }
        return self;
    }

    pub fn add_separator(self: *MenuBuilder) *MenuBuilder {
        if (self.count < self.items.len) {
            self.items[self.count] = .{ .kind = .separator };
            self.count += 1;
        }
        return self;
    }

    pub fn add_header(self: *MenuBuilder, title: []const u8) *MenuBuilder {
        if (self.count < self.items.len) {
            self.items[self.count] = .{ .label = title, .kind = .header };
            self.count += 1;
        }
        return self;
    }

    pub fn slice(self: *const MenuBuilder) []const MenuItemSpec {
        return self.items[0..self.count];
    }
};

/// Build a standardized ContextMenu from a slice of MenuItemSpecs (M27 G9).
pub fn menu_build(specs: []const MenuItemSpec) ContextMenu {
    return ContextMenu.initWithSpecs(specs);
}

pub const ContextMenuItem = struct {
    label: []const u8,
    // Optional callback — not used in host tests, reserved for app wiring.
    action: ?*const fn () void = null,
};

pub const ContextMenu = struct {
    items: []const ContextMenuItem = &[_]ContextMenuItem{},
    specs: []const MenuItemSpec = &[_]MenuItemSpec{},
    x: u32 = 0,
    y: u32 = 0,
    width: u32 = 120,
    row_h: u32 = 16,
    open: bool = false,
    hover_idx: ?usize = null,
    selected_idx: ?usize = null,

    pub fn init(items: []const ContextMenuItem) ContextMenu {
        return .{ .items = items, .specs = &[_]MenuItemSpec{} };
    }

    pub fn initWithSpecs(specs: []const MenuItemSpec) ContextMenu {
        return .{ .items = &[_]ContextMenuItem{}, .specs = specs };
    }

    pub fn show(self: *ContextMenu, x: u32, y: u32) void {
        self.x = x;
        self.y = y;
        self.open = true;
        self.hover_idx = null;
        self.selected_idx = null;
    }

    pub fn dismiss(self: *ContextMenu) void {
        self.open = false;
        self.hover_idx = null;
    }

    pub fn is_open(self: *const ContextMenu) bool {
        return self.open;
    }

    pub fn count(self: *const ContextMenu) usize {
        return if (self.specs.len > 0) self.specs.len else self.items.len;
    }

    pub fn bounds(self: *const ContextMenu) Rect {
        return Rect.make(self.x, self.y, self.width, @as(u32, @intCast(self.count())) * self.row_h);
    }

    fn is_item_selectable(self: *const ContextMenu, idx: usize) bool {
        if (self.specs.len > 0) {
            if (idx >= self.specs.len) return false;
            return self.specs[idx].kind == .action and !self.specs[idx].disabled;
        }
        return idx < self.items.len;
    }

    fn hit_test(self: *const ContextMenu, px: u32, py: u32) ?usize {
        if (!self.open) return null;
        const b = self.bounds();
        if (!b.contains(px, py)) return null;
        const rel_y = py - b.y;
        const idx = rel_y / self.row_h;
        if (idx < self.count()) return idx;
        return null;
    }

    pub fn handle_event(self: *ContextMenu, ev: *const Event) bool {
        switch (ev.kind) {
            KEY_DOWN => {
                if (!self.open) return false;
                const kc = ev.arg0;
                const total = self.count();
                if (total == 0) return false;
                if (kc == 0x52) { // Up arrow
                    var cur = if (self.hover_idx) |h| h else 0;
                    var tries: usize = 0;
                    while (tries < total) : (tries += 1) {
                        cur = if (cur == 0) total - 1 else cur - 1;
                        if (self.is_item_selectable(cur)) {
                            self.hover_idx = cur;
                            return true;
                        }
                    }
                    return true;
                } else if (kc == 0x51) { // Down arrow
                    var cur = if (self.hover_idx) |h| h else total - 1;
                    var tries: usize = 0;
                    while (tries < total) : (tries += 1) {
                        cur = if (cur + 1 >= total) 0 else cur + 1;
                        if (self.is_item_selectable(cur)) {
                            self.hover_idx = cur;
                            return true;
                        }
                    }
                    return true;
                } else if (kc == 0x28) { // Enter
                    if (self.hover_idx) |idx| {
                        if (self.is_item_selectable(idx)) {
                            self.selected_idx = idx;
                            self.open = false;
                            if (self.specs.len > 0) {
                                if (self.specs[idx].action) |act| act();
                            } else if (self.items.len > 0) {
                                if (self.items[idx].action) |act| act();
                            }
                            return true;
                        }
                    }
                    return false;
                } else if (kc == 0x29) { // Escape
                    self.dismiss();
                    return true;
                }
                return false;
            },
            MOUSE_RIGHT_DOWN => {
                self.show(ev.arg0, ev.arg1);
                return true;
            },
            MOUSE_DOWN => {
                if (!self.open) return false;
                if (self.hit_test(ev.arg0, ev.arg1)) |idx| {
                    if (self.is_item_selectable(idx)) {
                        self.selected_idx = idx;
                        self.open = false;
                        self.hover_idx = null;
                        if (self.specs.len > 0) {
                            if (self.specs[idx].action) |act| act();
                        } else if (self.items.len > 0) {
                            if (self.items[idx].action) |act| act();
                        }
                        return true;
                    }
                    return true;
                }
                self.dismiss();
                return false;
            },
            MOUSE_MOVE => {
                if (!self.open) return false;
                const hit = self.hit_test(ev.arg0, ev.arg1);
                if (hit) |idx| {
                    if (self.is_item_selectable(idx)) {
                        self.hover_idx = idx;
                    } else {
                        self.hover_idx = null;
                    }
                } else {
                    self.hover_idx = null;
                }
                return false;
            },
            MOUSE_RIGHT_UP => {
                if (self.open) return true;
                return false;
            },
            else => return false,
        }
    }

    pub fn draw(self: *const ContextMenu, win_id: u32) void {
        if (!self.open) return;
        const b = self.bounds();
        draw_rect(win_id, b, theme_surface());
        draw_rect_outline(win_id, b, 1, theme_border());
        const total = self.count();
        var i: usize = 0;
        while (i < total) : (i += 1) {
            const row_y = b.y + @as(u32, @intCast(i)) * self.row_h;
            const row_rect = Rect.make(b.x + 1, row_y, b.w - 2, self.row_h);

            if (self.specs.len > 0) {
                const spec = self.specs[i];
                if (spec.kind == .separator) {
                    const mid_y = row_y + self.row_h / 2;
                    draw_rect(win_id, Rect.make(b.x + 4, mid_y, if (b.w > 8) b.w - 8 else 0, 1), theme_border());
                    continue;
                }
                const bg = if (self.hover_idx != null and self.hover_idx.? == i and !spec.disabled)
                    theme_btn_hover()
                else
                    theme_surface();
                win_fill(win_id, row_rect.x, row_rect.y, row_rect.w, row_rect.h, bg);
                const text_col = if (spec.disabled) theme_text_muted() else theme_text_primary();
                draw_text(win_id, spec.label, row_rect.x + 6, row_rect.y + (self.row_h - 8) / 2, text_col);
                if (spec.shortcut.len > 0) {
                    const sc_w = @as(u32, @intCast(spec.shortcut.len)) * 8;
                    const sc_x = if (row_rect.w > sc_w + 6) row_rect.x + row_rect.w - sc_w - 6 else row_rect.x;
                    draw_text(win_id, spec.shortcut, sc_x, row_rect.y + (self.row_h - 8) / 2, theme_text_muted());
                }
            } else {
                const bg = if (self.hover_idx != null and self.hover_idx.? == i)
                    theme_btn_hover()
                else
                    theme_surface();
                win_fill(win_id, row_rect.x, row_rect.y, row_rect.w, row_rect.h, bg);
                draw_text(win_id, self.items[i].label, row_rect.x + 6, row_rect.y + (self.row_h - 8) / 2, theme_text_primary());
            }
        }
    }
};

// ---------------------------------------------------------------------------
// Component: ScrollView — vertical scroll container (GH #218, Arc1)
// ---------------------------------------------------------------------------

pub const MOUSE_SCROLL: u16 = 12;

pub const ScrollView = struct {
    rect: Rect,
    content_h: u32,
    offset: u32 = 0,
    dragging: bool = false,
    drag_start_y: u32 = 0,
    drag_start_offset: u32 = 0,

    const scrollbar_w: u32 = 6;
    const thumb_min_h: u32 = 16;

    pub fn init(rect: Rect, content_h: u32) ScrollView {
        var sv = ScrollView{ .rect = rect, .content_h = content_h };
        sv.clamp_offset();
        return sv;
    }

    pub fn set_content_height(self: *ScrollView, h: u32) void {
        self.content_h = h;
        self.clamp_offset();
    }

    pub fn max_offset(self: *const ScrollView) u32 {
        if (self.content_h <= self.rect.h) return 0;
        return self.content_h - self.rect.h;
    }

    fn clamp_offset(self: *ScrollView) void {
        const m = self.max_offset();
        if (self.offset > m) self.offset = m;
    }

    pub fn thumb_h(self: *const ScrollView) u32 {
        if (self.content_h <= self.rect.h) return self.rect.h;
        const visible = self.rect.h;
        const content = self.content_h;
        const proportional = visible * visible / content;
        return @max(thumb_min_h, proportional);
    }

    pub fn thumb_y(self: *const ScrollView) u32 {
        const m = self.max_offset();
        if (m == 0) return self.rect.y;
        const th = self.thumb_h();
        const track_h = self.rect.h - th;
        // offset * track_h / max_offset, rounded down
        return self.rect.y + (self.offset * track_h / m);
    }

    pub fn thumb_rect(self: *const ScrollView) Rect {
        if (self.content_h <= self.rect.h) return self.rect;
        const th = self.thumb_h();
        const ty = self.thumb_y();
        return Rect.make(self.rect.x + self.rect.w - scrollbar_w, ty, scrollbar_w, th);
    }

    fn track_contains(self: *const ScrollView, px: u32, py: u32) bool {
        const track = Rect.make(self.rect.x + self.rect.w - scrollbar_w, self.rect.y, scrollbar_w, self.rect.h);
        return track.contains(px, py);
    }

    pub fn scroll_by(self: *ScrollView, delta: i32) void {
        const m: i32 = @intCast(self.max_offset());
        var off: i32 = @intCast(self.offset);
        off += delta;
        if (off < 0) off = 0;
        if (off > m) off = m;
        self.offset = @intCast(off);
    }

    pub fn handle_event(self: *ScrollView, ev: *const Event) bool {
        if (self.content_h <= self.rect.h) return false;
        switch (ev.kind) {
            MOUSE_DOWN => {
                const px = ev.arg0;
                const py = ev.arg1;
                if (!self.rect.contains(px, py)) return false;
                const tr = self.thumb_rect();
                if (tr.contains(px, py)) {
                    self.dragging = true;
                    self.drag_start_y = py;
                    self.drag_start_offset = self.offset;
                    return true;
                }
                if (self.track_contains(px, py)) {
                    // Click on track outside thumb — page up/down
                    const ty = self.thumb_y();
                    if (py < ty) {
                        self.scroll_by(-@as(i32, @intCast(self.rect.h)));
                    } else {
                        self.scroll_by(@as(i32, @intCast(self.rect.h)));
                    }
                    return true;
                }
                return false;
            },
            MOUSE_MOVE => {
                if (!self.dragging) return false;
                const py: i32 = @intCast(ev.arg1);
                const start_y: i32 = @intCast(self.drag_start_y);
                const delta: i32 = py - start_y;
                const m = self.max_offset();
                if (m == 0) return false;
                const th = self.thumb_h();
                const track_h: i32 = @intCast(self.rect.h - th);
                if (track_h <= 0) return false;
                // Scale thumb drag to content offset: delta * max_offset / track_h
                const scaled = @divTrunc(delta * @as(i32, @intCast(m)), track_h);
                var new_off: i32 = @as(i32, @intCast(self.drag_start_offset)) + scaled;
                if (new_off < 0) new_off = 0;
                if (new_off > @as(i32, @intCast(m))) new_off = @intCast(m);
                self.offset = @intCast(new_off);
                return true;
            },
            MOUSE_UP => {
                if (self.dragging) {
                    self.dragging = false;
                    return true;
                }
                return false;
            },
            KEY_DOWN => {
                const keycode = ev.arg0;
                // PageUp 0x4b, PageDown 0x4e (from notepad.zig), also handle wheel if present
                if (keycode == 0x4b) { // PageUp
                    self.scroll_by(-@as(i32, @intCast(self.rect.h)));
                    return true;
                }
                if (keycode == 0x4e) { // PageDown
                    self.scroll_by(@as(i32, @intCast(self.rect.h)));
                    return true;
                }
                return false;
            },
            MOUSE_SCROLL => {
                // Arc4 #236: arg0 packed per ADR 0013 D2.
                // bits 0–13 = magnitude, bit 14 = horizontal, bit 15 = sign.
                const raw = ev.arg0;
                const horizontal = (raw & 0x4000) != 0;
                if (horizontal) return false; // vertical-only ScrollView
                const magnitude: i32 = @intCast(raw & 0x1fff);
                if (magnitude == 0) return false;
                const sign: i32 = if ((raw & 0x8000) != 0) 1 else -1;
                const step = sign * magnitude * 16;
                self.scroll_by(step);
                return true;
            },
            else => return false,
        }
    }

    pub fn draw(self: *const ScrollView, win_id: u32) void {
        if (self.content_h <= self.rect.h) return;
        // Track
        const track_x = self.rect.x + self.rect.w - scrollbar_w;
        draw_rect(win_id, Rect.make(track_x, self.rect.y, scrollbar_w, self.rect.h), theme_border());
        // Thumb
        const tr = self.thumb_rect();
        // Thumb as accent, with 1px inset for rounded feel
        win_fill(win_id, tr.x, tr.y, tr.w, tr.h, theme_accent());
    }
};

// ---------------------------------------------------------------------------
// Component: Checkbox — 12×12 boolean (GH #219, Arc1)
// ---------------------------------------------------------------------------

pub const Checkbox = struct {
    rect: Rect,
    checked: *bool,

    pub fn init(rect: Rect, checked: *bool) Checkbox {
        return .{ .rect = rect, .checked = checked };
    }

    pub fn handle_event(self: *Checkbox, ev: *const Event) bool {
        if (ev.kind != MOUSE_DOWN) return false;
        if ((ev.flags & BTN_LEFT) == 0) return false;
        if (!self.rect.contains(ev.arg0, ev.arg1)) return false;
        self.checked.* = !self.checked.*;
        return true;
    }

    pub fn draw(self: *const Checkbox, win_id: u32) void {
        // Box outline
        draw_rect(win_id, self.rect, theme_surface());
        draw_rect_outline(win_id, self.rect, 1, theme_border());
        if (self.checked.*) {
            // Filled inner square (inset 3) in accent
            const inner = self.rect.inset(3, 3);
            // Clamp to at least 6×6 for 12×12 box -> 6×6 inner
            win_fill(win_id, inner.x, inner.y, inner.w, inner.h, theme_accent());
        }
    }
};

// ---------------------------------------------------------------------------
// Component: Toggle — 48×20 pill boolean (GH #219, Arc1)
// ---------------------------------------------------------------------------

pub const Toggle = struct {
    rect: Rect,
    enabled: *bool,

    pub fn init(rect: Rect, enabled: *bool) Toggle {
        return .{ .rect = rect, .enabled = enabled };
    }

    pub fn handle_event(self: *Toggle, ev: *const Event) bool {
        if (ev.kind != MOUSE_DOWN) return false;
        if ((ev.flags & BTN_LEFT) == 0) return false;
        if (!self.rect.contains(ev.arg0, ev.arg1)) return false;
        self.enabled.* = !self.enabled.*;
        return true;
    }

    pub fn draw(self: *const Toggle, win_id: u32) void {
        // Pill background
        const bg = if (self.enabled.*) theme_accent() else theme_border();
        draw_rect(win_id, self.rect, bg);
        // Knob: 16×16 circle approximated as square, inset 2, left or right
        const knob_w: u32 = 16;
        const knob_h: u32 = 16;
        const knob_y = self.rect.y + (self.rect.h - knob_h) / 2;
        const knob_x = if (self.enabled.*)
            self.rect.x + self.rect.w - knob_w - 2
        else
            self.rect.x + 2;
        // Knob in surface (contrasts with accent/border bg)
        win_fill(win_id, knob_x, knob_y, knob_w, knob_h, theme_surface());
        draw_rect_outline(win_id, Rect.make(knob_x, knob_y, knob_w, knob_h), 1, theme_border());
    }
};

// ---------------------------------------------------------------------------
// Component: ProgressBar — determinate + indeterminate (GH #220, Arc1)
// ---------------------------------------------------------------------------

pub const ProgressBar = struct {
    rect: Rect,
    value: f32 = 0.0,
    label: []const u8 = "",
    indeterminate: bool = false,
    offset: i32 = 0,
    dir: i32 = 1,

    pub const indeterminate_width: u32 = 20;
    pub const indeterminate_step: i32 = 4;

    pub fn init(rect: Rect) ProgressBar {
        return .{ .rect = rect };
    }

    pub fn initWithValue(rect: Rect, value: f32) ProgressBar {
        var pb = ProgressBar.init(rect);
        pb.set_value(value);
        return pb;
    }

    pub fn set_value(self: *ProgressBar, v: f32) void {
        if (std.math.isNan(v) or std.math.isInf(v)) {
            self.value = if (v > 0 and std.math.isInf(v)) 1.0 else 0.0;
            if (std.math.isNan(v)) self.value = 0.0;
            return;
        }
        if (v < 0.0) {
            self.value = 0.0;
        } else if (v > 1.0) {
            self.value = 1.0;
        } else {
            self.value = v;
        }
    }

    pub fn set_label(self: *ProgressBar, text: []const u8) void {
        self.label = text;
    }

    pub fn set_indeterminate(self: *ProgressBar, enabled: bool) void {
        self.indeterminate = enabled;
        if (enabled) {
            self.offset = 0;
            self.dir = 1;
        }
    }

    pub fn inner_rect(self: *const ProgressBar) Rect {
        if (self.rect.w <= 2 or self.rect.h <= 2) return Rect.make(self.rect.x, self.rect.y, 0, 0);
        return Rect.make(self.rect.x + 1, self.rect.y + 1, self.rect.w - 2, self.rect.h - 2);
    }

    pub fn fill_width(self: *const ProgressBar) u32 {
        const inner = self.inner_rect();
        if (inner.w == 0) return 0;
        const clamped = if (self.value < 0.0) @as(f32, 0.0) else if (self.value > 1.0) @as(f32, 1.0) else self.value;
        const fw: f32 = @as(f32, @floatFromInt(inner.w)) * clamped;
        return @as(u32, @intFromFloat(@floor(fw)));
    }

    /// Max offset for the sliding block inside inner rect (inner_w - block_w).
    pub fn max_offset(self: *const ProgressBar) i32 {
        const inner = self.inner_rect();
        if (inner.w <= indeterminate_width) return 0;
        return @as(i32, @intCast(inner.w - indeterminate_width));
    }

    /// Advance indeterminate animation by one TIMER tick. Returns true if moved.
    pub fn tick(self: *ProgressBar) bool {
        if (!self.indeterminate) return false;
        const max = self.max_offset();
        if (max == 0) return false;
        self.offset += self.dir * indeterminate_step;
        if (self.offset >= max) {
            self.offset = max;
            self.dir = -1;
        } else if (self.offset <= 0) {
            self.offset = 0;
            self.dir = 1;
        }
        return true;
    }

    pub fn handle_event(self: *ProgressBar, ev: *const Event) bool {
        if (!self.indeterminate) return false;
        if (ev.kind != EVENT_TIMER) return false;
        return self.tick();
    }

    /// Test helper: is the i-th label character centered over the fill/block?
    pub fn is_label_char_over_fill(self: *const ProgressBar, char_idx: usize) bool {
        if (self.label.len == 0 or char_idx >= self.label.len) return false;
        const inner = self.inner_rect();
        const text_w = @as(u32, @intCast(self.label.len)) * 8;
        const label_x = if (self.rect.w > text_w) self.rect.x + (self.rect.w - text_w) / 2 else self.rect.x;
        const char_x = label_x + @as(u32, @intCast(char_idx)) * 8;
        const char_center = char_x + 4;
        if (self.indeterminate) {
            const block_x = @as(i32, @intCast(inner.x)) + self.offset;
            const block_x_u: u32 = if (block_x < 0) 0 else @as(u32, @intCast(block_x));
            return char_center >= block_x_u and char_center < block_x_u + indeterminate_width;
        } else {
            const fw = self.fill_width();
            if (fw == 0) return false;
            const fill_end = inner.x + fw;
            return char_center < fill_end;
        }
    }

    pub fn draw(self: *const ProgressBar, win_id: u32) void {
        // Background + border
        draw_rect(win_id, self.rect, theme_surface());
        draw_rect_outline(win_id, self.rect, 1, theme_border());
        const inner = self.inner_rect();
        if (inner.w == 0 or inner.h == 0) return;

        if (self.indeterminate) {
            const block_x_i: i32 = @as(i32, @intCast(inner.x)) + self.offset;
            const block_x: u32 = if (block_x_i < 0) inner.x else @as(u32, @intCast(block_x_i));
            // Clamp block inside inner
            const clamped_x = @min(block_x, inner.x + inner.w - indeterminate_width);
            const block_rect = Rect.make(clamped_x, inner.y, indeterminate_width, inner.h);
            draw_rect(win_id, block_rect, theme_accent());
        } else {
            const fw = self.fill_width();
            if (fw > 0) {
                const fill_rect = Rect.make(inner.x, inner.y, fw, inner.h);
                draw_rect(win_id, fill_rect, theme_accent());
            }
        }

        // Centered label with contrast inversion per character.
        if (self.label.len > 0) {
            const text_w = @as(u32, @intCast(self.label.len)) * 8;
            const text_h: u32 = 8;
            const lx = if (self.rect.w > text_w) self.rect.x + (self.rect.w - text_w) / 2 else self.rect.x;
            const ly = if (self.rect.h > text_h) self.rect.y + (self.rect.h - text_h) / 2 else self.rect.y;
            var i: usize = 0;
            while (i < self.label.len) : (i += 1) {
                const ch = self.label[i];
                const char_x = lx + @as(u32, @intCast(i)) * 8;
                const over_fill = self.is_label_char_over_fill(i);
                // Over fill/block: white for high contrast on accent; over bg: theme text primary.
                const fg: u32 = if (over_fill) 0xffffff else theme_text_primary();
                draw_char(win_id, ch, char_x, ly, fg);
            }
        }
    }
};

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

// ---------------------------------------------------------------------------
// Component: HScrollBar — horizontal scroll track (GH #222, Arc1)
// ---------------------------------------------------------------------------

pub const HScrollBar = struct {
    rect: Rect,
    content_w: u32,
    viewport_w: u32,
    offset: u32 = 0,
    dragging: bool = false,
    drag_start_x: u32 = 0,
    drag_start_offset: u32 = 0,

    pub const track_h: u32 = 8;
    pub const thumb_min_w: u32 = 16;

    pub fn init(rect: Rect, content_w: u32, viewport_w: u32) HScrollBar {
        var hb = HScrollBar{ .rect = rect, .content_w = content_w, .viewport_w = viewport_w };
        hb.clamp_offset();
        return hb;
    }

    pub fn set_content_width(self: *HScrollBar, w: u32) void {
        self.content_w = w;
        self.clamp_offset();
    }

    pub fn set_viewport_width(self: *HScrollBar, w: u32) void {
        self.viewport_w = w;
        self.clamp_offset();
    }

    pub fn max_offset(self: *const HScrollBar) u32 {
        if (self.content_w <= self.viewport_w) return 0;
        return self.content_w - self.viewport_w;
    }

    fn clamp_offset(self: *HScrollBar) void {
        const m = self.max_offset();
        if (self.offset > m) self.offset = m;
    }

    pub fn thumb_w(self: *const HScrollBar) u32 {
        if (self.content_w <= self.viewport_w) return self.rect.w;
        const visible = self.viewport_w;
        const content = self.content_w;
        const proportional = self.rect.w * visible / content;
        return @max(thumb_min_w, proportional);
    }

    pub fn thumb_x(self: *const HScrollBar) u32 {
        const m = self.max_offset();
        if (m == 0) return self.rect.x;
        const tw = self.thumb_w();
        const track_w = self.rect.w - tw;
        return self.rect.x + (self.offset * track_w / m);
    }

    pub fn thumb_rect(self: *const HScrollBar) Rect {
        if (self.content_w <= self.viewport_w) return self.rect;
        const tw = self.thumb_w();
        const tx = self.thumb_x();
        return Rect.make(tx, self.rect.y, tw, self.rect.h);
    }

    fn track_contains(self: *const HScrollBar, px: u32, py: u32) bool {
        return self.rect.contains(px, py);
    }

    pub fn scroll_by(self: *HScrollBar, delta: i32) void {
        const m: i32 = @intCast(self.max_offset());
        var off: i32 = @intCast(self.offset);
        off += delta;
        if (off < 0) off = 0;
        if (off > m) off = m;
        self.offset = @intCast(off);
    }

    pub fn handle_event(self: *HScrollBar, ev: *const Event) bool {
        if (self.content_w <= self.viewport_w) return false;
        switch (ev.kind) {
            MOUSE_DOWN => {
                const px = ev.arg0;
                const py = ev.arg1;
                if (!self.rect.contains(px, py)) return false;
                const tr = self.thumb_rect();
                if (tr.contains(px, py)) {
                    self.dragging = true;
                    self.drag_start_x = px;
                    self.drag_start_offset = self.offset;
                    return true;
                }
                if (self.track_contains(px, py)) {
                    const tx = self.thumb_x();
                    if (px < tx) {
                        self.scroll_by(-@as(i32, @intCast(self.viewport_w)));
                    } else {
                        self.scroll_by(@as(i32, @intCast(self.viewport_w)));
                    }
                    return true;
                }
                return false;
            },
            MOUSE_MOVE => {
                if (!self.dragging) return false;
                const px: i32 = @intCast(ev.arg0);
                const start_x: i32 = @intCast(self.drag_start_x);
                const delta: i32 = px - start_x;
                const m = self.max_offset();
                if (m == 0) return false;
                const tw = self.thumb_w();
                const track_w: i32 = @intCast(self.rect.w - tw);
                if (track_w <= 0) return false;
                const scaled = @divTrunc(delta * @as(i32, @intCast(m)), track_w);
                var new_off: i32 = @as(i32, @intCast(self.drag_start_offset)) + scaled;
                if (new_off < 0) new_off = 0;
                if (new_off > @as(i32, @intCast(m))) new_off = @intCast(m);
                self.offset = @intCast(new_off);
                return true;
            },
            MOUSE_UP => {
                if (self.dragging) {
                    self.dragging = false;
                    return true;
                }
                return false;
            },
            KEY_DOWN => {
                const keycode = ev.arg0;
                // Left 0x50, Right 0x4f, Home 0x4a, End 0x4d
                if (keycode == 0x50) {
                    self.scroll_by(-16);
                    return true;
                }
                if (keycode == 0x4f) {
                    self.scroll_by(16);
                    return true;
                }
                if (keycode == 0x4a) {
                    self.offset = 0;
                    return true;
                }
                if (keycode == 0x4d) {
                    self.offset = self.max_offset();
                    return true;
                }
                return false;
            },
            MOUSE_SCROLL => {
                // Horizontal via Shift (MOD_SHIFT) or packed horizontal bit.
                const is_shift = (ev.flags & MOD_SHIFT) != 0;
                const packed_horizontal = (ev.arg0 & 0x4000) != 0 and (ev.arg0 & 0xffff0000) == 0;
                const is_horizontal = is_shift or packed_horizontal;
                if (!is_horizontal) return false;
                var delta: i32 = 0;
                // Arc4 #236: arg0 packed per ADR 0013 D2.
                // bits 0–13 = magnitude, bit 14 = horizontal, bit 15 = sign.
                // Shift+scroll overrides horizontal flag.
                const raw = ev.arg0;
                const magnitude: i32 = @intCast(raw & 0x1fff);
                if (magnitude == 0) return false;
                const horiz = is_shift or (raw & 0x4000) != 0;
                if (!horiz) return false; // HScrollBar only consumes horizontal
                const sign: i32 = if ((raw & 0x8000) != 0) 1 else -1;
                delta = sign * magnitude * 16;
                self.scroll_by(delta);
                return true;
            },
            else => return false,
        }
    }

    pub fn draw(self: *const HScrollBar, win_id: u32) void {
        if (self.content_w <= self.viewport_w) return;
        // Track
        draw_rect(win_id, self.rect, theme_border());
        // Thumb
        const tr = self.thumb_rect();
        win_fill(win_id, tr.x, tr.y, tr.w, tr.h, theme_accent());
    }
};

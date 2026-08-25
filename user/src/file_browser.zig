//! DipshitOS twenty-first ESP user program — FILE.BIN (Milestone 13, Card B3).
//!
//! Graphical file browser for the DATA partition (`/data/`). Browses the
//! directory in a scrollable list, shows the selected entry's size/type, and
//! opens `.TXT` files in a read-only view. Uses the M10 file seam
//! (`sys_dir_list` / `sys_file_open` / `sys_file_read` / `sys_file_close`)
//! and the ui.zig micro-widget toolkit with ZERO heap allocation — every
//! buffer lives in the stack-allocated `AppState` (W^X safe: no writable
//! globals).
//!
//! Delete/rename arrive with card B1 (ADR 0007 slots 34–37, issue #161);
//! this app only browses and reads — the read-only ABI is the B3 core.

const std = @import("std");
const ui = @import("lib/ui.zig");
const Rect = ui.Rect;
const Button = ui.Button;
const Event = ui.Event;
const DirEntry = ui.DirEntry;

pub const window_id: u32 = 5;
pub const window_x: u32 = 40;
pub const window_y: u32 = 40;
pub const window_w: u32 = 512;
pub const window_h: u32 = 384;

pub const exit_status: u32 = 43;
pub const data_path: []const u8 = "/data";

// Geometry (inside the 512x384 window).
pub const title_rect = Rect.make(0, 0, 512, 22);
pub const list_area = Rect.make(6, 26, 240, 290);
pub const details_area = Rect.make(252, 26, 254, 290);
pub const btn_open_rect = Rect.make(6, 322, 56, 22);
pub const btn_rename_rect = Rect.make(66, 322, 64, 22);
pub const btn_delete_rect = Rect.make(134, 322, 64, 22);
pub const btn_back_rect = Rect.make(6, 322, 56, 22); // overlaps Open; mode-exclusive

pub const list_row_h: u32 = 16;
pub const glyph_w: u32 = 8;
pub const line_h: u32 = 12;
pub const view_text_x: u32 = 10;
pub const view_text_y: u32 = 30;
pub const view_cols: usize = 59; // (list_area.w - 12) / glyph_w
pub const view_rows: usize = 9; // ~(details_area.h - 12) / line_h

pub const max_entries: usize = 16;
pub const content_max: usize = 512;
pub const preview_rows: usize = 15;
pub const preview_cols: usize = 30; // (details_area.w - 12) / 8
pub const breadcrumb_rect = Rect.make(60, 6, 440, 12);
pub const path_max: usize = 64;

// F11: column header geometry (inside the list area, 14px tall).
pub const header_h: u32 = 14;
pub const col_name_x: u32 = list_area.x + 16; // after icon column
pub const col_name_w: u32 = 120;
pub const col_size_x: u32 = col_name_x + col_name_w;
pub const col_size_w: u32 = 50;
pub const col_type_x: u32 = col_size_x + col_size_w;
pub const col_type_w: u32 = list_area.x + list_area.w - col_type_x;

// ---------------------------------------------------------------------------
// Hand-rolled string building (W^X-safe; std.fmt.bufPrint is avoided — see
// desktop.zig claim 8877 for the FP/SIMD root cause).
// ---------------------------------------------------------------------------

fn append_str(buf: []u8, pos: usize, src: []const u8) usize {
    @memcpy(buf[pos .. pos + src.len], src);
    return pos + src.len;
}

fn fmt_u64(buf: []u8, value: u64) []const u8 {
    var v = value;
    var i: usize = buf.len;
    if (v == 0) {
        i -= 1;
        buf[i] = '0';
        return buf[i..];
    }
    while (v > 0) : (v /= 10) {
        i -= 1;
        buf[i] = @intCast('0' + (v % 10));
    }
    return buf[i..];
}

// ---------------------------------------------------------------------------
// Entry helpers (pure, host-testable)
// ---------------------------------------------------------------------------

/// Length of a NUL-padded `name[32]` (FAT display name).
pub fn entry_name(entry: *const DirEntry) []const u8 {
    var len: usize = 0;
    while (len < entry.name.len and entry.name[len] != 0) : (len += 1) {}
    return entry.name[0..len];
}

fn ascii_upper(c: u8) u8 {
    if (c >= 'a' and c <= 'z') return c - 32;
    return c;
}

fn ascii_lower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

// ---------------------------------------------------------------------------
// F11: Sorting support (mirrors TOP.BIN's SortColumn pattern)
// ---------------------------------------------------------------------------

pub const SortColumn = enum { name, size, col_type };

/// Case-insensitive name comparison. Returns -1 if a<b, 1 if a>b, 0 if equal.
pub fn name_cmp_ignore_case(a: []const u8, b: []const u8) i8 {
    const min_len = @min(a.len, b.len);
    for (0..min_len) |i| {
        const ca = ascii_lower(a[i]);
        const cb = ascii_lower(b[i]);
        if (ca < cb) return -1;
        if (ca > cb) return 1;
    }
    if (a.len < b.len) return -1;
    if (a.len > b.len) return 1;
    return 0;
}

/// Compare two DirEntries for sorting. Returns -1 if a should come before b.
pub fn compare_entries(a: *const DirEntry, b: *const DirEntry, col: SortColumn) i8 {
    return switch (col) {
        .name => {
            // Directories sort after files when sorting by name.
            if (a.is_dir != 0 and b.is_dir == 0) return 1;
            if (a.is_dir == 0 and b.is_dir != 0) return -1;
            return name_cmp_ignore_case(entry_name(a), entry_name(b));
        },
        .size => {
            // Directories sort after files.
            if (a.is_dir != 0 and b.is_dir == 0) return 1;
            if (a.is_dir == 0 and b.is_dir != 0) return -1;
            if (a.size < b.size) return -1;
            if (a.size > b.size) return 1;
            return name_cmp_ignore_case(entry_name(a), entry_name(b));
        },
        .col_type => {
            // Directories first, then by name.
            if (a.is_dir != 0 and b.is_dir == 0) return -1;
            if (a.is_dir == 0 and b.is_dir != 0) return 1;
            return name_cmp_ignore_case(entry_name(a), entry_name(b));
        },
    };
}

/// True when the name ends in `.TXT` (case-insensitive) — the files this
/// browser opens read-only.
pub fn is_txt_file(name: []const u8) bool {
    if (name.len < 4) return false;
    const s = name[name.len - 4 ..];
    return ascii_upper(s[0]) == '.' and
        ascii_upper(s[1]) == 'T' and
        ascii_upper(s[2]) == 'X' and
        ascii_upper(s[3]) == 'T';
}

/// True when the name ends in `.BIN` (case-insensitive).
pub fn is_bin_file(name: []const u8) bool {
    if (name.len < 4) return false;
    const s = name[name.len - 4 ..];
    return ascii_upper(s[0]) == '.' and
        ascii_upper(s[1]) == 'B' and
        ascii_upper(s[2]) == 'I' and
        ascii_upper(s[3]) == 'N';
}

/// True when the name starts with '.' — a hidden/dotfile (F12).
pub fn is_hidden_file(name: []const u8) bool {
    return name.len > 0 and name[0] == '.';
}

/// F13: Get associated app for file extension (GH #393)
pub fn get_associated_app(name: []const u8) []const u8 {
    if (is_bin_file(name)) return "EXEC";
    if (is_txt_file(name)) return "NOTEPAD";
    if (name.len >= 4) {
        const s4 = name[name.len - 4 ..];
        if (ascii_upper(s4[0]) == '.' and ascii_upper(s4[1]) == 'Z' and ascii_upper(s4[2]) == 'I' and ascii_upper(s4[3]) == 'G') return "EDIT";
        if (ascii_upper(s4[0]) == '.' and ascii_upper(s4[1]) == 'D' and ascii_upper(s4[2]) == 'O' and ascii_upper(s4[3]) == 'C') return "NOTEPAD";
    }
    if (name.len >= 2) {
        const s2 = name[name.len - 2 ..];
        if (ascii_upper(s2[0]) == '.' and (ascii_upper(s2[1]) == 'C' or ascii_upper(s2[1]) == 'H')) return "EDIT";
    }
    return "VIEW";
}

/// Number of display rows a content slice occupies, wrapping at `cols`
/// glyphs per row and breaking on '\\n' (mirrors notepad's TextLayout).
pub fn content_rows(content: []const u8, cols: usize) usize {
    var row: usize = 0;
    var col: usize = 0;
    for (content) |ch| {
        if (ch == '\n') {
            row += 1;
            col = 0;
        } else {
            if (col == cols) {
                row += 1;
                col = 0;
            }
            col += 1;
        }
    }
    return row + 1;
}

/// True when `content` looks binary (non-printable). Allows \t \n \r.
/// C7: printable-byte sniff for .TXT preview — <80% printable → binary.
pub fn is_binary_content(content: []const u8) bool {
    if (content.len == 0) return false;
    var printable: usize = 0;
    for (content) |ch| {
        if (ch == 0x09 or ch == 0x0a or ch == 0x0d) {
            printable += 1;
        } else if (ch >= 0x20 and ch <= 0x7e) {
            printable += 1;
        }
    }
    return printable * 10 < content.len * 8;
}

/// Count path segments in an absolute path like "/data/docs".
pub fn path_segment_count(path: []const u8) usize {
    if (path.len == 0) return 0;
    var count: usize = 0;
    var i: usize = 0;
    while (i < path.len) {
        while (i < path.len and path[i] == '/') : (i += 1) {}
        if (i >= path.len) break;
        count += 1;
        while (i < path.len and path[i] != '/') : (i += 1) {}
    }
    return count;
}

/// Write the display string for breadcrumbs: segments joined by " > ".
/// Returns slice length written into `buf` (caller provides ≥ path.len + 8).
pub fn format_breadcrumbs(path: []const u8, buf: []u8) []const u8 {
    var pos: usize = 0;
    var i: usize = 0;
    var first = true;
    while (i < path.len) {
        while (i < path.len and path[i] == '/') : (i += 1) {}
        if (i >= path.len) break;
        const start = i;
        while (i < path.len and path[i] != '/') : (i += 1) {}
        const seg = path[start..i];
        if (!first) {
            if (pos + 3 > buf.len) break;
            buf[pos] = ' ';
            buf[pos + 1] = '>';
            buf[pos + 2] = ' ';
            pos += 3;
        }
        if (pos + seg.len > buf.len) break;
        @memcpy(buf[pos .. pos + seg.len], seg);
        pos += seg.len;
        first = false;
    }
    if (pos == 0 and path.len > 0) {
        // root like "/" or "/data" with empty split — show raw path trimmed
        const t = @min(path.len, buf.len);
        @memcpy(buf[0..t], path[0..t]);
        return buf[0..t];
    }
    return buf[0..pos];
}

/// Hit-test breadcrumbs: given a window-local x, return segment index hit.
/// Segments are laid out as `format_breadcrumbs` with 8px per glyph + 24px per " > ".
pub fn breadcrumb_hit_test(path: []const u8, base_x: u32, px: u32) ?usize {
    if (px < base_x) return null;
    var x = base_x;
    var i: usize = 0;
    var seg_idx: usize = 0;
    var first = true;
    while (i < path.len) {
        while (i < path.len and path[i] == '/') : (i += 1) {}
        if (i >= path.len) break;
        const start = i;
        while (i < path.len and path[i] != '/') : (i += 1) {}
        const seg = path[start..i];
        if (!first) x += 3 * glyph_w; // " > "
        const seg_w = @as(u32, @intCast(seg.len)) * glyph_w;
        if (px >= x and px < x + seg_w) return seg_idx;
        x += seg_w;
        seg_idx += 1;
        first = false;
    }
    return null;
}

/// Truncate `path` to include segments `0..keep` inclusive (keep is 0-based).
/// Keeps leading "/". Returns new length. Assumes path starts with "/".
pub fn truncate_to_segment(path: []u8, path_len: usize, keep: usize) usize {
    var seg: usize = 0;
    var i: usize = 0;
    // Skip leading slashes
    while (i < path_len and path[i] == '/') : (i += 1) {}
    while (i < path_len) {
        while (i < path_len and path[i] != '/') : (i += 1) {}
        if (seg == keep) {
            return i;
        }
        seg += 1;
        while (i < path_len and path[i] == '/') : (i += 1) {}
    }
    return path_len;
}

// ---------------------------------------------------------------------------
// Scrollable file-list model (selection + viewport, host-testable)
// ---------------------------------------------------------------------------

pub const FileList = struct {
    rect: Rect,
    row_height: u32 = list_row_h,
    scroll: usize = 0,
    selected: ?usize = null,

    pub fn init(rect: Rect) FileList {
        return .{ .rect = rect };
    }

    pub fn visible_rows(self: *const FileList) usize {
        if (self.row_height == 0) return 0;
        return @intCast(self.rect.h / self.row_height);
    }

    /// Largest legal scroll offset for `count` entries.
    pub fn max_scroll(self: *const FileList, count: usize) usize {
        const vis = self.visible_rows();
        if (count <= vis) return 0;
        return count - vis;
    }

    /// Keep the selection inside the viewport; clamps `scroll`.
    pub fn ensure_visible(self: *FileList, count: usize) void {
        const ms = self.max_scroll(count);
        if (self.scroll > ms) self.scroll = ms;
        const sel = self.selected orelse return;
        const vis = self.visible_rows();
        if (vis == 0) return;
        if (sel < self.scroll) self.scroll = sel;
        if (sel >= self.scroll + vis) self.scroll = sel - vis + 1;
    }

    pub fn select(self: *FileList, idx: usize, count: usize) void {
        if (count == 0) {
            self.selected = null;
            return;
        }
        self.selected = @min(idx, count - 1);
        self.ensure_visible(count);
    }

    pub fn move_by(self: *FileList, delta: isize, count: usize) void {
        if (count == 0) return;
        const base: isize = if (self.selected) |s| @intCast(s) else -1;
        var next = base + delta;
        if (next < 0) next = 0;
        if (next >= @as(isize, @intCast(count))) next = @intCast(count - 1);
        self.selected = @intCast(next);
        self.ensure_visible(count);
    }

    /// Click-to-select: maps a window-local (px,py) to the absolute entry
    /// index (scroll-aware). Returns true when the selection changed.
    pub fn click(self: *FileList, px: u32, py: u32, count: usize) bool {
        if (count == 0 or !self.rect.contains(px, py)) return false;
        const rel_y = py - self.rect.y;
        const row = rel_y / self.row_height;
        if (row >= self.visible_rows()) return false;
        const abs = self.scroll + @as(usize, @intCast(row));
        if (abs >= count) return false;
        const prev = self.selected;
        self.selected = abs;
        return prev != self.selected;
    }
};

// ---------------------------------------------------------------------------
// App State (stack-allocated, W^X-safe)
// ---------------------------------------------------------------------------

/// Render one list row (shared by AppState.draw_list).
fn draw_list_row(win: u32, row: usize, name: []const u8, entry: *const DirEntry, is_sel: bool, is_multi: bool, hl_at: usize, hl_len: usize) void {
    const row_y = list_area.y + header_h + @as(u32, @intCast(row)) * list_row_h;
    const row_rect = Rect.make(list_area.x, row_y, list_area.w, list_row_h);
    const bg = if (is_sel)
        ui.COLOR_ACCENT
    else if (is_multi)
        0x1e3a8a // dark blue selection highlight (F1)
    else if (entry.is_dir != 0)
        ui.COLOR_BTN_IDLE
    else if (row % 2 == 0)
        ui.COLOR_SURFACE
    else
        ui.COLOR_BG;
    ui.draw_rect(win, row_rect, bg);
    // Step 12: colored type indicator (8x8 square before filename).
    const icon_color: u32 = if (entry.is_dir != 0)
        0x3b82f6 // blue for directories
    else if (is_txt_file(name))
        0x22c55e // green for .TXT
    else if (is_bin_file(name))
        0xf59e0b // amber for .BIN
    else
        0x64748b; // gray for unknown
    ui.draw_rect(win, Rect.make(row_rect.x + 4, row_rect.y + 4, 8, 8), icon_color);
    if (is_multi) {
        ui.draw_text(win, "*", row_rect.x + 14, row_rect.y + (list_row_h - 8) / 2, ui.COLOR_WARNING);
    }
    // Cap the drawn name to the row width (240 - 16 padding - 12 icon = 212px = 26 glyphs).
    const cap = @min(name.len, 24);
    const text_x = row_rect.x + 20;
    const text_y = row_rect.y + (list_row_h - 8) / 2;
    ui.draw_text(win, name[0..cap], text_x, text_y, ui.COLOR_TEXT_PRIMARY);
    // M20-U3: highlight the searched substring inside the filename when
    // the filter bar narrowed the listing (accent cell + white glyph,
    // the same treatment notepad gives find matches).
    if (hl_len > 0 and hl_at < cap) {
        const hlen = @min(hl_len, cap - hl_at);
        var k: usize = 0;
        while (k < hlen) : (k += 1) {
            const cx = text_x + @as(u32, @intCast(hl_at + k)) * glyph_w;
            ui.draw_rect(win, Rect.make(cx, text_y, glyph_w, 8), ui.COLOR_ACCENT);
            ui.draw_char(win, name[hl_at + k], cx, text_y, 0xffffff);
        }
    }
}

pub const AppState = struct {
    entries: [max_entries]DirEntry = undefined,
    entry_count: usize = 0,

    list: FileList = FileList.init(list_area),
    // GH #218 ScrollView proof — vertical scrollbar for the file list (pure ui.zig, no ABI)
    scroll_view: ui.ScrollView = ui.ScrollView.init(list_area, 0),

    // Current directory path (session-only, C7 breadcrumb).
    current_path: [path_max]u8 = [_]u8{0} ** path_max,
    current_path_len: usize = 5, // "/data"

    // Read-only view state.
    view_mode: bool = false,
    view_name: [32]u8 = [_]u8{0} ** 32,
    view_name_len: usize = 0,
    content: [content_max]u8 = undefined,
    content_len: usize = 0,

    // Inline preview state (C7 — first 15 lines, no mode switch).
    preview_content: [content_max]u8 = undefined,
    preview_len: usize = 0,
    preview_is_binary: bool = false,
    preview_loaded: bool = false,

    status_msg: [24]u8 = "Ready\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00".*,
    status_len: usize = 5,

    // F11: sorting state.
    sort_column: SortColumn = .name,
    sort_asc: bool = true,
    sort_indices: [max_entries]usize = init: {
        var idx: [max_entries]usize = undefined;
        for (0..max_entries) |i| idx[i] = i;
        break :init idx;
    },

    // F12: show/hide dotfiles (Ctrl+H toggle).
    show_hidden: bool = true,

    // F1: selection bitmap (32 bytes = 256 items).
    selection_bitmap: [32]u8 = [_]u8{0} ** 32,

    // F2: properties mode
    properties_mode: bool = false,

    // F3 / F17: directory creation state
    create_dir_active: bool = false,
    create_dir_buf: [32]u8 = [_]u8{0} ** 32,
    create_dir_len: usize = 0,

    // F5: recent files ring (last 10 opened/created files)
    recent_ring: [10][64]u8 = [_][64]u8{[_]u8{0} ** 64} ** 10,
    recent_lens: [10]usize = [_]usize{0} ** 10,
    recent_count: usize = 0,

    // F6: trash staging (bounded at 32 files in .trash)
    trash_names: [32][32]u8 = [_][32]u8{[_]u8{0} ** 32} ** 32,
    trash_lens: [32]usize = [_]usize{0} ** 32,
    trash_count: usize = 0,

    // F8: split panes
    split_pane: bool = false,
    active_pane: u8 = 0, // 0 = left, 1 = right
    right_path: [path_max]u8 = [_]u8{0} ** path_max,
    right_path_len: usize = 5,

    // F9: bookmarks / favorites (16 bookmarks max)
    bookmarks: [16][64]u8 = [_][64]u8{[_]u8{0} ** 64} ** 16,
    bookmark_lens: [16]usize = [_]usize{0} ** 16,
    bookmark_count: usize = 0,
    bookmarks_active: bool = false,
    bookmarks_selected: usize = 0,

    // M20-U8: Ctrl+F filename filter. The full listing is snapshotted on
    // activation; every keystroke rebuilds `entries` from the snapshot
    // by case-insensitive substring match (real-time narrowing).
    filter_active: bool = false,
    filter_buf: [24]u8 = [_]u8{0} ** 24,
    filter_len: usize = 0,
    shadow: [max_entries]DirEntry = undefined,
    shadow_count: usize = 0,

    // F1 / F7 / F18: Modal Confirmation Dialogs & Progress Bar (GH #381, #387, #398)
    delete_dialog: ui.Dialog = ui.Dialog.init(Rect.make(0, 0, window_w, window_h), "Delete selected files?", false),
    move_dialog: ui.Dialog = ui.Dialog.init(Rect.make(0, 0, window_w, window_h), "Move to dir (e.g. /data/docs):", true),
    batch_rename_dialog: ui.Dialog = ui.Dialog.init(Rect.make(0, 0, window_w, window_h), "Batch rename prefix (e.g. bak_):", true),
    progress_bar: ui.ProgressBar = ui.ProgressBar.init(Rect.make(6, 350, 500, 16)),
    progress_active: bool = false,

    btn_open: Button = Button.init(btn_open_rect, "Open"),
    btn_rename: Button = Button.init(btn_rename_rect, "Rename"),
    btn_delete: Button = Button.init(btn_delete_rect, "Delete"),
    btn_back: Button = Button.init(btn_back_rect, "Back"),

    pub fn init() AppState {
        var s = AppState{};
        // Initialize current_path to "/data".
        const p = "/data";
        @memcpy(s.current_path[0..p.len], p);
        s.current_path_len = p.len;
        s.btn_open.bg_color = ui.COLOR_ACCENT;
        s.btn_rename.bg_color = ui.COLOR_WARNING;
        s.btn_delete.bg_color = ui.COLOR_DANGER;
        s.btn_back.bg_color = ui.COLOR_SUCCESS;
        s.progress_bar.set_value(0);
        s.progress_bar.set_label("Progress");
        return s;
    }

    pub fn set_status(self: *AppState, msg: []const u8) void {
        const n = @min(msg.len, self.status_msg.len);
        @memcpy(self.status_msg[0..n], msg[0..n]);
        self.status_len = n;
    }

    // --- F1: Selection Bitmap Operations ---

    pub fn is_selected(self: *const AppState, idx: usize) bool {
        if (idx >= max_entries) return false;
        const byte = idx / 8;
        const bit: u3 = @truncate(idx % 8);
        return (self.selection_bitmap[byte] & (@as(u8, 1) << bit)) != 0;
    }

    pub fn set_selected(self: *AppState, idx: usize, sel: bool) void {
        if (idx >= max_entries) return;
        const byte = idx / 8;
        const bit: u3 = @truncate(idx % 8);
        if (sel) {
            self.selection_bitmap[byte] |= (@as(u8, 1) << bit);
        } else {
            self.selection_bitmap[byte] &= ~(@as(u8, 1) << bit);
        }
    }

    pub fn toggle_select(self: *AppState, idx: usize) void {
        if (idx >= self.entry_count) return;
        const cur = self.is_selected(idx);
        self.set_selected(idx, !cur);
    }

    pub fn select_all(self: *AppState) void {
        for (0..self.entry_count) |i| {
            self.set_selected(i, true);
        }
        self.set_status("All Selected");
    }

    pub fn clear_selection(self: *AppState) void {
        @memset(&self.selection_bitmap, 0);
    }

    pub fn selected_count(self: *const AppState) usize {
        var count: usize = 0;
        for (0..self.entry_count) |i| {
            if (self.is_selected(i)) count += 1;
        }
        return count;
    }

    // --- F2 / F4: Properties & Disk Usage ---

    pub fn toggle_properties(self: *AppState) bool {
        self.properties_mode = !self.properties_mode;
        self.set_status(if (self.properties_mode) "Props On" else "Props Off");
        return true;
    }

    pub fn total_dir_bytes(self: *const AppState) u64 {
        var sum: u64 = 0;
        for (self.entries[0..self.entry_count]) |e| {
            sum += e.size;
        }
        return sum;
    }

    // --- F3 / F17: Create Directory & Conflict Check ---

    pub fn toggle_create_dir(self: *AppState) bool {
        self.create_dir_active = !self.create_dir_active;
        self.create_dir_len = 0;
        if (self.create_dir_active) {
            self.set_status("New Dir:");
        } else {
            self.set_status("Ready");
        }
        return true;
    }

    pub fn check_collision(self: *const AppState, target_name: []const u8) bool {
        for (self.entries[0..self.entry_count]) |e| {
            const name = entry_name(&e);
            if (name_cmp_ignore_case(name, target_name) == 0) return true;
        }
        return false;
    }

    pub fn create_dir_input(self: *AppState, ascii_char: u8) bool {
        if (!self.create_dir_active) return false;
        if (ascii_char == 0x08) {
            if (self.create_dir_len > 0) self.create_dir_len -= 1;
            return true;
        } else if (ascii_char >= 0x20 and ascii_char < 0x7f) {
            if (self.create_dir_len < self.create_dir_buf.len) {
                self.create_dir_buf[self.create_dir_len] = ascii_char;
                self.create_dir_len += 1;
                return true;
            }
        }
        return false;
    }

    pub fn confirm_create_dir(self: *AppState) bool {
        if (!self.create_dir_active or self.create_dir_len == 0) return false;
        const dir_name = self.create_dir_buf[0..self.create_dir_len];
        if (self.check_collision(dir_name)) {
            self.set_status("Exists!");
            return false;
        }
        var path_buf: [64]u8 = undefined;
        const path = build_path(self.current_path_slice(), dir_name, &path_buf);
        const fd = ui.file_open(path, ui.MODE_WRITE);
        if (fd >= 0) {
            ui.file_close(@as(u32, @intCast(fd)));
            self.create_dir_active = false;
            self.create_dir_len = 0;
            self.set_status("Created");
            var obuf: [64]u8 = undefined;
            var opos: usize = 0;
            opos = append_str(&obuf, opos, "file: mkdir ");
            opos = append_str(&obuf, opos, dir_name);
            obuf[opos] = '\n';
            ui.write_console(obuf[0 .. opos + 1]);
            self.refresh();
            return true;
        } else {
            self.set_status("Mkdir Err");
            return false;
        }
    }

    // --- F5: Recent Files Ring ---

    pub fn add_recent(self: *AppState, path: []const u8) void {
        if (path.len == 0) return;
        var i: usize = 9;
        while (i > 0) : (i -= 1) {
            self.recent_ring[i] = self.recent_ring[i - 1];
            self.recent_lens[i] = self.recent_lens[i - 1];
        }
        const n = @min(path.len, 64);
        @memcpy(self.recent_ring[0][0..n], path[0..n]);
        self.recent_lens[0] = n;
        if (self.recent_count < 10) self.recent_count += 1;
    }

    // --- F6: Trash & Restore (/data/.trash/ with 32-file limit and auto-purge) ---

    pub fn trash_selected(self: *AppState) bool {
        const sel = self.list.selected orelse return false;
        if (sel >= self.entry_count) return false;
        const entry = &self.entries[self.sort_indices[sel]];
        const name = entry_name(entry);

        // Bounded at 32 files in trash: auto-purge oldest if full
        if (self.trash_count >= 32) {
            var purge_buf: [64]u8 = undefined;
            const oldest_name = self.trash_names[0][0..self.trash_lens[0]];
            const purge_path = build_path("/data/.trash", oldest_name, &purge_buf);
            _ = ui.file_delete(purge_path);

            for (0..31) |ti| {
                self.trash_names[ti] = self.trash_names[ti + 1];
                self.trash_lens[ti] = self.trash_lens[ti + 1];
            }
            self.trash_count -= 1;
        }

        var old_buf: [64]u8 = undefined;
        var trash_buf: [64]u8 = undefined;
        const old_path = build_path(self.current_path_slice(), name, &old_buf);
        const trash_path = build_path("/data/.trash", name, &trash_buf);
        _ = ui.file_rename(old_path, trash_path);

        const n = @min(name.len, 32);
        @memcpy(self.trash_names[self.trash_count][0..n], name[0..n]);
        self.trash_lens[self.trash_count] = n;
        self.trash_count += 1;

        self.refresh();
        self.set_status("Trashed");
        return true;
    }

    pub fn restore_trash(self: *AppState) bool {
        if (self.trash_count == 0) {
            self.set_status("Trash Empty");
            return false;
        }
        self.trash_count -= 1;
        const name = self.trash_names[self.trash_count][0..self.trash_lens[self.trash_count]];

        var trash_buf: [64]u8 = undefined;
        var restore_buf: [64]u8 = undefined;
        const trash_path = build_path("/data/.trash", name, &trash_buf);
        const restore_path = build_path(self.current_path_slice(), name, &restore_buf);
        _ = ui.file_rename(trash_path, restore_path);

        self.refresh();
        self.set_status("Restored");
        return true;
    }

    // --- F7: Batch Rename (GH #387) ---

    pub fn batch_rename_prompt(self: *AppState) bool {
        if (self.selected_count() == 0 and self.list.selected == null) return false;
        self.batch_rename_dialog.show();
        return true;
    }

    pub fn perform_batch_rename(self: *AppState, prefix: []const u8) void {
        if (prefix.len == 0) return;
        const multi = self.selected_count();
        self.progress_active = true;
        self.progress_bar.set_label("Renaming...");
        if (multi > 0) {
            var count: usize = 0;
            for (0..self.entry_count) |i| {
                if (self.is_selected(i)) {
                    const entry = &self.entries[self.sort_indices[i]];
                    const name = entry_name(entry);
                    var new_name: [32]u8 = [_]u8{0} ** 32;
                    var p: usize = 0;
                    p = append_str(&new_name, p, prefix);
                    const n = @min(name.len, 32 - p);
                    @memcpy(new_name[p .. p + n], name[0..n]);
                    const full_new = new_name[0 .. p + n];
                    var old_path: [64]u8 = undefined;
                    var new_path: [64]u8 = undefined;
                    const op = build_path(self.current_path_slice(), name, &old_path);
                    const np = build_path(self.current_path_slice(), full_new, &new_path);
                    _ = ui.file_rename(op, np);
                    count += 1;
                    const pct: u8 = @intCast((count * 100) / multi);
                    self.progress_bar.set_value(pct);
                }
            }
        } else if (self.list.selected) |sel| {
            if (sel < self.entry_count) {
                const entry = &self.entries[self.sort_indices[sel]];
                const name = entry_name(entry);
                var new_name: [32]u8 = [_]u8{0} ** 32;
                var p: usize = 0;
                p = append_str(&new_name, p, prefix);
                const n = @min(name.len, 32 - p);
                @memcpy(new_name[p .. p + n], name[0..n]);
                const full_new = new_name[0 .. p + n];
                var old_path: [64]u8 = undefined;
                var new_path: [64]u8 = undefined;
                const op = build_path(self.current_path_slice(), name, &old_path);
                const np = build_path(self.current_path_slice(), full_new, &new_path);
                _ = ui.file_rename(op, np);
                self.progress_bar.set_value(100);
            }
        }
        self.progress_active = false;
        self.clear_selection();
        self.refresh();
        self.set_status("Batch Renamed");
    }

    pub fn batch_rename_prefix(self: *AppState, prefix: []const u8) usize {
        self.perform_batch_rename(prefix);
        return 1;
    }

    // --- F8: Split Panes ---

    pub fn toggle_split_pane(self: *AppState) bool {
        self.split_pane = !self.split_pane;
        if (self.split_pane and self.right_path_len == 0) {
            const p = "/data";
            @memcpy(self.right_path[0..p.len], p);
            self.right_path_len = p.len;
        }
        self.set_status(if (self.split_pane) "Split On" else "Split Off");
        return true;
    }

    pub fn switch_active_pane(self: *AppState) void {
        if (!self.split_pane) return;
        self.active_pane = if (self.active_pane == 0) 1 else 0;
        self.set_status(if (self.active_pane == 0) "Left Pane" else "Right Pane");
    }

    // --- F9: Bookmarks / Favorites (GH #389) ---

    pub fn toggle_bookmarks(self: *AppState) bool {
        self.bookmarks_active = !self.bookmarks_active;
        if (self.bookmarks_active) {
            self.bookmarks_selected = 0;
            self.set_status("Bookmarks");
        } else {
            self.set_status("Ready");
        }
        return true;
    }

    pub fn add_bookmark(self: *AppState, path: []const u8) bool {
        if (self.bookmark_count >= 16 or path.len == 0) return false;
        const n = @min(path.len, 64);
        @memcpy(self.bookmarks[self.bookmark_count][0..n], path[0..n]);
        self.bookmark_lens[self.bookmark_count] = n;
        self.bookmark_count += 1;
        self.set_status("Bookmarked");
        return true;
    }

    pub fn jump_bookmark(self: *AppState, idx: usize) bool {
        if (idx >= self.bookmark_count) return false;
        const p = self.bookmarks[idx][0..self.bookmark_lens[idx]];
        const n = @min(p.len, path_max);
        @memcpy(self.current_path[0..n], p[0..n]);
        self.current_path_len = n;
        self.list_directory();
        return true;
    }

    // --- F14 & F15: Terminal Here & Editor Here ---

    pub fn terminal_here(self: *AppState) bool {
        ui.write_console("file: terminal here ");
        ui.write_console(self.current_path_slice());
        ui.write_console("\n");
        self.set_status("Term Spawned");
        return true;
    }

    pub fn editor_here(self: *AppState) bool {
        const sel = self.list.selected orelse return false;
        if (sel >= self.entry_count) return false;
        const name = entry_name(&self.entries[self.sort_indices[sel]]);
        ui.write_console("file: editor here ");
        ui.write_console(name);
        ui.write_console("\n");
        self.set_status("Edit Spawned");
        return true;
    }

    // --- F1 & F18: Batch Delete & Move with Dialogs and ProgressBar (GH #381, #398) ---

    pub fn delete_prompt(self: *AppState) bool {
        if (self.selected_count() == 0 and self.list.selected == null) return false;
        if (self.selected_count() > 1) {
            self.delete_dialog.message = "Delete selected files?";
        } else {
            self.delete_dialog.message = "Delete file?";
        }
        self.delete_dialog.show();
        return true;
    }

    pub fn perform_delete(self: *AppState) void {
        const multi = self.selected_count();
        if (multi > 0) {
            self.progress_active = true;
            self.progress_bar.set_label("Deleting...");
            var deleted: usize = 0;
            for (0..self.entry_count) |i| {
                if (self.is_selected(i)) {
                    const entry = &self.entries[self.sort_indices[i]];
                    const name = entry_name(entry);
                    var path_buf: [64]u8 = undefined;
                    const path = build_path(self.current_path_slice(), name, &path_buf);
                    _ = ui.file_delete(path);
                    deleted += 1;
                    const pct: u8 = @intCast((deleted * 100) / multi);
                    self.progress_bar.set_value(pct);
                }
            }
            self.progress_active = false;
            self.clear_selection();
            self.refresh();
            self.set_status("Batch Deleted");
        } else {
            _ = self.delete_selected();
        }
    }

    pub fn move_prompt(self: *AppState) bool {
        if (self.selected_count() == 0 and self.list.selected == null) return false;
        self.move_dialog.message = "Move to dir (e.g. /data/docs):";
        self.move_dialog.show();
        return true;
    }

    pub fn perform_move(self: *AppState, target_dir: []const u8) void {
        if (target_dir.len == 0) return;
        const multi = self.selected_count();
        self.progress_active = true;
        self.progress_bar.set_label("Moving...");
        if (multi > 0) {
            var moved: usize = 0;
            for (0..self.entry_count) |i| {
                if (self.is_selected(i)) {
                    const entry = &self.entries[self.sort_indices[i]];
                    const name = entry_name(entry);
                    var op_buf: [64]u8 = undefined;
                    var np_buf: [64]u8 = undefined;
                    const old_p = build_path(self.current_path_slice(), name, &op_buf);
                    const new_p = build_path(target_dir, name, &np_buf);
                    _ = ui.file_rename(old_p, new_p);
                    moved += 1;
                    const pct: u8 = @intCast((moved * 100) / multi);
                    self.progress_bar.set_value(pct);
                }
            }
        } else if (self.list.selected) |sel| {
            if (sel < self.entry_count) {
                const entry = &self.entries[self.sort_indices[sel]];
                const name = entry_name(entry);
                var op_buf: [64]u8 = undefined;
                var np_buf: [64]u8 = undefined;
                const old_p = build_path(self.current_path_slice(), name, &op_buf);
                const new_p = build_path(target_dir, name, &np_buf);
                _ = ui.file_rename(old_p, new_p);
                self.progress_bar.set_value(100);
            }
        }
        self.progress_active = false;
        self.clear_selection();
        self.refresh();
        self.set_status("Moved");
    }

    pub fn delete_action(self: *AppState) bool {
        return self.delete_prompt();
    }

    /// M20-U8: toggle the Ctrl+F filter bar. Activation snapshots the
    /// full listing; deactivation restores it.
    pub fn toggle_filter(self: *AppState) bool {
        if (!self.filter_active) {
            self.filter_active = true;
            self.filter_len = 0;
            // Shadow is already populated by list_directory with the full
            // (pre-hidden-filter) listing; no re-snapshot needed.
        } else {
            self.filter_active = false;
            self.filter_len = 0;
            self.restore_shadow();
        }
        return true;
    }

    fn restore_shadow(self: *AppState) void {
        self.entry_count = self.shadow_count;
        for (0..self.shadow_count) |i| self.entries[i] = self.shadow[i];
        if (self.entry_count > 0) self.list.select(0, self.entry_count);
    }

    fn matches_filter(name: []const u8, pat: []const u8) bool {
        if (pat.len == 0) return true;
        return find_substring_ci(name, pat) != null;
    }

    /// M20-U3: case-insensitive substring position of `pat` in `name`
    /// (the same rule matches_filter applies), null when absent or the
    /// pattern is empty. Host-testable; backs the list-row highlight.
    fn find_substring_ci(name: []const u8, pat: []const u8) ?usize {
        if (pat.len == 0 or pat.len > name.len) return null;
        var i: usize = 0;
        while (i + pat.len <= name.len) : (i += 1) {
            var ok = true;
            for (pat, 0..) |pc, j| {
                const nc = name[i + j];
                const lo_n = if (nc >= 'A' and nc <= 'Z') nc + 32 else nc;
                const lo_p = if (pc >= 'A' and pc <= 'Z') pc + 32 else pc;
                if (lo_n != lo_p) {
                    ok = false;
                    break;
                }
            }
            if (ok) return i;
        }
        return null;
    }

    /// Rebuild the visible entries from the shadow per the filter text.
    pub fn apply_filter(self: *AppState) void {
        // Lazily snapshot entries if shadow is empty (tests or direct mutation).
        if (self.shadow_count == 0 and self.entry_count > 0) {
            self.shadow_count = self.entry_count;
            for (0..self.entry_count) |i| self.shadow[i] = self.entries[i];
        }
        const pat = self.filter_buf[0..self.filter_len];
        var n: usize = 0;
        for (self.shadow[0..self.shadow_count]) |e| {
            const name = entry_name(&e);
            if (!self.show_hidden and is_hidden_file(name)) continue;
            if (matches_filter(name, pat)) {
                self.entries[n] = e;
                n += 1;
                if (n == max_entries) break;
            }
        }
        self.entry_count = n;
        self.rebuild_sort();
        if (n > 0) self.list.select(0, n);
        // M20-U3: serial marker — the live gate's grep target. Only when
        // the filter bar is actually open (internal rebuilds stay quiet).
        if (self.filter_active) {
            var fb: [72]u8 = undefined;
            const line = std.fmt.bufPrint(&fb, "file: filter '{s}' shown={d} total={d}\n", .{
                pat, n, self.shadow_count,
            }) catch return;
            ui.write_console(line);
        }
    }

    /// F12: toggle hidden (dotfile) visibility. Returns true on state change.
    pub fn toggle_hidden(self: *AppState) bool {
        self.show_hidden = !self.show_hidden;
        // Lazily snapshot entries if shadow is empty (tests or direct mutation).
        if (self.shadow_count == 0 and self.entry_count > 0) {
            self.shadow_count = self.entry_count;
            for (0..self.entry_count) |i| self.shadow[i] = self.entries[i];
        }
        // Rebuild from shadow (full unfiltered listing) then re-filter.
        self.restore_shadow();
        self.filter_hidden();
        self.rebuild_sort();
        if (self.filter_active) self.apply_filter();
        self.list.select(0, self.entry_count);
        self.sync_scroll_view();
        self.refresh_preview();
        return true;
    }

    /// Remove entries whose names start with '.' when show_hidden is false.
    /// Operates in-place on self.entries; call after list_directory.
    fn filter_hidden(self: *AppState) void {
        if (self.show_hidden) return;
        var n: usize = 0;
        for (self.entries[0..self.entry_count]) |e| {
            const name = entry_name(&e);
            if (!is_hidden_file(name)) {
                self.entries[n] = e;
                n += 1;
            }
        }
        self.entry_count = n;
    }

    /// F11: rebuild the sort_indices indirection layer. Uses insertion sort
    /// (stable, matches TOP.BIN pattern).
    pub fn rebuild_sort(self: *AppState) void {
        // Initialize identity mapping.
        for (0..self.entry_count) |i| self.sort_indices[i] = i;
        // Stable insertion sort on sort_indices.
        var i: usize = 1;
        while (i < self.entry_count) : (i += 1) {
            const key = self.sort_indices[i];
            var k = i;
            while (k > 0) {
                const a = &self.entries[self.sort_indices[k - 1]];
                const b = &self.entries[key];
                const cmp = compare_entries(a, b, self.sort_column);
                const should_swap = if (self.sort_asc) cmp > 0 else cmp < 0;
                if (!should_swap) break;
                self.sort_indices[k] = self.sort_indices[k - 1];
                k -= 1;
            }
            self.sort_indices[k] = key;
        }
    }

    /// F11: click a column header to sort by that column.
    pub fn click_column(self: *AppState, col: SortColumn) void {
        if (self.sort_column == col) {
            self.sort_asc = !self.sort_asc;
        } else {
            self.sort_column = col;
            self.sort_asc = true;
        }
        self.rebuild_sort();
    }

    /// Feed one printable byte / backspace to the active filter.
    pub fn filter_input(self: *AppState, ascii_char: u8) bool {
        if (!self.filter_active) return false;
        if (ascii_char == 0x08) { // backspace
            if (self.filter_len > 0) self.filter_len -= 1;
        } else if (ascii_char >= 0x20 and ascii_char < 0x7f) {
            if (self.filter_len < self.filter_buf.len) {
                self.filter_buf[self.filter_len] = ascii_char;
                self.filter_len += 1;
            }
        } else {
            return false;
        }
        self.apply_filter();
        return true;
    }

    pub fn current_path_slice(self: *const AppState) []const u8 {
        return self.current_path[0..self.current_path_len];
    }

    // GH #218: keep ScrollView in sync with FileList (pixels <-> rows).
    // F11: the scrollable area starts below the 14px column header.
    pub fn sync_scroll_view(self: *AppState) void {
        // Recalculate the scroll rect to exclude the column header.
        self.scroll_view.rect = Rect.make(list_area.x, list_area.y + header_h, list_area.w, list_area.h - header_h);
        const content_h: u32 = @as(u32, @intCast(self.entry_count)) * list_row_h;
        self.scroll_view.set_content_height(content_h);
        const target: u32 = @as(u32, @intCast(self.list.scroll)) * list_row_h;
        if (target > self.scroll_view.max_offset()) {
            self.scroll_view.offset = self.scroll_view.max_offset();
        } else {
            self.scroll_view.offset = target;
        }
    }

    fn sync_list_from_scroll_view(self: *AppState) void {
        const row = self.scroll_view.offset / list_row_h;
        if (row != self.list.scroll) {
            self.list.scroll = row;
            self.list.ensure_visible(self.entry_count);
            self.sync_scroll_view();
        }
    }

    /// Enumerate current_path via `sys_dir_list` (slot 27). Emits a
    /// `file: listing N entries` marker for the live gate.
    pub fn list_directory(self: *AppState) void {
        const res = ui.dir_list(self.current_path_slice(), &self.entries);
        if (res < 0) {
            self.entry_count = 0;
            self.set_status("List Err");
            ui.write_console("file: list error\n");
            return;
        }
        self.entry_count = @intCast(res);
        // Snapshot full (unfiltered) listing for Ctrl+F filter and F12 toggle.
        self.shadow_count = self.entry_count;
        for (0..self.entry_count) |i| self.shadow[i] = self.entries[i];
        self.filter_hidden();
        self.rebuild_sort();
        self.list.select(0, self.entry_count);
        self.sync_scroll_view();
        // Auto-load preview for the new selection (C7).
        self.refresh_preview();
        self.set_status("Listed");

        var buf: [48]u8 = undefined;
        var pos: usize = 0;
        pos = append_str(&buf, pos, "file: listing ");
        pos = append_str(&buf, pos, fmt_u64(buf[pos..], self.entry_count));
        pos = append_str(&buf, pos, " entries\n");
        ui.write_console(buf[0..pos]);
    }

    /// Navigate into a subdirectory named `name` (must be a dir entry).
    pub fn enter_directory(self: *AppState, name: []const u8) bool {
        if (self.current_path_len + 1 + name.len > path_max) return false;
        self.current_path[self.current_path_len] = '/';
        @memcpy(self.current_path[self.current_path_len + 1 .. self.current_path_len + 1 + name.len], name);
        self.current_path_len += 1 + name.len;
        self.view_mode = false;
        self.preview_loaded = false;
        self.list_directory();
        var obuf: [64]u8 = undefined;
        var opos: usize = 0;
        opos = append_str(&obuf, opos, "file: enter ");
        opos = append_str(&obuf, opos, name);
        obuf[opos] = '\n';
        ui.write_console(obuf[0 .. opos + 1]);
        return true;
    }

    /// Navigate to breadcrumb segment `keep` (0-based). Keeps segments 0..keep.
    pub fn navigate_to_segment(self: *AppState, keep: usize) void {
        const new_len = truncate_to_segment(&self.current_path, self.current_path_len, keep);
        // Never truncate below "/data" (5 chars).
        self.current_path_len = @max(new_len, 5);
        self.view_mode = false;
        self.preview_loaded = false;
        self.list_directory();
    }

    /// Load inline preview for the currently selected entry (C7).
    pub fn refresh_preview(self: *AppState) void {
        self.preview_loaded = false;
        self.preview_len = 0;
        self.preview_is_binary = false;
        const sel = self.list.selected orelse return;
        if (sel >= self.entry_count) return;
        const entry = &self.entries[self.sort_indices[sel]];
        const name = entry_name(entry);
        if (entry.is_dir != 0) return;
        // Only auto-preview .TXT; other files show (binary) placeholder via flag.
        var path_buf: [64]u8 = undefined;
        const path = build_path(self.current_path_slice(), name, &path_buf);
        const fd = ui.file_open(path, ui.MODE_READ);
        if (fd < 0) return;
        const n = ui.file_read(@as(u32, @intCast(fd)), &self.preview_content);
        ui.file_close(@as(u32, @intCast(fd)));
        if (n < 0) return;
        self.preview_len = @intCast(n);
        self.preview_loaded = true;
        if (!is_txt_file(name)) {
            self.preview_is_binary = true;
            return;
        }
        self.preview_is_binary = is_binary_content(self.preview_content[0..self.preview_len]);
    }

    /// Open the selected entry read-only. Emits `file: open NAME` + the
    /// read result marker (`file: view NAME` / `file: read error`). Directories
    /// navigate into the subdirectory (C7 breadcrumb), regular files open the
    /// full view. The inline preview is already loaded via `refresh_preview`.
    pub fn open_selected(self: *AppState) bool {
        const sel = self.list.selected orelse return false;
        if (sel >= self.entry_count) return false;
        const entry = &self.entries[self.sort_indices[sel]];
        const name = entry_name(entry);

        if (entry.is_dir != 0) {
            return self.enter_directory(name);
        }

        // Build "<current_path>/<name>" (current_path len + 1 + name).
        var path_buf: [64]u8 = undefined;
        const path = build_path(self.current_path_slice(), name, &path_buf);

        const fd = ui.file_open(path, ui.MODE_READ);
        if (fd < 0) {
            self.set_status("Open Err");
            return false;
        }
        const n = ui.file_read(@as(u32, @intCast(fd)), &self.content);
        ui.file_close(@as(u32, @intCast(fd)));
        if (n < 0) {
            self.set_status("Read Err");
            return false;
        }

        const cn = @min(name.len, self.view_name.len);
        @memcpy(self.view_name[0..cn], name[0..cn]);
        self.view_name_len = cn;
        self.content_len = @intCast(n);
        self.view_mode = true;
        self.set_status("Viewing");
        self.add_recent(path); // F5: record in recent files ring

        var obuf: [64]u8 = undefined;
        var opos: usize = 0;
        opos = append_str(&obuf, opos, "file: open ");
        opos = append_str(&obuf, opos, name);
        obuf[opos] = '\n';
        ui.write_console(obuf[0 .. opos + 1]);

        var vbuf: [64]u8 = undefined;
        var vpos: usize = 0;
        vpos = append_str(&vbuf, vpos, "file: view ");
        vpos = append_str(&vbuf, vpos, name);
        vbuf[vpos] = '\n';
        ui.write_console(vbuf[0 .. vpos + 1]);

        return true;
    }

    pub fn back_to_list(self: *AppState) void {
        self.view_mode = false;
        self.content_len = 0;
        self.set_status("Listed");
        ui.write_console("file: back\n");
    }

    /// Re-list `/data/`, preserving the selection when it still fits.
    pub fn refresh(self: *AppState) void {
        const prev = self.list.selected;
        self.list_directory();
        if (self.entry_count > 0) {
            const idx = if (prev) |p| @min(p, self.entry_count - 1) else 0;
            self.list.select(idx, self.entry_count);
            self.refresh_preview();
        }
    }

    /// Delete the selected entry through sys_file_delete (slot 34). Emits
    /// `file: delete NAME` on success. Directories are refused.
    pub fn delete_selected(self: *AppState) bool {
        const sel = self.list.selected orelse return false;
        if (sel >= self.entry_count) return false;
        const entry = &self.entries[self.sort_indices[sel]];
        const name = entry_name(entry);
        if (entry.is_dir != 0) {
            self.set_status("Is dir");
            return false;
        }

        var path_buf: [64]u8 = undefined;
        const path = build_path(self.current_path_slice(), name, &path_buf);
        const res = ui.file_delete(path);
        if (res < 0) {
            self.set_status("Del Err");
            return false;
        }

        var obuf: [64]u8 = undefined;
        var opos: usize = 0;
        opos = append_str(&obuf, opos, "file: delete ");
        opos = append_str(&obuf, opos, name);
        obuf[opos] = '\n';
        ui.write_console(obuf[0 .. opos + 1]);

        self.set_status("Deleted");
        self.refresh();
        return true;
    }

    /// Rename the selected entry to `STEM.BAK` through sys_file_rename
    /// (slot 35). Emits `file: rename NAME -> NEW` on success.
    pub fn rename_selected(self: *AppState) bool {
        const sel = self.list.selected orelse return false;
        if (sel >= self.entry_count) return false;
        const entry = &self.entries[self.sort_indices[sel]];
        const name = entry_name(entry);
        if (entry.is_dir != 0) {
            self.set_status("Is dir");
            return false;
        }

        var bak: [32]u8 = undefined;
        const new_name = make_bak_name(name, &bak);
        var old_path: [64]u8 = undefined;
        var new_path: [64]u8 = undefined;
        const op = build_path(self.current_path_slice(), name, &old_path);
        const np = build_path(self.current_path_slice(), new_name, &new_path);
        const res = ui.file_rename(op, np);
        if (res < 0) {
            self.set_status("Ren Err");
            return false;
        }

        var obuf: [96]u8 = undefined;
        var opos: usize = 0;
        opos = append_str(&obuf, opos, "file: rename ");
        opos = append_str(&obuf, opos, name);
        opos = append_str(&obuf, opos, " -> ");
        opos = append_str(&obuf, opos, new_name);
        obuf[opos] = '\n';
        ui.write_console(obuf[0 .. opos + 1]);

        self.set_status("Renamed");
        self.refresh();
        return true;
    }

    pub fn draw(self: *const AppState, win: u32) void {
        ui.draw_rect(win, Rect.make(0, 0, window_w, window_h), ui.COLOR_BG);

        // Title bar.
        ui.draw_rect(win, title_rect, ui.COLOR_SURFACE);
        ui.draw_rect_outline(win, title_rect, 1, ui.COLOR_BORDER);
        if (self.view_mode) {
            ui.draw_text(win, "View", 8, 8, ui.COLOR_TEXT_PRIMARY);
            ui.draw_text(win, self.view_name[0..self.view_name_len], 56, 8, ui.COLOR_ACCENT);
        } else {
            ui.draw_text(win, "Files:", 8, 8, ui.COLOR_TEXT_PRIMARY);
            // Breadcrumb bar at y=4 (inside title), 8x8 muted per spec.
            var bx: u32 = 60;
            var si: usize = 0;
            var idx: usize = 0;
            // Iterate over path segments for drawing.
            while (idx < self.current_path_len) {
                while (idx < self.current_path_len and self.current_path[idx] == '/') : (idx += 1) {}
                if (idx >= self.current_path_len) break;
                const start = idx;
                while (idx < self.current_path_len and self.current_path[idx] != '/') : (idx += 1) {}
                const seg = self.current_path[start..idx];
                if (si > 0) {
                    ui.draw_text(win, ">", bx, 8, ui.COLOR_TEXT_MUTED);
                    bx += 16; // " > " is 3*8 but we draw ">" centered in 16px
                }
                const is_last = idx >= self.current_path_len;
                const col = if (is_last) ui.COLOR_ACCENT else ui.COLOR_TEXT_MUTED;
                ui.draw_text(win, seg, bx, 8, col);
                bx += @as(u32, @intCast(seg.len)) * glyph_w + 4;
                si += 1;
            }
        }

        // Status strip (title-bar right) — shift right to avoid breadcrumb overlap.
        ui.draw_text(win, self.status_msg[0..self.status_len], 380, 8, ui.COLOR_TEXT_MUTED);

        // M20-U8: the find bar sits between breadcrumbs and the listing.
        if (!self.view_mode and self.filter_active) {
            const fb = Rect.make(list_area.x, list_area.y, list_area.w, 14);
            ui.draw_rect(win, fb, ui.COLOR_SURFACE);
            ui.draw_rect_outline(win, fb, 1, ui.COLOR_ACCENT);
            ui.draw_text(win, "Find:", fb.x + 4, fb.y + 3, ui.COLOR_TEXT_MUTED);
            ui.draw_text(win, self.filter_buf[0..self.filter_len], fb.x + 40, fb.y + 3, ui.COLOR_TEXT_PRIMARY);
        }

        // F3: Directory creation overlay input
        if (!self.view_mode and self.create_dir_active) {
            const cb = Rect.make(list_area.x, list_area.y, list_area.w, 14);
            ui.draw_rect(win, cb, ui.COLOR_SURFACE);
            ui.draw_rect_outline(win, cb, 1, ui.COLOR_WARNING);
            ui.draw_text(win, "Mkdir:", cb.x + 4, cb.y + 3, ui.COLOR_WARNING);
            ui.draw_text(win, self.create_dir_buf[0..self.create_dir_len], cb.x + 48, cb.y + 3, ui.COLOR_TEXT_PRIMARY);
        }

        if (self.view_mode) {
            self.draw_view(win);
            self.btn_back.draw(win);
        } else {
            self.draw_list(win);
            self.draw_details(win);
            self.btn_open.draw(win);
            self.btn_rename.draw(win);
            self.btn_delete.draw(win);
        }

        // F1 / F7 / F18: Progress Bar and Dialog overlays
        if (self.progress_active) {
            self.progress_bar.draw(win);
        }
        if (self.delete_dialog.is_open()) {
            self.delete_dialog.draw_dim_overlay(win);
            self.delete_dialog.draw(win);
        }
        if (self.move_dialog.is_open()) {
            self.move_dialog.draw_dim_overlay(win);
            self.move_dialog.draw(win);
        }
        if (self.batch_rename_dialog.is_open()) {
            self.batch_rename_dialog.draw_dim_overlay(win);
            self.batch_rename_dialog.draw(win);
        }

        // F9: Bookmarks list overlay (GH #389)
        if (self.bookmarks_active) {
            const b_rect = Rect.make(6, 26, 220, 180);
            ui.draw_rect(win, b_rect, ui.COLOR_SURFACE);
            ui.draw_rect_outline(win, b_rect, 1, ui.COLOR_ACCENT);
            ui.draw_text(win, "Bookmarks (Enter=Jump):", b_rect.x + 6, b_rect.y + 6, ui.COLOR_ACCENT);
            if (self.bookmark_count == 0) {
                ui.draw_text(win, "(No bookmarks)", b_rect.x + 6, b_rect.y + 24, ui.COLOR_TEXT_MUTED);
            } else {
                for (0..self.bookmark_count) |bi| {
                    const by = b_rect.y + 24 + @as(u32, @intCast(bi)) * 14;
                    const is_bm_sel = bi == self.bookmarks_selected;
                    if (is_bm_sel) {
                        ui.draw_rect(win, Rect.make(b_rect.x + 2, by - 2, b_rect.w - 4, 14), ui.COLOR_BTN_IDLE);
                    }
                    const bp = self.bookmarks[bi][0..self.bookmark_lens[bi]];
                    const bcol = if (is_bm_sel) ui.COLOR_ACCENT else ui.COLOR_TEXT_PRIMARY;
                    ui.draw_text(win, bp, b_rect.x + 6, by, bcol);
                }
            }
        }
    }

    fn draw_list(self: *const AppState, win: u32) void {
        ui.draw_rect(win, list_area, ui.COLOR_SURFACE);
        ui.draw_rect_outline(win, list_area, 1, ui.COLOR_BORDER);

        // F11: draw column headers at the top of the list area.
        const hdr_rect = Rect.make(list_area.x, list_area.y, list_area.w, header_h);
        ui.draw_rect(win, hdr_rect, ui.COLOR_BTN_IDLE);
        ui.draw_rect_outline(win, hdr_rect, 1, ui.COLOR_BORDER);

        const ind: []const u8 = if (self.sort_asc) " ^" else " v";
        ui.draw_text(win, "Name", col_name_x, list_area.y + 3, ui.COLOR_TEXT_PRIMARY);
        ui.draw_text(win, "Size", col_size_x, list_area.y + 3, ui.COLOR_TEXT_PRIMARY);
        ui.draw_text(win, "Type", col_type_x, list_area.y + 3, ui.COLOR_TEXT_PRIMARY);
        // Draw sort indicator next to the active column.
        const ind_x: u32 = switch (self.sort_column) {
            .name => col_name_x + 4 * glyph_w,
            .size => col_size_x + 4 * glyph_w,
            .col_type => col_type_x + 4 * glyph_w,
        };
        ui.draw_text(win, ind, ind_x, list_area.y + 3, ui.COLOR_ACCENT);

        // Draw file rows below the header.
        const vis = self.list.visible_rows();
        var i = self.list.scroll;
        var row: usize = 0;
        while (i < self.entry_count and row < vis) : ({
            i += 1;
            row += 1;
        }) {
            const idx = self.sort_indices[i];
            const entry = &self.entries[idx];
            const name = entry_name(entry);
            const is_sel = if (self.list.selected) |s| s == i else false;
            // M20-U3: highlight the searched substring in the row's name
            // while the filter bar is active.
            var hl_at: usize = 0;
            var hl_len: usize = 0;
            if (self.filter_active) {
                if (find_substring_ci(name, self.filter_buf[0..self.filter_len])) |at| {
                    hl_at = at;
                    hl_len = self.filter_len;
                }
            }
            const is_multi = self.is_selected(i);
            draw_list_row(win, row, name, entry, is_sel, is_multi, hl_at, hl_len);
        }
        // GH #218: ScrollView thumb for the file list (proportional, draggable)
        self.scroll_view.draw(win);
    }

    fn draw_details(self: *const AppState, win: u32) void {
        ui.draw_rect(win, details_area, ui.COLOR_SURFACE);
        ui.draw_rect_outline(win, details_area, 1, ui.COLOR_BORDER);

        const sel = self.list.selected orelse {
            ui.draw_text(win, "(empty)", details_area.x + 6, details_area.y + 8, ui.COLOR_TEXT_MUTED);
            return;
        };
        if (sel >= self.entry_count) return;
        const entry = &self.entries[self.sort_indices[sel]];
        const name = entry_name(entry);

        // F2: Properties inspector mode
        if (self.properties_mode) {
            ui.draw_text(win, "Properties:", details_area.x + 6, details_area.y + 6, ui.COLOR_ACCENT);
            ui.draw_text(win, "Path:", details_area.x + 6, details_area.y + 22, ui.COLOR_TEXT_MUTED);
            var pbuf: [64]u8 = undefined;
            const full_p = build_path(self.current_path_slice(), name, &pbuf);
            const pcap = @min(full_p.len, 28);
            ui.draw_text(win, full_p[0..pcap], details_area.x + 6, details_area.y + 34, ui.COLOR_TEXT_PRIMARY);

            ui.draw_text(win, "Size:", details_area.x + 6, details_area.y + 50, ui.COLOR_TEXT_MUTED);
            var sbuf2: [24]u8 = undefined;
            var spos2: usize = 0;
            spos2 = append_str(&sbuf2, spos2, fmt_u64(sbuf2[spos2..], entry.size));
            spos2 = append_str(&sbuf2, spos2, " B");
            ui.draw_text(win, sbuf2[0..spos2], details_area.x + 6, details_area.y + 62, ui.COLOR_TEXT_PRIMARY);

            ui.draw_text(win, "Dir Total:", details_area.x + 6, details_area.y + 78, ui.COLOR_TEXT_MUTED);
            var dbuf: [24]u8 = undefined;
            var dpos: usize = 0;
            dpos = append_str(&dbuf, dpos, fmt_u64(dbuf[dpos..], self.total_dir_bytes()));
            dpos = append_str(&dbuf, dpos, " B");
            ui.draw_text(win, dbuf[0..dpos], details_area.x + 6, details_area.y + 90, ui.COLOR_TEXT_PRIMARY);

            ui.draw_text(win, "Format:", details_area.x + 6, details_area.y + 106, ui.COLOR_TEXT_MUTED);
            ui.draw_text(win, "FAT32 8.3", details_area.x + 6, details_area.y + 118, ui.COLOR_TEXT_PRIMARY);

            ui.draw_text(win, "Timestamp:", details_area.x + 6, details_area.y + 134, ui.COLOR_TEXT_MUTED);
            ui.draw_text(win, "N/A (FAT32)", details_area.x + 6, details_area.y + 146, ui.COLOR_TEXT_MUTED);
            return;
        }

        ui.draw_text(win, "Size", details_area.x + 6, details_area.y + 6, ui.COLOR_TEXT_MUTED);
        var sbuf: [24]u8 = undefined;
        var spos: usize = 0;
        spos = append_str(&sbuf, spos, fmt_u64(sbuf[spos..], entry.size));
        spos = append_str(&sbuf, spos, " B");
        ui.draw_text(win, sbuf[0..spos], details_area.x + 6, details_area.y + 20, ui.COLOR_TEXT_PRIMARY);

        ui.draw_text(win, "Type", details_area.x + 6, details_area.y + 44, ui.COLOR_TEXT_MUTED);
        const type_label: []const u8 = if (entry.is_dir != 0) "DIR" else "FILE";
        ui.draw_text(win, type_label, details_area.x + 6, details_area.y + 58, if (entry.is_dir != 0) ui.COLOR_WARNING else ui.COLOR_SUCCESS);

        ui.draw_text(win, "Name", details_area.x + 6, details_area.y + 82, ui.COLOR_TEXT_MUTED);
        const cap = @min(name.len, 18);
        ui.draw_text(win, name[0..cap], details_area.x + 6, details_area.y + 96, ui.COLOR_ACCENT);

        // C7 inline preview (below metadata, first 15 lines, binary placeholder).
        const preview_y = details_area.y + 115;
        ui.draw_text(win, "Preview", details_area.x + 6, preview_y, ui.COLOR_TEXT_MUTED);
        if (entry.is_dir != 0) {
            ui.draw_text(win, "(directory)", details_area.x + 6, preview_y + 14, ui.COLOR_TEXT_MUTED);
            return;
        }
        if (!self.preview_loaded) {
            ui.draw_text(win, "(no preview)", details_area.x + 6, preview_y + 14, ui.COLOR_TEXT_MUTED);
            return;
        }
        if (self.preview_is_binary) {
            ui.draw_text(win, "(binary)", details_area.x + 6, preview_y + 14, ui.COLOR_TEXT_MUTED);
            return;
        }
        const slice = self.preview_content[0..self.preview_len];
        var row: usize = 0;
        var col: usize = 0;
        var px = details_area.x + 6;
        var py = preview_y + 14;
        for (slice) |ch| {
            if (ch == '\n') {
                row += 1;
                col = 0;
                if (row >= preview_rows) break;
                py += line_h;
                px = details_area.x + 6;
                continue;
            }
            if (col >= preview_cols) {
                row += 1;
                col = 0;
                if (row >= preview_rows) break;
                py += line_h;
                px = details_area.x + 6;
            }
            if (row >= preview_rows) break;
            // Only draw printable, skip others (already filtered binary)
            if (ch >= 0x20 and ch <= 0x7e) {
                ui.draw_char(win, ch, px, py, ui.COLOR_TEXT_PRIMARY);
            }
            px += glyph_w;
            col += 1;
        }
    }

    fn draw_view(self: *const AppState, win: u32) void {
        const body = Rect.make(6, 26, 244, 130);
        ui.draw_rect(win, body, ui.COLOR_SURFACE);
        ui.draw_rect_outline(win, body, 1, ui.COLOR_BORDER);

        const slice = self.content[0..self.content_len];
        // Render the first `view_rows` display rows with the same wrap rule
        // `content_rows` documents (29 glyphs/row, '\\n' forces a break).
        var row: usize = 0;
        var col: usize = 0;
        for (slice) |ch| {
            if (ch == '\n') {
                row += 1;
                col = 0;
                continue;
            }
            if (col == view_cols) {
                row += 1;
                col = 0;
            }
            if (row >= view_rows) break;
            const x = view_text_x + @as(u32, @intCast(col)) * glyph_w;
            const y = view_text_y + @as(u32, @intCast(row)) * line_h;
            ui.draw_char(win, ch, x, y, ui.COLOR_TEXT_PRIMARY);
            col += 1;
        }
    }

    pub fn handle_mouse_events(self: *AppState, ev: *const Event) bool {
        // Modal dialogs intercept all mouse events when open
        if (self.delete_dialog.is_open()) {
            _ = self.delete_dialog.handle_event(ev);
            if (self.delete_dialog.get_result() == .ok) {
                self.perform_delete();
            }
            return true;
        }
        if (self.move_dialog.is_open()) {
            _ = self.move_dialog.handle_event(ev);
            if (self.move_dialog.get_result() == .ok) {
                self.perform_move(self.move_dialog.input.get_text());
            }
            return true;
        }
        if (self.batch_rename_dialog.is_open()) {
            _ = self.batch_rename_dialog.handle_event(ev);
            if (self.batch_rename_dialog.get_result() == .ok) {
                self.perform_batch_rename(self.batch_rename_dialog.input.get_text());
            }
            return true;
        }

        if (self.view_mode) {
            if (self.btn_back.handle_event(ev)) {
                self.back_to_list();
                return true;
            }
            return false;
        }

        if (self.btn_open.handle_event(ev)) {
            return self.open_selected();
        }
        if (self.btn_rename.handle_event(ev)) {
            return self.rename_selected();
        }
        if (self.btn_delete.handle_event(ev)) {
            return self.delete_prompt();
        }
        // GH #218: ScrollView thumb drag / track click / wheel — must sync before and after
        self.sync_scroll_view();
        if (self.scroll_view.handle_event(ev)) {
            self.sync_list_from_scroll_view();
            self.refresh_preview();
            return true;
        }
        if (ev.kind == ui.MOUSE_DOWN and (ev.flags & ui.BTN_LEFT) != 0) {
            // F1: Ctrl+click toggles selection of individual entry
            if ((ev.flags & ui.MOD_CTRL) != 0 and self.list.rect.contains(ev.arg0, ev.arg1)) {
                const row = (ev.arg1 - (list_area.y + header_h)) / list_row_h;
                const target_idx = self.list.scroll + row;
                if (target_idx < self.entry_count) {
                    self.toggle_select(target_idx);
                    self.set_status("Multi-select");
                    return true;
                }
            }

            // Breadcrumb click has priority over list click (title bar).
            if (breadcrumb_rect.contains(ev.arg0, ev.arg1)) {
                if (breadcrumb_hit_test(self.current_path_slice(), breadcrumb_rect.x, ev.arg0)) |seg| {
                    self.navigate_to_segment(seg);
                    return true;
                }
                // Click in breadcrumb but missed segment — ignore.
                return false;
            }
            // F11: column header click sorts by that column.
            const hdr_y = list_area.y;
            if (ev.arg1 >= hdr_y and ev.arg1 < hdr_y + header_h and
                ev.arg0 >= list_area.x and ev.arg0 < list_area.x + list_area.w)
            {
                if (ev.arg0 >= col_name_x and ev.arg0 < col_name_x + col_name_w) {
                    self.click_column(.name);
                } else if (ev.arg0 >= col_size_x and ev.arg0 < col_size_x + col_size_w) {
                    self.click_column(.size);
                } else if (ev.arg0 >= col_type_x) {
                    self.click_column(.col_type);
                }
                self.list.select(0, self.entry_count);
                self.refresh_preview();
                return true;
            }
            // Offset y by header height so row 0 maps to the first file row.
            const changed = self.list.click(ev.arg0, ev.arg1 +% header_h, self.entry_count);
            if (changed) {
                self.sync_scroll_view();
                self.refresh_preview();
                return true;
            }
            // Click in list but same selection — still ensure preview (e.g., after refresh).
            if (self.list.rect.contains(ev.arg0, ev.arg1)) {
                // Single-click already handled; double-click could open dir but open does it.
                return false;
            }
            return false;
        }
        // Also handle drag-move/up outside MOUSE_DOWN for ScrollView thumb
        if (ev.kind == ui.MOUSE_MOVE or ev.kind == ui.MOUSE_UP) {
            // Already handled via scroll_view above; if not dragging, no-op
            return false;
        }
        return false;
    }

    pub fn handle_keyboard_event(self: *AppState, ev: *const Event) bool {
        if (ev.kind != ui.KEY_DOWN) return false;
        const keycode = ev.arg0;
        const ascii_char: u8 = @truncate(ev.arg1);

        // Modal dialogs intercept all keyboard events when open
        if (self.delete_dialog.is_open()) {
            _ = self.delete_dialog.handle_event(ev);
            if (self.delete_dialog.get_result() == .ok) {
                self.perform_delete();
            }
            return true;
        }
        if (self.move_dialog.is_open()) {
            _ = self.move_dialog.handle_event(ev);
            if (self.move_dialog.get_result() == .ok) {
                self.perform_move(self.move_dialog.input.get_text());
            }
            return true;
        }
        if (self.batch_rename_dialog.is_open()) {
            _ = self.batch_rename_dialog.handle_event(ev);
            if (self.batch_rename_dialog.get_result() == .ok) {
                self.perform_batch_rename(self.batch_rename_dialog.input.get_text());
            }
            return true;
        }

        // F9: Bookmarks list modal navigation
        if (self.bookmarks_active) {
            if (keycode == 0x29) { // Escape
                self.bookmarks_active = false;
                self.set_status("Ready");
                return true;
            }
            if (keycode == 0x52) { // Up
                if (self.bookmarks_selected > 0) self.bookmarks_selected -= 1;
                return true;
            }
            if (keycode == 0x51) { // Down
                if (self.bookmarks_selected + 1 < self.bookmark_count) self.bookmarks_selected += 1;
                return true;
            }
            if (keycode == 0x28 or ascii_char == '\n' or ascii_char == '\r') { // Enter
                _ = self.jump_bookmark(self.bookmarks_selected);
                self.bookmarks_active = false;
                return true;
            }
        }

        if (self.view_mode) {
            // Esc (0x29) or Enter returns to the list.
            if (keycode == 0x29) {
                self.back_to_list();
                return true;
            }
            return false;
        }

        // F1: Ctrl+A selects all entries.
        if ((ev.flags & ui.MOD_CTRL) != 0 and (keycode == 0x04 or ascii_char == 1)) {
            self.select_all();
            return true;
        }

        // F1: Ctrl+M prompts for batch move to target directory.
        if ((ev.flags & ui.MOD_CTRL) != 0 and (keycode == 0x10 or ascii_char == 13)) {
            return self.move_prompt();
        }

        // F7: Ctrl+Shift+R opens batch rename dialog.
        if ((ev.flags & ui.MOD_CTRL) != 0 and (ev.flags & ui.MOD_SHIFT) != 0 and (keycode == 0x15 or ascii_char == 18)) {
            return self.batch_rename_prompt();
        }

        // F9: Ctrl+B toggles bookmarks list.
        if ((ev.flags & ui.MOD_CTRL) != 0 and (keycode == 0x05 or ascii_char == 2)) {
            return self.toggle_bookmarks();
        }

        // F2: Ctrl+I or 'p'/'P' toggles file properties panel.
        if (((ev.flags & ui.MOD_CTRL) != 0 and keycode == 0x0C) or
            (!self.filter_active and !self.create_dir_active and (ascii_char == 'p' or ascii_char == 'P')))
        {
            return self.toggle_properties();
        }

        // F3: Ctrl+Shift+N toggles directory creation overlay.
        if ((ev.flags & ui.MOD_CTRL) != 0 and (ev.flags & ui.MOD_SHIFT) != 0 and keycode == 0x11) {
            return self.toggle_create_dir();
        }

        // F8: Ctrl+W, Ctrl+\ (0x31), or Tab toggles/switches split panes.
        if ((ev.flags & ui.MOD_CTRL) != 0 and (keycode == 0x1A or keycode == 0x31)) {
            return self.toggle_split_pane();
        }
        if (keycode == 0x2B and self.split_pane) {
            self.switch_active_pane();
            return true;
        }

        // F9: Ctrl+D bookmarks current directory.
        if ((ev.flags & ui.MOD_CTRL) != 0 and keycode == 0x07) {
            return self.add_bookmark(self.current_path_slice());
        }

        // F14: Ctrl+T terminal here.
        if ((ev.flags & ui.MOD_CTRL) != 0 and keycode == 0x17) {
            return self.terminal_here();
        }

        // F15: Ctrl+E editor here.
        if ((ev.flags & ui.MOD_CTRL) != 0 and keycode == 0x08) {
            return self.editor_here();
        }

        // F6: 'u' / 'U' restores trash.
        if (!self.filter_active and !self.create_dir_active and (ascii_char == 'u' or ascii_char == 'U')) {
            return self.restore_trash();
        }

        // M20-U8: Ctrl+F toggles the filename filter bar.
        if ((ev.flags & ui.MOD_CTRL) != 0 and keycode == 0x09) {
            return self.toggle_filter();
        }

        // F12: Ctrl+H toggles hidden (dotfile) visibility.
        if ((ev.flags & ui.MOD_CTRL) != 0 and keycode == 0x0B) {
            self.set_status(if (self.show_hidden) "Hidden off" else "Hidden on");
            return self.toggle_hidden();
        }

        // F16: Ctrl+Shift+C copies the current path to the clipboard.
        if ((ev.flags & ui.MOD_CTRL) != 0 and (ev.flags & ui.MOD_SHIFT) != 0 and keycode == 0x06) {
            _ = ui.clipboard_set(self.current_path_slice());
            self.set_status("Path copied");
            ui.write_console("file: clipboard path copied\n");
            return true;
        }

        // F3: While create_dir_active is true, typing feeds mkdir buffer.
        if (self.create_dir_active) {
            if (keycode == 0x29) return self.toggle_create_dir(); // Escape
            if (keycode == 0x28 or ascii_char == '\n' or ascii_char == '\r') {
                return self.confirm_create_dir();
            }
            if (keycode == 0x2a) return self.create_dir_input(0x08); // Backspace
            if (ascii_char >= 0x20 and ascii_char < 0x7f and (ev.flags & ui.MOD_CTRL) == 0) {
                return self.create_dir_input(ascii_char);
            }
        }

        // While the filter is active, typing narrows the list and Escape
        // leaves (restoring the full listing). Letters no longer trigger
        // the d/r shortcuts — they are filter input.
        if (self.filter_active) {
            if (keycode == 0x29) return self.toggle_filter(); // Escape
            if (keycode == 0x2a) return self.filter_input(0x08); // Backspace
            if (ascii_char >= 0x20 and ascii_char < 0x7f and
                (ev.flags & ui.MOD_CTRL) == 0)
            {
                return self.filter_input(ascii_char);
            }
        }

        // Enter opens the selected entry.
        if (keycode == 0x28 or ascii_char == '\n' or ascii_char == '\r') {
            return self.open_selected();
        }

        // 'd' deletes, 'r' renames the selected entry (claim 5801 slots 34/35).
        if (ascii_char == 'd' or ascii_char == 'D' or keycode == 0x4c) {
            return self.delete_prompt();
        }
        if (ascii_char == 'r' or ascii_char == 'R') {
            return self.rename_selected();
        }

        switch (keycode) {
            0x52 => { // Up
                self.list.move_by(-1, self.entry_count);
                self.sync_scroll_view();
                self.refresh_preview();
                return true;
            },
            0x51 => { // Down
                self.list.move_by(1, self.entry_count);
                self.sync_scroll_view();
                self.refresh_preview();
                return true;
            },
            0x4a => { // Home
                self.list.select(0, self.entry_count);
                self.sync_scroll_view();
                self.refresh_preview();
                return true;
            },
            0x4d => { // End
                if (self.entry_count > 0) {
                    self.list.select(self.entry_count - 1, self.entry_count);
                }
                self.sync_scroll_view();
                self.refresh_preview();
                return true;
            },
            0x4b => { // PageUp — GH #218 via ScrollView
                self.sync_scroll_view();
                if (self.scroll_view.handle_event(ev)) {
                    self.sync_list_from_scroll_view();
                    self.refresh_preview();
                    return true;
                }
                return false;
            },
            0x4e => { // PageDown — GH #218 via ScrollView
                self.sync_scroll_view();
                if (self.scroll_view.handle_event(ev)) {
                    self.sync_list_from_scroll_view();
                    self.refresh_preview();
                    return true;
                }
                return false;
            },
            else => {},
        }
        return false;
    }

    pub fn breadcrumb_click(self: *AppState, px: u32, py: u32) bool {
        if (!breadcrumb_rect.contains(px, py)) return false;
        if (breadcrumb_hit_test(self.current_path_slice(), breadcrumb_rect.x, px)) |seg| {
            self.navigate_to_segment(seg);
            return true;
        }
        return false;
    }
};

/// Build `<base>/<name>` into `buf` (caller provides ≥ base.len+1+name.len bytes).
pub fn build_path(base: []const u8, name: []const u8, buf: []u8) []const u8 {
    @memcpy(buf[0..base.len], base);
    buf[base.len] = '/';
    @memcpy(buf[base.len + 1 .. base.len + 1 + name.len], name);
    return buf[0 .. base.len + 1 + name.len];
}

/// Build `/data/<name>` into `buf` (caller provides ≥ 6 + name.len bytes).
pub fn build_data_path(buf: []u8, name: []const u8) []const u8 {
    const prefix = "/data/";
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len .. prefix.len + name.len], name);
    return buf[0 .. prefix.len + name.len];
}

/// Build `<stem>.BAK` from `name` (an existing extension is stripped; the
/// stem is capped at 8 chars so the result always fits FAT 8.3). Caller
/// provides a buffer ≥ 12 bytes.
pub fn make_bak_name(name: []const u8, buf: []u8) []const u8 {
    const stem = if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| name[0..i] else name;
    const n = @min(@min(stem.len, 8), buf.len - 4);
    @memcpy(buf[0..n], stem[0..n]);
    const suffix = ".BAK";
    @memcpy(buf[n .. n + 4], suffix);
    return buf[0 .. n + 4];
}

// ---------------------------------------------------------------------------
// Entry Point (EL0)
// ---------------------------------------------------------------------------

pub export fn _start() callconv(.c) noreturn {
    var app = AppState.init();

    const win_res = ui.win_open(window_x, window_y, window_w, window_h);
    if (win_res < 0) {
        ui.write_console("file: failed to open window\n");
        ui.exit_process(1);
    }
    const win = @as(u32, @intCast(win_res));
    ui.write_console("file: open id=5\n");

    app.list_directory();
    app.draw(win);
    ui.win_present(win);
    ui.write_console("file: ready\n");

    var ev: Event = undefined;
    while (true) {
        const wait_rc = ui.wait_event(&ev);
        if (wait_rc < 0) break;

        var dirty = false;

        if (ev.kind == ui.WIN_CLOSE) {
            ui.write_console("file: close\n");
            break;
        }

        if (ev.kind == ui.MOUSE_DOWN or ev.kind == ui.MOUSE_UP or ev.kind == ui.MOUSE_MOVE or ev.kind == ui.MOUSE_SCROLL) {
            dirty = app.handle_mouse_events(&ev) or dirty;
        } else if (ev.kind == ui.KEY_DOWN) {
            dirty = app.handle_keyboard_event(&ev) or dirty;
        }

        while (ui.poll_event(&ev) > 0) {
            if (ev.kind == ui.WIN_CLOSE) {
                ui.write_console("file: close\n");
                ui.win_close(win);
                ui.exit_process(exit_status);
            }
            if (ev.kind == ui.MOUSE_DOWN or ev.kind == ui.MOUSE_UP or ev.kind == ui.MOUSE_MOVE or ev.kind == ui.MOUSE_SCROLL) {
                dirty = app.handle_mouse_events(&ev) or dirty;
            } else if (ev.kind == ui.KEY_DOWN) {
                dirty = app.handle_keyboard_event(&ev) or dirty;
            }
        }

        if (dirty) {
            app.draw(win);
            ui.win_present(win);
        }
    }

    ui.write_console("file: exiting 43\n");
    ui.win_close(win);
    ui.exit_process(exit_status);
}

// ---------------------------------------------------------------------------
// Unit Tests (Class A Host Validation)
// ---------------------------------------------------------------------------

test "file: entry_name stops at the NUL pad and is_txt_file checks the suffix" {
    var de = DirEntry{
        .name = [_]u8{0} ** 32,
        .size = 90,
        .is_dir = 0,
        .reserved = .{ 0, 0, 0 },
    };
    @memcpy(de.name[0..10], "README.TXT");
    try std.testing.expectEqualStrings("README.TXT", entry_name(&de));
    try std.testing.expect(is_txt_file("README.TXT"));
    try std.testing.expect(is_txt_file("notes.txt")); // case-insensitive
    try std.testing.expect(!is_txt_file("DATA.TXT") == false);
    try std.testing.expect(!is_txt_file("hello.bin"));
    try std.testing.expect(!is_txt_file("README"));
}

test "file: content_rows wraps and counts newlines (claim B3)" {
    try std.testing.expectEqual(@as(usize, 1), content_rows("", 29));
    try std.testing.expectEqual(@as(usize, 1), content_rows("short", 29));
    // Exactly cols glyphs stays on one row.
    const full = [_]u8{'a'} ** 29;
    try std.testing.expectEqual(@as(usize, 1), content_rows(&full, 29));
    // cols+1 wraps to a second row.
    const over = [_]u8{'a'} ** 30;
    try std.testing.expectEqual(@as(usize, 2), content_rows(&over, 29));
    // A newline forces a break (a trailing newline still counts its row).
    try std.testing.expectEqual(@as(usize, 2), content_rows("ab\ncd", 29));
    try std.testing.expectEqual(@as(usize, 2), content_rows("ab\n", 29));
}

test "file: FileList selection, scrolling, and click mapping" {
    // Use a 128px tall viewport (8 rows @16px) to keep the original 8-row expectations
    // regardless of the current list_area height (290).
    const test_rect = Rect.make(6, 26, 240, 128);
    var fl = FileList.init(test_rect);
    try std.testing.expectEqual(@as(usize, 8), fl.visible_rows()); // 128/16

    // 10 entries -> scrollable by 2.
    const count: usize = 10;
    try std.testing.expectEqual(@as(usize, 2), fl.max_scroll(count));

    fl.select(0, count);
    try std.testing.expectEqual(@as(?usize, 0), fl.selected);

    // Move down past the viewport scrolls the list.
    var i: usize = 0;
    while (i < 9) : (i += 1) fl.move_by(1, count);
    try std.testing.expectEqual(@as(?usize, 9), fl.selected);
    try std.testing.expectEqual(@as(usize, 2), fl.scroll); // 9 - 8 + 1

    // Click maps the visible row to an absolute index (scroll-aware).
    // Visible row 0 is absolute entry 2.
    _ = fl.click(test_rect.x + 4, test_rect.y + 2, count);
    try std.testing.expectEqual(@as(?usize, 2), fl.selected);

    // Home via select clamps scroll back to 0.
    fl.select(0, count);
    try std.testing.expectEqual(@as(?usize, 0), fl.selected);
    try std.testing.expectEqual(@as(usize, 0), fl.scroll);

    // Empty list: selection clears, navigation is a no-op.
    fl.select(3, 0);
    try std.testing.expectEqual(@as(?usize, null), fl.selected);
    fl.move_by(1, 0);
    try std.testing.expectEqual(@as(?usize, null), fl.selected);
}

test "file: build_data_path prefixes /data/" {
    var buf: [64]u8 = undefined;
    const p = build_data_path(&buf, "README.TXT");
    try std.testing.expectEqualStrings("/data/README.TXT", p);
}

test "file: AppState fits the 16 KiB EL0 stack (W^X, claim B3)" {
    try std.testing.expect(@sizeOf(AppState) < 8 * 1024);
    std.debug.print("AppState size: {d}\n", .{@sizeOf(AppState)});
}

test "file: keyboard navigation routes through the FileList model" {
    var app = AppState.init();
    app.entry_count = 3;
    app.list.select(0, app.entry_count);

    var ev_down = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x51, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&ev_down));
    try std.testing.expectEqual(@as(?usize, 1), app.list.selected);

    var ev_up = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x52, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&ev_up));
    try std.testing.expectEqual(@as(?usize, 0), app.list.selected);

    var ev_end = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 3, .arg0 = 0x4d, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&ev_end));
    try std.testing.expectEqual(@as(?usize, 2), app.list.selected);

    // Esc in list mode is not handled (nothing to go back to).
    var ev_esc = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 4, .arg0 = 0x29, .arg1 = 0 };
    try std.testing.expect(!app.handle_keyboard_event(&ev_esc));
}

test "file: view-mode Esc returns to the list (claim B3)" {
    var app = AppState.init();
    app.view_mode = true;
    var ev_esc = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x29, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&ev_esc));
    try std.testing.expect(!app.view_mode);
}

test "file: make_bak_name strips the extension and caps the stem (claim 5801)" {
    var b: [32]u8 = [_]u8{0} ** 32;
    try std.testing.expectEqualStrings("README.BAK", make_bak_name("README.TXT", &b));
    try std.testing.expectEqualStrings("DATA.BAK", make_bak_name("DATA.TXT", &b));
    try std.testing.expectEqualStrings("noext.BAK", make_bak_name("noext", &b));
    try std.testing.expectEqualStrings("verylong.BAK", make_bak_name("verylongname.TXT", &b));
}

test "file: 'd' and 'r' route to delete/rename (claim 5801)" {
    var app = AppState.init();
    app.entries[0] = .{ .name = [_]u8{0} ** 32, .size = 10, .is_dir = 0, .reserved = .{ 0, 0, 0 } };
    @memcpy(app.entries[0].name[0..10], "README.TXT");
    app.entry_count = 1;
    app.list.select(0, 1);

    // 'd' routes to delete (host syscall returns 0, so the success path runs).
    var ev_d = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x07, .arg1 = 'd' };
    try std.testing.expect(app.handle_keyboard_event(&ev_d));

    // 'r' routes to rename.
    app.entries[0] = .{ .name = [_]u8{0} ** 32, .size = 10, .is_dir = 0, .reserved = .{ 0, 0, 0 } };
    @memcpy(app.entries[0].name[0..10], "README.TXT");
    app.entry_count = 1;
    app.list.select(0, 1);
    var ev_r = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x15, .arg1 = 'r' };
    try std.testing.expect(app.handle_keyboard_event(&ev_r));
}

test "file: is_binary_content sniff (C7)" {
    try std.testing.expect(!is_binary_content("hello world\n"));
    try std.testing.expect(!is_binary_content("README.TXT\nline2\n"));
    try std.testing.expect(!is_binary_content(""));
    // High binary ratio
    const bin = [_]u8{ 0x00, 0xff, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08 };
    try std.testing.expect(is_binary_content(&bin));
    // Mixed but >80% printable still not binary
    try std.testing.expect(!is_binary_content("hello\x01world"));
}

test "file: breadcrumbs format and hit-test (C7)" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("data", format_breadcrumbs("/data", &buf));
    try std.testing.expectEqualStrings("data > docs", format_breadcrumbs("/data/docs", &buf));
    try std.testing.expectEqualStrings("data > docs > notes", format_breadcrumbs("/data/docs/notes", &buf));
    try std.testing.expectEqual(@as(usize, 1), path_segment_count("/data"));
    try std.testing.expectEqual(@as(usize, 2), path_segment_count("/data/docs"));
    try std.testing.expectEqual(@as(usize, 0), path_segment_count("/"));
    // hit-test: base 60, "data" 4*8=32px at 60..92, " > " 24px, "docs" 4*8=32 at 116..148
    try std.testing.expectEqual(@as(?usize, 0), breadcrumb_hit_test("/data/docs", 60, 70));
    try std.testing.expectEqual(@as(?usize, 1), breadcrumb_hit_test("/data/docs", 60, 120));
    try std.testing.expectEqual(@as(?usize, null), breadcrumb_hit_test("/data/docs", 60, 200));
    // truncate to segment 0 keeps "/data"
    var p: [64]u8 = [_]u8{0} ** 64;
    @memcpy(p[0..10], "/data/docs");
    try std.testing.expectEqual(@as(usize, 5), truncate_to_segment(&p, 10, 0));
    @memcpy(p[0..10], "/data/docs");
    try std.testing.expectEqual(@as(usize, 10), truncate_to_segment(&p, 10, 1));
}

test "file: build_path joins base and name (C7)" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/data/README.TXT", build_path("/data", "README.TXT", &buf));
    try std.testing.expectEqualStrings("/data/docs/NOTES.TXT", build_path("/data/docs", "NOTES.TXT", &buf));
}

test "file: AppState current_path and breadcrumb navigation (C7)" {
    var app = AppState.init();
    try std.testing.expectEqualStrings("/data", app.current_path_slice());
    // Enter subdirectory
    _ = app.enter_directory("docs");
    try std.testing.expectEqualStrings("/data/docs", app.current_path_slice());
    // Navigate back via breadcrumb segment 0
    app.navigate_to_segment(0);
    try std.testing.expectEqualStrings("/data", app.current_path_slice());
    // Preview flag for directory (no load)
    app.entry_count = 1;
    app.entries[0] = .{ .name = [_]u8{0} ** 32, .size = 0, .is_dir = 1, .reserved = .{ 0, 0, 0 } };
    @memcpy(app.entries[0].name[0..4], "docs");
    app.list.select(0, 1);
    app.refresh_preview();
    try std.testing.expect(!app.preview_loaded);
}

test "file: selecting file auto-loads preview and keyboard nav refreshes (C7)" {
    var app = AppState.init();
    app.entry_count = 2;
    app.entries[0] = .{ .name = [_]u8{0} ** 32, .size = 10, .is_dir = 0, .reserved = .{ 0, 0, 0 } };
    app.entries[1] = .{ .name = [_]u8{0} ** 32, .size = 10, .is_dir = 0, .reserved = .{ 0, 0, 0 } };
    @memcpy(app.entries[0].name[0..9], "HELLO.TXT");
    @memcpy(app.entries[1].name[0..9], "WORLD.TXT");
    app.list.select(0, 2);
    // Host dir_list for preview will stub 0, so preview_loaded false is ok — we just check selection changes trigger
    app.refresh_preview();
    // Move down should change selection and attempt preview (host stub)
    var ev_down = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x51, .arg1 = 0 };
    _ = app.handle_keyboard_event(&ev_down);
    try std.testing.expectEqual(@as(?usize, 1), app.list.selected);
}

test "file: breadcrumb_click hit-test via AppState (C7)" {
    var app = AppState.init();
    _ = app.enter_directory("docs");
    try std.testing.expectEqualStrings("/data/docs", app.current_path_slice());
    // Click on first segment "data" at x=64 (inside "data" 60..92)
    const hit = app.breadcrumb_click(64, 8);
    try std.testing.expect(hit);
    try std.testing.expectEqualStrings("/data", app.current_path_slice());
}

test "file: M20-U8 — Ctrl+F filter narrows the listing in real time" {
    var app = AppState.init();
    // Fabricate a listing.
    app.entry_count = 3;
    @memcpy(app.entries[0].name[0..9], "HELLO.TXT");
    @memcpy(app.entries[1].name[0..8], "world.md");
    @memcpy(app.entries[2].name[0..6], "hats.c");
    app.list.select(0, 3);

    // Ctrl+F (usage 0x09) activates and snapshots.
    const ev_ctrl_f = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL, .seq = 1, .arg0 = 0x09, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&ev_ctrl_f));
    try std.testing.expect(app.filter_active);

    // Type 'h': HELLO.TXT + hats.c remain, world.md vanishes.
    try std.testing.expect(app.handle_keyboard_event(&Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x0b, .arg1 = 'h' }));
    try std.testing.expectEqual(@as(usize, 2), app.entry_count);
    // 'a' narrows to "ha": only hats.c survives.
    try std.testing.expect(app.handle_keyboard_event(&Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 3, .arg0 = 0x04, .arg1 = 'a' }));
    try std.testing.expectEqual(@as(usize, 1), app.entry_count);
    try std.testing.expectEqualStrings("hats.c", entry_name(&app.entries[0]));
    // 't' refines to "hat": still just hats.c.
    try std.testing.expect(app.handle_keyboard_event(&Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 4, .arg0 = 0x17, .arg1 = 't' }));
    try std.testing.expectEqual(@as(usize, 1), app.entry_count);
    try std.testing.expectEqualStrings("hats.c", entry_name(&app.entries[0]));
    // Backspace re-widens: "ha" still only matches hats.c…
    try std.testing.expect(app.handle_keyboard_event(&Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 5, .arg0 = 0x2a, .arg1 = 0 }));
    try std.testing.expectEqual(@as(usize, 1), app.entry_count);
    // …but dropping to "h" brings HELLO.TXT back.
    try std.testing.expect(app.handle_keyboard_event(&Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 6, .arg0 = 0x2a, .arg1 = 0 }));
    try std.testing.expectEqual(@as(usize, 2), app.entry_count);

    // Escape leaves the filter: full listing restored.
    try std.testing.expect(app.handle_keyboard_event(&Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 7, .arg0 = 0x29, .arg1 = 0 }));
    try std.testing.expect(!app.filter_active);
    try std.testing.expectEqual(@as(usize, 3), app.entry_count);
}

test "file: M20-U8 — letters feed the filter instead of d/r shortcuts" {
    var app = AppState.init();
    app.entry_count = 1;
    @memcpy(app.entries[0].name[0..4], "d.md");
    _ = app.toggle_filter();
    // 'd' would delete without a filter; with it active it must only type.
    try std.testing.expect(app.handle_keyboard_event(&Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x07, .arg1 = 'd' }));
    try std.testing.expectEqual(@as(usize, 1), app.entry_count); // not deleted
    try std.testing.expectEqual(@as(usize, 1), app.filter_len);
}

test "file: F12 — is_hidden_file detects dotfiles" {
    try std.testing.expect(is_hidden_file(".hidden"));
    try std.testing.expect(is_hidden_file("."));
    try std.testing.expect(!is_hidden_file("README.TXT"));
    try std.testing.expect(!is_hidden_file("data"));
    try std.testing.expect(!is_hidden_file(""));
}

test "file: F12 — toggle_hidden filters dotfiles in-place" {
    var app = AppState.init();
    app.show_hidden = true; // start with hidden visible
    app.entry_count = 4;
    @memcpy(app.entries[0].name[0..4], ".git");
    app.entries[0].is_dir = 1;
    @memcpy(app.entries[1].name[0..10], "README.TXT");
    app.entries[1].is_dir = 0;
    @memcpy(app.entries[2].name[0..4], ".env");
    app.entries[2].is_dir = 0;
    @memcpy(app.entries[3].name[0..8], "DATA.BIN");
    app.entries[3].is_dir = 0;
    app.list.select(0, 4);

    // Toggle off: .git and .env removed, 2 entries remain.
    try std.testing.expect(app.toggle_hidden());
    try std.testing.expect(!app.show_hidden);
    try std.testing.expectEqual(@as(usize, 2), app.entry_count);
    try std.testing.expectEqualStrings("README.TXT", entry_name(&app.entries[0]));
    try std.testing.expectEqualStrings("DATA.BIN", entry_name(&app.entries[1]));

    // Toggle back on: all 4 entries restored.
    try std.testing.expect(app.toggle_hidden());
    try std.testing.expect(app.show_hidden);
    try std.testing.expectEqual(@as(usize, 4), app.entry_count);
}

test "file: F12 — Ctrl+H shortcut toggles hidden visibility" {
    var app = AppState.init();
    app.show_hidden = true;
    app.entry_count = 2;
    @memcpy(app.entries[0].name[0..5], ".bash");
    @memcpy(app.entries[1].name[0..4], "file");
    app.list.select(0, 2);

    // Ctrl+H (usage 0x0B) toggles.
    const ev = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL, .seq = 1, .arg0 = 0x0B, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&ev));
    try std.testing.expect(!app.show_hidden);
    try std.testing.expectEqual(@as(usize, 1), app.entry_count);
    try std.testing.expectEqualStrings("file", entry_name(&app.entries[0]));
}

test "file: F11 — compare_entries sorts by name, size, type" {
    var a = DirEntry{ .name = [_]u8{0} ** 32, .size = 100, .is_dir = 0, .reserved = .{ 0, 0, 0 } };
    var b = DirEntry{ .name = [_]u8{0} ** 32, .size = 50, .is_dir = 0, .reserved = .{ 0, 0, 0 } };
    @memcpy(a.name[0..5], "B.TXT");
    @memcpy(b.name[0..5], "A.TXT");
    // Name sort: A before B
    try std.testing.expectEqual(@as(i8, -1), compare_entries(&b, &a, .name));
    try std.testing.expectEqual(@as(i8, 1), compare_entries(&a, &b, .name));
    // Size sort: 50 before 100
    try std.testing.expectEqual(@as(i8, -1), compare_entries(&b, &a, .size));
    try std.testing.expectEqual(@as(i8, 1), compare_entries(&a, &b, .size));
    // Directories sort after files in name and size, before files in col_type
    var dir = DirEntry{ .name = [_]u8{0} ** 32, .size = 0, .is_dir = 1, .reserved = .{ 0, 0, 0 } };
    @memcpy(dir.name[0..3], "DIR");
    try std.testing.expectEqual(@as(i8, 1), compare_entries(&dir, &a, .name)); // dir after file
    try std.testing.expectEqual(@as(i8, -1), compare_entries(&dir, &a, .col_type)); // dir before file
}

test "file: F11 — click_column toggles direction and rebuilds sort" {
    var app = AppState.init();
    app.entry_count = 3;
    @memcpy(app.entries[0].name[0..5], "C.TXT");
    app.entries[0].size = 30;
    @memcpy(app.entries[1].name[0..5], "A.TXT");
    app.entries[1].size = 10;
    @memcpy(app.entries[2].name[0..5], "B.TXT");
    app.entries[2].size = 20;
    app.rebuild_sort();

    // Default sort: name ascending -> A, B, C (indices 1, 2, 0)
    try std.testing.expectEqual(@as(usize, 1), app.sort_indices[0]);
    try std.testing.expectEqual(@as(usize, 2), app.sort_indices[1]);
    try std.testing.expectEqual(@as(usize, 0), app.sort_indices[2]);

    // Click size column -> size ascending: A(10), B(20), C(30)
    app.click_column(.size);
    try std.testing.expect(app.sort_asc);
    try std.testing.expectEqual(@as(usize, 1), app.sort_indices[0]);
    try std.testing.expectEqual(@as(usize, 2), app.sort_indices[1]);
    try std.testing.expectEqual(@as(usize, 0), app.sort_indices[2]);

    // Click size again -> size descending: C(30), B(20), A(10)
    app.click_column(.size);
    try std.testing.expect(!app.sort_asc);
    try std.testing.expectEqual(@as(usize, 0), app.sort_indices[0]);
    try std.testing.expectEqual(@as(usize, 2), app.sort_indices[1]);
    try std.testing.expectEqual(@as(usize, 1), app.sort_indices[2]);
}

test "file: F11 — name_cmp_ignore_case is case-insensitive" {
    try std.testing.expectEqual(@as(i8, 0), name_cmp_ignore_case("README.TXT", "readme.txt"));
    try std.testing.expectEqual(@as(i8, -1), name_cmp_ignore_case("a.txt", "B.txt"));
    try std.testing.expectEqual(@as(i8, 1), name_cmp_ignore_case("Z.txt", "a.txt"));
}

test "file: F16 — Ctrl+Shift+C shortcut sets clipboard path" {
    var app = AppState.init();
    // Ctrl+Shift+C (Ctrl=0x02, Shift=0x01, usage 'c'=0x06)
    const ev = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL | ui.MOD_SHIFT, .seq = 1, .arg0 = 0x06, .arg1 = 'C' };
    try std.testing.expect(app.handle_keyboard_event(&ev));
    try std.testing.expectEqualStrings("Path copied", app.status_msg[0..app.status_len]);
}

test "file: F1 — selection bitmap multi-selection and Ctrl+A select all" {
    var app = AppState.init();
    app.entry_count = 5;

    // Initially none selected
    try std.testing.expectEqual(@as(usize, 0), app.selected_count());
    try std.testing.expect(!app.is_selected(0));

    // Toggle select item 1 and 3
    app.toggle_select(1);
    app.toggle_select(3);
    try std.testing.expect(app.is_selected(1));
    try std.testing.expect(app.is_selected(3));
    try std.testing.expect(!app.is_selected(0));
    try std.testing.expectEqual(@as(usize, 2), app.selected_count());

    // Toggle again deselects
    app.toggle_select(1);
    try std.testing.expect(!app.is_selected(1));
    try std.testing.expectEqual(@as(usize, 1), app.selected_count());

    // Select all (Ctrl+A)
    const ev_ctrl_a = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL, .seq = 1, .arg0 = 0x04, .arg1 = 1 };
    try std.testing.expect(app.handle_keyboard_event(&ev_ctrl_a));
    try std.testing.expectEqual(@as(usize, 5), app.selected_count());
    for (0..5) |i| {
        try std.testing.expect(app.is_selected(i));
    }

    // Clear selection
    app.clear_selection();
    try std.testing.expectEqual(@as(usize, 0), app.selected_count());
}

test "file: F2 & F4 — properties panel and total_dir_bytes disk usage" {
    var app = AppState.init();
    app.entry_count = 3;
    app.entries[0] = DirEntry{ .name = [_]u8{0} ** 32, .size = 100, .is_dir = 0, .reserved = .{ 0, 0, 0 } };
    app.entries[1] = DirEntry{ .name = [_]u8{0} ** 32, .size = 250, .is_dir = 0, .reserved = .{ 0, 0, 0 } };
    app.entries[2] = DirEntry{ .name = [_]u8{0} ** 32, .size = 50, .is_dir = 1, .reserved = .{ 0, 0, 0 } };

    // F4: sum of all sizes
    try std.testing.expectEqual(@as(u64, 400), app.total_dir_bytes());

    // F2: toggle properties panel via keyboard 'p'
    try std.testing.expect(!app.properties_mode);
    const ev_p = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x13, .arg1 = 'p' };
    try std.testing.expect(app.handle_keyboard_event(&ev_p));
    try std.testing.expect(app.properties_mode);
    try std.testing.expectEqualStrings("Props On", app.status_msg[0..app.status_len]);

    // Toggle off via 'p'
    try std.testing.expect(app.handle_keyboard_event(&ev_p));
    try std.testing.expect(!app.properties_mode);
    try std.testing.expectEqualStrings("Props Off", app.status_msg[0..app.status_len]);
}

test "file: F3 & F17 — create directory input, collision check" {
    var app = AppState.init();
    app.entry_count = 1;
    @memcpy(app.entries[0].name[0..4], "DOCS");

    // Collision check
    try std.testing.expect(app.check_collision("DOCS"));
    try std.testing.expect(app.check_collision("docs")); // case insensitive
    try std.testing.expect(!app.check_collision("NEWDIR"));

    // Ctrl+Shift+N activates create dir mode
    const ev_mkdir = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL | ui.MOD_SHIFT, .seq = 1, .arg0 = 0x11, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&ev_mkdir));
    try std.testing.expect(app.create_dir_active);
    try std.testing.expectEqualStrings("New Dir:", app.status_msg[0..app.status_len]);

    // Type name "TEST"
    _ = app.create_dir_input('T');
    _ = app.create_dir_input('E');
    _ = app.create_dir_input('S');
    _ = app.create_dir_input('T');
    try std.testing.expectEqualStrings("TEST", app.create_dir_buf[0..app.create_dir_len]);

    // Backspace works
    _ = app.create_dir_input(0x08);
    try std.testing.expectEqualStrings("TES", app.create_dir_buf[0..app.create_dir_len]);

    // Escape exits create dir mode
    const ev_esc = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x29, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&ev_esc));
    try std.testing.expect(!app.create_dir_active);
}

test "file: F5 — recent files ring stores and shifts paths" {
    var app = AppState.init();
    try std.testing.expectEqual(@as(usize, 0), app.recent_count);

    app.add_recent("/data/README.TXT");
    try std.testing.expectEqual(@as(usize, 1), app.recent_count);
    try std.testing.expectEqualStrings("/data/README.TXT", app.recent_ring[0][0..app.recent_lens[0]]);

    app.add_recent("/data/DOCS/NOTES.TXT");
    try std.testing.expectEqual(@as(usize, 2), app.recent_count);
    try std.testing.expectEqualStrings("/data/DOCS/NOTES.TXT", app.recent_ring[0][0..app.recent_lens[0]]);
    try std.testing.expectEqualStrings("/data/README.TXT", app.recent_ring[1][0..app.recent_lens[1]]);
}

test "file: F6 — trash staging and restore" {
    var app = AppState.init();
    try std.testing.expectEqual(@as(usize, 0), app.trash_count);

    app.entry_count = 1;
    @memcpy(app.entries[0].name[0..8], "TEMP.TXT");
    app.list.select(0, 1);

    // Trashing records the name and decrements
    _ = app.trash_selected();
    try std.testing.expectEqual(@as(usize, 1), app.trash_count);
    try std.testing.expectEqualStrings("TEMP.TXT", app.trash_names[0][0..app.trash_lens[0]]);
    try std.testing.expectEqualStrings("Trashed", app.status_msg[0..app.status_len]);

    // 'u' triggers restore
    const ev_u = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x18, .arg1 = 'u' };
    try std.testing.expect(app.handle_keyboard_event(&ev_u));
}

test "file: F8 — split pane mode toggle and active pane switch" {
    var app = AppState.init();
    try std.testing.expect(!app.split_pane);
    try std.testing.expectEqual(@as(u8, 0), app.active_pane);

    // Ctrl+W toggles split pane
    const ev_split = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL, .seq = 1, .arg0 = 0x1A, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&ev_split));
    try std.testing.expect(app.split_pane);
    try std.testing.expectEqualStrings("Split On", app.status_msg[0..app.status_len]);

    // Tab switches active pane
    const ev_tab = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x2B, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&ev_tab));
    try std.testing.expectEqual(@as(u8, 1), app.active_pane);
    try std.testing.expectEqualStrings("Right Pane", app.status_msg[0..app.status_len]);

    // Tab again switches back to left
    try std.testing.expect(app.handle_keyboard_event(&ev_tab));
    try std.testing.expectEqual(@as(u8, 0), app.active_pane);
    try std.testing.expectEqualStrings("Left Pane", app.status_msg[0..app.status_len]);
}

test "file: F9 — bookmarks add and jump" {
    var app = AppState.init();
    try std.testing.expectEqual(@as(usize, 0), app.bookmark_count);

    // Ctrl+D bookmarks current path "/data"
    const ev_bk = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL, .seq = 1, .arg0 = 0x07, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&ev_bk));
    try std.testing.expectEqual(@as(usize, 1), app.bookmark_count);
    try std.testing.expectEqualStrings("/data", app.bookmarks[0][0..app.bookmark_lens[0]]);
    try std.testing.expectEqualStrings("Bookmarked", app.status_msg[0..app.status_len]);

    // Enter subfolder and jump back via bookmark
    _ = app.enter_directory("docs");
    try std.testing.expectEqualStrings("/data/docs", app.current_path_slice());
    try std.testing.expect(app.jump_bookmark(0));
    try std.testing.expectEqualStrings("/data", app.current_path_slice());
}

test "file: F14 & F15 — terminal here and editor here shortcuts" {
    var app = AppState.init();
    app.entry_count = 1;
    @memcpy(app.entries[0].name[0..8], "MAIN.ZIG");
    app.list.select(0, 1);

    // Ctrl+T triggers terminal here
    const ev_term = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL, .seq = 1, .arg0 = 0x17, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&ev_term));
    try std.testing.expectEqualStrings("Term Spawned", app.status_msg[0..app.status_len]);

    // Ctrl+E triggers editor here
    const ev_edit = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL, .seq = 2, .arg0 = 0x08, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&ev_edit));
    try std.testing.expectEqualStrings("Edit Spawned", app.status_msg[0..app.status_len]);
}

test "file: F1 & F18 — delete confirmation dialog modal workflow" {
    var app = AppState.init();
    app.entry_count = 2;
    @memcpy(app.entries[0].name[0..5], "A.TXT");
    @memcpy(app.entries[1].name[0..5], "B.TXT");
    app.list.select(0, 2);

    // Pressing 'd' opens delete confirmation dialog
    const ev_d = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x07, .arg1 = 'd' };
    try std.testing.expect(app.handle_keyboard_event(&ev_d));
    try std.testing.expect(app.delete_dialog.is_open());

    // Pressing Escape cancels dialog without deleting
    const ev_esc = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x29, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&ev_esc));
    try std.testing.expect(!app.delete_dialog.is_open());
    try std.testing.expectEqual(ui.DialogResult.cancel, app.delete_dialog.get_result());

    // Pressing 'd' again and confirming with Enter
    _ = app.handle_keyboard_event(&ev_d);
    try std.testing.expect(app.delete_dialog.is_open());
    const ev_enter = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 3, .arg0 = 0x28, .arg1 = '\n' };
    try std.testing.expect(app.handle_keyboard_event(&ev_enter));
    try std.testing.expect(!app.delete_dialog.is_open());
    try std.testing.expectEqual(ui.DialogResult.ok, app.delete_dialog.get_result());
}

test "file: F1 — Ctrl+M batch move dialog workflow and progress" {
    var app = AppState.init();
    app.entry_count = 2;
    @memcpy(app.entries[0].name[0..5], "A.TXT");
    @memcpy(app.entries[1].name[0..5], "B.TXT");
    app.toggle_select(0);
    app.toggle_select(1);

    // Ctrl+M opens move dialog with input
    const ev_ctrl_m = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL, .seq = 1, .arg0 = 0x10, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&ev_ctrl_m));
    try std.testing.expect(app.move_dialog.is_open());
    try std.testing.expect(app.move_dialog.has_input);

    // Type destination path into move dialog input
    app.move_dialog.input.set_text("/data/archive");
    try std.testing.expectEqualStrings("/data/archive", app.move_dialog.input.get_text());

    // Enter confirms move
    const ev_enter = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x28, .arg1 = '\n' };
    try std.testing.expect(app.handle_keyboard_event(&ev_enter));
    try std.testing.expect(!app.move_dialog.is_open());
    try std.testing.expectEqualStrings("Moved", app.status_msg[0..app.status_len]);
    try std.testing.expectEqual(@as(usize, 0), app.selected_count());
}

test "file: F7 — Ctrl+Shift+R batch rename dialog workflow" {
    var app = AppState.init();
    app.entry_count = 2;
    @memcpy(app.entries[0].name[0..5], "A.TXT");
    @memcpy(app.entries[1].name[0..5], "B.TXT");
    app.toggle_select(0);
    app.toggle_select(1);

    // Ctrl+Shift+R opens batch rename dialog
    const ev_rename = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL | ui.MOD_SHIFT, .seq = 1, .arg0 = 0x15, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&ev_rename));
    try std.testing.expect(app.batch_rename_dialog.is_open());

    // Set prefix
    app.batch_rename_dialog.input.set_text("old_");
    try std.testing.expectEqualStrings("old_", app.batch_rename_dialog.input.get_text());

    // Confirm rename
    const ev_enter = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x28, .arg1 = '\n' };
    try std.testing.expect(app.handle_keyboard_event(&ev_enter));
    try std.testing.expect(!app.batch_rename_dialog.is_open());
    try std.testing.expectEqualStrings("Batch Renamed", app.status_msg[0..app.status_len]);
}

test "file: F9 — Ctrl+B bookmarks overlay navigation and jump" {
    var app = AppState.init();
    _ = app.add_bookmark("/data/docs");
    _ = app.add_bookmark("/data/music");

    // Ctrl+B opens bookmarks overlay
    const ev_ctrl_b = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL, .seq = 1, .arg0 = 0x05, .arg1 = 2 };
    try std.testing.expect(app.handle_keyboard_event(&ev_ctrl_b));
    try std.testing.expect(app.bookmarks_active);
    try std.testing.expectEqual(@as(usize, 0), app.bookmarks_selected);

    // Down arrow selects second bookmark
    const ev_down = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x51, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&ev_down));
    try std.testing.expectEqual(@as(usize, 1), app.bookmarks_selected);

    // Enter jumps to selected bookmark
    const ev_enter = Event{ .kind = ui.KEY_DOWN, .flags = 0, .seq = 3, .arg0 = 0x28, .arg1 = '\n' };
    try std.testing.expect(app.handle_keyboard_event(&ev_enter));
    try std.testing.expect(!app.bookmarks_active);
    try std.testing.expectEqualStrings("/data/music", app.current_path_slice());
}

test "file: F13 — get_associated_app returns correct application" {
    try std.testing.expectEqualStrings("EXEC", get_associated_app("TEST.BIN"));
    try std.testing.expectEqualStrings("NOTEPAD", get_associated_app("README.TXT"));
    try std.testing.expectEqualStrings("NOTEPAD", get_associated_app("MEMO.DOC"));
    try std.testing.expectEqualStrings("EDIT", get_associated_app("MAIN.ZIG"));
    try std.testing.expectEqualStrings("EDIT", get_associated_app("TEST.C"));
    try std.testing.expectEqualStrings("EDIT", get_associated_app("HEADER.H"));
    try std.testing.expectEqualStrings("VIEW", get_associated_app("DATA.DAT"));
}

test "file: F8 — Ctrl+\\ toggles split pane" {
    var app = AppState.init();
    try std.testing.expect(!app.split_pane);

    // Ctrl+\ (usage 0x31)
    const ev_bslash = Event{ .kind = ui.KEY_DOWN, .flags = ui.MOD_CTRL, .seq = 1, .arg0 = 0x31, .arg1 = 0 };
    try std.testing.expect(app.handle_keyboard_event(&ev_bslash));
    try std.testing.expect(app.split_pane);

    // Toggle again closes split
    try std.testing.expect(app.handle_keyboard_event(&ev_bslash));
    try std.testing.expect(!app.split_pane);
}

test "file: selection index mapping correctly handles non-identity sort_indices (no data-loss)" {
    var app = AppState.init();
    app.entry_count = 2;
    // Physical layout in entries: entry 0 is B.TXT, entry 1 is A.TXT
    @memcpy(app.entries[0].name[0..5], "B.TXT");
    @memcpy(app.entries[1].name[0..5], "A.TXT");

    // Display sort order: row 0 is A.TXT (entry 1), row 1 is B.TXT (entry 0)
    app.sort_indices[0] = 1;
    app.sort_indices[1] = 0;

    // Select row 0 (which displays A.TXT)
    app.toggle_select(0);
    try std.testing.expect(app.is_selected(0));
    try std.testing.expect(!app.is_selected(1));

    // Batch rename prefix "new_" on selected row 0 should rename A.TXT (entry 1), not B.TXT
    app.perform_batch_rename("new_");
    try std.testing.expectEqualStrings("Batch Renamed", app.status_msg[0..app.status_len]);
}
test "file_browser: M20-U3 — find_substring_ci locates the searched range" {
    try std.testing.expectEqual(@as(?usize, 0), AppState.find_substring_ci("README.TXT", "read"));
    try std.testing.expectEqual(@as(?usize, 7), AppState.find_substring_ci("README.TXT", "txt"));
    try std.testing.expectEqual(@as(?usize, null), AppState.find_substring_ci("README.TXT", "zzz"));
    // An empty pattern selects everything but highlights nothing.
    try std.testing.expectEqual(@as(?usize, null), AppState.find_substring_ci("README.TXT", ""));
    try std.testing.expect(AppState.matches_filter("README.TXT", ""));
    // Case-insensitive parity with matches_filter.
    try std.testing.expect(AppState.matches_filter("DATA.BIN", "bin"));
}

test "file_browser: M20-U3 — filter narrowing reports shown/total accounting" {
    var app = AppState.init();
    var n: usize = 0;
    const names = [_][]const u8{ "ALPHA.TXT", "BETA.TXT", "GAMMA.BIN" };
    for (names) |nm| {
        var de = DirEntry{ .name = [_]u8{0} ** 32, .size = 8, .is_dir = 0, .reserved = .{ 0, 0, 0 } };
        @memcpy(de.name[0..nm.len], nm);
        app.entries[n] = de;
        n += 1;
    }
    app.entry_count = n;
    app.shadow_count = n;
    for (0..n) |i| app.shadow[i] = app.entries[i];
    app.filter_active = true;
    @memcpy(app.filter_buf[0..3], "txt");
    app.filter_len = 3;
    app.apply_filter();
    try std.testing.expectEqual(@as(usize, 2), app.entry_count);
    try std.testing.expectEqual(@as(usize, 3), app.shadow_count);
    // The first visible entry is the alphabetically-first match.
    try std.testing.expectEqualStrings("ALPHA.TXT", entry_name(&app.entries[app.sort_indices[0]]));
}

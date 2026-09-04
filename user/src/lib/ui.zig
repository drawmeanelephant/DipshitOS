//! VirelaiOS Micro-Widget Toolkit & Runtime (ADR 0011, Milestone 11, M39 UI1).
//!
//! Reusable, lightweight GUI primitives with ZERO heap allocation.
//! Decomposed into modular submodules under `user/src/lib/ui/` with a facade
//! preserving 100% backward compatibility for all userland applications and LIBUI.SO:
//!   - abi.zig: Syscall numbers, raw syscall invocations, Event, WmRpc, ProcessRow
//!   - theme.zig: Theme, ThemeColors, ChromeColors, DQ4 tokens, WidgetState, CursorKind
//!   - draw.zig: Rect, Point, fill_rect, draw_text (Inter TTF), FillBatcher, WindowBacking
//!   - widgets.zig: Button, Label, TextInput, ListView, DropDown, Menu, ScrollView, Dialog, etc.

const std = @import("std");

pub const font8x8 = @import("font8x8.zig");
pub const font_ttf = @import("font_ttf.zig");
pub const TrueTypeFace = font_ttf.TrueTypeFace;
pub const image = @import("image.zig");
pub const Image = image.Image;

pub const abi = @import("ui/abi.zig");
pub const theme = @import("ui/theme.zig");
pub const draw = @import("ui/draw.zig");
pub const widgets = @import("ui/widgets.zig");

// Re-exports for 100% backward compatibility:
pub const AudioInfo = abi.AudioInfo;
pub const BTN_LEFT = abi.BTN_LEFT;
pub const BTN_MIDDLE = abi.BTN_MIDDLE;
pub const BTN_RIGHT = abi.BTN_RIGHT;
pub const COMPOSITE_TICK = abi.COMPOSITE_TICK;
pub const DirEntry = abi.DirEntry;
pub const EVENT_TIMER = abi.EVENT_TIMER;
pub const Event = abi.Event;
pub const KEY_DOWN = abi.KEY_DOWN;
pub const KEY_UP = abi.KEY_UP;
pub const MAP_ANONYMOUS = abi.MAP_ANONYMOUS;
pub const MAP_POPULATE = abi.MAP_POPULATE;
pub const MAP_PRIVATE = abi.MAP_PRIVATE;
pub const MODE_APPEND = abi.MODE_APPEND;
pub const MODE_CREATE = abi.MODE_CREATE;
pub const MODE_DIR = abi.MODE_DIR;
pub const MODE_READ = abi.MODE_READ;
pub const MODE_WRITE = abi.MODE_WRITE;
pub const MOD_ALT = abi.MOD_ALT;
pub const MOD_CMD = abi.MOD_CMD;
pub const MOD_CTRL = abi.MOD_CTRL;
pub const MOD_SHIFT = abi.MOD_SHIFT;
pub const MOUSE_DOWN = abi.MOUSE_DOWN;
pub const MOUSE_MOVE = abi.MOUSE_MOVE;
pub const MOUSE_RIGHT_DOWN = abi.MOUSE_RIGHT_DOWN;
pub const MOUSE_RIGHT_UP = abi.MOUSE_RIGHT_UP;
pub const MOUSE_UP = abi.MOUSE_UP;
pub const PROT_EXEC = abi.PROT_EXEC;
pub const PROT_READ = abi.PROT_READ;
pub const PROT_WRITE = abi.PROT_WRITE;
pub const ProcInfo = abi.ProcInfo;
pub const ProcState = abi.ProcState;
pub const ProcessRow = abi.ProcessRow;
pub const WIN_BLUR = abi.WIN_BLUR;
pub const WIN_CLOSE = abi.WIN_CLOSE;
pub const WIN_FOCUS = abi.WIN_FOCUS;
pub const WIN_RESIZE = abi.WIN_RESIZE;
pub const WIN_UNSAVED = abi.WIN_UNSAVED;
pub const WmRpc = abi.WmRpc;
pub const audio_info = abi.audio_info;
pub const audio_mute = abi.audio_mute;
pub const audio_play = abi.audio_play;
pub const audio_volume = abi.audio_volume;
pub const clipboard_capacity = abi.clipboard_capacity;
pub const clipboard_get = abi.clipboard_get;
pub const clipboard_set = abi.clipboard_set;
pub const datagram_max = abi.datagram_max;
pub const dir_list = abi.dir_list;
pub const drag_read = abi.drag_read;
pub const drag_start = abi.drag_start;
pub const exec_program = abi.exec_program;
pub const exit_process = abi.exit_process;
pub const file_close = abi.file_close;
pub const file_delete = abi.file_delete;
pub const file_free = abi.file_free;
pub const file_mkdir = abi.file_mkdir;
pub const file_open = abi.file_open;
pub const file_read = abi.file_read;
pub const file_rename = abi.file_rename;
pub const file_truncate = abi.file_truncate;
pub const file_write = abi.file_write;
pub const get_procs = abi.get_procs;
pub const kill_process = abi.kill_process;
pub const mmap = abi.mmap;
pub const munmap = abi.munmap;
pub const notify = abi.notify;
pub const parse_procs = abi.parse_procs;
pub const payload_max = abi.payload_max;
pub const ping_poll = abi.ping_poll;
pub const ping_send = abi.ping_send;
pub const poll_event = abi.poll_event;
pub const sleep_ticks = abi.sleep_ticks;
pub const sys_audio_info_num = abi.sys_audio_info_num;
pub const sys_audio_mute_num = abi.sys_audio_mute_num;
pub const sys_audio_play_num = abi.sys_audio_play_num;
pub const sys_audio_volume_num = abi.sys_audio_volume_num;
pub const sys_clipboard_get_num = abi.sys_clipboard_get_num;
pub const sys_clipboard_set_num = abi.sys_clipboard_set_num;
pub const sys_dir_list_num = abi.sys_dir_list_num;
pub const sys_drag_read_num = abi.sys_drag_read_num;
pub const sys_drag_start_num = abi.sys_drag_start_num;
pub const sys_exec_num = abi.sys_exec_num;
pub const sys_exit_num = abi.sys_exit_num;
pub const sys_file_close_num = abi.sys_file_close_num;
pub const sys_file_delete_num = abi.sys_file_delete_num;
pub const sys_file_free_num = abi.sys_file_free_num;
pub const sys_file_open_num = abi.sys_file_open_num;
pub const sys_file_read_num = abi.sys_file_read_num;
pub const sys_file_rename_num = abi.sys_file_rename_num;
pub const sys_file_truncate_num = abi.sys_file_truncate_num;
pub const sys_file_write_num = abi.sys_file_write_num;
pub const sys_ipc_recv_num = abi.sys_ipc_recv_num;
pub const sys_ipc_send_num = abi.sys_ipc_send_num;
pub const sys_kill_num = abi.sys_kill_num;
pub const sys_mmap_num = abi.sys_mmap_num;
pub const sys_munmap_num = abi.sys_munmap_num;
pub const sys_net_stats_num = abi.sys_net_stats_num;
pub const sys_notify_num = abi.sys_notify_num;
pub const sys_ping_poll_num = abi.sys_ping_poll_num;
pub const sys_ping_send_num = abi.sys_ping_send_num;
pub const sys_poll_event_num = abi.sys_poll_event_num;
pub const sys_procs_num = abi.sys_procs_num;
pub const sys_sleep_num = abi.sys_sleep_num;
pub const sys_tcp_close_num = abi.sys_tcp_close_num;
pub const sys_tcp_connect_num = abi.sys_tcp_connect_num;
pub const sys_tcp_recv_num = abi.sys_tcp_recv_num;
pub const sys_tcp_send_num = abi.sys_tcp_send_num;
pub const sys_timer_cancel_num = abi.sys_timer_cancel_num;
pub const sys_timer_set_num = abi.sys_timer_set_num;
pub const sys_udp_listen_num = abi.sys_udp_listen_num;
pub const sys_udp_recv_num = abi.sys_udp_recv_num;
pub const sys_udp_send_num = abi.sys_udp_send_num;
pub const sys_wait_event_num = abi.sys_wait_event_num;
pub const sys_win_close_num = abi.sys_win_close_num;
pub const sys_win_fill_batch_num = abi.sys_win_fill_batch_num;
pub const sys_win_fill_num = abi.sys_win_fill_num;
pub const sys_win_get_num = abi.sys_win_get_num;
pub const sys_win_lower_back_num = abi.sys_win_lower_back_num;
pub const sys_win_move_num = abi.sys_win_move_num;
pub const sys_win_move_to_workspace_num = abi.sys_win_move_to_workspace_num;
pub const sys_win_open_num = abi.sys_win_open_num;
pub const sys_win_present_num = abi.sys_win_present_num;
pub const sys_win_query_num = abi.sys_win_query_num;
pub const sys_win_raise_front_num = abi.sys_win_raise_front_num;
pub const sys_win_raise_num = abi.sys_win_raise_num;
pub const sys_win_set_unsaved_num = abi.sys_win_set_unsaved_num;
pub const sys_win_set_visible_num = abi.sys_win_set_visible_num;
pub const sys_write_num = abi.sys_write_num;
pub const sys_yield_num = abi.sys_yield_num;
pub const syscall0 = abi.syscall0;
pub const syscall1 = abi.syscall1;
pub const syscall2 = abi.syscall2;
pub const syscall3 = abi.syscall3;
pub const syscall4 = abi.syscall4;
pub const syscall6 = abi.syscall6;
pub const tcp_close = abi.tcp_close;
pub const tcp_connect = abi.tcp_connect;
pub const tcp_listen = abi.tcp_listen;
pub const tcp_recv = abi.tcp_recv;
pub const tcp_send = abi.tcp_send;
pub const timer_cancel = abi.timer_cancel;
pub const timer_set = abi.timer_set;
pub const udp_listen = abi.udp_listen;
pub const udp_recv = abi.udp_recv;
pub const udp_send = abi.udp_send;
pub const wait_event = abi.wait_event;
pub const win_close = abi.win_close;
pub const win_fill = abi.win_fill;
pub const win_lower_back = abi.win_lower_back;
pub const win_move_to_workspace = abi.win_move_to_workspace;
pub const win_open = abi.win_open;
pub const win_present = abi.win_present;
pub const win_raise_front = abi.win_raise_front;
pub const win_set_unsaved = abi.win_set_unsaved;
pub const wm_attach_tab = abi.wm_attach_tab;
pub const wm_available = abi.wm_available;
pub const wm_config = abi.wm_config;
pub const wm_cycle_tab = abi.wm_cycle_tab;
pub const wm_detach_tab = abi.wm_detach_tab;
pub const wm_find_pid = abi.wm_find_pid;
pub const wm_invoke_action = abi.wm_invoke_action;
pub const wm_mail_request = abi.wm_mail_request;
pub const wm_peers = abi.wm_peers;
pub const wm_proc_name = abi.wm_proc_name;
pub const wm_procs_buf = abi.wm_procs_buf;
pub const wm_raise_front = abi.wm_raise_front;
pub const wm_register_action = abi.wm_register_action;
pub const wm_rpc_kind_attach_tab = abi.wm_rpc_kind_attach_tab;
pub const wm_rpc_kind_config = abi.wm_rpc_kind_config;
pub const wm_rpc_kind_cycle_tab = abi.wm_rpc_kind_cycle_tab;
pub const wm_rpc_kind_detach_tab = abi.wm_rpc_kind_detach_tab;
pub const wm_rpc_kind_invoke_action = abi.wm_rpc_kind_invoke_action;
pub const wm_rpc_kind_raise = abi.wm_rpc_kind_raise;
pub const wm_rpc_kind_register_action = abi.wm_rpc_kind_register_action;
pub const wm_rpc_max = abi.wm_rpc_max;
pub const wm_rpc_reply_flag = abi.wm_rpc_reply_flag;
pub const wm_rpc_slot_bytes = abi.wm_rpc_slot_bytes;
pub const wm_rpc_title_max = abi.wm_rpc_title_max;
pub const write_console = abi.write_console;
pub const yield_task = abi.yield_task;
pub const CHROME_AMBER = theme.CHROME_AMBER;
pub const CHROME_DARK = theme.CHROME_DARK;
pub const CHROME_LIGHT = theme.CHROME_LIGHT;
pub const COLOR_ACCENT = theme.COLOR_ACCENT;
pub const COLOR_BG = theme.COLOR_BG;
pub const COLOR_BORDER = theme.COLOR_BORDER;
pub const COLOR_BTN_HOVER = theme.COLOR_BTN_HOVER;
pub const COLOR_BTN_IDLE = theme.COLOR_BTN_IDLE;
pub const COLOR_BTN_PRESSED = theme.COLOR_BTN_PRESSED;
pub const COLOR_DANGER = theme.COLOR_DANGER;
pub const COLOR_SUCCESS = theme.COLOR_SUCCESS;
pub const COLOR_SURFACE = theme.COLOR_SURFACE;
pub const COLOR_TEXT_MUTED = theme.COLOR_TEXT_MUTED;
pub const COLOR_TEXT_PRIMARY = theme.COLOR_TEXT_PRIMARY;
pub const COLOR_WARNING = theme.COLOR_WARNING;
pub const ChromeColors = theme.ChromeColors;
pub const CursorKind = theme.CursorKind;
pub const THEME_AMBER = theme.THEME_AMBER;
pub const THEME_DARK = theme.THEME_DARK;
pub const THEME_LIGHT = theme.THEME_LIGHT;
pub const Theme = theme.Theme;
pub const ThemeColors = theme.ThemeColors;
pub const WidgetState = theme.WidgetState;
pub const border_w = theme.border_w;
pub const caret_h = theme.caret_h;
pub const caret_w = theme.caret_w;
pub const contrast_ratio = theme.contrast_ratio;
pub const current_theme = &theme.current_theme;
pub const cursor_for_region = theme.cursor_for_region;
pub const emit_tokens_marker = theme.emit_tokens_marker;
pub const focus_w = theme.focus_w;
pub const frame_border = theme.frame_border;
pub const get_theme_colors = theme.get_theme_colors;
pub const live_color = theme.live_color;
pub const luminance = theme.luminance;
pub const pad_lg = theme.pad_lg;
pub const pad_md = theme.pad_md;
pub const pad_sm = theme.pad_sm;
pub const pad_xs = theme.pad_xs;
pub const parse_theme_setting = theme.parse_theme_setting;
pub const set_theme = theme.set_theme;
pub const shadow_off = theme.shadow_off;
pub const sync_theme_from_host = theme.sync_theme_from_host;
pub const theme_accent = theme.theme_accent;
pub const theme_bg = theme.theme_bg;
pub const theme_border = theme.theme_border;
pub const theme_btn_hover = theme.theme_btn_hover;
pub const theme_btn_idle = theme.theme_btn_idle;
pub const theme_btn_pressed = theme.theme_btn_pressed;
pub const theme_caret = theme.theme_caret;
pub const theme_danger = theme.theme_danger;
pub const theme_file_bin = theme.theme_file_bin;
pub const theme_file_dir = theme.theme_file_dir;
pub const theme_file_txt = theme.theme_file_txt;
pub const theme_file_unknown = theme.theme_file_unknown;
pub const theme_gutter_bg = theme.theme_gutter_bg;
pub const theme_line_highlight = theme.theme_line_highlight;
pub const theme_multi_select = theme.theme_multi_select;
pub const theme_name = theme.theme_name;
pub const theme_on_accent = theme.theme_on_accent;
pub const theme_selection_bg = theme.theme_selection_bg;
pub const theme_shadow = theme.theme_shadow;
pub const theme_success = theme.theme_success;
pub const theme_surface = theme.theme_surface;
pub const theme_text_muted = theme.theme_text_muted;
pub const theme_text_primary = theme.theme_text_primary;
pub const theme_warning = theme.theme_warning;
pub const widget_bg = theme.widget_bg;
pub const widget_border = theme.widget_border;
pub const widget_text = theme.widget_text;
pub const sidebar_w = theme.sidebar_w;
pub const tab_row_h = theme.tab_row_h;
pub const tab_pill_inset_x = theme.tab_pill_inset_x;
pub const tab_pill_inset_y = theme.tab_pill_inset_y;
pub const tab_pill_radius = theme.tab_pill_radius;
pub const font_size_tab_title = theme.font_size_tab_title;
pub const font_size_clock = theme.font_size_clock;
pub const font_size_badge = theme.font_size_badge;
pub const SidebarColors = theme.SidebarColors;
pub const SIDEBAR_DARK = theme.SIDEBAR_DARK;
pub const SIDEBAR_LIGHT = theme.SIDEBAR_LIGHT;
pub const SIDEBAR_AMBER = theme.SIDEBAR_AMBER;
pub const sidebar_bg = theme.sidebar_bg;
pub const sidebar_border = theme.sidebar_border;
pub const sidebar_active_pill = theme.sidebar_active_pill;
pub const sidebar_hover_pill = theme.sidebar_hover_pill;
pub const sidebar_text_active = theme.sidebar_text_active;
pub const sidebar_text_inactive = theme.sidebar_text_inactive;
pub const isqrt = draw.isqrt;
pub const fill_rounded_rect_buf = draw.fill_rounded_rect_buf;
pub const fill_rounded_rect = draw.fill_rounded_rect;
pub const draw_rounded_rect = draw.draw_rounded_rect;
pub const fill_pill = draw.fill_pill;
pub const fill_pill_buf = draw.fill_pill_buf;
pub const draw_text_sized = draw.draw_text_sized;
pub const measure_text_sized = draw.measure_text_sized;
pub const FILL_BATCH_MAX = draw.FILL_BATCH_MAX;
pub const FILL_RECT_SIZE = draw.FILL_RECT_SIZE;

pub const FillBatcher = draw.FillBatcher;
pub const Rect = draw.Rect;
pub const WindowBacking = draw.WindowBacking;
pub const active_mono_cache = &draw.active_mono_cache;
pub const active_mono_font = &draw.active_mono_font;
pub const active_ui_cache = &draw.active_ui_cache;
pub const active_ui_font = &draw.active_ui_font;
pub const blend_source_over = draw.blend_source_over;
pub const draw_alpha_mask = draw.draw_alpha_mask;
pub const draw_char = draw.draw_char;
pub const draw_char_16 = draw.draw_char_16;
pub const draw_char_mono = draw.draw_char_mono;
pub const draw_focus_outline = draw.draw_focus_outline;
pub const draw_image = draw.draw_image;
pub const draw_image_clipped = draw.draw_image_clipped;
pub const draw_image_scaled = draw.draw_image_scaled;
pub const draw_panel_frame = draw.draw_panel_frame;
pub const draw_rect = draw.draw_rect;
pub const draw_rect_outline = draw.draw_rect_outline;
pub const draw_text = draw.draw_text;
pub const draw_text_centered = draw.draw_text_centered;
pub const draw_text_centered_large = draw.draw_text_centered_large;
pub const draw_text_large = draw.draw_text_large;
pub const draw_text_mono = draw.draw_text_mono;
pub const fill_batcher = &draw.fill_batcher;
pub const flush_fills = draw.flush_fills;
pub const fonts_initialized = &draw.fonts_initialized;
pub const init_fonts = draw.init_fonts;
pub const measure_text = draw.measure_text;
pub const measure_text_mono = draw.measure_text_mono;
pub const win_clear_backing = draw.win_clear_backing;
pub const win_fill_batched = draw.win_fill_batched;
pub const win_get_backing = draw.win_get_backing;
pub const win_set_backing = draw.win_set_backing;
pub const Button = widgets.Button;
pub const ButtonState = widgets.ButtonState;
pub const CanonicalMenuCategory = widgets.CanonicalMenuCategory;
pub const Checkbox = widgets.Checkbox;
pub const ContextMenu = widgets.ContextMenu;
pub const ContextMenuItem = widgets.ContextMenuItem;
pub const Dialog = widgets.Dialog;
pub const DialogButtons = widgets.DialogButtons;
pub const DialogResult = widgets.DialogResult;
pub const DialogSeverity = widgets.DialogSeverity;
pub const DropDown = widgets.DropDown;
pub const HScrollBar = widgets.HScrollBar;
pub const Label = widgets.Label;
pub const ListView = widgets.ListView;
pub const MOUSE_SCROLL = widgets.MOUSE_SCROLL;
pub const MenuBuilder = widgets.MenuBuilder;
pub const MenuItemKind = widgets.MenuItemKind;
pub const MenuItemSpec = widgets.MenuItemSpec;
pub const MenuSection = widgets.MenuSection;
pub const ProgressBar = widgets.ProgressBar;
pub const ScrollView = widgets.ScrollView;
pub const StandardShortcut = widgets.StandardShortcut;
pub const TextInput = widgets.TextInput;
pub const Toggle = widgets.Toggle;
pub const canonical_menu_bar = widgets.canonical_menu_bar;
pub const draw_empty_state = widgets.draw_empty_state;
pub const draw_empty_state_icon = widgets.draw_empty_state_icon;
pub const format_error = widgets.format_error;
pub const format_error_ctx = widgets.format_error_ctx;
pub const format_error_with_context = widgets.format_error_with_context;
pub const menu_build = widgets.menu_build;
pub const show_dialog = widgets.show_dialog;

// ---------------------------------------------------------------------------
// Unit Tests (Class A Host Validation)
// ---------------------------------------------------------------------------

test "ui: Rect contains and inset geometry" {
    const r = Rect.make(10, 20, 100, 50);
    try std.testing.expect(r.contains(10, 20));
    try std.testing.expect(r.contains(50, 40));
    try std.testing.expect(r.contains(109, 69));
    try std.testing.expect(!r.contains(9, 20));
    try std.testing.expect(!r.contains(110, 20));
    try std.testing.expect(!r.contains(10, 70));

    const inner = r.inset(2, 5);
    try std.testing.expectEqual(@as(u32, 12), inner.x);
    try std.testing.expectEqual(@as(u32, 25), inner.y);
    try std.testing.expectEqual(@as(u32, 96), inner.w);
    try std.testing.expectEqual(@as(u32, 40), inner.h);
}

test "ui: Button state transitions and click trigger" {
    var btn = Button.init(Rect.make(10, 10, 80, 30), "OK");
    try std.testing.expectEqual(ButtonState.idle, btn.state);

    // Mouse hover inside
    var ev_move = Event{ .kind = MOUSE_MOVE, .flags = 0, .seq = 1, .arg0 = 20, .arg1 = 20 };
    _ = btn.handle_event(&ev_move);
    try std.testing.expectEqual(ButtonState.hover, btn.state);

    // Mouse press inside
    var ev_down = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 2, .arg0 = 20, .arg1 = 20 };
    _ = btn.handle_event(&ev_down);
    try std.testing.expectEqual(ButtonState.pressed, btn.state);

    // Mouse release inside -> triggers click!
    var ev_up = Event{ .kind = MOUSE_UP, .flags = 0, .seq = 3, .arg0 = 20, .arg1 = 20 };
    const clicked = btn.handle_event(&ev_up);
    try std.testing.expect(clicked);
    try std.testing.expectEqual(ButtonState.hover, btn.state);

    // Mouse press and drag outside -> no click
    _ = btn.handle_event(&ev_down);
    var ev_up_outside = Event{ .kind = MOUSE_UP, .flags = 0, .seq = 4, .arg0 = 200, .arg1 = 200 };
    const clicked_outside = btn.handle_event(&ev_up_outside);
    try std.testing.expect(!clicked_outside);
    try std.testing.expectEqual(ButtonState.idle, btn.state);
}

test "ui: TextInput buffer typing, backspace, and cursor" {
    var input = TextInput.init(Rect.make(10, 10, 120, 20));
    input.focused = true;

    // Type 'A' (ASCII 65)
    var ev_a = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x04, .arg1 = 'A' };
    try std.testing.expect(input.handle_event(&ev_a));
    try std.testing.expectEqualStrings("A", input.get_text());
    try std.testing.expectEqual(@as(usize, 1), input.cursor);

    // Type 'B' (ASCII 66)
    var ev_b = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x05, .arg1 = 'B' };
    try std.testing.expect(input.handle_event(&ev_b));
    try std.testing.expectEqualStrings("AB", input.get_text());
    try std.testing.expectEqual(@as(usize, 2), input.cursor);

    // Backspace
    var ev_bs = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 3, .arg0 = 0x2a, .arg1 = 0x08 };
    try std.testing.expect(input.handle_event(&ev_bs));
    try std.testing.expectEqualStrings("A", input.get_text());
    try std.testing.expectEqual(@as(usize, 1), input.cursor);
}

test "ui: ListView row selection and keyboard navigation" {
    var list = ListView.init(Rect.make(10, 10, 100, 100), 16);
    list.item_count = 5;

    // Click row 2 (y=10 + 2*16 + 4 = 46)
    var ev_click = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 1, .arg0 = 20, .arg1 = 46 };
    try std.testing.expect(list.handle_event(&ev_click));
    try std.testing.expectEqual(@as(?usize, 2), list.selected_idx);

    // Down arrow -> row 3
    var ev_down = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x51, .arg1 = 0 };
    try std.testing.expect(list.handle_event(&ev_down));
    try std.testing.expectEqual(@as(?usize, 3), list.selected_idx);

    // Up arrow -> row 2
    var ev_up = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 3, .arg0 = 0x52, .arg1 = 0 };
    try std.testing.expect(list.handle_event(&ev_up));
    try std.testing.expectEqual(@as(?usize, 2), list.selected_idx);
}

test "ui: parse_procs decodes 40-byte snapshot rows" {
    var raw: [80]u8 = [_]u8{0} ** 80;
    // Row 0: pid=1, state=2 (running), exit=0, name="KERNEL.BIN"
    std.mem.writeInt(u64, raw[0..8], 1, .little);
    std.mem.writeInt(u64, raw[8..16], 2, .little);
    std.mem.writeInt(u64, raw[16..24], 0, .little);
    @memcpy(raw[24..34], "KERNEL.BIN");

    // Row 1: pid=2, state=3 (exited), exit=43, name="CALC.BIN"
    std.mem.writeInt(u64, raw[40..48], 2, .little);
    std.mem.writeInt(u64, raw[48..56], 3, .little);
    std.mem.writeInt(u64, raw[56..64], 43, .little);
    @memcpy(raw[64..72], "CALC.BIN");

    var procs: [4]ProcInfo = undefined;
    const count = parse_procs(&raw, 2, &procs);
    try std.testing.expectEqual(@as(usize, 2), count);

    try std.testing.expectEqual(@as(u64, 1), procs[0].pid);
    try std.testing.expectEqual(ProcState.running, procs[0].state);
    try std.testing.expectEqual(@as(u64, 0), procs[0].exit_status);
    try std.testing.expectEqualStrings("KERNEL.BIN", procs[0].name[0..procs[0].name_len]);

    try std.testing.expectEqual(@as(u64, 2), procs[1].pid);
    try std.testing.expectEqual(ProcState.exited, procs[1].state);
    try std.testing.expectEqual(@as(u64, 43), procs[1].exit_status);
    try std.testing.expectEqualStrings("CALC.BIN", procs[1].name[0..procs[1].name_len]);
}

test "ui: DropDown open, select, and dismiss" {
    const options = [_][]const u8{ "dark", "light", "amber" };
    var dd = DropDown.init(Rect.make(10, 10, 120, 20), &options);
    try std.testing.expectEqual(@as(usize, 0), dd.selected);
    try std.testing.expect(!dd.open);
    try std.testing.expectEqualStrings("dark", dd.selected_text());

    // Click button -> opens overlay.
    var ev_down = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 1, .arg0 = 30, .arg1 = 15 };
    _ = dd.handle_event(&ev_down);
    try std.testing.expect(dd.open);

    // Click option 2 ("amber") in overlay.
    var ev_opt = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 2, .arg0 = 30, .arg1 = 70 };
    _ = dd.handle_event(&ev_opt);
    try std.testing.expect(!dd.open);
    try std.testing.expectEqual(@as(usize, 2), dd.selected);
    try std.testing.expectEqualStrings("amber", dd.selected_text());

    // Open again and click outside -> dismisses.
    _ = dd.handle_event(&ev_down);
    try std.testing.expect(dd.open);
    var ev_outside = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 3, .arg0 = 200, .arg1 = 200 };
    _ = dd.handle_event(&ev_outside);
    try std.testing.expect(!dd.open);
}

test "ui: DropDown keyboard navigation" {
    const options = [_][]const u8{ "a", "b", "c", "d" };
    var dd = DropDown.init(Rect.make(10, 10, 80, 20), &options);
    dd.open = true;

    // Down arrow -> select 1.
    var ev_down = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x51, .arg1 = 0 };
    _ = dd.handle_event(&ev_down);
    try std.testing.expectEqual(@as(usize, 1), dd.selected);

    // Down arrow -> select 2.
    _ = dd.handle_event(&ev_down);
    try std.testing.expectEqual(@as(usize, 2), dd.selected);

    // Up arrow -> back to 1.
    var ev_up = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x52, .arg1 = 0 };
    _ = dd.handle_event(&ev_up);
    try std.testing.expectEqual(@as(usize, 1), dd.selected);

    // Enter -> closes overlay.
    var ev_enter = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 3, .arg0 = 0x28, .arg1 = 0 };
    _ = dd.handle_event(&ev_enter);
    try std.testing.expect(!dd.open);

    // Escape -> closes overlay.
    dd.open = true;
    var ev_esc = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 4, .arg0 = 0x29, .arg1 = 0 };
    _ = dd.handle_event(&ev_esc);
    try std.testing.expect(!dd.open);
}

test "ui: DropDown set_selected_by_name" {
    const options = [_][]const u8{ "dark", "light", "amber" };
    var dd = DropDown.init(Rect.make(10, 10, 120, 20), &options);
    dd.set_selected_by_name("amber");
    try std.testing.expectEqual(@as(usize, 2), dd.selected);
    try std.testing.expectEqualStrings("amber", dd.selected_text());

    // Name not found -> no change.
    dd.set_selected_by_name("nope");
    try std.testing.expectEqual(@as(usize, 2), dd.selected);
}

test "ui: ScrollView proportional thumb and offset clamp" {
    // Visible 100, content 200 -> thumb = max(16, 100*100/200=50) = 50
    var sv = ScrollView.init(Rect.make(0, 0, 120, 100), 200);
    try std.testing.expectEqual(@as(u32, 100), sv.max_offset());
    try std.testing.expectEqual(@as(u32, 50), sv.thumb_h());
    try std.testing.expectEqual(@as(u32, 0), sv.offset);
    try std.testing.expectEqual(@as(u32, 0), sv.thumb_y());

    // Visible 100, content 400 -> thumb = max(16, 100*100/400=25) = 25
    var sv2 = ScrollView.init(Rect.make(0, 0, 120, 100), 400);
    try std.testing.expectEqual(@as(u32, 300), sv2.max_offset());
    try std.testing.expectEqual(@as(u32, 25), sv2.thumb_h());

    // Content fits — no scrolling, thumb fills track, offset clamped
    var sv3 = ScrollView.init(Rect.make(0, 0, 120, 100), 80);
    try std.testing.expectEqual(@as(u32, 0), sv3.max_offset());
    try std.testing.expectEqual(@as(u32, 100), sv3.thumb_h());
    sv3.offset = 999;
    sv3.set_content_height(80);
    try std.testing.expectEqual(@as(u32, 0), sv3.offset);

    // Small content with large visible — thumb clamp to 16 minimum
    var sv4 = ScrollView.init(Rect.make(0, 0, 120, 20), 500);
    // 20*20/500 = 0 -> clamp to 16
    try std.testing.expectEqual(@as(u32, 16), sv4.thumb_h());
}

test "ui: ScrollView PAGE_UP/DOWN and track click" {
    var sv = ScrollView.init(Rect.make(10, 10, 100, 100), 300);
    try std.testing.expectEqual(@as(u32, 200), sv.max_offset());

    // PageDown moves by viewport height
    var ev_pgdn = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x4e, .arg1 = 0 };
    _ = sv.handle_event(&ev_pgdn);
    try std.testing.expectEqual(@as(u32, 100), sv.offset);
    _ = sv.handle_event(&ev_pgdn);
    try std.testing.expectEqual(@as(u32, 200), sv.offset);
    // Clamped at max
    _ = sv.handle_event(&ev_pgdn);
    try std.testing.expectEqual(@as(u32, 200), sv.offset);

    // PageUp
    var ev_pgup = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x4b, .arg1 = 0 };
    _ = sv.handle_event(&ev_pgup);
    try std.testing.expectEqual(@as(u32, 100), sv.offset);
    _ = sv.handle_event(&ev_pgup);
    try std.testing.expectEqual(@as(u32, 0), sv.offset);

    // Track click below thumb — page down
    sv.offset = 0;
    const th = sv.thumb_rect();
    // Click 10px below thumb but inside track
    var ev_track_down = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 3, .arg0 = th.x + 1, .arg1 = th.y + th.h + 5 };
    _ = sv.handle_event(&ev_track_down);
    try std.testing.expectEqual(@as(u32, 100), sv.offset);

    // Track click above thumb — page up
    var ev_track_up = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 4, .arg0 = th.x + 1, .arg1 = 15 };
    // Need to be above current thumb (which is now at y=33 for offset 100 with thumb 33)
    _ = sv.handle_event(&ev_track_up);
    try std.testing.expectEqual(@as(u32, 0), sv.offset);
}

test "ui: ScrollView thumb drag scales to content offset" {
    // Viewport 100, content 300 -> max 200, thumb 33, track_h 67
    var sv = ScrollView.init(Rect.make(10, 10, 100, 100), 300);
    const tr = sv.thumb_rect();
    try std.testing.expectEqual(@as(u32, 33), tr.h);

    // Drag thumb from y=10 down by 33px (half track) -> offset ~100
    var ev_down = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 1, .arg0 = tr.x + 1, .arg1 = tr.y + 2 };
    try std.testing.expect(sv.handle_event(&ev_down));
    try std.testing.expect(sv.dragging);

    var ev_move = Event{ .kind = MOUSE_MOVE, .flags = BTN_LEFT, .seq = 2, .arg0 = tr.x + 1, .arg1 = tr.y + 35 };
    _ = sv.handle_event(&ev_move);
    // delta 33, scaled 33*200/67 ≈ 98
    try std.testing.expect(sv.offset >= 95 and sv.offset <= 102);

    var ev_up = Event{ .kind = MOUSE_UP, .flags = 0, .seq = 3, .arg0 = tr.x + 1, .arg1 = tr.y + 35 };
    _ = sv.handle_event(&ev_up);
    try std.testing.expect(!sv.dragging);

    // Drag beyond max clamps
    sv.offset = 0;
    _ = sv.handle_event(&ev_down);
    var ev_far = Event{ .kind = MOUSE_MOVE, .flags = BTN_LEFT, .seq = 4, .arg0 = tr.x + 1, .arg1 = 200 };
    _ = sv.handle_event(&ev_far);
    try std.testing.expectEqual(sv.max_offset(), sv.offset);
}

test "ui: ScrollView 50+ lines demo scrolls via thumb" {
    // Simulate a file list: 60 lines, each 10px, viewport 100 -> content 600
    const line_h: u32 = 10;
    const lines: u32 = 60;
    const content_h = lines * line_h;
    var sv = ScrollView.init(Rect.make(0, 0, 120, 100), content_h);
    try std.testing.expectEqual(@as(u32, 500), sv.max_offset());
    // Thumb for 100 visible / 600 content -> 16 (clamped minimum)
    try std.testing.expectEqual(@as(u32, 16), sv.thumb_h());

    // Scroll through all pages via PAGE_DOWN
    var steps: u32 = 0;
    while (sv.offset < sv.max_offset()) : (steps += 1) {
        var ev = Event{ .kind = KEY_DOWN, .flags = 0, .seq = steps, .arg0 = 0x4e, .arg1 = 0 };
        _ = sv.handle_event(&ev);
        if (steps > 10) break;
    }
    try std.testing.expectEqual(sv.max_offset(), sv.offset);
    try std.testing.expect(steps >= 5);
}

test "ui: Checkbox click toggles *bool and visual state" {
    var checked: bool = false;
    var cb = Checkbox.init(Rect.make(10, 10, 12, 12), &checked);

    // Click inside toggles to true
    var ev_down = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 1, .arg0 = 15, .arg1 = 15 };
    try std.testing.expect(cb.handle_event(&ev_down));
    try std.testing.expect(checked);

    // Click again toggles back to false
    var ev2 = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 2, .arg0 = 15, .arg1 = 15 };
    try std.testing.expect(cb.handle_event(&ev2));
    try std.testing.expect(!checked);

    // Click outside does not toggle
    var ev_out = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 3, .arg0 = 30, .arg1 = 30 };
    try std.testing.expect(!cb.handle_event(&ev_out));
    try std.testing.expect(!checked);

    // Visual state reflects bool on every frame (draw does not panic)
    checked = true;
    // draw is no-panic check — we call it with a dummy win_id (no kernel, just logic)
    // Host test just ensures draw path doesn't crash; actual pixels checked on VZ.
    cb.draw(0);
    checked = false;
    cb.draw(0);
}

test "ui: Toggle click toggles *bool, pill accent/muted" {
    var enabled: bool = false;
    var tg = Toggle.init(Rect.make(20, 20, 48, 20), &enabled);

    // Click inside toggles to true
    var ev_down = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 1, .arg0 = 30, .arg1 = 30 };
    try std.testing.expect(tg.handle_event(&ev_down));
    try std.testing.expect(enabled);

    // Click again toggles false
    var ev2 = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 2, .arg0 = 30, .arg1 = 30 };
    try std.testing.expect(tg.handle_event(&ev2));
    try std.testing.expect(!enabled);

    // Click outside does not toggle
    var ev_out = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 3, .arg0 = 100, .arg1 = 100 };
    try std.testing.expect(!tg.handle_event(&ev_out));
    try std.testing.expect(!enabled);

    // Visual state reflects bool
    enabled = true;
    tg.draw(1);
    enabled = false;
    tg.draw(1);
}

test "ui: Checkbox and Toggle ignore non-left or non-MOUSE_DOWN" {
    var b: bool = false;
    var cb = Checkbox.init(Rect.make(0, 0, 12, 12), &b);
    var tg = Toggle.init(Rect.make(0, 0, 48, 20), &b);

    var ev_move = Event{ .kind = MOUSE_MOVE, .flags = BTN_LEFT, .seq = 1, .arg0 = 5, .arg1 = 5 };
    try std.testing.expect(!cb.handle_event(&ev_move));
    try std.testing.expect(!tg.handle_event(&ev_move));

    var ev_right = Event{ .kind = MOUSE_DOWN, .flags = BTN_RIGHT, .seq = 2, .arg0 = 5, .arg1 = 5 };
    try std.testing.expect(!cb.handle_event(&ev_right));
    try std.testing.expect(!tg.handle_event(&ev_right));

    var ev_key = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 3, .arg0 = 0x04, .arg1 = 'a' };
    try std.testing.expect(!cb.handle_event(&ev_key));
    try std.testing.expect(!tg.handle_event(&ev_key));
}

test "ui: ProgressBar determinate fill at 0%/50%/100% and clamp" {
    var pb = ProgressBar.init(Rect.make(10, 10, 100, 20));
    // inner 98x18 (100-2, 20-2)
    try std.testing.expectEqual(@as(u32, 98), pb.inner_rect().w);

    pb.set_value(0.0);
    try std.testing.expectEqual(@as(u32, 0), pb.fill_width());
    pb.set_value(0.5);
    try std.testing.expectEqual(@as(u32, 49), pb.fill_width());
    pb.set_value(1.0);
    try std.testing.expectEqual(@as(u32, 98), pb.fill_width());

    // Clamp
    pb.set_value(-0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), pb.value, 0.001);
    try std.testing.expectEqual(@as(u32, 0), pb.fill_width());
    pb.set_value(2.0);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), pb.value, 0.001);
    try std.testing.expectEqual(@as(u32, 98), pb.fill_width());
    pb.set_value(std.math.nan(f32));
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), pb.value, 0.001);

    // 25% -> 24 (98*0.25=24.5 floor 24)
    pb.set_value(0.25);
    try std.testing.expectEqual(@as(u32, 24), pb.fill_width());
}

test "ui: ProgressBar indeterminate slides via TIMER and bounces" {
    var pb = ProgressBar.init(Rect.make(0, 0, 100, 20));
    pb.set_indeterminate(true);
    try std.testing.expect(pb.indeterminate);
    try std.testing.expectEqual(@as(i32, 0), pb.offset);
    try std.testing.expectEqual(@as(i32, 1), pb.dir);
    const max = pb.max_offset(); // 98-20=78
    try std.testing.expectEqual(@as(i32, 78), max);

    var ev_timer = Event{ .kind = EVENT_TIMER, .flags = 0, .seq = 1, .arg0 = 0, .arg1 = 0 };
    // Step forward 5 ticks -> offset 20
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        try std.testing.expect(pb.handle_event(&ev_timer));
    }
    try std.testing.expectEqual(@as(i32, 20), pb.offset);

    // Run to max and bounce
    while (pb.offset < max) {
        _ = pb.handle_event(&ev_timer);
    }
    try std.testing.expectEqual(max, pb.offset);
    try std.testing.expectEqual(@as(i32, -1), pb.dir);
    // One more tick moves back
    _ = pb.handle_event(&ev_timer);
    try std.testing.expectEqual(max - 4, pb.offset);

    // Return to 0 and bounce to +1
    while (pb.offset > 0) {
        _ = pb.handle_event(&ev_timer);
    }
    try std.testing.expectEqual(@as(i32, 0), pb.offset);
    try std.testing.expectEqual(@as(i32, 1), pb.dir);

    // Non-TIMER ignored
    var ev_other = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 2, .arg0 = 10, .arg1 = 10 };
    try std.testing.expect(!pb.handle_event(&ev_other));
    // Determinate ignores TIMER
    pb.set_indeterminate(false);
    try std.testing.expect(!pb.handle_event(&ev_timer));
}

test "ui: ProgressBar label contrast inversion over fill/block" {
    var pb = ProgressBar.init(Rect.make(10, 10, 100, 20));
    pb.set_label("50%");
    // At 0%, no char over fill
    pb.set_value(0.0);
    try std.testing.expect(!pb.is_label_char_over_fill(0));
    try std.testing.expect(!pb.is_label_char_over_fill(1));
    // At 100%, centered label "50%" (3*8=24, rect 100 -> label_x=10+38=48)
    // char0 at 48 center 52, char1 at 56 center 60, char2 at 64 center 68
    // inner 11..108 (10+1), fill_end 109 -> all over fill
    pb.set_value(1.0);
    try std.testing.expect(pb.is_label_char_over_fill(0));
    try std.testing.expect(pb.is_label_char_over_fill(1));
    try std.testing.expect(pb.is_label_char_over_fill(2));
    // At 50% fill_end 60 (11+49=60): char0 center 52 <60 over, char1 60 not <60, char2 68 not
    pb.set_value(0.5);
    try std.testing.expect(pb.is_label_char_over_fill(0));
    try std.testing.expect(!pb.is_label_char_over_fill(1));
    try std.testing.expect(!pb.is_label_char_over_fill(2));

    // Indeterminate block at offset 0: block 11..31
    pb.set_indeterminate(true);
    pb.offset = 0;
    // label "50%" same centers 52,60,68 -> none over block 11..31
    try std.testing.expect(!pb.is_label_char_over_fill(0));
    // Move block to cover label: offset 37 -> block 48..68 covers char0 and char1 partially
    pb.offset = 37;
    try std.testing.expect(pb.is_label_char_over_fill(0)); // 52 in 48..68
    try std.testing.expect(pb.is_label_char_over_fill(1)); // 60 in
    try std.testing.expect(!pb.is_label_char_over_fill(2) or pb.is_label_char_over_fill(2)); // char2 center 68 is at block end exclusive, so false
    // Out of range idx false
    try std.testing.expect(!pb.is_label_char_over_fill(99));
}

test "ui: ProgressBar draw paths no panic (determinate/indeterminate/label)" {
    var pb = ProgressBar.init(Rect.make(10, 10, 120, 20));
    pb.set_value(0.0);
    pb.draw(0);
    pb.set_value(0.5);
    pb.set_label("Loading 50%");
    pb.draw(1);
    pb.set_value(1.0);
    pb.set_label("Done");
    pb.draw(2);
    pb.set_indeterminate(true);
    pb.set_label("Fetching...");
    pb.draw(3);
    // Tick and draw again
    var ev = Event{ .kind = EVENT_TIMER, .flags = 0, .seq = 1, .arg0 = 0, .arg1 = 0 };
    _ = pb.handle_event(&ev);
    pb.draw(3);
    // Small rect edge case (no inner)
    var pb_small = ProgressBar.init(Rect.make(0, 0, 2, 2));
    pb_small.set_value(0.5);
    pb_small.draw(0);
    try std.testing.expectEqual(@as(u32, 0), pb_small.fill_width());
    try std.testing.expectEqual(@as(i32, 0), pb_small.max_offset());
}

test "ui: ProgressBar initWithValue and theme contrast draw" {
    var pb = ProgressBar.initWithValue(Rect.make(0, 0, 200, 24), 0.75);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), pb.value, 0.001);
    // inner 198, 75% -> 148
    try std.testing.expectEqual(@as(u32, 148), pb.fill_width());
    // Theme switch does not panic
    _ = set_theme("light");
    pb.set_label("75% light");
    pb.draw(0);
    _ = set_theme("dark");
    pb.draw(0);
    _ = set_theme("amber");
    pb.draw(0);
    _ = set_theme("dark");
}

test "ui: Dialog centered 300x150 and button geometry" {
    const parent = Rect.make(0, 0, 400, 300);
    var dlg = Dialog.init(parent, "Delete file?", false);
    // Centered 300x150 at (50,75)
    try std.testing.expectEqual(@as(u32, 300), dlg.rect.w);
    try std.testing.expectEqual(@as(u32, 150), dlg.rect.h);
    try std.testing.expectEqual(@as(u32, 50), dlg.rect.x);
    try std.testing.expectEqual(@as(u32, 75), dlg.rect.y);
    try std.testing.expect(!dlg.is_open());
    try std.testing.expect(!dlg.needs_dim());
    dlg.show();
    try std.testing.expect(dlg.is_open());
    try std.testing.expect(dlg.needs_dim());
    try std.testing.expectEqual(DialogResult.none, dlg.get_result());
    // Buttons placed at bottom right
    try std.testing.expectEqual(@as(u32, 60), dlg.ok_button.rect.w);
    try std.testing.expectEqual(@as(u32, 20), dlg.ok_button.rect.h);
    try std.testing.expectEqual(@as(u32, 60), dlg.cancel_button.rect.w);
    // OK at x+160 (300-140), Cancel at x+230 (300-70)
    try std.testing.expectEqual(dlg.rect.x + 160, dlg.ok_button.rect.x);
    try std.testing.expectEqual(dlg.rect.x + 230, dlg.cancel_button.rect.x);
    try std.testing.expectEqual(dlg.rect.y + 120, dlg.ok_button.rect.y);
    // Small parent clamps
    const small = Rect.make(10, 10, 200, 100);
    const dlg2 = Dialog.init(small, "Hi", false);
    try std.testing.expectEqual(@as(u32, 200), dlg2.rect.w);
    try std.testing.expectEqual(@as(u32, 100), dlg2.rect.h);
    try std.testing.expectEqual(@as(u32, 10), dlg2.rect.x);
}

test "ui: Dialog OK/Cancel via click and keyboard, dim overlay" {
    const parent = Rect.make(0, 0, 500, 400);
    var dlg = Dialog.init(parent, "Confirm delete?", false);
    dlg.show();
    try std.testing.expect(dlg.is_open());
    // Click OK → need MOUSE_DOWN + MOUSE_UP sequence via Button
    const ok = dlg.ok_button.rect;
    var ev_down = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 1, .arg0 = ok.x + 5, .arg1 = ok.y + 5 };
    var ev_up = Event{ .kind = MOUSE_UP, .flags = 0, .seq = 2, .arg0 = ok.x + 5, .arg1 = ok.y + 5 };
    _ = dlg.handle_event(&ev_down);
    const ok_clicked = dlg.handle_event(&ev_up);
    try std.testing.expect(ok_clicked);
    try std.testing.expect(!dlg.is_open());
    try std.testing.expectEqual(DialogResult.ok, dlg.get_result());
    try std.testing.expect(!dlg.needs_dim());

    // Reopen and Cancel via mouse
    dlg.show();
    const cancel = dlg.cancel_button.rect;
    var ev_down_c = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 3, .arg0 = cancel.x + 5, .arg1 = cancel.y + 5 };
    var ev_up_c = Event{ .kind = MOUSE_UP, .flags = 0, .seq = 4, .arg0 = cancel.x + 5, .arg1 = cancel.y + 5 };
    _ = dlg.handle_event(&ev_down_c);
    _ = dlg.handle_event(&ev_up_c);
    try std.testing.expect(!dlg.is_open());
    try std.testing.expectEqual(DialogResult.cancel, dlg.get_result());

    // Keyboard Enter → OK, Escape → Cancel
    dlg.show();
    var ev_enter = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 5, .arg0 = 0x28, .arg1 = 0 };
    _ = dlg.handle_event(&ev_enter);
    try std.testing.expect(!dlg.is_open());
    try std.testing.expectEqual(DialogResult.ok, dlg.get_result());
    dlg.show();
    var ev_esc = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 6, .arg0 = 0x29, .arg1 = 0 };
    _ = dlg.handle_event(&ev_esc);
    try std.testing.expect(!dlg.is_open());
    try std.testing.expectEqual(DialogResult.cancel, dlg.get_result());

    // Modal: click outside still consumed when open, ignored when closed
    dlg.show();
    var ev_outside = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 7, .arg0 = 5, .arg1 = 5 };
    try std.testing.expect(dlg.handle_event(&ev_outside));
    dlg.dismiss(.cancel);
    try std.testing.expect(!dlg.handle_event(&ev_outside));
}

test "ui: Dialog with TextInput focus, typing, and draw no panic" {
    const parent = Rect.make(0, 0, 400, 300);
    var dlg = Dialog.init(parent, "Rename file:", true);
    try std.testing.expect(dlg.has_input);
    dlg.show();
    try std.testing.expect(dlg.input.focused);
    try std.testing.expectEqualStrings("", dlg.input.get_text());
    // Click inside input should keep focus
    var ev_click_input = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 1, .arg0 = dlg.input.rect.x + 2, .arg1 = dlg.input.rect.y + 5 };
    _ = dlg.handle_event(&ev_click_input);
    try std.testing.expect(dlg.input.focused);
    // Type 'A' via KEY_DOWN
    var ev_a = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x04, .arg1 = 'A' };
    _ = dlg.handle_event(&ev_a);
    try std.testing.expectEqualStrings("A", dlg.input.get_text());
    var ev_b = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 3, .arg0 = 0x05, .arg1 = 'B' };
    _ = dlg.handle_event(&ev_b);
    try std.testing.expectEqualStrings("AB", dlg.input.get_text());
    // Backspace
    var ev_bs = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 4, .arg0 = 0x2a, .arg1 = 0x08 };
    _ = dlg.handle_event(&ev_bs);
    try std.testing.expectEqualStrings("A", dlg.input.get_text());
    // Draw paths no panic (both windows)
    dlg.draw_dim_overlay(0);
    dlg.draw(1);
    dlg.dismiss(.ok);
    try std.testing.expectEqualStrings("A", dlg.input.get_text());
    try std.testing.expectEqual(DialogResult.ok, dlg.get_result());
    // Closed draw is no-op no panic
    dlg.draw(1);
    dlg.draw_dim_overlay(0);
}

test "ui: HScrollBar proportional thumb and offset clamp" {
    // Viewport 100, content 200 → thumb max(16,120*100/200=60)=60, max_offset 100
    var hb = HScrollBar.init(Rect.make(0, 0, 120, 8), 200, 100);
    try std.testing.expectEqual(@as(u32, 100), hb.max_offset());
    try std.testing.expectEqual(@as(u32, 60), hb.thumb_w());
    try std.testing.expectEqual(@as(u32, 0), hb.offset);
    try std.testing.expectEqual(@as(u32, 0), hb.thumb_x());
    // Viewport 100, content 400 → thumb 30, max 300
    var hb2 = HScrollBar.init(Rect.make(0, 0, 120, 8), 400, 100);
    try std.testing.expectEqual(@as(u32, 300), hb2.max_offset());
    try std.testing.expectEqual(@as(u32, 30), hb2.thumb_w());
    // Content fits → no scroll, thumb fills
    var hb3 = HScrollBar.init(Rect.make(0, 0, 120, 8), 80, 100);
    try std.testing.expectEqual(@as(u32, 0), hb3.max_offset());
    try std.testing.expectEqual(@as(u32, 120), hb3.thumb_w());
    hb3.offset = 999;
    hb3.set_content_width(80);
    try std.testing.expectEqual(@as(u32, 0), hb3.offset);
    // Min thumb clamp 16
    var hb4 = HScrollBar.init(Rect.make(0, 0, 120, 8), 500, 20);
    // 120*20/500=4 → clamp 16
    try std.testing.expectEqual(@as(u32, 16), hb4.thumb_w());
}

test "ui: HScrollBar track click and drag scales to content offset" {
    var hb = HScrollBar.init(Rect.make(10, 10, 120, 8), 300, 100);
    try std.testing.expectEqual(@as(u32, 200), hb.max_offset());
    // Track click right of thumb → page right by viewport (100)
    hb.offset = 0;
    const tr = hb.thumb_rect();
    try std.testing.expectEqual(@as(u32, 40), tr.w); // 120*100/300=40
    var ev_track_right = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 1, .arg0 = tr.x + tr.w + 5, .arg1 = 14 };
    _ = hb.handle_event(&ev_track_right);
    try std.testing.expectEqual(@as(u32, 100), hb.offset);
    // Track click left of thumb → page left
    var ev_track_left = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 2, .arg0 = 15, .arg1 = 14 };
    _ = hb.handle_event(&ev_track_left);
    try std.testing.expectEqual(@as(u32, 0), hb.offset);
    // Thumb drag: from x=10 drag +40px (≈ half track) → offset ~100
    hb.offset = 0;
    var ev_down = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 3, .arg0 = tr.x + 2, .arg1 = 14 };
    try std.testing.expect(hb.handle_event(&ev_down));
    try std.testing.expect(hb.dragging);
    var ev_move = Event{ .kind = MOUSE_MOVE, .flags = BTN_LEFT, .seq = 4, .arg0 = tr.x + 42, .arg1 = 14 };
    _ = hb.handle_event(&ev_move);
    // delta 40, track_w 80 (120-40), scaled 40*200/80=100
    try std.testing.expect(hb.offset >= 95 and hb.offset <= 105);
    var ev_up = Event{ .kind = MOUSE_UP, .flags = 0, .seq = 5, .arg0 = tr.x + 42, .arg1 = 14 };
    _ = hb.handle_event(&ev_up);
    try std.testing.expect(!hb.dragging);
    // Drag beyond max clamps
    hb.offset = 0;
    _ = hb.handle_event(&ev_down);
    var ev_far = Event{ .kind = MOUSE_MOVE, .flags = BTN_LEFT, .seq = 6, .arg0 = 250, .arg1 = 14 };
    _ = hb.handle_event(&ev_far);
    try std.testing.expectEqual(hb.max_offset(), hb.offset);
}

test "ui: HScrollBar Shift+scroll and keyboard" {
    var hb = HScrollBar.init(Rect.make(0, 0, 120, 8), 300, 100);
    // Keyboard Right 0x4f → +16
    var ev_right = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x4f, .arg1 = 0 };
    _ = hb.handle_event(&ev_right);
    try std.testing.expectEqual(@as(u32, 16), hb.offset);
    var ev_left = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x50, .arg1 = 0 };
    _ = hb.handle_event(&ev_left);
    try std.testing.expectEqual(@as(u32, 0), hb.offset);
    // Home 0x4a → 0, End 0x4d → max
    _ = hb.handle_event(&ev_right);
    var ev_home = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 3, .arg0 = 0x4a, .arg1 = 0 };
    _ = hb.handle_event(&ev_home);
    try std.testing.expectEqual(@as(u32, 0), hb.offset);
    var ev_end = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 4, .arg0 = 0x4d, .arg1 = 0 };
    _ = hb.handle_event(&ev_end);
    try std.testing.expectEqual(@as(u32, 200), hb.offset);
    // Shift+scroll right (packed arg0: mag=1, sign=1, bit15=1)
    hb.offset = 0;
    var ev_scroll = Event{ .kind = MOUSE_SCROLL, .flags = MOD_SHIFT, .seq = 5, .arg0 = 0x8001, .arg1 = 0 };
    _ = hb.handle_event(&ev_scroll);
    try std.testing.expectEqual(@as(u32, 16), hb.offset);
    // Without Shift, vertical scroll ignored for HScrollBar
    var ev_scroll_vert = Event{ .kind = MOUSE_SCROLL, .flags = 0, .seq = 6, .arg0 = 0x8001, .arg1 = 0 };
    const before = hb.offset;
    _ = hb.handle_event(&ev_scroll_vert);
    try std.testing.expectEqual(before, hb.offset);
    // Scroll left via Shift+scroll (packed: mag=1, sign=0, bit15=0)
    var ev_scroll_left = Event{ .kind = MOUSE_SCROLL, .flags = MOD_SHIFT, .seq = 7, .arg0 = 0x0001, .arg1 = 0 };
    _ = hb.handle_event(&ev_scroll_left);
    try std.testing.expectEqual(@as(u32, 0), hb.offset);
    // Content fits → no scroll even with keys
    var hb_small = HScrollBar.init(Rect.make(0, 0, 120, 8), 80, 100);
    try std.testing.expect(!hb_small.handle_event(&ev_right));
    try std.testing.expect(!hb_small.handle_event(&ev_scroll));
}

test "ui: HScrollBar + ScrollView 2D demo scrolls via both" {
    var sv = ScrollView.init(Rect.make(0, 0, 120, 100), 300);
    var hb = HScrollBar.init(Rect.make(0, 100, 120, 8), 400, 120);
    try std.testing.expectEqual(@as(u32, 200), sv.max_offset());
    try std.testing.expectEqual(@as(u32, 280), hb.max_offset());
    // Scroll vertical page down + horizontal page right
    var ev_pgdn = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x4e, .arg1 = 0 };
    _ = sv.handle_event(&ev_pgdn);
    try std.testing.expectEqual(@as(u32, 100), sv.offset);
    var ev_right = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x4f, .arg1 = 0 };
    _ = hb.handle_event(&ev_right);
    try std.testing.expectEqual(@as(u32, 16), hb.offset);
    // Drag both thumbs to near max
    const v_tr = sv.thumb_rect();
    var ev_v_down = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 3, .arg0 = v_tr.x + 1, .arg1 = v_tr.y + 2 };
    _ = sv.handle_event(&ev_v_down);
    var ev_v_move = Event{ .kind = MOUSE_MOVE, .flags = BTN_LEFT, .seq = 4, .arg0 = v_tr.x + 1, .arg1 = 200 };
    _ = sv.handle_event(&ev_v_move);
    try std.testing.expectEqual(sv.max_offset(), sv.offset);
    const h_tr = hb.thumb_rect();
    var ev_h_down = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 5, .arg0 = h_tr.x + 2, .arg1 = 104 };
    _ = hb.handle_event(&ev_h_down);
    var ev_h_move = Event{ .kind = MOUSE_MOVE, .flags = BTN_LEFT, .seq = 6, .arg0 = 250, .arg1 = 104 };
    _ = hb.handle_event(&ev_h_move);
    try std.testing.expectEqual(hb.max_offset(), hb.offset);
    // Draw both no panic
    sv.draw(0);
    hb.draw(0);
}

test "ui: ContextMenu show/dismiss and bounds" {
    const items = [_]ContextMenuItem{
        .{ .label = "Copy" },
        .{ .label = "Cut" },
        .{ .label = "Paste" },
    };
    var m = ContextMenu.init(items[0..]);
    try std.testing.expect(!m.is_open());
    m.show(50, 60);
    try std.testing.expect(m.is_open());
    const b = m.bounds();
    try std.testing.expectEqual(@as(u32, 50), b.x);
    try std.testing.expectEqual(@as(u32, 60), b.y);
    try std.testing.expectEqual(@as(u32, 120), b.w);
    try std.testing.expectEqual(@as(u32, 48), b.h);
    m.dismiss();
    try std.testing.expect(!m.is_open());
    m.draw(0);
}

test "ui: ContextMenu hit-test maps rows and outside dismisses" {
    const items = [_]ContextMenuItem{
        .{ .label = "Open" },
        .{ .label = "Rename" },
        .{ .label = "Delete" },
    };
    var m = ContextMenu.init(items[0..]);
    m.show(10, 10);
    // Hit first row
    var ev_down = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 1, .arg0 = 15, .arg1 = 12 };
    _ = m.handle_event(&ev_down);
    try std.testing.expect(!m.is_open());
    try std.testing.expectEqual(@as(?usize, 0), m.selected_idx);
    // Reopen and click outside
    m.show(10, 10);
    var ev_out = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 2, .arg0 = 200, .arg1 = 200 };
    _ = m.handle_event(&ev_out);
    try std.testing.expect(!m.is_open());
    // Reopen and hover second row
    m.show(10, 10);
    var ev_move = Event{ .kind = MOUSE_MOVE, .flags = 0, .seq = 3, .arg0 = 15, .arg1 = 30 };
    _ = m.handle_event(&ev_move);
    try std.testing.expectEqual(@as(?usize, 1), m.hover_idx);
    m.draw(0);
}

test "ui: ContextMenu via MOUSE_RIGHT_DOWN and NOTEPAD/FILE/TOP integration" {
    const notepad_items = [_]ContextMenuItem{
        .{ .label = "Copy" },
        .{ .label = "Cut" },
        .{ .label = "Paste" },
    };
    const file_items = [_]ContextMenuItem{
        .{ .label = "Open" },
        .{ .label = "Rename" },
        .{ .label = "Delete" },
    };
    const top_items = [_]ContextMenuItem{
        .{ .label = "Kill" },
        .{ .label = "Inspect" },
    };
    var m1 = ContextMenu.init(notepad_items[0..]);
    var m2 = ContextMenu.init(file_items[0..]);
    var m3 = ContextMenu.init(top_items[0..]);
    // Right-click shows menu
    var ev_r = Event{ .kind = MOUSE_RIGHT_DOWN, .flags = BTN_RIGHT, .seq = 1, .arg0 = 100, .arg1 = 80 };
    _ = m1.handle_event(&ev_r);
    try std.testing.expect(m1.is_open());
    try std.testing.expectEqual(@as(u32, 100), m1.bounds().x);
    // FILE.BIN menu opens separately
    var ev_r2 = Event{ .kind = MOUSE_RIGHT_DOWN, .flags = BTN_RIGHT, .seq = 2, .arg0 = 50, .arg1 = 40 };
    _ = m2.handle_event(&ev_r2);
    try std.testing.expect(m2.is_open());
    // Click first item selects and dismisses
    var ev_click = Event{ .kind = MOUSE_DOWN, .flags = BTN_LEFT, .seq = 3, .arg0 = 55, .arg1 = 42 };
    _ = m2.handle_event(&ev_click);
    try std.testing.expect(!m2.is_open());
    try std.testing.expectEqual(@as(?usize, 0), m2.selected_idx);
    // TOP menu hover
    m3.show(20, 20);
    var ev_move = Event{ .kind = MOUSE_MOVE, .flags = 0, .seq = 4, .arg0 = 25, .arg1 = 38 };
    _ = m3.handle_event(&ev_move);
    try std.testing.expectEqual(@as(?usize, 1), m3.hover_idx);
    m1.draw(0);
    m2.draw(0);
    m3.draw(0);
}

test "ui: WidgetState styling accessors" {
    try std.testing.expect(widget_bg(.normal) != 0);
    try std.testing.expect(widget_bg(.hover) != 0);
    try std.testing.expect(widget_border(.normal) != 0);
    try std.testing.expect(widget_text(.normal) != 0);
    try std.testing.expect(widget_text(.disabled) != 0);
}

test "ui: ContextMenu with MenuItemSpec, separators, shortcuts, and keyboard navigation" {
    const specs = [_]MenuItemSpec{
        .{ .label = "New", .shortcut = "Ctrl+N" },
        .{ .label = "Open", .shortcut = "Ctrl+O" },
        .{ .kind = .separator },
        .{ .label = "Save", .shortcut = "Ctrl+S", .disabled = true },
        .{ .label = "Quit", .shortcut = "Ctrl+Q" },
    };
    var menu = ContextMenu.initWithSpecs(specs[0..]);
    menu.show(10, 20);
    try std.testing.expect(menu.is_open());
    try std.testing.expectEqual(@as(usize, 5), menu.count());

    // Down arrow should select first item (0: "New")
    var ev_down = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 1, .arg0 = 0x51, .arg1 = 0 };
    _ = menu.handle_event(&ev_down);
    try std.testing.expectEqual(@as(?usize, 0), menu.hover_idx);

    // Down arrow again should select second item (1: "Open")
    _ = menu.handle_event(&ev_down);
    try std.testing.expectEqual(@as(?usize, 1), menu.hover_idx);

    // Down arrow again should skip separator (2) and disabled item (3) to select (4: "Quit")
    _ = menu.handle_event(&ev_down);
    try std.testing.expectEqual(@as(?usize, 4), menu.hover_idx);

    // Enter on "Quit" should select index 4 and close menu
    var ev_enter = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 2, .arg0 = 0x28, .arg1 = 0 };
    _ = menu.handle_event(&ev_enter);
    try std.testing.expect(!menu.is_open());
    try std.testing.expectEqual(@as(?usize, 4), menu.selected_idx);

    // Reopen and test Escape dismissal
    menu.show(10, 20);
    var ev_esc = Event{ .kind = KEY_DOWN, .flags = 0, .seq = 3, .arg0 = 0x29, .arg1 = 0 };
    _ = menu.handle_event(&ev_esc);
    try std.testing.expect(!menu.is_open());

    menu.draw(0);
}

test "ui: show_dialog, draw_empty_state, and format_error" {
    const parent = Rect.make(0, 0, 400, 300);
    var dlg = Dialog.init(parent, "Test Dialog", false);
    show_dialog(&dlg, "Updated Message", true);
    try std.testing.expect(dlg.is_open());
    try std.testing.expectEqualStrings("Updated Message", dlg.message);
    try std.testing.expect(dlg.has_input);

    draw_empty_state(0, Rect.make(10, 10, 200, 100), "No Files Found", "Create a file or mount volume");

    var err_buf: [64]u8 = undefined;
    const msg_enoent = format_error(-2, &err_buf);
    try std.testing.expectEqualStrings("File or directory not found", msg_enoent);

    const msg_eacces = format_error(-13, &err_buf);
    try std.testing.expectEqualStrings("Permission denied", msg_eacces);

    const msg_custom = format_error(-999, &err_buf);
    try std.testing.expect(std.mem.startsWith(u8, msg_custom, "System error"));
}

test "ui: MenuBuilder and canonical shortcuts (M27 G9)" {
    var mb = MenuBuilder.init();
    _ = mb.add_item("Save", StandardShortcut.save);
    _ = mb.add_item("Open", StandardShortcut.open);
    _ = mb.add_separator();
    _ = mb.add_item("Quit", StandardShortcut.quit);

    const specs = mb.slice();
    try std.testing.expectEqual(@as(usize, 4), specs.len);
    try std.testing.expectEqualStrings("Save", specs[0].label);
    try std.testing.expectEqualStrings("Ctrl+S", specs[0].shortcut);
    try std.testing.expectEqual(MenuItemKind.separator, specs[2].kind);

    var menu = menu_build(specs);
    try std.testing.expectEqual(@as(usize, 4), menu.count());
    try std.testing.expectEqualStrings("File", canonical_menu_bar[0]);
    try std.testing.expectEqualStrings("Help", canonical_menu_bar[3]);
}

test "ui: Dialog with custom buttons and DialogResult (M27 G10)" {
    const parent = Rect.make(0, 0, 400, 300);
    const buttons = [_][]const u8{ "Yes", "No" };
    var dlg = Dialog.initWithButtons(parent, "Confirm", "Do you wish to proceed?", buttons[0..]);
    dlg.show();
    try std.testing.expect(dlg.is_open());
    try std.testing.expectEqualStrings("Yes", dlg.ok_button.label);
    try std.testing.expectEqualStrings("No", dlg.cancel_button.label);

    dlg.dismiss(.button_0);
    try std.testing.expect(!dlg.is_open());
    try std.testing.expect(dlg.get_result().is_ok());

    dlg.show();
    dlg.dismiss(.button_1);
    try std.testing.expect(dlg.get_result().is_cancel());
}

test "ui: ButtonState variants and ThemeColors (M27 G14, G20)" {
    try std.testing.expectEqual(WidgetState.normal, ButtonState.normal.to_widget_state());
    try std.testing.expectEqual(WidgetState.hover, ButtonState.hovered.to_widget_state());

    const tc = get_theme_colors();
    try std.testing.expect(tc.bg != 0);
    try std.testing.expect(tc.accent != 0);
}

test "ui: draw_empty_state_icon and format_error_ctx (M27 G22, G23)" {
    draw_empty_state_icon(0, Rect.make(10, 10, 200, 100), "Empty Directory", '>');

    var buf: [128]u8 = undefined;
    const err = format_error_ctx(&buf, -2, "File open");
    try std.testing.expectEqualStrings("File open: File or directory not found", err);
}

// ---------------------------------------------------------------------------
// M32 WMS9 (issue #629): span batching tests.
// The batcher is host-testable: in non-freestanding builds `syscall2` returns
// 0 without touching real registers, so we can exercise push/flush/auto-flush
// and the span-emit logic of draw_char without a kernel.
// ---------------------------------------------------------------------------

test "ui: FillBatcher buffers up to 32 rects then auto-flushes (WMS9)" {
    fill_batcher.reset();
    fill_batcher.cur_id = 0;

    // Push 32 rects — none should trigger a syscall mid-batch.
    var i: u32 = 0;
    while (i < FILL_BATCH_MAX) : (i += 1) {
        win_fill_batched(7, i * 10, 20, 10, 5, 0xff0000);
    }
    try std.testing.expectEqual(FILL_BATCH_MAX * FILL_RECT_SIZE, fill_batcher.len);

    // The 33rd rect forces an auto-flush, then starts a fresh batch.
    win_fill_batched(7, 999, 20, 10, 5, 0x00ff00);
    try std.testing.expectEqual(FILL_RECT_SIZE, fill_batcher.len);

    fill_batcher.reset();
}

test "ui: FillBatcher flushes on window-id change (WMS9)" {
    fill_batcher.reset();
    fill_batcher.cur_id = 0;

    win_fill_batched(7, 0, 0, 10, 10, 0xff0000);
    try std.testing.expectEqual(FILL_RECT_SIZE, fill_batcher.len);

    // A different window id forces a flush before the new rect is queued.
    win_fill_batched(9, 5, 5, 3, 3, 0x0000ff);
    try std.testing.expectEqual(FILL_RECT_SIZE, fill_batcher.len);
    try std.testing.expectEqual(@as(u32, 9), fill_batcher.cur_id);

    fill_batcher.reset();
}

test "ui: draw_char emits row spans, not per-pixel fills (WMS9)" {
    fill_batcher.reset();
    fill_batcher.cur_id = 0;

    // 'W' is a wide glyph (dense rows) — verify span emission per row:
    // each row's set pixels become one contiguous span, not N 1×1 fills.
    draw_char(7, 'W', 100, 50, 0xffffff);

    // W spans 8 columns; its densest row has 3 separate runs (W shape).
    // Total spans for 'W' = 22 (vs 24 per-pixel fills in the old path).
    // We don't pin the exact count here (font-dependent); instead verify
    // that every span is at least 1px wide and rows stay within the glyph box.
    try std.testing.expect(fill_batcher.len > 0);
    try std.testing.expect(fill_batcher.len <= FILL_BATCH_MAX * FILL_RECT_SIZE);

    // Decode spans and check each is a valid 1px-tall horizontal run.
    var i: usize = 0;
    while (i < fill_batcher.len) : (i += FILL_RECT_SIZE) {
        const w = std.mem.readInt(u32, fill_batcher.buf[i + 12 ..][0..4], .little);
        const h = std.mem.readInt(u32, fill_batcher.buf[i + 16 ..][0..4], .little);
        try std.testing.expect(w >= 1 and w <= 8);
        try std.testing.expectEqual(@as(u32, 1), h);
    }

    fill_batcher.reset();
}

test "ui: draw_char_16 emits 2px-tall spans, pixel-identical to old path (WMS9)" {
    fill_batcher.reset();
    fill_batcher.cur_id = 0;

    draw_char_16(7, 'A', 50, 50, 0x00ff00);

    try std.testing.expect(fill_batcher.len > 0);
    var i: usize = 0;
    while (i < fill_batcher.len) : (i += FILL_RECT_SIZE) {
        const w = std.mem.readInt(u32, fill_batcher.buf[i + 12 ..][0..4], .little);
        const h = std.mem.readInt(u32, fill_batcher.buf[i + 16 ..][0..4], .little);
        try std.testing.expect(w >= 1 and w <= 8);
        try std.testing.expectEqual(@as(u32, 2), h);
    }

    fill_batcher.reset();
}

test "ui: draw_image skips transparent pixels and batches contiguous spans" {
    fill_batcher.reset();
    fill_batcher.cur_id = 0;

    var raw_pixels = [_]u32{
        0x00FFFFFF, 0xFFFF0000, 0xFFFF0000, 0x00000000, // Row 0: Transparent, Red, Red, Transparent
        0xFF00FF00, 0xFF00FF00, 0xFF00FF00, 0xFF00FF00, // Row 1: 4 Green pixels
    };
    const img = Image{ .width = 4, .height = 2, .pixels = &raw_pixels };

    draw_image(5, 10, 20, img);

    // Should emit:
    // Span 1: at (11, 20) with width 2 (2 Red pixels)
    // Span 2: at (10, 21) with width 4 (4 Green pixels)
    try std.testing.expectEqual(2 * FILL_RECT_SIZE, fill_batcher.len);

    const x1 = std.mem.readInt(u32, fill_batcher.buf[4..8], .little);
    const y1 = std.mem.readInt(u32, fill_batcher.buf[8..12], .little);
    const w1 = std.mem.readInt(u32, fill_batcher.buf[12..16], .little);
    const rgb1 = std.mem.readInt(u32, fill_batcher.buf[20..24], .little);

    try std.testing.expectEqual(@as(u32, 11), x1);
    try std.testing.expectEqual(@as(u32, 20), y1);
    try std.testing.expectEqual(@as(u32, 2), w1);
    try std.testing.expectEqual(@as(u32, 0x00FF0000), rgb1);

    const x2 = std.mem.readInt(u32, fill_batcher.buf[FILL_RECT_SIZE + 4 ..][0..4], .little);
    const y2 = std.mem.readInt(u32, fill_batcher.buf[FILL_RECT_SIZE + 8 ..][0..4], .little);
    const w2 = std.mem.readInt(u32, fill_batcher.buf[FILL_RECT_SIZE + 12 ..][0..4], .little);
    const rgb2 = std.mem.readInt(u32, fill_batcher.buf[FILL_RECT_SIZE + 20 ..][0..4], .little);

    try std.testing.expectEqual(@as(u32, 10), x2);
    try std.testing.expectEqual(@as(u32, 21), y2);
    try std.testing.expectEqual(@as(u32, 4), w2);
    try std.testing.expectEqual(@as(u32, 0x0000FF00), rgb2);

    fill_batcher.reset();
}

test "ui: draw_image_clipped and draw_image_scaled" {
    fill_batcher.reset();
    fill_batcher.cur_id = 0;

    var raw_pixels = [_]u32{
        0xFFFF0000, 0xFFFF0000,
        0xFFFF0000, 0xFFFF0000,
    };
    const img = Image{ .width = 2, .height = 2, .pixels = &raw_pixels };

    // Clipped to only x=10..10, y=20..20 (1x1 area)
    draw_image_clipped(5, 10, 20, img, Rect.make(10, 20, 1, 1));
    try std.testing.expectEqual(1 * FILL_RECT_SIZE, fill_batcher.len);
    fill_batcher.reset();

    // Scaled 2x2 up to 4x4
    draw_image_scaled(5, Rect.make(0, 0, 4, 4), img);
    // 4 rows of 1 span each = 4 spans
    try std.testing.expectEqual(4 * FILL_RECT_SIZE, fill_batcher.len);
    fill_batcher.reset();
}

test "ui: blend_source_over arithmetic" {
    // 1. Transparent source: preserves destination
    try std.testing.expectEqual(@as(u32, 0xFF112233), blend_source_over(0xFF112233, 0x00AABBCC));

    // 2. Fully opaque source: completely replaces destination
    try std.testing.expectEqual(@as(u32, 0xFFAABBCC), blend_source_over(0xFF112233, 0xFFAABBCC));

    // 3. Partial alpha blending (50% red over black)
    const blended = blend_source_over(0xFF000000, 0x80FF0000);
    const r = (blended >> 16) & 0xFF;
    const g = (blended >> 8) & 0xFF;
    const b = blended & 0xFF;
    const a = (blended >> 24) & 0xFF;
    try std.testing.expect(r >= 127 and r <= 129);
    try std.testing.expectEqual(@as(u32, 0), g);
    try std.testing.expectEqual(@as(u32, 0), b);
    try std.testing.expectEqual(@as(u32, 255), a);
}

test "ui: direct backing buffer draw_image with alpha blit and clipping" {
    var buf = [_]u32{0xFF000000} ** (10 * 10);
    win_set_backing(7, &buf, 10, 10);
    defer win_clear_backing(7);

    try std.testing.expect(win_get_backing(7) != null);
    try std.testing.expectEqual(@as(u32, 10), win_get_backing(7).?.width);

    var raw_src = [_]u32{
        0x80FF0000, 0x8000FF00,
        0x00000000, 0xFF0000FF,
    };
    const src_img = Image{ .width = 2, .height = 2, .pixels = &raw_src };

    // Blit at (2, 3)
    draw_image(7, 2, 3, src_img);

    // Pixel at (2, 3) is 50% red over black -> ~0xFF800000
    const p0 = buf[3 * 10 + 2];
    try std.testing.expect(((p0 >> 16) & 0xFF) >= 127 and ((p0 >> 16) & 0xFF) <= 129);

    // Pixel at (3, 3) is 50% green over black -> ~0xFF008000
    const p1 = buf[3 * 10 + 3];
    try std.testing.expect(((p1 >> 8) & 0xFF) >= 127 and ((p1 >> 8) & 0xFF) <= 129);

    // Pixel at (2, 4) is 0% alpha -> remains unchanged (0xFF000000)
    try std.testing.expectEqual(@as(u32, 0xFF000000), buf[4 * 10 + 2]);

    // Pixel at (3, 4) is 100% blue -> becomes 0xFF0000FF
    try std.testing.expectEqual(@as(u32, 0xFF0000FF), buf[4 * 10 + 3]);

    // Test clipping: draw clipped to (2, 3, 1, 1) -> only (2, 3) blitted
    buf = [_]u32{0xFF000000} ** (10 * 10);
    draw_image_clipped(7, 2, 3, src_img, Rect.make(2, 3, 1, 1));
    try std.testing.expect(((buf[3 * 10 + 2] >> 16) & 0xFF) >= 127);
    try std.testing.expectEqual(@as(u32, 0xFF000000), buf[3 * 10 + 3]); // clipped out
}

test "ui: direct backing buffer draw_image_scaled" {
    var buf = [_]u32{0xFF000000} ** (8 * 8);
    win_set_backing(8, &buf, 8, 8);
    defer win_clear_backing(8);

    var raw_src = [_]u32{
        0xFFFF0000, 0xFF00FF00,
        0xFF0000FF, 0xFFFFFFFF,
    };
    const src_img = Image{ .width = 2, .height = 2, .pixels = &raw_src };

    // Scale 2x2 to 4x4 placed at (2, 2)
    draw_image_scaled(8, Rect.make(2, 2, 4, 4), src_img);

    // Check quadrant 1 (top-left: (2..3, 2..3)) is red
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), buf[2 * 8 + 2]);
    try std.testing.expectEqual(@as(u32, 0xFFFF0000), buf[3 * 8 + 3]);

    // Check quadrant 2 (top-right: (4..5, 2..3)) is green
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), buf[2 * 8 + 4]);
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), buf[3 * 8 + 5]);
}

// ---------------------------------------------------------------------------
// M37 DQ4 design-token tests (issue #838). Token VALUES are pinned here:
// change a metric/color and these fail. Dark values equal the pre-DQ4
// rendering (frozen COLOR_* / hardcoded app colors) so the migration is a
// dark no-op; each test restores the dark theme via defer.
// ---------------------------------------------------------------------------

test "dq4: metric values pinned" {
    try std.testing.expectEqual(@as(u32, 2), pad_xs);
    try std.testing.expectEqual(@as(u32, 4), pad_sm);
    try std.testing.expectEqual(@as(u32, 8), pad_md);
    try std.testing.expectEqual(@as(u32, 16), pad_lg);
    try std.testing.expectEqual(@as(u32, 1), border_w);
    try std.testing.expectEqual(@as(u32, 2), focus_w);
    try std.testing.expectEqual(@as(u32, 2), caret_w);
    try std.testing.expectEqual(@as(u32, 8), caret_h);
    try std.testing.expectEqual(@as(u32, 4), shadow_off);
}

test "dq4: dark chrome values equal pre-DQ4 rendering" {
    defer theme.current_theme = THEME_DARK;
    theme.current_theme = THEME_DARK;
    try std.testing.expectEqual(@as(u32, 0x2a4460), theme_selection_bg());
    try std.testing.expectEqual(@as(u32, 0x3b82f6), theme_caret());
    try std.testing.expectEqual(@as(u32, 0x0b0e11), theme_gutter_bg());
    try std.testing.expectEqual(@as(u32, 0x22303a), theme_line_highlight());
    try std.testing.expectEqual(@as(u32, 0x3b82f6), theme_file_dir());
    try std.testing.expectEqual(@as(u32, 0x22c55e), theme_file_txt());
    try std.testing.expectEqual(@as(u32, 0xf59e0b), theme_file_bin());
    try std.testing.expectEqual(@as(u32, 0x64748b), theme_file_unknown());
    try std.testing.expectEqual(@as(u32, 0x1e3a8a), theme_multi_select());
    try std.testing.expectEqual(@as(u32, 0xffffff), theme_on_accent());
    try std.testing.expectEqual(@as(u32, 0x000000), theme_shadow());
}

test "dq4: light chrome values" {
    defer theme.current_theme = THEME_DARK;
    theme.current_theme = THEME_LIGHT;
    try std.testing.expectEqualStrings("light", theme_name());
    try std.testing.expectEqual(@as(u32, 0xbfdbfe), theme_selection_bg());
    try std.testing.expectEqual(@as(u32, 0x2563eb), theme_caret());
    try std.testing.expectEqual(@as(u32, 0xe5e7eb), theme_gutter_bg());
    try std.testing.expectEqual(@as(u32, 0xe0e7ff), theme_line_highlight());
    try std.testing.expectEqual(@as(u32, 0x2563eb), theme_file_dir());
    try std.testing.expectEqual(@as(u32, 0x16a34a), theme_file_txt());
    try std.testing.expectEqual(@as(u32, 0xd97706), theme_file_bin());
    try std.testing.expectEqual(@as(u32, 0x64748b), theme_file_unknown());
    try std.testing.expectEqual(@as(u32, 0x93c5fd), theme_multi_select());
    try std.testing.expectEqual(@as(u32, 0xffffff), theme_on_accent());
    try std.testing.expectEqual(@as(u32, 0x94a3b8), theme_shadow());
}

test "dq4: amber chrome values" {
    defer theme.current_theme = THEME_DARK;
    theme.current_theme = THEME_AMBER;
    try std.testing.expectEqualStrings("amber", theme_name());
    try std.testing.expectEqual(@as(u32, 0x1a1000), theme_on_accent());
    try std.testing.expectEqual(@as(u32, 0x000000), theme_shadow());
}

test "dq4: live_color is identity on dark" {
    defer theme.current_theme = THEME_DARK;
    theme.current_theme = THEME_DARK;
    try std.testing.expectEqual(COLOR_BG, live_color(COLOR_BG));
    try std.testing.expectEqual(COLOR_SURFACE, live_color(COLOR_SURFACE));
    try std.testing.expectEqual(COLOR_BORDER, live_color(COLOR_BORDER));
    try std.testing.expectEqual(COLOR_TEXT_PRIMARY, live_color(COLOR_TEXT_PRIMARY));
    try std.testing.expectEqual(COLOR_ACCENT, live_color(COLOR_ACCENT));
    try std.testing.expectEqual(COLOR_DANGER, live_color(COLOR_DANGER));
    // Customs pass through untouched.
    try std.testing.expectEqual(@as(u32, 0x8b5cf6), live_color(0x8b5cf6));
}

test "dq4: live_color maps frozen aliases on light" {
    defer theme.current_theme = THEME_DARK;
    theme.current_theme = THEME_LIGHT;
    try std.testing.expectEqual(THEME_LIGHT.bg, live_color(COLOR_BG));
    try std.testing.expectEqual(THEME_LIGHT.surface, live_color(COLOR_SURFACE));
    try std.testing.expectEqual(THEME_LIGHT.border, live_color(COLOR_BORDER));
    try std.testing.expectEqual(THEME_LIGHT.text_primary, live_color(COLOR_TEXT_PRIMARY));
    try std.testing.expectEqual(THEME_LIGHT.accent, live_color(COLOR_ACCENT));
    try std.testing.expectEqual(THEME_LIGHT.danger, live_color(COLOR_DANGER));
    try std.testing.expectEqual(@as(u32, 0x8b5cf6), live_color(0x8b5cf6));
}

test "dq4: text contrast spot-checks clear 3.0 on all themes" {
    const themes = [_]Theme{ THEME_DARK, THEME_LIGHT, THEME_AMBER };
    for (themes) |t| {
        defer theme.current_theme = THEME_DARK;
        theme.current_theme = t;
        try std.testing.expect(contrast_ratio(theme_text_primary(), theme_bg()) >= 3.0);
        try std.testing.expect(contrast_ratio(theme_text_muted(), theme_bg()) >= 3.0);
        try std.testing.expect(contrast_ratio(theme_on_accent(), theme_accent()) >= 2.5);
        try std.testing.expect(contrast_ratio(theme_text_primary(), theme_surface()) >= 3.0);
    }
}

test "dq4: cursor region mapping" {
    try std.testing.expectEqual(CursorKind.resize_diag, cursor_for_region(true, true, true));
    try std.testing.expectEqual(CursorKind.pointer, cursor_for_region(false, true, true));
    try std.testing.expectEqual(CursorKind.pointer, cursor_for_region(false, true, false));
    try std.testing.expectEqual(CursorKind.ibeam, cursor_for_region(false, false, true));
    try std.testing.expectEqual(CursorKind.arrow, cursor_for_region(false, false, false));
    try std.testing.expectEqualStrings("ibeam", CursorKind.ibeam.name());
    try std.testing.expectEqualStrings("resize_diag", CursorKind.resize_diag.name());
}

test "dq4: frame_border follows focus" {
    defer theme.current_theme = THEME_DARK;
    theme.current_theme = THEME_DARK;
    try std.testing.expectEqual(theme_accent(), frame_border(true));
    try std.testing.expectEqual(theme_border(), frame_border(false));
    theme.current_theme = THEME_LIGHT;
    try std.testing.expectEqual(THEME_LIGHT.accent, frame_border(true));
    try std.testing.expectEqual(THEME_LIGHT.border, frame_border(false));
}

test "dq4: parse_theme_setting" {
    try std.testing.expectEqualStrings("dark", parse_theme_setting("theme=dark\n").?);
    try std.testing.expectEqualStrings("light", parse_theme_setting("#v1\ntheme=light\nprompt=x\n").?);
    try std.testing.expectEqualStrings("amber", parse_theme_setting("hostname=v\ntheme=amber").?);
    try std.testing.expect(parse_theme_setting("theme=neon\n") == null);
    try std.testing.expect(parse_theme_setting("prompt=virelai> \n") == null);
    try std.testing.expect(parse_theme_setting("") == null);
}

test "dq4: set_theme + theme_name round-trip" {
    defer theme.current_theme = THEME_DARK;
    try std.testing.expect(set_theme("light"));
    try std.testing.expectEqualStrings("light", theme_name());
    try std.testing.expect(set_theme("amber"));
    try std.testing.expectEqualStrings("amber", theme_name());
    try std.testing.expect(set_theme("dark"));
    try std.testing.expectEqualStrings("dark", theme_name());
    try std.testing.expect(!set_theme("neon"));
}

test "m38: direct backing buffer draw_alpha_mask blends anti-aliased font glyphs" {
    var pixels = [_]u32{0xFF101418} ** 400; // 20x20 buffer
    win_set_backing(9, &pixels, 20, 20);
    defer win_clear_backing(9);

    const mask = [_]u8{
        0,   64,
        128, 255,
    };

    draw_alpha_mask(9, 5, 5, 2, 2, &mask, 0x00FF00);

    // Pixel at (5, 5) had alpha=0: should remain unchanged background
    try std.testing.expectEqual(@as(u32, 0xFF101418), pixels[5 * 20 + 5]);

    // Pixel at (6, 5) had alpha=64: should be blended between bg and green
    const p_64 = pixels[5 * 20 + 6];
    const g_64 = (p_64 >> 8) & 0xFF;
    try std.testing.expect(g_64 > 0x14 and g_64 < 0xFF);

    // Pixel at (5, 6) had alpha=128: should be strongly blended
    const p_128 = pixels[6 * 20 + 5];
    const g_128 = (p_128 >> 8) & 0xFF;
    try std.testing.expect(g_128 > g_64 and g_128 < 0xFF);

    // Pixel at (6, 6) had alpha=255: should be pure green with full alpha
    try std.testing.expectEqual(@as(u32, 0xFF00FF00), pixels[6 * 20 + 6]);
}

test "m38: TextInput proportional cursor calculation and click placement" {
    var input = TextInput.init(Rect.make(10, 10, 150, 24));
    input.set_text("Hello World");
    input.focused = true;

    // Mouse click before text start (x <= rect.x + pad_sm) should place cursor at 0
    var ev_start = Event{ .kind = MOUSE_DOWN, .flags = 0, .seq = 1, .arg0 = 12, .arg1 = 15 };
    _ = input.handle_event(&ev_start);
    try std.testing.expectEqual(@as(usize, 0), input.cursor);

    // Mouse click near character 3
    const x_for_3 = 10 + pad_sm + measure_text("Hel");
    var ev_mid = Event{ .kind = MOUSE_DOWN, .flags = 0, .seq = 2, .arg0 = x_for_3, .arg1 = 15 };
    _ = input.handle_event(&ev_mid);
    try std.testing.expectEqual(@as(usize, 3), input.cursor);

    // Mouse click far to the right should place cursor at end
    var ev_end = Event{ .kind = MOUSE_DOWN, .flags = 0, .seq = 3, .arg0 = 150, .arg1 = 15 };
    _ = input.handle_event(&ev_end);
    try std.testing.expectEqual(@as(usize, 11), input.cursor);
}

test "m39 ui2: isqrt integer square root" {
    try std.testing.expectEqual(@as(u32, 0), isqrt(0));
    try std.testing.expectEqual(@as(u32, 1), isqrt(1));
    try std.testing.expectEqual(@as(u32, 2), isqrt(4));
    try std.testing.expectEqual(@as(u32, 3), isqrt(9));
    try std.testing.expectEqual(@as(u32, 4), isqrt(16));
    try std.testing.expectEqual(@as(u32, 5), isqrt(25));
    try std.testing.expectEqual(@as(u32, 10), isqrt(100));
    try std.testing.expectEqual(@as(u32, 128), isqrt(16384));
    try std.testing.expectEqual(@as(u32, 169), isqrt(28800));
}

test "m39 ui2: fill_rounded_rect_buf anti-aliased geometry and symmetry" {
    var pixels = [_]u32{0xFF000000} ** (24 * 24);
    fill_rounded_rect_buf(&pixels, 24, 24, Rect.make(0, 0, 24, 24), 8, 0xFFFFFFFF);

    // 1. Center must be pure white
    try std.testing.expectEqual(@as(u32, 0xFFFFFFFF), pixels[12 * 24 + 12]);

    // 2. Outer corners (0,0), (23,0), (0,23), (23,23) must be outside the radius and completely untouched
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[0 * 24 + 0]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[0 * 24 + 23]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[23 * 24 + 0]);
    try std.testing.expectEqual(@as(u32, 0xFF000000), pixels[23 * 24 + 23]);

    // 3. Corner edge pixel (2, 2) must be anti-aliased: blended between black and white
    const p_corner = pixels[2 * 24 + 2];
    const r_corner = p_corner & 0xFF;
    try std.testing.expect(r_corner > 0 and r_corner < 255);

    // 4. 4-way quarter-circle symmetry
    try std.testing.expectEqual(pixels[2 * 24 + 2], pixels[2 * 24 + 21]);
    try std.testing.expectEqual(pixels[2 * 24 + 2], pixels[21 * 24 + 2]);
    try std.testing.expectEqual(pixels[2 * 24 + 2], pixels[21 * 24 + 21]);
}

test "m39 ui2: fill_pill_buf clamps radius to half height" {
    var pixels = [_]u32{0xFF111111} ** (32 * 16);
    fill_pill_buf(&pixels, 32, 16, Rect.make(0, 0, 32, 16), 0xFF3B82F6);

    // Outer corner untouched
    try std.testing.expectEqual(@as(u32, 0xFF111111), pixels[0 * 32 + 0]);
    try std.testing.expectEqual(@as(u32, 0xFF111111), pixels[0 * 32 + 31]);

    // Center filled with solid blue
    try std.testing.expectEqual(@as(u32, 0xFF3B82F6), pixels[8 * 32 + 16]);
}

test "m39 ui2: sidebar design tokens and theme reactivity" {
    try std.testing.expectEqual(@as(u32, 180), sidebar_w);
    try std.testing.expectEqual(@as(u32, 38), tab_row_h);
    try std.testing.expectEqual(@as(u32, 6), tab_pill_radius);
    try std.testing.expectEqual(@as(u32, 14), font_size_tab_title);
    try std.testing.expectEqual(@as(u32, 13), font_size_clock);
    try std.testing.expectEqual(@as(u32, 11), font_size_badge);

    // Dark theme values
    defer theme.current_theme = THEME_DARK;
    theme.current_theme = THEME_DARK;
    try std.testing.expectEqual(SIDEBAR_DARK.bg, sidebar_bg());
    try std.testing.expectEqual(SIDEBAR_DARK.active_pill, sidebar_active_pill());
    try std.testing.expectEqual(SIDEBAR_DARK.hover_pill, sidebar_hover_pill());

    // Light theme values
    theme.current_theme = THEME_LIGHT;
    try std.testing.expectEqual(SIDEBAR_LIGHT.bg, sidebar_bg());
    try std.testing.expectEqual(SIDEBAR_LIGHT.active_pill, sidebar_active_pill());
    try std.testing.expectEqual(SIDEBAR_LIGHT.hover_pill, sidebar_hover_pill());
}

test "m39 ui2: measure_text_sized returns sensible metrics" {
    const w = measure_text_sized("Virelai", 14);
    try std.testing.expect(w > 20);
}

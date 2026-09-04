//! VirelaiOS Micro-Widget Component Library (M39 UI1, M41 TS2).
//!
//! Decomposed into granular components under `user/src/lib/ui/widgets/`:
//!   - button.zig: ButtonState, Button, Label
//!   - text_input.zig: TextInput
//!   - list_view.zig: ListView
//!   - dropdown.zig: DropDown
//!   - scroll_view.zig: MOUSE_SCROLL, ScrollView, HScrollBar
//!   - toggle.zig: Checkbox, Toggle
//!   - progress_bar.zig: ProgressBar
//!   - context_menu.zig: ContextMenu, MenuBuilder, canonical shortcuts
//!   - dialog.zig: Dialog, show_dialog, draw_empty_state, format_error

const std = @import("std");
pub const abi = @import("abi.zig");
pub const theme = @import("theme.zig");
pub const draw = @import("draw.zig");

// Granular widget submodules
pub const button = @import("widgets/button.zig");
pub const text_input = @import("widgets/text_input.zig");
pub const list_view = @import("widgets/list_view.zig");
pub const dropdown = @import("widgets/dropdown.zig");
pub const scroll_view = @import("widgets/scroll_view.zig");
pub const toggle = @import("widgets/toggle.zig");
pub const progress_bar = @import("widgets/progress_bar.zig");
pub const context_menu = @import("widgets/context_menu.zig");
pub const dialog = @import("widgets/dialog.zig");

// Re-exports for 100% backward compatibility:
pub const ButtonState = button.ButtonState;
pub const Button = button.Button;
pub const Label = button.Label;

pub const TextInput = text_input.TextInput;

pub const ListView = list_view.ListView;

pub const DropDown = dropdown.DropDown;

pub const MOUSE_SCROLL = scroll_view.MOUSE_SCROLL;
pub const ScrollView = scroll_view.ScrollView;
pub const HScrollBar = scroll_view.HScrollBar;

pub const Checkbox = toggle.Checkbox;
pub const Toggle = toggle.Toggle;

pub const ProgressBar = progress_bar.ProgressBar;

pub const CanonicalMenuCategory = context_menu.CanonicalMenuCategory;
pub const canonical_menu_bar = context_menu.canonical_menu_bar;
pub const StandardShortcut = context_menu.StandardShortcut;
pub const MenuItemKind = context_menu.MenuItemKind;
pub const MenuItemSpec = context_menu.MenuItemSpec;
pub const MenuSection = context_menu.MenuSection;
pub const MenuBuilder = context_menu.MenuBuilder;
pub const ContextMenuItem = context_menu.ContextMenuItem;
pub const ContextMenu = context_menu.ContextMenu;
pub const menu_build = context_menu.menu_build;

pub const DialogResult = dialog.DialogResult;
pub const Dialog = dialog.Dialog;
pub const DialogSeverity = dialog.DialogSeverity;
pub const DialogButtons = dialog.DialogButtons;
pub const show_dialog = dialog.show_dialog;
pub const draw_empty_state = dialog.draw_empty_state;
pub const draw_empty_state_icon = dialog.draw_empty_state_icon;
pub const format_error = dialog.format_error;
pub const format_error_ctx = dialog.format_error_ctx;
pub const format_error_with_context = dialog.format_error_with_context;

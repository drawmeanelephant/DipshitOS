//! VirelaiOS lib/tabapp.zig — the tab-aware app interface (M42 SX3, issue #984).
//!
//! The library behind "every app we've made works full screen in the tabbed
//! desktop" (umbrella #981). Writing a tab-friendly app by hand means
//! hand-rolling four things; this module packages them once:
//!
//!   1. **Opening** — theme sync + `win_open` with the legacy fixed rect
//!      (the shim/WND presentation is unchanged).
//!   2. **Declaring** — a `wm_rpc_kind_declare_fullscreen` RPC to the running
//!      WM server (TABWM.BIN or WND.BIN — either seat resolves since SX3).
//!      TABWM marks the tab full-viewport-eligible and answers with the
//!      kernel's `WIN_RESIZE` seam (SX2) when the tab is activated; WND.BIN
//!      refuses the additive kind and the app keeps its native size — the
//!      zero-regression path.
//!   3. **Dispatching** — `WIN_CLOSE` → clean exit, `WIN_RESIZE` → the app's
//!      relayout at the new canvas size (the library tracks w/h).
//!   4. **Scaling** — `scale` maps a fixed-layout rect into the new canvas
//!      (the mechanical full-viewport port for apps laid out at compile
//!      time; CALC is the exemplar port).
//!
//! The ~40-line app shape:
//!
//! ```zig
//! const tabapp = @import("lib/tabapp.zig");
//! var ta = tabapp.TabApp.init(.{ .name = "MYAPP.BIN", .title = "MyApp",
//!     .x = 32, .y = 32, .w = 512, .h = 384 }) orelse return;
//! app.layout(ta.w, ta.h);
//! app.draw(ta.win);
//! ta.present();
//! while (true) {
//!     var ev: ui.Event = undefined;
//!     if (ui.wait_event(&ev) < 0) break;
//!     switch (ta.dispatch(&ev)) {
//!         .closed => break,
//!         .resized => { app.layout(ta.w, ta.h); },
//!         .none => {},
//!     }
//!     // ... bespoke event handling, then on dirty:
//!     app.draw(ta.win);
//!     ta.present();
//! }
//! ta.close_and_exit(status);
//! ```
//!
//! Zero heap (all state is the returned struct + static BSS at the call
//! site), freestanding, and host-testable: the syscall wrappers no-op on
//! the host like every lib, so the dispatch/scale logic is plain unit-test
//! surface.

const std = @import("std");
pub const ui = @import("ui.zig");
const Rect = ui.Rect;
const Event = ui.Event;

// ---------------------------------------------------------------------------
// The app-facing type
// ---------------------------------------------------------------------------

/// Open/declare configuration. `name` is THIS process's own name (the WM ack
/// routing needs it — the WMRPC pattern); `title` is the tab title.
pub const Config = struct {
    name: []const u8,
    title: []const u8,
    x: u32 = 32,
    y: u32 = 32,
    w: u32,
    h: u32,
};

/// What `dispatch` decided the app should do with an event.
pub const Action = enum {
    /// Not a WM-lifecycle event — handle it as usual (mouse/key/timer...).
    none,
    /// The WM resized the window's canvas: relayout at the new w/h.
    resized,
    /// The window closed: clean up and exit.
    closed,
};

pub const TabApp = struct {
    win: u32 = 0,
    /// CURRENT canvas size — starts at the open rect, follows every
    /// WIN_RESIZE (the WM's SET_WINDOW seam, SX2). Apps lay out against
    /// these, never against compile-time constants, once tab-aware.
    w: u32 = 0,
    h: u32 = 0,
    /// True when the running WM ACCEPTED the tab-aware declaration (TABWM).
    /// False = shim mode or WND.BIN (which refuses the additive kind): the
    /// app stays at its native size — the legacy presentation.
    tab_aware: bool = false,
    open_ok: bool = false,

    /// Open the window + declare tab-awareness. Null = win_open failed
    /// (the caller prints and exits).
    pub fn init(cfg: Config) ?TabApp {
        _ = ui.sync_theme_from_host();
        const win_res = ui.win_open(cfg.x, cfg.y, cfg.w, cfg.h);
        if (win_res < 0) return null;
        var self = TabApp{
            .win = @intCast(win_res),
            .w = cfg.w,
            .h = cfg.h,
            .open_ok = true,
        };
        // The declaration is best-effort: TABWM accepts it (tab becomes
        // full-viewport eligible), WND/shim refuse it and the app keeps the
        // legacy fixed presentation. One blocking RPC at startup is fine.
        self.tab_aware = ui.wm_mail_request(
            ui.wm_rpc_kind_declare_fullscreen,
            self.win,
            0,
            0,
            0,
            0,
            cfg.title,
            cfg.name,
            1,
        );
        return self;
    }

    /// Classify one WM-lifecycle event and track the canvas size.
    /// Everything else is `.none` (the app's own handler stays in charge).
    pub fn dispatch(self: *TabApp, ev: *const Event) Action {
        switch (ev.kind) {
            ui.WIN_CLOSE => return .closed,
            ui.WIN_RESIZE => {
                self.w = ev.arg0;
                self.h = ev.arg1;
                return .resized;
            },
            else => return .none,
        }
    }

    /// Present the current frame (the app draws first).
    pub fn present(self: *const TabApp) void {
        ui.win_present(self.win);
    }

    /// Close the window (the exit itself stays the app's `ui.exit_process`).
    pub fn close(self: *const TabApp) void {
        ui.win_close(self.win);
    }

    /// The common exit path: close the window and exit with `status`.
    pub fn close_and_exit(self: *const TabApp, status: u32) noreturn {
        self.close();
        ui.exit_process(status);
    }
};

// ---------------------------------------------------------------------------
// Fixed-layout scaling (the mechanical full-viewport port)
// ---------------------------------------------------------------------------

/// Map a rect laid out for a `from_w x from_h` canvas into a `to_w x to_h`
/// canvas, preserving margins proportionally on BOTH axes. Integer math
/// only (no floats — the freestanding image has no soft-float budget for
/// layout); rounding is toward the top-left so button grids never spill.
/// At the identity mapping (to == from) every rect maps to itself exactly —
/// the legacy layout is the fixed point, which is what makes the port
/// zero-regression: without a resize the app renders byte-identically.
pub fn scale(r: Rect, from_w: u32, from_h: u32, to_w: u32, to_h: u32) Rect {
    if (from_w == 0 or from_h == 0) return r;
    if (from_w == to_w and from_h == to_h) return r;
    const x: u32 = @intCast((@as(u64, r.x) * to_w) / from_w);
    const y: u32 = @intCast((@as(u64, r.y) * to_h) / from_h);
    const w: u32 = @intCast((@as(u64, r.w) * to_w) / from_w);
    const h: u32 = @intCast((@as(u64, r.h) * to_h) / from_h);
    return Rect.make(x, y, @max(w, 1), @max(h, 1));
}

// ---------------------------------------------------------------------------
// Host unit tests (M42 SX3)
// ---------------------------------------------------------------------------

test "tabapp: dispatch classifies WM lifecycle events and tracks the canvas" {
    var ta = TabApp{ .win = 4, .w = 512, .h = 384, .tab_aware = true, .open_ok = true };

    // Unrelated events pass through.
    const mouse = Event{ .kind = ui.MOUSE_DOWN, .flags = ui.BTN_LEFT, .seq = 1, .arg0 = 10, .arg1 = 10 };
    try std.testing.expectEqual(Action.none, ta.dispatch(&mouse));
    try std.testing.expectEqual(@as(u32, 512), ta.w);

    // Resize updates the tracked canvas and asks for a relayout.
    const resize = Event{ .kind = ui.WIN_RESIZE, .flags = 0, .seq = 2, .arg0 = 1100, .arg1 = 720 };
    try std.testing.expectEqual(Action.resized, ta.dispatch(&resize));
    try std.testing.expectEqual(@as(u32, 1100), ta.w);
    try std.testing.expectEqual(@as(u32, 720), ta.h);

    // Close classifies as the exit action.
    const close = Event{ .kind = ui.WIN_CLOSE, .flags = 0, .seq = 3, .arg0 = 0, .arg1 = 0 };
    try std.testing.expectEqual(Action.closed, ta.dispatch(&close));
}

test "tabapp: scale is the identity at the native canvas (zero-regression fixed point)" {
    const r = Rect.make(8, 104, 56, 20);
    const same = scale(r, 512, 340, 512, 340);
    try std.testing.expectEqual(r.x, same.x);
    try std.testing.expectEqual(r.y, same.y);
    try std.testing.expectEqual(r.w, same.w);
    try std.testing.expectEqual(r.h, same.h);
}

test "tabapp: scale maps a fixed layout into the full viewport" {
    // A 512x340 layout grows into 1100x720: proportionally on both axes.
    const btn = Rect.make(8, 104, 56, 20);
    const scaled = scale(btn, 512, 340, 1100, 720);
    try std.testing.expectEqual(@as(u32, (8 * 1100) / 512), scaled.x);
    try std.testing.expectEqual(@as(u32, (104 * 720) / 340), scaled.y);
    try std.testing.expectEqual(@as(u32, (56 * 1100) / 512), scaled.w);
    try std.testing.expectEqual(@as(u32, (20 * 720) / 340), scaled.h);
    // Content never spills the canvas.
    try std.testing.expect(scaled.x + scaled.w <= 1100);
    try std.testing.expect(scaled.y + scaled.h <= 720);
}

test "tabapp: scale never produces zero-size rects" {
    const tiny = Rect.make(0, 0, 1, 1);
    const grown = scale(tiny, 512, 340, 1100, 720);
    try std.testing.expect(grown.w >= 1);
    try std.testing.expect(grown.h >= 1);
    // Degenerate source canvas is passed through untouched.
    const degenerate = scale(tiny, 0, 0, 1100, 720);
    try std.testing.expectEqual(tiny, degenerate);
}

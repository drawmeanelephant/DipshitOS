# ADR 0011: Desktop Platform & Userland GUI Application Architecture

Status: **accepted** · Date: 2026-08-15 · Milestone: eleven (desktop platform & GUI apps)

## Context

Milestones zero through ten delivered a full-featured, freestanding AArch64 operating system on Apple silicon:
preemptive multitasking, per-process address spaces, FAT32 kernel/user storage, virtio-net,
virtio-gpu window manager (Driving Award), USB xHCI / HID input, human-interface shell,
interactive EL0 application events (ADR 0009), and userland filesystem access (ADR 0010).

However, EL0 user programs are currently **isolated test binaries or batch tools** (e.g. `WIN.BIN`, `KEYTEST.BIN`, `SAVETEXT.BIN`). There is no unified desktop environment, no standardized component toolkit for user applications, and no launcher or multi-application workflow.

Milestone eleven combines windowing (Milestone 6), interactive events (Milestone 9), and userland storage (Milestone 10) into a recognizable **graphical desktop platform with dedicated consumer applications (`CALC.BIN`, `NOTEPAD.BIN`, `TOP.BIN`) and a desktop launcher (`DESKTOP.BIN`)**.

This ADR establishes the normative architectural specification for userland GUI applications, event loop dispatch conventions, zero-heap micro-widget state models, typography and color palettes, and desktop lifecycle management.

---

## Decisions

### D1. Window Coordinate Spaces & Translation

1. **Window-Local Coordinates:**
   All userland GUI widgets and drawing operations operate strictly within **window-local coordinates** $[0, W_{\text{win}}-1] \times [0, H_{\text{win}}-1]$:
   - $(0, 0)$ is the top-left pixel of the window's client area.
   - $(W_{\text{win}}-1, H_{\text{win}}-1)$ is the bottom-right pixel.
2. **Kernel-Handled Translation:**
   In accordance with ADR 0009 D4, pointer events (`MOUSE_DOWN`, `MOUSE_UP`, `MOUSE_MOVE`) delivered to the application via `sys_wait_event` (slot 22) or `sys_poll_event` (slot 21) are already translated into window-local coordinates:
   $$\text{local\_x} = \text{event.arg0}, \quad \text{local\_y} = \text{event.arg1}$$
   Applications never need to query the window manager's scanout position to handle local mouse interactions.
3. **Scanout Bounds:**
   Standard user application windows are bounded within $256 \times 192$ (the Driving Award back-buffer capacity) or full-scanout overlays managed by dedicated platform processes.

---

### D2. Event Loop Dispatch Discipline & Frame Presentation

All userland GUI applications follow a standardized, non-blocking / event-driven execution loop:

```
[Start] ──> Open Window (sys_win_open)
              │
              ▼
        Initial Render ──> sys_win_present
              │
    ┌─────────┴──────────────────────────────┐
    │ Event Loop:                            │
    │  1. Wait for Event (sys_wait_event)    │
    │  2. Dispatch to Widgets / App State    │
    │  3. Drain pending events (sys_poll)    │
    │  4. If dirty: Render UI & Present      │
    │  5. If WIN_CLOSE or Exit: Break        │
    └─────────┬──────────────────────────────┘
              │
              ▼
        Exit Application (sys_exit)
```

1. **Event Drain & Batching:**
   Applications process all available queued events before initiating a redraw pass. This avoids redundant intermediate redraws during high-frequency pointer motion.
2. **Dirty Tracking:**
   Applications maintain a boolean `dirty` flag. `sys_win_fill` (slot 13) and `sys_win_present` (slot 14) are only invoked when widget state (e.g. hover, click, text edit, focus) actually changes.
3. **Window Lifecycle Handshake:**
   On receiving `WIN_CLOSE` (kind 8), applications must release resources and exit cleanly via `sys_exit` (slot 3) or `sys_win_close` (slot 15).

---

### D3. Zero-Allocation Micro-Widget Component State Models

In adherence to the core DipshitOS philosophy, all GUI primitives in `user/src/lib/ui.zig` operate with **0 heap allocations**. All widget structures are pure value types stored in static BSS or on the caller's stack frame.

#### 1. `Rect`
```zig
pub const Rect = extern struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,

    pub fn contains(self: Rect, px: u32, py: u32) bool {
        return px >= self.x and px < self.x + self.w and
               py >= self.y and py < self.y + self.h;
    }
};
```

#### 2. `Button`
```zig
pub const ButtonState = enum { idle, hover, pressed };

pub const Button = struct {
    rect: Rect,
    label: []const u8,
    state: ButtonState = .idle,
    text_color: u32 = 0xffffff,

    pub fn handle_event(self: *Button, ev: *const Event) bool;
    pub fn draw(self: *const Button, win_id: u32) void;
};
```

#### 3. `TextInput`
```zig
pub const TextInput = struct {
    rect: Rect,
    buf: [64]u8 = [_]u8{0} ** 64,
    len: usize = 0,
    cursor: usize = 0,
    focused: bool = false,

    pub fn handle_event(self: *TextInput, ev: *const Event) bool;
    pub fn get_text(self: *const TextInput) []const u8;
    pub fn set_text(self: *TextInput, text: []const u8) void;
    pub fn draw(self: *const TextInput, win_id: u32) void;
};
```

#### 4. `ListView`
```zig
pub const ListView = struct {
    rect: Rect,
    row_height: u32 = 14,
    selected_idx: ?usize = null,
    item_count: usize = 0,

    pub fn handle_event(self: *ListView, ev: *const Event) bool;
    pub fn draw_row(self: *const ListView, win_id: u32, row: usize, text: []const u8) void;
};
```

---

### D4. Typography, 8×8 Bitmap Rasterization, & Palette Tokens

1. **8×8 Bitmap Typography:**
   Text rendering in userland utilizes the public-domain 8×8 monochrome font (`user/src/lib/font8x8.zig`), identical to the kernel font table. Glyphs are drawn by emitting single-pixel or sub-block fills via `sys_win_fill`.
2. **Standard HIG Color Palette:**
   Applications adopt a unified modern dark-theme palette adhering to ADR 0008:

| Token | RGB Hex | Usage |
|:------|:-------:|:------|
| `COLOR_BG` | `0x182026` | Default application window background |
| `COLOR_SURFACE` | `0x222d35` | Container surfaces, panels, text box background |
| `COLOR_BORDER` | `0x334155` | Widget borders and dividers |
| `COLOR_TEXT_PRIMARY` | `0xffffff` | Primary body text, labels, button text |
| `COLOR_TEXT_MUTED` | `0x94a3b8` | Placeholders, status bar secondary text |
| `COLOR_ACCENT` | `0x3b82f6` | Focused borders, active selections, primary actions |
| `COLOR_BTN_IDLE` | `0x2d3748` | Default button face |
| `COLOR_BTN_HOVER` | `0x4a5568` | Button hover state under pointer |
| `COLOR_BTN_PRESSED` | `0x1a202c` | Button depressed / active state |
| `COLOR_SUCCESS` | `0x22c55e` | Success states, saved indicators |
| `COLOR_DANGER` | `0xef4444` | Errors, kill actions, warning highlights |

---

### D5. Desktop Environment & Application Lifecycle

1. **`DESKTOP.BIN` Environment:**
   `DESKTOP.BIN` acts as the user environment manager:
   - Houses a persistent status bar across the top displaying clock, active process diagnostics, and system health.
   - Provides an interactive application menu allowing users to inspect and launch EL0 programs (`CALC.BIN`, `NOTEPAD.BIN`, `TOP.BIN`, `KEYTEST.BIN`).
2. **Process Observation:**
   `TOP.BIN` and `DESKTOP.BIN` poll `sys_procs` (slot 7) to inspect active process slots, tracking PIDs, process names, and execution states (`created`, `running`, `exited`).
3. **Application Autonomy:**
   Each GUI application runs as a fully isolated EL0 process owning its own TTBR0 address space, window handle, event queue, and file handles. Applications communicate with the environment solely through frozen syscall ABIs.

---

## Enforceability Table

| Requirement | Enforcing Gate |
|:---|:---|
| Zero heap allocation & widget state logic | Class A host unit tests in `user/src/lib/ui.zig` |
| Calculator button grid & 64-bit arithmetic | Class A math unit tests + Class B interactive gate |
| Notepad text editing & persistent storage | Class A editor buffer tests + Class B persistent round-trip gate |
| Top process table rendering & polling | Class A table parsing tests + Class B live execution gate |
| Desktop environment & full platform verification | Class B Capstone Gate: `tools/verify-live-desktop.sh` |

---

## Amendment 2026-08-16 — application identity manifest (M13 card B2, claim 8877)

### Context

`DESKTOP.BIN` originally hardcoded its application catalog (`installed_apps`
in `user/src/desktop.zig`). Adding an app meant recompiling the launcher.
This amendment gives the desktop a manifest to read instead, so application
identity lives in the image, not the binary.

### Contract

- **Location:** `/APPS.TXT` at the ESP volume root, embedded by the image
  build (`image/apps.txt` → `image/mkfat32.py --apps-txt`).
- **Format:** one app per line, `NAME.BIN | Display Name | icon-char`;
  `#` comments and blank lines ignored; fields are trimmed; the icon is a
  single ASCII glyph (an index into the `font8x8` glyph table).
- **Reader:** `DESKTOP.BIN` opens `/esp/APPS.TXT` via `sys_file_open`
  (slot 23, ADR 0010), reads it into a stack-owned bounded buffer
  (640 B — W^X safe, zero heap), and parses it with `parse_manifest`
  (pure, host-tested). The entry count is bounded at 16.
- **Fallback:** if the manifest is missing, unreadable, or empty,
  `DESKTOP.BIN` renders its built-in catalog — honest degradation; the
  desktop always has a launcher list.
- **Marker:** the launcher prints `desktop: manifest apps=N` on the serial
  console (N = parsed count) for the live gate.
- **DSK1 compatibility:** the manifest is a separate text file — the DSK1
  flat-image header (ADR 0002) and the `.BIN` files are untouched.

### Consequences

- Adding a `.BIN` to the system = one `APPS.TXT` line, no launcher
  recompile.
- The gate `tools/verify-live-desktop.sh` asserts `desktop: manifest
  apps=8` (the current catalog) alongside the launch markers.

---

## What this is not

- It is not a heavy web runtime or HTML/DOM engine.
- It is not a dynamic heap-allocating UI framework.
- It is not POSIX X11, Wayland, or Cocoa.
- It does not modify existing frozen syscall slots (ADR 0007 / ADR 0009 / ADR 0010).

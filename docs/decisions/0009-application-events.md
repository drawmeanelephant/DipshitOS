# ADR 0009: Interactive EL0 application events and syscalls

Status: **accepted** · Date: 2026-08-15 · Milestone: nine (interactive application platform)

## Context

Milestones zero through eight delivered a fully functional operating system on Apple silicon:
preemptive multitasking, per-process address spaces, FAT32 storage, virtio-net, virtio-gpu
windows (the Driving Award window manager), USB xHCI / HID input, and a human-interface shell.

However, EL0 user programs remain **output-only or batch-driven**: user processes can open
windows, render pixels, and present frames, but cannot receive interactive keystrokes,
pointer clicks/motion, or window lifecycle events. Keystrokes currently route only to the
terminal line editor, while mouse reports update the cursor and window focus inside the kernel.

Milestone nine turns DipshitOS into an **interactive application platform** by routing user
input and window lifecycle transitions into per-process bounded event queues and exposing
standard event polling and blocking syscalls to EL0.

This ADR establishes the normative event wire format, event kind enumeration, modifier/button
bitmasks, coordinate mapping contract, and the ADR 0007 syscall ABI amendments (slots 21 and 22).

---

## Decisions

### D1. Normative 16-byte event wire layout

All events share a compact, fixed 16-byte C-ABI extern layout (`Event`), identical across
kernel and userspace:

```zig
pub const Event = extern struct {
    /// Event category / discriminator (1..8).
    kind: u16,
    /// Modifier bitmask (keyboard) or button bitmask (mouse).
    flags: u16,
    /// Monotonic per-process sequence counter (starts at 1).
    seq: u32,
    /// Event-specific primary argument (e.g. keycode, window-local X, window ID).
    arg0: u32,
    /// Event-specific secondary argument (e.g. ASCII byte, window-local Y, previous focus).
    arg1: u32,
};
```

- Total size is exactly 16 bytes: `2 + 2 + 4 + 4 + 4 = 16`.
- Wire format is little-endian, natural AArch64 alignment (4-byte aligned).
- Pure data structure: no pointers, no heap allocations, no dynamically sized payloads.

---

### D2. Event kinds and argument encoding

The `kind` field identifies the event type (values 1..8; 0 is reserved/invalid):

| Value | Constant | Description | `arg0` | `arg1` | `flags` |
|:-----:|:---------|:------------|:-------|:-------|:--------|
| 1 | `KEY_DOWN` | Key pressed | HID usage / keycode | Decoded ASCII / symbol (or 0) | Modifier mask |
| 2 | `KEY_UP` | Key released | HID usage / keycode | Decoded ASCII / symbol (or 0) | Modifier mask |
| 3 | `MOUSE_DOWN` | Mouse button pressed | Window-local X (`0..w-1`) | Window-local Y (`0..h-1`) | Button mask \| Modifier mask |
| 4 | `MOUSE_UP` | Mouse button released | Window-local X (`0..w-1`) | Window-local Y (`0..h-1`) | Button mask \| Modifier mask |
| 5 | `MOUSE_MOVE` | Mouse motion | Window-local X (`0..w-1`) | Window-local Y (`0..h-1`) | Button mask \| Modifier mask |
| 6 | `WIN_FOCUS` | Window gained focus | Window ID (`2..3`) | Previous focused window ID | 0 |
| 7 | `WIN_BLUR` | Window lost focus | Window ID (`2..3`) | Newly focused window ID | 0 |
| 8 | `WIN_CLOSE` | Close requested | Window ID (`2..3`) | 0 | 0 |

---

### D3. Modifier and button bitmasks

The `flags` field contains bitmasks for keyboard modifiers and mouse button state:

#### Keyboard Modifiers (bits 0–7)
- `MOD_SHIFT = 0x0001` (Shift key held)
- `MOD_CTRL  = 0x0002` (Control key held)
- `MOD_ALT   = 0x0004` (Alt / Option key held)
- `MOD_CMD   = 0x0008` (Command / Meta / GUI key held)

#### Mouse Buttons (bits 8–11)
- `BTN_LEFT   = 0x0100` (Left button pressed)
- `BTN_RIGHT  = 0x0200` (Right button pressed)
- `BTN_MIDDLE = 0x0400` (Middle button pressed)

For convenience in user programs, low-byte button aliases (`BTN_LEFT_BIT = 0x01`, `BTN_RIGHT_BIT = 0x02`, `BTN_MIDDLE_BIT = 0x04`) are provided when checking button-only reports.

---

### D4. Window-local coordinate translation

Pointer events (`MOUSE_DOWN`, `MOUSE_UP`, `MOUSE_MOVE`) delivered to a process are always
translated into **window-local coordinates**:

$$\text{arg0} = \text{clamp}(X_{\text{scanout}} - X_{\text{win}}, 0, W_{\text{win}} - 1)$$
$$\text{arg1} = \text{clamp}(Y_{\text{scanout}} - Y_{\text{win}}, 0, H_{\text{win}} - 1)$$

User programs never need to query the window manager for window position to handle local
pointer coordinates.

---

### D5. Syscall ABI amendments (ADR 0007 slots 21 & 22)

Milestone 9 allocates slots 21 and 22 in the frozen ADR 0007 syscall table:

| Slot | Name | Signature | Semantics |
|:----:|:-----|:----------|:----------|
| 21 | `sys_poll_event` | `poll_event(buf) -> i64` | Non-blocking event poll. If an event is queued for the calling process, pops it, copies the 16-byte `Event` structure to `buf` via `uaccess.copy_out`, and returns `1`. If the queue is empty, returns `0`. Returns `-3` (`EFAULT`) for an invalid user buffer, `-1` (`EINVAL`) if the calling task is not a registered process. |
| 22 | `sys_wait_event` | `wait_event(buf) -> i64` | Blocking event wait. If an event is queued, immediately pops it, copies 16 bytes to `buf`, and returns `1`. If the queue is empty, blocks the calling task in the scheduler (`scheduler.wait_event_current`) without consuming CPU. When an event is pushed, the process wakes immediately, restarts the syscall at `svc #0`, copies the event, and returns `1`. Returns `-3` (`EFAULT`) or `-1` (`EINVAL`). |

- `implemented_count` in `kernel/src/syscall.zig` becomes **23** (slots 0..22).
- Both syscalls strictly adhere to the ADR 0007 uaccess fault-safe contract.

---

### D6. Queue geometry and lifecycle discipline

- **Queue Capacity:** Exactly 16 events per process slot (`events_per_process = 16`).
- **Memory Discipline:** Statically allocated in kernel BSS (`[process.max_processes]EventQueue`). No heap allocation.
- **Overflow Policy:** Drop-oldest FIFO. When full, pushing an event drops the oldest unconsumed event and increments `dropped_count`.
- **Lifecycle Reset:** `events.reset(pid)` is called during process creation (`process.allocate`) and process termination (`process.free`).

---

### D7. Enforceability and verification gates

| Subsystem | Requirement | Gate |
|:----------|:------------|:-----|
| Contract | Wire layout, enum values, size = 16B | Class A unit tests (`kernel/src/events.zig`) |
| Keyboard routing | Keypresses to focused user window | Class A + live keyboard routing proof |
| Pointer routing | Window-local translated clicks | Class A + hit-test dispatch proof |
| Lifecycle events | Focus and blur synthetic events | Class A state machine tests |
| Syscall seam | `sys_poll_event` & `sys_wait_event` | Class B live wait/wake gate |
| Interactive app | `KEYTEST.BIN` interactive graphics | Class B capstone gate (`tools/verify-live-events.sh`) |

---

## Consequences

- Applications can implement real-time interactive loops using `sys_wait_event` without polling or spinning.
- The window manager gains bidirectional event flow between host input and guest user processes.
- Syscall dispatch table grows to 23 implemented slots (0..22).

## Amendment (2026-08-19, claim 5390 — the application timers card)

Milestone 14 card S2 (issue #176) extends the event-kind enumeration with one
kind, posted by the bounded per-process timer facility (`kernel/src/timers.zig`):

| Value | Constant | Description | `arg0` | `arg1` | `flags` |
|:-----:|:---------|:------------|:-------|:-------|:--------|
| 9 | `TIMER` | A per-process application timer fired | Timer id (from `sys_timer_set`) | 0 | 0 |

`TIMER` events ride the exact same bounded 16-event FIFO, sequence numbering,
and `sys_poll_event`/`sys_wait_event` delivery as input and window-lifecycle
events — no new blocking primitive, no new queue geometry. A process's timers
are cancelled when it exits, so a `TIMER` event never outlives its owner.

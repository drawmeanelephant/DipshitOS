//! Dipshit Monitor command layer (Milestone 1.5, commands & personality).
//!
//! A reusable, host-testable command registry for the future interactive
//! monitor (`dipshit>`). It depends only on the console abstraction
//! (`console.zig`), the handoff-v2 contract (`handoff.zig`), and the
//! captured EFI map view (`memmap.zig`); it never touches hardware, so it
//! runs unchanged under `zig test` against a mock console and, later,
//! inside the kernel once the Console & Shell Core stream wires the real
//! serial transport.
//!
//! Constraints honored: no heap allocation, no libc, no POSIX, no dynamic
//! command registration, no unbounded recursion or output, and no hidden
//! global mutable state. All state lives in the caller-owned `Monitor`
//! value (console, system state, machine control).
//!
//! `kernel/src/main.zig` is intentionally untouched by this stream.

const std = @import("std");
const builtin = @import("builtin");
const alloc = @import("alloc.zig");
const console = @import("console.zig");
const esp = @import("esp.zig");
const esp_exec = @import("exec.zig"); // claim 6783: load a user program from the ESP and enter it at EL0
const fat = @import("fat.zig");
const syscall_mod = @import("syscall.zig"); // claim 6420: FAT write diagnostics (last failing LBA)
const exceptions = @import("exceptions.zig");
const gic = @import("gic.zig");
const handoff = @import("handoff.zig");
const mailbox = @import("mailbox.zig"); // claim 5965: per-process IPC rings behind `mbox`
const memmap = @import("memmap.zig");
const mmu = @import("mmu.zig"); // claim 5804: per-task TTBR0 roots + user-root inventory
const pci = @import("pci.zig");
const process = @import("process.zig"); // milestone four (claim 3848): the process registry behind `procs`
const scheduler = @import("scheduler.zig"); // claim 5275: tick-driven round-robin tasks
const syscall = @import("syscall.zig"); // claim 3594: syscall table + counters
const timer = @import("timer.zig");
const uaccess = @import("uaccess.zig"); // claim 6120: fault-safe copy-in/copy-out
const userspace = @import("userspace.zig"); // claim 5804: user-VA layout
const virtio_blk = @import("virtio_blk.zig"); // claim 6420: the sector interface behind `mount` (milestone four card 2)
const csprng = @import("csprng.zig"); // milestone four (claim 2665): the seeded CSPRNG behind `random`
const clipboard = @import("clipboard.zig"); // milestone fourteen (claim 0169): the shared kernel clipboard behind `clip`
const virtio_net = @import("virtio_net.zig"); // milestone five card N1 (claim 1373): the net transport behind `net`/`netsend`
const virtio_gpu = @import("virtio_gpu.zig"); // milestone six card G1 (claim 6053): the gpu transport + framebuffer behind `screen`
const virtio_snd = @import("virtio_snd.zig"); // milestone fifteen card A1 (claim 6140): the virtio-snd transport behind `sound`
const road_pops = @import("road_pops.zig"); // milestone six card G3 (claim 1574): the Road Pops tee console behind `roadpops`
const fbtext = @import("text.zig"); // milestone six card G2 (claim 3194): framebuffer text rendering behind `text`
const xhci = @import("xhci.zig"); // milestone seven card I1 (claim 4272): the XHCI host-controller transport behind `usb`
const input = @import("input.zig"); // milestone seven card I3 (claim 6050): the keyboard/pointer event FIFO behind `input`
const driving_award = @import("driving_award.zig"); // milestone six card G5 (claim 1543): Driving Award, the window manager behind `dui`
const wm_server = @import("wm_server.zig"); // M32 WMS2 (issue #622): the render-server register behind `wm`
const settings = @import("settings.zig"); // milestone eight card U8 (claim 2649): persistent settings engine
const tombstone = @import("tombstone.zig"); // Arc5 issue #243: crash tombstone engine
const dns = @import("dns.zig"); // milestone twelve card N2 (claim 7566): DNS resolver
const events = @import("events.zig"); // milestone sixteen C3 (claim 0339): per-process event queue bound behind `resources`
const file_table = @import("file_table.zig"); // milestone sixteen C3 (claim 0339): per-process handle bound behind `resources`
const serial_ring = @import("serial_ring.zig"); // Arc5 issue #243: serial output ring buffer behind `dmesg`
const smp = @import("smp.zig");

// ---------------------------------------------------------------------------
// Limits (fixed-size, explicit bounds)
// ---------------------------------------------------------------------------

/// Maximum arguments after the command name for any single invocation.
pub const max_args_limit: u8 = 16;
/// `repeat` refuses counts outside 1..repeat_max_count.
pub const repeat_max_count: u64 = 64;
/// `repeat` refuses outputs larger than this many bytes.
pub const repeat_max_bytes: usize = 4096;
/// `beans` refuses counts outside 1..beans_max_count.
pub const beans_max_count: u64 = 100;
/// `random` refuses counts outside 1..random_max_bytes (milestone four,
/// claim 2665).
pub const random_max_bytes: usize = 256;

// ---------------------------------------------------------------------------
// Execution result
// ---------------------------------------------------------------------------

pub const ExecError = enum {
    none,
    unknown_command,
    usage,
    invalid_argument,
    not_implemented,
    machine_failed,
};

// ---------------------------------------------------------------------------
// System state handed to the monitor
// ---------------------------------------------------------------------------

/// Everything the commands may read. Caller-owned, immutable from the
/// command layer's point of view.
pub const SystemState = struct {
    handoff: handoff.HandoffV2,
    map: memmap.MapView,
    /// Human-readable transport name ("mock", later "virtio-console",
    /// "pl011", ...). Reported by `elephant` diagnostics.
    console_name: []const u8,
};

// ---------------------------------------------------------------------------
// Machine control (reboot / shutdown)
// ---------------------------------------------------------------------------

pub const MachineResult = enum { ok, not_implemented, failed };

/// Interface behind which `reboot`/`shutdown` live, so command behavior can
/// be host-tested without rebooting the test process. The kernel's real
/// post-ExitBootServices mechanism (Runtime Services `ResetSystem`) is not
/// proven by any gate, so the default is `MachineControl.disabled()`, which
/// honestly reports `not_implemented`; a later stream that proves a
/// mechanism supplies a real implementation.
pub const MachineControl = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        reboot: *const fn (ctx: *anyopaque) MachineResult,
        shutdown: *const fn (ctx: *anyopaque) MachineResult,
    };

    pub fn reboot(self: MachineControl) MachineResult {
        return self.vtable.reboot(self.ctx);
    }

    pub fn shutdown(self: MachineControl) MachineResult {
        return self.vtable.shutdown(self.ctx);
    }

    /// Honest default: no proven post-exit machine-control mechanism.
    /// The vtable is built at runtime (not a const table) so its function
    /// pointers resolve PC-relatively at the kernel's runtime load base
    /// (claim 0015 root cause).
    pub fn disabled() MachineControl {
        ensure_disabled_vtable();
        return .{
            .ctx = @ptrCast(@constCast(&NoopDisabled)),
            .vtable = &disabled_vtable,
        };
    }
};

/// Storage + builder for `MachineControl.disabled()`'s vtable (module-level
/// so the pointer outlives the call).
const NoopDisabled = struct {
    fn reboot(_: *anyopaque) MachineResult {
        return .not_implemented;
    }
    fn shutdown(_: *anyopaque) MachineResult {
        return .not_implemented;
    }
};
var disabled_vtable: MachineControl.VTable = undefined;
var disabled_vtable_ready = false;
fn ensure_disabled_vtable() void {
    if (!disabled_vtable_ready) {
        disabled_vtable = .{ .reboot = NoopDisabled.reboot, .shutdown = NoopDisabled.shutdown };
        disabled_vtable_ready = true;
    }
}

/// Host-test double: records calls and returns scripted results.
pub const MockMachineControl = struct {
    reboot_result: MachineResult = .ok,
    shutdown_result: MachineResult = .ok,
    reboot_calls: usize = 0,
    shutdown_calls: usize = 0,

    /// Runtime-built vtable (claim 0015 root cause): a const table would
    /// hold link-time absolute addresses, wrong at the runtime load base.
    /// Module-level storage so the returned pointer outlives the call.
    pub fn control(self: *MockMachineControl) MachineControl {
        ensure_mock_vtable();
        return .{ .ctx = self, .vtable = &mock_vtable };
    }

    fn rebootFn(ctx: *anyopaque) MachineResult {
        const self: *MockMachineControl = @ptrCast(@alignCast(ctx));
        self.reboot_calls += 1;
        return self.reboot_result;
    }

    fn shutdownFn(ctx: *anyopaque) MachineResult {
        const self: *MockMachineControl = @ptrCast(@alignCast(ctx));
        self.shutdown_calls += 1;
        return self.shutdown_result;
    }
};

/// Storage + builder for `MockMachineControl.control()`'s vtable.
var mock_vtable: MachineControl.VTable = undefined;
var mock_vtable_ready = false;
fn ensure_mock_vtable() void {
    if (!mock_vtable_ready) {
        mock_vtable = .{ .reboot = MockMachineControl.rebootFn, .shutdown = MockMachineControl.shutdownFn };
        mock_vtable_ready = true;
    }
}

// ---------------------------------------------------------------------------
// Monitor context
// ---------------------------------------------------------------------------

pub const Monitor = struct {
    console: console.Console,
    state: SystemState,
    machine: MachineControl,

    pub fn init(con: console.Console, state: SystemState, machine: MachineControl) Monitor {
        return .{ .console = con, .state = state, .machine = machine };
    }
};

// ---------------------------------------------------------------------------
// Command registry
// ---------------------------------------------------------------------------

/// Command category (ADR 0008 D1): the seven groups `help` lists.
pub const Category = enum {
    machine_identity,
    memory_state,
    tasks_processes,
    storage,
    networking,
    graphics_input,
    system,
};

/// The fixed group order `help` lists (ADR 0008 D1). Enum values only — no
/// string-literal pointers in a const table, because the kernel's flat loader
/// applies no relocations (the claim-0015 lesson): `category_name` returns the
/// display strings PC-relatively at the call site instead.
const category_order = [_]Category{
    .machine_identity,
    .memory_state,
    .tasks_processes,
    .storage,
    .networking,
    .graphics_input,
    .system,
};

fn category_name(cat: Category) []const u8 {
    return switch (cat) {
        .machine_identity => "machine / identity",
        .memory_state => "memory / machine state",
        .tasks_processes => "tasks / processes",
        .storage => "storage",
        .networking => "networking",
        .graphics_input => "graphics / input",
        .system => "system",
    };
}

pub const Command = struct {
    name: []const u8,
    help: []const u8,
    usage: []const u8,
    category: Category,
    min_args: u8 = 0,
    max_args: u8 = max_args_limit,
    handler: *const fn (m: *Monitor, args: []const []const u8) ExecError,
};

/// Number of commands. The registry is built at runtime (not a const
/// table): see `ensure_registry`.
/// Number of commands. The registry is built at runtime (not a const
/// table): see `ensure_registry`. Milestone five card N1 (claim 1373)
/// grows it 32 -> 34 (`net` + `netsend`). Milestone seven card I1
/// (claim 4272) grows it 37 -> 38 (`usb`). Milestone seven card I3
/// (claim 6050) grows it 38 -> 39 (`input`). Milestone six card G5
/// (claim 1543) grows it 39 -> 40 (`dui`). Milestone eight card U6
/// (claim 8323) grows it 40 -> 42 (`welcome`, `tour`). Milestone eight card U7
/// (claim 2990) grows it 42 -> 43 (`sysinfo`). Milestone eight card U8
/// (claim 2649) grows it 43 -> 44 (`settings`). Milestone fourteen card S1
/// (claim 0169) grows it 44 -> 45 (`clip`). Milestone fifteen card A1
/// (claim 6140) grows it 45 -> 46 (`sound`). Milestone fifteen card A2
/// (claim 5877) grows it 46 -> 47 (`beep`). Milestone sixteen card C3
/// (claim 0339) grows it 47 -> 48 (`resources`). Milestone eighteen T5
/// (claim 0163) grows it 50 -> 51 (`color`). Milestone eighteen T16
/// (issue #419) grows it 51 -> 52 (`sh`). Milestone twenty-four K5
/// grows it 52 -> 53 (`calc`). Milestone twenty U1 (issue #307, claim
/// 5127) grows it 53 -> 54 (`font`). Milestone twenty-two D3 (issue #326)
/// grows it 54 -> 55 (`sym`). Milestone twenty-two D5 (issue #328)
/// grows it 55 -> 56 (`strace`). Milestone twenty-two D6 (issue #329)
/// grows it 56 -> 57 (`ps`).
pub const registry_count: usize = 71; // 51 + sh/calc + `font` (M20 U1) + sym/strace/ps (M22 D3/D5/D6) + `type` (M19 P1) + `mktemp` (M19 P16) + stat/find/dmesg/time/which/inventory (M22 D8/D12/D13/D16) + du (M25 F4) + screenshot/shortcuts (M27 G27/G29) + smp (M28) + `wm` (M32 WMS2, issue #622) + `wnd` (M32 WMS3, issue #623)

/// `sym <file>` reads at most this many bytes for on-disk symtab inspection
/// (M22 D3). ELF symbol tables live near the file tail; 64 KiB covers every
/// program the D1 loader can run that still fits its own staging contract.
pub const sym_file_max: usize = 64 * 1024;

/// Command registry, built at runtime into BSS. A `const` table would hold
/// link-time absolute addresses for BOTH the string slices and the handler
/// function pointers, which are wrong at the kernel's runtime-chosen load
/// base (claim 0015 root cause: the first vtable dispatch crashed; the
/// flat loader applies no relocations, unlike macOS for host tests). Built
/// once here in RAM so every pointer resolves PC-relatively (ADRP) and is
/// correct at any load base. `help` derives its listing from this table,
/// so the two cannot drift.
var registry_storage: [registry_count]Command = undefined;
var registry_ready = false;

fn ensure_registry() []const Command {
    if (!registry_ready) {
        registry_storage = .{
            .{ .name = "addrspaces", .help = "per-task user address spaces: per-task TTBR0, EL1-only kernel overlay, user-root contents", .usage = "addrspaces", .category = .memory_state, .handler = cmd_addrspaces },
            .{ .name = "beep", .help = "synthesize + play a sine through the virtio-snd PCM path ('beep <freq> <ms>' — reports the full control flow + submit/drain accounting)", .usage = "beep <freq> <ms>", .category = .system, .min_args = 2, .max_args = 2, .handler = cmd_beep },
            .{ .name = "about", .help = "explain this questionable system", .usage = "about", .category = .machine_identity, .handler = cmd_about },
            .{ .name = "beans", .help = "count beans, probably", .usage = "beans [count]", .category = .machine_identity, .max_args = 1, .handler = cmd_beans },
            .{ .name = "calc", .help = "calculator utilities: 'calc history' shows saved calculation history from /data/calc_hst.txt", .usage = "calc [history]", .category = .system, .max_args = 1, .handler = cmd_calc },
            .{ .name = "cat", .help = "print a file from the ESP (by name or /path)", .usage = "cat <file|path>", .category = .storage, .min_args = 1, .max_args = 1, .handler = cmd_cat },
            .{ .name = "clear", .help = "clean up the crime scene", .usage = "clear", .category = .system, .handler = cmd_clear },
            .{ .name = "font", .help = "terminal font size: small 8x8 (default), medium 16x16, large 24x24 (M20-U1)", .usage = "font [small|medium|large]", .category = .graphics_input, .min_args = 0, .max_args = 1, .handler = cmd_font },
            .{ .name = "compose", .help = "list available Alt+key compose sequences for accented characters", .usage = "compose", .category = .system, .handler = cmd_compose },
            .{ .name = "crash", .help = "list recent crash tombstones from /data/crash/", .usage = "crash", .category = .system, .handler = cmd_crash },
            .{ .name = "clip", .help = "copy/paste the shared kernel clipboard ('clip <text...>' sets it, 'clip' prints it)", .usage = "clip [<text...>]", .category = .system, .handler = cmd_clip },
            .{ .name = "color", .help = "toggle ANSI terminal colors ('color on'/'color off'; 'color' shows current)", .usage = "color [on|off]", .category = .system, .max_args = 1, .handler = cmd_color },
            .{ .name = "echo", .help = "repeat your regrettable decisions", .usage = "echo <text...>", .category = .system, .handler = cmd_echo },
            .{ .name = "elephant", .help = "operational mascot diagnostics", .usage = "elephant", .category = .machine_identity, .handler = cmd_elephant },
            .{ .name = "exec", .help = "load a user program from the ESP and enter it at EL0", .usage = "exec [<file> [arg...]]", .category = .tasks_processes, .max_args = 1 + esp_exec.max_exec_args, .handler = cmd_exec },
            .{ .name = "fault", .help = "trigger a synchronous exception (diagnostic)", .usage = "fault", .category = .memory_state, .handler = cmd_fault },
            .{ .name = "handoff", .help = "display boot-to-kernel ABI data", .usage = "handoff", .category = .memory_state, .handler = cmd_handoff },
            .{ .name = "help", .help = "grouped command catalog and per-command/per-topic help", .usage = "help [<command>|<topic>]", .category = .system, .max_args = 1, .handler = cmd_help },
            .{ .name = "hex", .help = "format an integer in hexadecimal", .usage = "hex <number>...", .category = .memory_state, .min_args = 1, .handler = cmd_hex },
            .{ .name = "input", .help = "keyboard/pointer event FIFO: armed state, occupancy, drop count, last keyboard + pointer events", .usage = "input", .category = .graphics_input, .handler = cmd_input },
            .{ .name = "kill", .help = "terminate a running process (kernel-owned lifetime)", .usage = "kill <pid|name>", .category = .tasks_processes, .min_args = 1, .max_args = 1, .handler = cmd_kill },
            .{ .name = "ls", .help = "list files on the ESP (or a directory by path); '-l' for long format (D15)", .usage = "ls [-l] [<dir>]", .category = .storage, .max_args = 2, .handler = cmd_ls },
            .{ .name = "mem", .help = "summarize the EFI memory map", .usage = "mem", .category = .memory_state, .handler = cmd_mem },
            .{ .name = "mbox", .help = "per-process IPC mailbox: pending messages and drain counters", .usage = "mbox [<pid>]", .category = .tasks_processes, .max_args = 1, .handler = cmd_mbox },
            .{ .name = "mount", .help = "switch the active FAT volume (esp or data)", .usage = "mount <esp|data>", .category = .storage, .min_args = 1, .max_args = 1, .handler = cmd_mount },
            .{ .name = "net", .help = "virtio-net transport + RX + ARP + ICMP + UDP + DHCP + TCP + DNS: device DID, MAC, queues, feature bits, RX counters ('net recv' prints received frames; 'net ip <a.b.c.d>' sets the static IP; 'net arp [<a.b.c.d>]' shows/resolves the ARP table; 'net ping <a.b.c.d>' sends an ICMP echo request; 'net udp [listen <port>|close <port>|send <addr> <port> <len>|recv [<port>]]' drives UDP; 'net dhcp' runs the bounded DHCP client one step per invocation; 'net tcp [connect <addr> <port>|send <len>|recv|close|reset]' drives the bounded TCP client; 'net dns <hostname> [<server>]' resolves DNS A-records)", .usage = "net [recv|ip <addr>|arp [<addr>]|ping <addr>|udp [listen <port>|close <port>|send <addr> <port> <len>|recv [<port>]]|dhcp|tcp [connect <addr> <port>|send <len>|recv|close|reset]|dns <host> [<server>]]", .category = .networking, .max_args = 5, .handler = cmd_net },
            .{ .name = "netsend", .help = "send a known Ethernet frame (bounded staging, TX + used-ring drain)", .usage = "netsend <bytes>", .category = .networking, .min_args = 1, .max_args = 1, .handler = cmd_netsend },
            .{ .name = "pages", .help = "physical page allocator pool", .usage = "pages [selftest]", .category = .memory_state, .max_args = 1, .handler = cmd_pages },
            .{ .name = "pci", .help = "enumerate PCI devices on the bus", .usage = "pci", .category = .memory_state, .handler = cmd_pci },
            .{ .name = "procs", .help = "process registry: image, address space, lifecycle, exit status", .usage = "procs", .category = .tasks_processes, .handler = cmd_procs },
            .{ .name = "random", .help = "print n random bytes from the seeded CSPRNG (hex)", .usage = "random [n]", .category = .system, .max_args = 1, .handler = cmd_random },
            .{ .name = "resources", .help = "fixed-pool audit: scheduler tasks, process registry, windows, page-table carve-out, and per-process ring bounds", .usage = "resources", .category = .memory_state, .handler = cmd_resources },
            .{ .name = "reboot", .help = "restart the machine", .usage = "reboot", .category = .system, .handler = cmd_reboot },
            .{ .name = "repeat", .help = "repeat text, safely bounded", .usage = "repeat <count> <text...>", .category = .system, .min_args = 1, .handler = cmd_repeat },
            .{ .name = "sh", .help = "run a script file of shell commands ('sh <script>' executes it line by line; 64 lines max, 256 chars per line; '#' comments; 'exit' stops early)", .usage = "sh <script>", .category = .system, .min_args = 1, .max_args = 1, .handler = cmd_sh },
            .{ .name = "roadpops", .help = "Road Pops framebuffer console: armed/dirty/present counters (the boot terminal on the screen)", .usage = "roadpops", .category = .graphics_input, .handler = cmd_roadpops },
            .{ .name = "screen", .help = "virtio-gpu transport + framebuffer: device DID, features, scanout, status, re-arm ('screen fill <rrggbb>' fills the framebuffer and flushes it to the scanout)", .usage = "screen [fill <rrggbb>]", .category = .graphics_input, .max_args = 2, .handler = cmd_screen },
            .{ .name = "screenshot", .help = "capture the current framebuffer (1280x720) and save as BMP to disk (G27)", .usage = "screenshot [<file>]", .category = .graphics_input, .max_args = 1, .handler = cmd_screenshot },
            .{ .name = "settings", .help = "persistent configuration: `settings [list]`, `settings get <key>`, `settings set <key> <val>`, `settings reset`", .usage = "settings [list|get <key>|set <key> <val>|reset]", .category = .system, .max_args = 3, .handler = cmd_settings },
            .{ .name = "shortcuts", .help = "keyboard shortcut reference card (G29)", .usage = "shortcuts", .category = .system, .handler = cmd_shortcuts },
            .{ .name = "sound", .help = "virtio-snd transport: device DID, class, status, control-queue state, device-config counts (jacks/streams/channel-maps), re-arm; stream-state control: 'sound volume <0-100>' and 'sound mute <on|off>'", .usage = "sound [volume <0-100> | mute <on|off>]", .category = .system, .min_args = 0, .max_args = 2, .handler = cmd_sound },
            .{ .name = "text", .help = "framebuffer text: text region, cursor, scrollback ('text put <string...>' renders + flushes to the scanout; 'text clear' clears; 'text putraw' skips the trailing newline; 'text fontdebug [on|off]' missing-glyph stats)", .usage = "text [put <string...>|putraw <string...>|clear|fontdebug [on|off]]", .category = .graphics_input, .min_args = 0, .max_args = 9, .handler = cmd_text },
            .{ .name = "shutdown", .help = "request power-off", .usage = "shutdown", .category = .system, .handler = cmd_shutdown },
            .{ .name = "ps", .help = "process status table: PID, name, state, memory footprint, CPU ticks, and executor task per live/exited process (M22 D6)", .usage = "ps", .category = .tasks_processes, .handler = cmd_ps },
            .{ .name = "spawn", .help = "spawn the lifecycle demo task", .usage = "spawn", .category = .tasks_processes, .handler = cmd_spawn },
            .{ .name = "sysinfo", .help = "comprehensive system and subsystem diagnostic snapshot", .usage = "sysinfo", .category = .machine_identity, .handler = cmd_sysinfo },
            .{ .name = "strace", .help = "trace a program's syscalls: 'strace exec APP.BIN [args]' arms the tracer around an exec and prints one line per syscall; 'strace off' disarms", .usage = "strace exec <file> [args...] | off", .category = .tasks_processes, .handler = cmd_strace },
            .{ .name = "sym", .help = "crash-report symbol table: 'sym' lists symbols loaded from the last ELF exec; 'sym <file>' parses an ELF's symtab from disk", .usage = "sym [<file>]", .category = .tasks_processes, .max_args = 1, .handler = cmd_sym },
            .{ .name = "syscalls", .help = "numbered syscall table and counters", .usage = "syscalls", .category = .tasks_processes, .handler = cmd_syscalls },
            .{ .name = "wm", .help = "M32 WMS2/WMS4/WMS5 render-server register: the registered WM server pid, present-sequence counter, presents, COMPOSITE_TICK count, SET_WINDOW chrome submissions + SET_STATE visibility/workspace calls, and the WMS5 input-seam fan-out counters (ptr_fan = raw pointer samples, win_mirror = registry mirrors, key_fan = raw keyboard samples; 'wm none' means the shell idle shim is compositing)", .usage = "wm", .category = .graphics_input, .handler = cmd_wm },
            .{ .name = "wnd", .help = "M32 WMS3 WM server: 'wnd' reports the registered WM server (pid, present seq/count, tick count; 'wnd: none' = shell-shim compositing); 'wnd start' launches the long-lived EL0 WND.BIN server (infrastructure — not in APPS.TXT; the default VM stays shim-only)", .usage = "wnd [start]", .category = .graphics_input, .max_args = 1, .handler = cmd_wnd },
            .{ .name = "tasks", .help = "tick-driven task scheduler status", .usage = "tasks", .category = .tasks_processes, .handler = cmd_tasks },
            .{ .name = "smp", .help = "multiprocessor topology, online CPU cores, and per-core task state", .usage = "smp", .category = .tasks_processes, .handler = cmd_smp },
            .{ .name = "type", .help = "echo stdin (the pipe source) to stdout — the right half of `a | type`", .usage = "type", .category = .system, .handler = cmd_type },
            .{ .name = "timer", .help = "interrupt controller + timer status", .usage = "timer", .category = .memory_state, .handler = cmd_timer },
            .{ .name = "tour", .help = "guided tour of the system for new users", .usage = "tour", .category = .machine_identity, .handler = cmd_welcome },
            .{ .name = "uaccess", .help = "user-memory copy diagnostics (valid, fault, recovery)", .usage = "uaccess", .category = .memory_state, .handler = cmd_uaccess },
            .{ .name = "usb", .help = "XHCI host controller: `usb` transport report, `usb devices` enumerated HID devices, `usb report` last HID report", .usage = "usb [devices|report]", .category = .graphics_input, .handler = cmd_usb },
            .{ .name = "uname", .help = "compact system identity", .usage = "uname", .category = .machine_identity, .handler = cmd_uname },
            .{ .name = "version", .help = "display build information", .usage = "version", .category = .machine_identity, .handler = cmd_version },
            .{ .name = "welcome", .help = "guided tour of the system for new users", .usage = "welcome", .category = .machine_identity, .handler = cmd_welcome },
            .{ .name = "dui", .help = "Driving Award window manager: registry (with owner pids), z-order, focus, hit-testing ('dui focus <n>' focuses; 'dui raise <n>' raises; 'dui lower <n>' lowers to back; 'dui move <n> <x> <y>' moves a user window; 'dui close <n>' releases a user window; 'dui list <pid>' filters by owner; 'dui hit <x> <y>' hit-tests; 'dui cycle' cycles focus like Alt+Tab; 'dui tile <n>' toggles a user window floating/tiled (M21 W1); 'dui master' swaps master/detail (M21 W2))", .usage = "dui [focus <n>|raise <n>|lower <n>|move <n> <x> <y>|close <n>|list <pid>|hit <x> <y>|cycle|tile <n>|master]", .category = .graphics_input, .max_args = 4, .handler = cmd_dui },
            .{ .name = "write", .help = "write text to a file on the ESP", .usage = "write <file> <text...>", .category = .storage, .min_args = 1, .handler = cmd_write },
            .{ .name = "mktemp", .help = "create a temporary file (empty, unique name)", .usage = "mktemp [prefix]", .category = .storage, .max_args = 1, .handler = cmd_mktemp },
            .{ .name = "stat", .help = "file metadata: size, type, cluster, path (D8)", .usage = "stat <file|path>", .category = .storage, .min_args = 1, .max_args = 1, .handler = cmd_stat },
            .{ .name = "du", .help = "recursive directory disk usage (M25 F4)", .usage = "du [<path>]", .category = .storage, .max_args = 1, .handler = cmd_du },
            .{ .name = "find", .help = "recursive file search with glob patterns ('find / -name \"*.BIN\"' — bounded 3 levels, 256 results)", .usage = "find <dir> -name <pattern>", .category = .storage, .min_args = 3, .max_args = 3, .handler = cmd_find },
            .{ .name = "dmesg", .help = "system log viewer: last bytes of serial output (D12)", .usage = "dmesg", .category = .system, .handler = cmd_dmesg },
            .{ .name = "time", .help = "command timing: measure elapsed ticks and wall-clock time (D13)", .usage = "time <command> [args...]", .category = .system, .min_args = 1, .handler = cmd_time },
            .{ .name = "which", .help = "locate a command: shell builtin, monitor command, or ESP application (D16)", .usage = "which <name>", .category = .system, .min_args = 1, .max_args = 1, .handler = cmd_which },
            .{ .name = "inventory", .help = "list all installed applications from APPS.TXT with sizes and types (D16)", .usage = "inventory", .category = .storage, .handler = cmd_inventory },
        };
        registry_ready = true;
    }
    return &registry_storage;
}

pub fn lookup(name: []const u8) ?*const Command {
    for (ensure_registry()) |*cmd| {
        if (std.mem.eql(u8, cmd.name, name)) return cmd;
    }
    return null;
}

/// Execute an already-tokenized command line: `argv[0]` is the command
/// name, the rest are its arguments. Tokenization and line editing belong
/// to the later Console & Shell Core stream.
pub fn exec(m: *Monitor, argv: []const []const u8) ExecError {
    if (argv.len == 0) {
        // ADR 0008 D3 shape 2: a dispatch-level refusal wears the `error:`
        // prefix like any other. An empty line is not an unknown VERB (there
        // is no verb to quote), so shape 3 would be a lie.
        err_line(m, "no command given; type 'help' for a list of commands");
        return .usage;
    }
    if (argv.len > max_args_limit + 1) {
        err_line(m, too_many_arguments_message);
        return .usage;
    }
    const cmd = lookup(argv[0]) orelse {
        // ADR 0008 D3 shape 3: unknown verb -> `unknown command '<x>' --
        // try 'help'` (the two hyphens are the byte-safe rendering of the
        // ADR's typographic em dash — the framebuffer text layer renders
        // only 0x20..0x7e, so a multi-byte dash would render as blanks).
        m.console.puts("unknown command '");
        m.console.puts(argv[0]);
        m.console.print_line("' -- try 'help'");
        return .unknown_command;
    };
    const args = argv[1..];
    if (args.len < cmd.min_args or args.len > cmd.max_args) {
        print_usage(m, cmd);
        return .usage;
    }
    return cmd.handler(m, args);
}

// ---------------------------------------------------------------------------
// Tab completion (ADR 0008 D2)
// ---------------------------------------------------------------------------

/// Given the line being edited and the cursor, return the suffix to insert
/// (a long-lived slice of a string literal), or null when there is no unique
/// completion. The first token completes against command names; a later
/// token completes against the leading command's fixed sub-verb vocabulary.
pub fn complete(line: []const u8, cursor: usize) ?[]const u8 {
    if (cursor > line.len) return null;
    var start = cursor;
    while (start > 0 and line[start - 1] != ' ' and line[start - 1] != '\t') start -= 1;
    const prefix = line[start..cursor];
    if (prefix.len == 0) return null;
    // The first token (the command name) has only whitespace before it.
    var first = true;
    var i: usize = 0;
    while (i < start) : (i += 1) {
        if (line[i] != ' ' and line[i] != '\t') {
            first = false;
            break;
        }
    }
    if (first) return complete_command(prefix);
    // Sub-verb completion: find the leading command (the first token).
    var cmd_start: usize = 0;
    while (cmd_start < line.len and (line[cmd_start] == ' ' or line[cmd_start] == '\t')) cmd_start += 1;
    var cmd_end = cmd_start;
    while (cmd_end < line.len and line[cmd_end] != ' ' and line[cmd_end] != '\t') cmd_end += 1;
    if (cmd_end <= cmd_start) return null;
    return sub_verb_complete(line[cmd_start..cmd_end], prefix);
}

fn complete_command(prefix: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (ensure_registry()) |*cmd| {
        if (std.mem.startsWith(u8, cmd.name, prefix)) {
            if (found != null) return null; // ambiguous
            found = cmd.name;
        }
    }
    return if (found) |name| name[prefix.len..] else null;
}

fn match_one(prefix: []const u8, verbs: []const []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    for (verbs) |v| {
        if (std.mem.startsWith(u8, v, prefix)) {
            if (found != null) return null; // ambiguous
            found = v;
        }
    }
    return if (found) |v| v[prefix.len..] else null;
}

fn sub_verb_complete(cmd: []const u8, prefix: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, cmd, "net"))
        return match_one(prefix, &.{ "recv", "ip", "arp", "ping", "udp", "dhcp", "tcp" });
    if (std.mem.eql(u8, cmd, "dui"))
        return match_one(prefix, &.{ "focus", "raise", "move", "close", "list", "hit", "cycle" });
    if (std.mem.eql(u8, cmd, "usb"))
        return match_one(prefix, &.{ "devices", "report" });
    if (std.mem.eql(u8, cmd, "screen"))
        return match_one(prefix, &.{"fill"});
    if (std.mem.eql(u8, cmd, "text"))
        return match_one(prefix, &.{ "put", "clear" });
    if (std.mem.eql(u8, cmd, "mount"))
        return match_one(prefix, &.{ "esp", "data" });
    if (std.mem.eql(u8, cmd, "help"))
        return match_one(prefix, &.{ "networking", "windows", "storage", "graphics" });
    return null;
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

/// The one dispatch-level too-many-tokens message, shared by the shell's
/// tokenizer refusal and `exec`'s own guard so the two can never drift.
pub const too_many_arguments_message = "too many arguments (max 17 tokens)";

/// ADR 0008 D3 shape 1: misuse -> `usage: <cmd> <args>` PLUS a one-line
/// hint. The hint is the registry's own blurb for the command, so there is
/// exactly one source for it and no per-handler copy can drift. Sub-verb
/// misuse reuses the command's full usage, so a fourth shape can never slip
/// in on a bad invocation.
fn print_usage(m: *Monitor, cmd: *const Command) void {
    m.console.puts("usage: ");
    m.console.puts(cmd.usage);
    m.console.puts("\n");
    m.console.puts(cmd.help);
    m.console.puts("\n");
}

/// ADR 0008 D3 shape 2: failure -> `error: <actionable message>`. The
/// prefix only; the caller appends the actionable text.
fn err_prefix(m: *Monitor) void {
    m.console.puts("error: ");
}

/// ADR 0008 D3 shape 2 for a fixed message: `error: <text>` on one line.
pub fn err_line(m: *Monitor, text: []const u8) void {
    err_prefix(m);
    m.console.print_line(text);
}

/// Parse a u64 from an optional "0x"/"0X"-prefixed hexadecimal string or a
/// bare decimal string. Explicit bounds: empty input, invalid digits, and
/// overflow are all errors; nothing wraps silently.
pub fn parseInt(text: []const u8) error{ Empty, InvalidDigit, Overflow }!u64 {
    if (text.len == 0) return error.Empty;
    var index: usize = 0;
    const radix: u64 = if (text.len > 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) blk: {
        index = 2;
        break :blk 16;
    } else 10;
    if (index >= text.len) return error.Empty;
    var value: u64 = 0;
    while (index < text.len) : (index += 1) {
        const c = text[index];
        const digit: u64 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return error.InvalidDigit,
        };
        if (radix == 10 and digit >= 10) return error.InvalidDigit;
        value = std.math.mul(u64, value, radix) catch return error.Overflow;
        value = std.math.add(u64, value, digit) catch return error.Overflow;
    }
    return value;
}

pub fn parseSignedInt(text: []const u8) error{ Empty, InvalidDigit, Overflow }!i64 {
    if (text.len == 0) return error.Empty;
    if (text[0] == '-') {
        const u = try parseInt(text[1..]);
        if (u > @as(u64, @intCast(std.math.maxInt(i64))) + 1) return error.Overflow;
        return -@as(i64, @intCast(u));
    }
    const u = try parseInt(text);
    if (u > @as(u64, @intCast(std.math.maxInt(i64)))) return error.Overflow;
    return @as(i64, @intCast(u));
}

/// Hex-only parse (an optional 0x/0X prefix is accepted; the documented
/// `screen fill <rrggbb>` form is bare hex) — used for the color argument.
pub fn parseHex(text: []const u8) error{ Empty, InvalidDigit, Overflow }!u64 {
    if (text.len == 0) return error.Empty;
    var start: usize = 0;
    if (text.len > 2 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) start = 2;
    if (start >= text.len) return error.Empty;
    var value: u64 = 0;
    for (text[start..]) |c| {
        const digit: u64 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return error.InvalidDigit,
        };
        value = std.math.mul(u64, value, 16) catch return error.Overflow;
        value = std.math.add(u64, value, digit) catch return error.Overflow;
    }
    return value;
}

/// "  <label>: <value>"
fn print_plain_field(m: *Monitor, label: []const u8, value: []const u8) void {
    m.console.puts("  ");
    m.console.puts(label);
    m.console.puts(": ");
    m.console.puts(value);
}

/// "  <label>: <hex bytes> bytes (<hex pages> pages)"
fn print_mem_row(m: *Monitor, label: []const u8, pages: u64) void {
    m.console.puts("  ");
    m.console.puts(label);
    m.console.puts(": ");
    m.console.print_hex(memmap.bytes_of(pages));
    m.console.puts(" bytes (");
    m.console.print_hex(pages);
    m.console.puts(" pages)\n");
}

fn report_machine(m: *Monitor, verb: []const u8, result: MachineResult) ExecError {
    switch (result) {
        .ok => {
            m.console.puts(verb);
            m.console.puts(": ok\n");
            return .none;
        },
        .not_implemented => {
            err_prefix(m);
            m.console.puts(verb);
            m.console.print_line(": not implemented - no proven post-ExitBootServices machine-control mechanism; terminal WFE loop continues");
            return .not_implemented;
        },
        .failed => {
            err_prefix(m);
            m.console.puts(verb);
            m.console.print_line(": failed");
            return .machine_failed;
        },
    }
}

// ---------------------------------------------------------------------------
// Identity and inspection commands
// ---------------------------------------------------------------------------

/// `help <topic>` pages (ADR 0008 D1, M27 G28 #471). Bodies are returned as string
/// literals from code (PC-relative at any load base — the claim-0015
/// lesson), never stored in a const table of pointers. Topics are
/// non-command keywords; `syscalls` is a command, so its `help <cmd>` detail
/// is the syscall page rather than a shadowed topic.
fn topic_body(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, "networking") or std.mem.eql(u8, name, "network")) {
        return "networking\n" ++
            "  virtio-net (DID 0x1041), flag-gated by the runner's --net mode: TX + RX,\n" ++
            "  ARP, IPv4/ICMP, UDP, a bounded DHCP client, and an outward-only bounded TCP\n" ++
            "  client with NAT. `net` drives it (recv/ip/arp/ping/udp/dhcp/tcp); `netsend`\n" ++
            "  sends a known frame. EL0 reaches UDP through ADR 0007 slots 9-11.\n" ++
            "  Bounds: static IP, no DNS, TCP is client-only (no listen or loopback).\n";
    }
    if (std.mem.eql(u8, name, "windows")) {
        return "windows\n" ++
            "  Driving Award (G5) owns the window registry: z-order, focus, hit-testing,\n" ++
            "  dirty-rect compositing. Road Pops is window 0; a 1 Hz clock is window 1.\n" ++
            "  `dui` inspects/focuses/raises/moves/closes; EL0 opens windows through ADR 0007\n" ++
            "  slots 12-20 (open/fill/present/close/move/raise/get/query/set_visible). Windows\n" ++
            "  are process-owned and auto-close when their process exits.\n";
    }
    if (std.mem.eql(u8, name, "storage")) {
        return "storage\n" ++
            "  GPT + FAT32 over virtio-blk (DID 0x1042): the ESP boot volume and a second\n" ++
            "  DATA partition. `mount <esp|data>` switches volumes; `ls`/`cat`/`write` read\n" ++
            "  and write files, and writes persist on the disk across reboot.\n";
    }
    if (std.mem.eql(u8, name, "files")) {
        return "files\n" ++
            "  GPT + FAT32 filesystem access: `ls`, `cat`, `write`, `find`, `stat`,\n" ++
            "  `du`, and `inventory`. Persistent file operations on ESP and DATA partitions.\n";
    }
    if (std.mem.eql(u8, name, "graphics")) {
        return "graphics\n" ++
            "  virtio-gpu (DID 0x1050) framebuffer: `screen` reports/fills the scanout,\n" ++
            "  `text` renders the 8x8 font, Road Pops is the on-screen terminal, and Driving\n" ++
            "  Award composites windows over it. 1280x720 B8G8R8X8, 2D blits only.\n";
    }
    if (std.mem.eql(u8, name, "editor")) {
        return "editor\n" ++
            "  Full-screen and windowed text editing via EDIT.BIN and NOTEPAD.BIN.\n" ++
            "  Shortcuts: Ctrl+S save, Ctrl+O open, Ctrl+N new, Ctrl+Z undo, Ctrl+Y redo,\n" ++
            "  Ctrl+F find, Ctrl+Q quit. Full clipboard integration on Ctrl+C/Ctrl+V/Ctrl+X.\n";
    }
    if (std.mem.eql(u8, name, "calc")) {
        return "calc\n" ++
            "  64-bit Programmer, Scientific, and Basic calculator modes (CALC.BIN).\n" ++
            "  Base conversions (HEX/DEC/OCT/BIN), bitwise logic (AND/OR/XOR/NOT/SHL/SHR),\n" ++
            "  scientific functions (trig, exp, log), and persistent calculation history.\n";
    }
    if (std.mem.eql(u8, name, "system")) {
        return "system\n" ++
            "  Machine management and diagnostic commands: `sysinfo`, `uname`, `version`,\n" ++
            "  `settings` (theme, prompt, font, scrollback), `shutdown`, `reboot`,\n" ++
            "  `dmesg`, `time`, and crash tombstone viewing with `crash`.\n";
    }
    if (std.mem.eql(u8, name, "shortcuts")) {
        return "shortcuts\n" ++
            "  Global: Ctrl+Shift+A (About), Ctrl+Shift+/ (Shortcuts), Alt+Tab (Switch window),\n" ++
            "  Alt+F4 (Close window), F11 (Fullscreen/Tile), Ctrl+Alt+Del (Reboot).\n" ++
            "  Navigation: Tab / Shift+Tab (Focus control), Enter/Space (Activate), Esc (Dismiss).\n" ++
            "  Editing: Ctrl+C (Copy), Ctrl+X (Cut), Ctrl+V (Paste), Ctrl+Z (Undo), Ctrl+S (Save).\n" ++
            "  Run `shortcuts` command for full list.\n";
    }
    if (std.mem.eql(u8, name, "dev") or std.mem.eql(u8, name, "diag")) {
        return "dev / diag\n" ++
            "  Developer tools and diagnostics: `strace` (syscall tracer), `sym` (symbol table),\n" ++
            "  `disas` (AArch64 disassembler), `asm` (assembler), `ps` (process table),\n" ++
            "  `crash` (tombstone viewer), `resources` (pool audit), `which` / `inventory`.\n";
    }
    return null;
}

fn cmd_help(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 1) {
        if (std.mem.eql(u8, args[0], "--all")) {
            m.console.print_line("all monitor commands:");
            const reg = ensure_registry();
            for (reg) |cmd| {
                m.console.puts("  ");
                m.console.puts(cmd.name);
                m.console.puts(" - ");
                m.console.puts(cmd.help);
                m.console.puts("\n    usage: ");
                m.console.puts(cmd.usage);
                m.console.puts("\n");
            }
            return .none;
        }
        if (lookup(args[0])) |cmd| {
            m.console.puts(cmd.name);
            m.console.puts(" - ");
            m.console.puts(cmd.help);
            m.console.puts("\nusage: ");
            m.console.puts(cmd.usage);
            m.console.puts("\n");
            return .none;
        }
        if (topic_body(args[0])) |body| {
            m.console.puts(body);
            return .none;
        }
        err_prefix(m);
        m.console.puts("no such command or topic: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    }
    m.console.print_line("available commands:");
    const reg = ensure_registry();
    var width: usize = 0;
    for (reg) |cmd| width = @max(width, cmd.name.len);
    for (category_order) |cat| {
        m.console.puts(category_name(cat));
        m.console.puts("\n");
        for (reg) |cmd| {
            if (cmd.category != cat) continue;
            m.console.puts("  ");
            m.console.puts(cmd.name);
            var pad: usize = cmd.name.len;
            while (pad < width) : (pad += 1) m.console.putc(' ');
            m.console.puts("  ");
            m.console.puts(cmd.help);
            m.console.puts("\n");
        }
    }
    m.console.print_line("type 'help <command>' for details on a single command.");
    m.console.print_line("type 'help <topic>' for a topic page (networking, windows, storage, graphics).");
    return .none;
}

fn cmd_about(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    m.console.print_line("DipshitOS is a from-scratch AArch64 operating system.");
    m.console.print_line("Written in freestanding Zig: no libc, no POSIX.");
    m.console.print_line("Hosted under Apple Virtualization.framework on Apple silicon.");
    m.console.print_line("Core subsystems: identity-map MMU, GICv3 PPI timer, round-robin");
    m.console.print_line("scheduler, per-task TTBR0 address spaces, EL0 processes & SVC (ADR 0007),");
    m.console.print_line("ESP/DATA FAT32 storage, virtio-net (ARP/ICMP/UDP/DHCP/TCP), Driving Award");
    m.console.print_line("window compositor + Road Pops terminal, and Apple xHCI USB HID input.");
    m.console.print_line("Type 'help' for the grouped command catalog, or 'welcome' for a tour.");
    return .none;
}

fn cmd_welcome(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    m.console.print_line("Welcome to DipshitOS! Here is a quick tour to get you oriented:");
    m.console.print_line("  1. Discovery: Type 'help' to see grouped commands, or 'help <cmd>' / 'help <topic>' for details.");
    m.console.print_line("  2. System Info: Type 'version', 'uname', or 'about' for architectural details.");
    m.console.print_line("  3. Tasks & Procs: Type 'procs' to view active processes or 'tasks' for scheduler states.");
    m.console.print_line("  4. Storage: Type 'ls' and 'cat <file>' to view files on the ESP; 'mount data' to switch volumes.");
    m.console.print_line("  5. Windows & Graphics: Type 'win' to inspect window registry and z-order; 'dui cycle' to cycle focus.");
    m.console.print_line("  6. Networking: Type 'net' for device status, 'net ping <ip>' or 'net dhcp' to configure.");
    m.console.print_line("  7. Documentation: Architecture, decisions, and hardware contracts live in docs/.");
    m.console.print_line("Have fun and break things responsibly.");
    return .none;
}

fn cmd_sysinfo(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    const h = &m.state.handoff;
    const map_summary = memmap.summarize(m.state.map);
    const p_stats = alloc.stats();
    const sched_rep = scheduler.stats();
    const win_armed = driving_award.armed();
    const rp_rep = road_pops.report();
    const in_rep = input.report();

    m.console.print_line("sysinfo: DipshitOS AArch64 support snapshot");

    // System & Handoff
    m.console.puts("  system:     kernel=dipshit-kernel handoff=v2 status=");
    if (handoff.validate(h) == .none) {
        m.console.print_line("valid");
    } else {
        m.console.print_line("invalid");
    }

    // CPU & Timer
    m.console.puts("  cpu:        arch=aarch64 timer_armed=");
    m.console.puts(if (timer.armed()) "1" else "0");
    m.console.puts(" gic=");
    m.console.puts(gic.kind_name());
    m.console.puts(" ticks=");
    m.console.print_u64(timer.ticks);
    m.console.puts(" irq=");
    m.console.print_u64(timer.irq_ticks);
    m.console.puts("\n");

    // Memory & Allocator
    m.console.puts("  memory:     descriptors=");
    m.console.print_u64(m.state.map.count);
    m.console.puts(" usable=");
    m.console.print_hex(map_summary.usable_pages * memmap.page_size);
    m.console.puts(" (");
    m.console.print_hex(map_summary.usable_pages);
    m.console.puts(" pages)\n");

    m.console.puts("  allocator:  armed=");
    m.console.puts(if (p_stats.armed) "1" else "0");
    m.console.puts(" total=");
    m.console.print_hex(p_stats.total_pages);
    m.console.puts(" free=");
    m.console.print_hex(p_stats.free_pages);
    m.console.puts(" excluded=");
    m.console.print_hex(p_stats.excluded_pages);
    m.console.puts(" regions=");
    m.console.print_hex(@intCast(p_stats.region_count));
    m.console.puts("\n");

    // Tasks & Processes
    m.console.puts("  scheduler:  enabled=");
    m.console.puts(if (sched_rep.enabled) "1" else "0");
    m.console.puts(" tasks=");
    m.console.print_u64(sched_rep.count);
    m.console.puts("/");
    m.console.print_u64(scheduler.max_tasks);
    m.console.puts(" switches=");
    m.console.print_u64(sched_rep.switches);
    m.console.puts("\n");

    m.console.puts("  processes:  active=");
    m.console.print_u64(@intCast(process.count()));
    m.console.puts("/");
    m.console.print_u64(process.max_processes);
    m.console.puts("\n");

    // Storage
    m.console.puts("  storage:    fat_volume=");
    m.console.puts(esp.volume());
    m.console.puts(" files=");
    m.console.print_u64(@intCast(esp.esp_count()));
    const free_bytes = fat.free_space();
    const total_bytes = @as(u64, @intCast(fat.geometry().total_clusters)) * @as(u64, @intCast(fat.geometry().spc)) * fat.sector_size;
    if (total_bytes > 0) {
        m.console.puts(" free=");
        m.console.print_hex(free_bytes);
        m.console.puts("/");
        m.console.print_hex(total_bytes);
    }
    m.console.puts("\n");

    // Network
    m.console.puts("  network:    virtio-net=");
    m.console.puts(if (virtio_net.net_ready) "armed" else "unarmed");
    if (virtio_net.net_ready) {
        m.console.puts(" mac=");
        m.console.puts(&virtio_net.net_mac_text);
        m.console.puts(" ip=");
        var ipbuf: [15]u8 = undefined;
        const n = virtio_net.arp.format_ip(virtio_net.arp.own_ip, &ipbuf);
        m.console.puts(ipbuf[0..n]);
    }
    m.console.puts("\n");

    // Graphics & Windows
    m.console.puts("  graphics:   gpu=");
    m.console.puts(if (virtio_gpu.gpu_ready) "armed" else "unarmed");
    m.console.puts(" roadpops=");
    m.console.puts(if (rp_rep.armed) "armed" else "unarmed");
    m.console.puts(" windows=");
    if (win_armed) {
        m.console.print_u64(driving_award.count());
        m.console.puts(" focused=");
        m.console.print_u64(driving_award.focused_window_id());
    } else {
        m.console.puts("unarmed");
    }
    m.console.puts("\n");

    // Input
    m.console.puts("  input:      xhci=");
    m.console.puts(if (xhci.xhci_ready) "armed" else "unarmed");
    m.console.puts(" devices=");
    m.console.print_u64(xhci.enum_count);
    m.console.puts(" fifo=");
    m.console.puts(if (in_rep.armed) "armed" else "unarmed");
    m.console.puts("\n");

    // Uptime
    m.console.puts("  uptime:     ticks=");
    m.console.print_u64(timer.ticks);
    m.console.puts("\n");

    return .none;
}

fn cmd_version(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    m.console.print_line("dipshit-kernel");
    m.console.print_line("milestone-two kernel proper (ADR 0004)");
    m.console.print_line("handoff ABI v2");
    m.console.print_line("build label: m1.5 commands & personality (mock console)");
    return .none;
}

fn cmd_uname(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    m.console.print_line("DipshitOS aarch64");
    m.console.print_line("freestanding kernel; no POSIX compatibility");
    return .none;
}

fn cmd_handoff(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    const h = &m.state.handoff;
    m.console.print_line("handoff v2");
    const fields = [_]struct { label: []const u8, value: u64 }{
        .{ .label = "magic", .value = h.magic },
        .{ .label = "version", .value = h.version },
        .{ .label = "kernel_base", .value = h.kernel_base },
        .{ .label = "kernel_size", .value = h.kernel_size },
        .{ .label = "system_table", .value = h.system_table },
        .{ .label = "image_handle", .value = h.image_handle },
        .{ .label = "stack_base", .value = h.stack_base },
        .{ .label = "stack_size", .value = h.stack_size },
        .{ .label = "flags", .value = h.flags },
    };
    for (fields) |field| {
        m.console.puts("  ");
        m.console.puts(field.label);
        var pad: usize = field.label.len;
        while (pad < 12) : (pad += 1) m.console.putc(' ');
        m.console.puts(" ");
        m.console.print_hex(field.value);
        m.console.puts("\n");
    }
    m.console.puts("  status");
    var pad: usize = "status".len;
    while (pad < 12) : (pad += 1) m.console.putc(' ');
    m.console.puts(" ");
    const err = handoff.validate(h);
    if (err == .none) {
        m.console.print_line("valid");
    } else {
        m.console.puts("invalid (");
        m.console.puts(handoff.error_name(err));
        m.console.puts(")\n");
    }
    return .none;
}

fn cmd_mem(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    const view = m.state.map;
    const summary = memmap.summarize(view);
    m.console.puts("mem: descriptors=");
    m.console.print_hex(@intCast(view.count));
    m.console.puts(" size=");
    m.console.print_hex(@intCast(view.descriptor_size));
    m.console.puts(" version=");
    m.console.print_hex(view.descriptor_version);
    m.console.puts(" key=");
    m.console.print_hex(view.key);
    m.console.puts("\n");
    print_mem_row(m, "usable", summary.usable_pages);
    print_mem_row(m, "conventional", summary.conventional_pages);
    print_mem_row(m, "loader", summary.loader_pages);
    print_mem_row(m, "boot_services", summary.boot_services_pages);
    print_mem_row(m, "runtime", summary.runtime_pages);
    print_mem_row(m, "reserved", summary.reserved_pages);
    print_mem_row(m, "mmio", summary.mmio_pages);
    // Kernel image bounds come from the handoff record, not the map. The
    // end address is computed with a checked add so a hostile handoff can
    // never wrap (or panic a Debug build) — the same saturating policy as
    // the map summary.
    const h = &m.state.handoff;
    const kernel_end = std.math.add(u64, h.kernel_base, h.kernel_size) catch std.math.maxInt(u64);
    m.console.puts("  kernel: ");
    m.console.print_hex(h.kernel_base);
    m.console.puts("..");
    m.console.print_hex(kernel_end);
    m.console.puts(" (");
    m.console.print_hex(h.kernel_size);
    m.console.puts(" bytes)\n");
    return .none;
}

// ---------------------------------------------------------------------------
// ESP file-window commands (claim 3475 hard gate 5; FAT-backed since
// claim 6420)
// ---------------------------------------------------------------------------

/// List files: no argument lists the ESP root window (unchanged behavior);
/// a `/`-path lists a subdirectory straight from the FAT volume (milestone
/// four card 2 Stage C). Deterministic and grep-able.
/// M22 D15 (issue #338): `ls [-l] [<dir>]` — list files with optional
/// long listing format showing type, permissions, owner, size, and name.
fn cmd_ls(m: *Monitor, args: []const []const u8) ExecError {
    var long_mode = false;
    var path_arg: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-l")) {
            long_mode = true;
        } else {
            path_arg = arg;
        }
    }
    if (path_arg) |path| return cmd_ls_path_long(m, path, long_mode);
    // Root listing
    m.console.puts("ls: ");
    m.console.puts(esp.volume());
    m.console.puts("=");
    m.console.print_hex(@intCast(esp.esp_count()));
    m.console.puts("\n");
    const list = esp.entries();
    if (list.len == 0) {
        m.console.print_line("ls: no files on the ESP (FAT volume unavailable or empty)");
        return .none;
    }
    if (long_mode) {
        for (list) |e| {
            print_ls_long_entry(m, e.name[0..e.name_len], e.size, e.kind == .esp_dir);
        }
    } else {
        var width: usize = 0;
        for (list) |e| width = @max(width, e.name_len);
        for (list) |e| {
            m.console.puts("  ");
            m.console.puts(e.name[0..e.name_len]);
            var pad: usize = e.name_len;
            while (pad < width) : (pad += 1) m.console.putc(' ');
            m.console.puts("  ");
            m.console.print_hex(e.size);
            m.console.puts("  [");
            m.console.puts(switch (e.kind) {
                .esp_dir => "dir",
                .esp_file => esp.volume(),
            });
            m.console.puts("]\n");
        }
    }
    return .none;
}

/// List a directory by `/`-path, straight from the FAT volume (the window
/// only snapshots the root). Same row format as the root listing, with a
/// path-aware header. Honest diagnostics distinguish a file ("is a file")
/// from an absent/non-directory path ("not found").
fn cmd_ls_path(m: *Monitor, path: []const u8) ExecError {
    return cmd_ls_path_long(m, path, false);
}

fn cmd_ls_path_long(m: *Monitor, path: []const u8, long_mode: bool) ExecError {
    var list: [esp.entries_max]fat.DirEntry = undefined;
    const n = fat.list_path(path, &list);
    if (n == 0) {
        err_prefix(m);
        m.console.puts(path);
        if (fat.file_size(path) != null) {
            m.console.print_line(": is a file, not a directory");
        } else {
            m.console.print_line(": not found (no such directory on the FAT volume)");
        }
        return .invalid_argument;
    }
    m.console.puts("ls: ");
    m.console.puts(path);
    m.console.puts(" entries=");
    m.console.print_hex(@intCast(n));
    m.console.puts("\n");
    if (long_mode) {
        for (list[0..n]) |e| {
            print_ls_long_entry(m, e.name[0..e.name_len], e.size, e.is_dir);
        }
    } else {
        var width: usize = 0;
        for (list[0..n]) |e| width = @max(width, e.name_len);
        for (list[0..n]) |e| {
            m.console.puts("  ");
            m.console.puts(e.name[0..e.name_len]);
            var pad: usize = e.name_len;
            while (pad < width) : (pad += 1) m.console.putc(' ');
            m.console.puts("  ");
            m.console.print_hex(e.size);
            m.console.puts("  [");
            m.console.puts(if (e.is_dir) "dir" else esp.volume());
            m.console.puts("]\n");
        }
    }
    return .none;
}

/// M22 D15: print one entry in `ls -l` long format.
fn print_ls_long_entry(m: *Monitor, name: []const u8, size: u64, is_dir: bool) void {
    // Type + permissions
    m.console.putc(if (is_dir) 'd' else '-');
    if (is_dir) {
        m.console.print_line("rwx     1  root");
    } else {
        m.console.print_line("rw-     1  root");
    }
    // Indent + size + name
    m.console.puts("        ");
    m.console.print_u64(size);
    var pad_buf: [20]u8 = undefined;
    var sz_digits: usize = 0;
    var v = size;
    if (v == 0) {
        pad_buf[0] = '0';
        sz_digits = 1;
    }
    while (v > 0) : (v /= 10) {
        pad_buf[sz_digits] = @intCast('0' + v % 10);
        sz_digits += 1;
    }
    // Pad to 8 chars
    var i: usize = sz_digits;
    while (i < 8) : (i += 1) m.console.putc(' ');
    m.console.puts("  ");
    m.console.print_line(name);
}

/// Switch the active FAT volume (milestone four card 2): `mount esp`
/// re-mounts the EFI System Partition by its GPT type GUID; `mount data`
/// mounts the second FAT32 partition (the general-filesystem volume) by
/// its GUID. The window re-snapshots the newly active volume's root,
/// labeled honestly (`ls: <volume>=..`, `[<volume>]`).
fn cmd_mount(m: *Monitor, args: []const []const u8) ExecError {
    const name = args[0];
    const is_data = std.mem.eql(u8, name, "data");
    if (!is_data and !std.mem.eql(u8, name, "esp")) {
        err_prefix(m);
        m.console.puts("unknown volume: ");
        m.console.puts(name);
        m.console.print_line(" (expected esp or data)");
        return .invalid_argument;
    }
    const r = if (is_data) fat.mount_data(virtio_blk.disk_ops()) else fat.mount(virtio_blk.disk_ops());
    switch (r) {
        .ok => {
            esp.set_volume(if (is_data) "data" else "esp");
            esp.resnapshot();
            m.console.puts("mount: ");
            m.console.puts(name);
            m.console.puts(" vol_lba=");
            m.console.print_hex(fat.geometry().vol_lba);
            m.console.puts(" files=");
            m.console.print_hex(@intCast(esp.entry_count()));
            m.console.puts("\n");
            return .none;
        },
        .no_disk => {
            err_prefix(m);
            m.console.puts(name);
            m.console.print_line(": no disk (FAT volume unavailable)");
            return .not_implemented;
        },
        .bad_gpt => {
            err_prefix(m);
            m.console.puts(name);
            m.console.print_line(": partition not found (bad GPT or no such type GUID)");
            return .machine_failed;
        },
        .bad_bpb => {
            err_prefix(m);
            m.console.puts(name);
            m.console.print_line(": not a FAT32 volume (bad BPB)");
            return .machine_failed;
        },
        .io_failed => {
            err_prefix(m);
            m.console.puts(name);
            m.console.puts(": sector I/O failed (last lba=");
            m.console.print_hex_min(fat.last_fail_lba());
            m.console.print_line(")");
            return .machine_failed;
        },
    }
}

/// Calculator utilities: 'calc history' reads and prints /data/calc_hst.txt
/// (M24 K5 — the persisted calculation history ring).
fn cmd_calc(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 0 or std.mem.eql(u8, args[0], "history")) {
        const path = "/data/calc_hst.txt";
        const size = fat.file_size(path) orelse {
            err_prefix(m);
            m.console.print_line("calc: no history file found (/data/calc_hst.txt)");
            return .none;
        };
        if (size == 0) {
            m.console.print_line("calc: history is empty");
            return .none;
        }
        var buf: [esp.write_content_max]u8 = undefined;
        if (size > @as(u32, @intCast(buf.len))) {
            err_prefix(m);
            m.console.puts("calc: history file is ");
            m.console.print_hex(size);
            m.console.puts(" bytes; display caps at ");
            m.console.print_hex(esp.write_content_max);
            m.console.print_line(" bytes");
            return .invalid_argument;
        }
        const got = fat.read_file(path, &buf) orelse {
            err_prefix(m);
            m.console.print_line("calc: failed to read history file");
            return .invalid_argument;
        };
        // Count lines for the header
        var lines: u32 = 0;
        for (buf[0..got]) |ch| {
            if (ch == '\n') lines += 1;
        }
        m.console.puts("calc history (");
        m.console.print_u64(lines);
        m.console.print_line(" entries):\n");
        m.console.puts(buf[0..got]);
        if (got > 0 and buf[got - 1] != '\n') m.console.puts("\n");
        return .none;
    }
    // M24 K11 (issue #375) — Lane B shared-file insertion (Rule 4, one
    // self-contained commit): any non-`history` argument is an expression
    // for CALC.BIN's CLI mode; hand the args over verbatim. CALC.BIN
    // evaluates, prints "<expr> = <result>", and exits — no GUI window.
    // A no-args or `calc history` invocation never reaches this path.
    if (args.len >= 1 and esp_exec.max_exec_args >= args.len) {
        switch (esp_exec.exec_file("CALC.BIN", args)) {
            .ok => return .none,
            else => {}, // fall through to the honest error below
        }
    }
    err_prefix(m);
    m.console.puts("unknown calc subcommand: ");
    m.console.print_line(args[0]);
    print_usage(m, lookup("calc").?);
    return .invalid_argument;
}

/// Print a file's content — a bare name serves the ESP window (unchanged
/// behavior); a `/`-path reads the FAT volume directly (milestone four
/// card 2 Stage C). Honest diagnostics for directories, files larger than
/// the bounded read buffer, and unknown paths.
fn cmd_cat(m: *Monitor, args: []const []const u8) ExecError {
    const name = args[0];
    if (std.mem.indexOfScalar(u8, name, '/') != null) return cmd_cat_path(m, name);
    const e = esp.lookup(name) orelse {
        err_prefix(m);
        m.console.puts(name);
        m.console.print_line(": not found (no such file on the ESP)");
        return .invalid_argument;
    };
    switch (e.kind) {
        .esp_dir => {
            err_prefix(m);
            m.console.puts(name);
            m.console.print_line(": is a directory");
            return .invalid_argument;
        },
        .esp_file => {
            if (e.len == 0 and e.size > 0) {
                err_prefix(m);
                m.console.puts(name);
                m.console.puts(": content not loaded (file is ");
                m.console.print_hex(e.size);
                m.console.puts(" bytes; the window keeps files up to ");
                m.console.print_hex(esp.esp_content_max);
                m.console.print_line(" bytes)");
                return .invalid_argument;
            }
        },
    }
    const content = esp.content_of(e);
    m.console.puts(content);
    // A trailing newline keeps the shell prompt on its own line; a file
    // that already ends with one is printed verbatim (no double blank).
    if (content.len == 0 or content[content.len - 1] != '\n') m.console.puts("\n");
    return .none;
}

/// Print a file by `/`-path, read straight from the FAT volume. The file's
/// size is checked first: a file larger than the bounded read buffer is
/// reported honestly (never silently truncated).
fn cmd_cat_path(m: *Monitor, path: []const u8) ExecError {
    const size = fat.file_size(path) orelse {
        err_prefix(m);
        m.console.puts(path);
        m.console.print_line(": not found (no such file on the FAT volume)");
        return .invalid_argument;
    };
    var buf: [esp.write_content_max]u8 = undefined;
    if (size > @as(u32, @intCast(buf.len))) {
        err_prefix(m);
        m.console.puts(path);
        m.console.puts(": file is ");
        m.console.print_hex(size);
        m.console.puts(" bytes; direct read caps at ");
        m.console.print_hex(esp.write_content_max);
        m.console.print_line(" bytes");
        return .invalid_argument;
    }
    const got = fat.read_file(path, &buf) orelse {
        err_prefix(m);
        m.console.puts(path);
        m.console.print_line(": not found (no such file on the FAT volume)");
        return .invalid_argument;
    };
    m.console.puts(buf[0..got]);
    if (got == 0 or buf[got - 1] != '\n') m.console.puts("\n");
    return .none;
}

/// Write text to the ESP's FAT32 volume (claim 6420 — the real storage
/// driver replacing claim 3475's NVRAM variables): the file survives
/// reboot because it is on the disk itself. Capacity is checked before the
/// write; a failed sector write is reported honestly, never faked.
fn cmd_write(m: *Monitor, args: []const []const u8) ExecError {
    const name = args[0];
    const parts = args[1..];
    var len: usize = 0;
    for (parts, 0..) |p, i| len += p.len + (if (i > 0) @as(usize, 1) else 0);
    if (len > esp.write_content_max) {
        err_prefix(m);
        m.console.puts("content too long (max ");
        m.console.print_hex(esp.write_content_max);
        m.console.puts(" bytes, got ");
        m.console.print_hex(@intCast(len));
        m.console.print_line(")");
        return .invalid_argument;
    }
    var buf: [esp.write_content_max]u8 = undefined;
    var n: usize = 0;
    for (parts, 0..) |p, i| {
        if (i > 0) {
            buf[n] = ' ';
            n += 1;
        }
        @memcpy(buf[n..][0..p.len], p);
        n += p.len;
    }
    switch (esp.write_file(name, buf[0..n])) {
        .ok => {
            m.console.puts("write: ok (persisted ");
            m.console.print_u64(n);
            m.console.puts(" bytes to FAT on the ");
            m.console.puts(esp.volume());
            m.console.puts(")\n");
            return .none;
        },
        .no_disk => {
            err_prefix(m);
            m.console.puts(name);
            m.console.print_line(": not persisted - no disk (FAT volume unavailable)");
            return .not_implemented;
        },
        .name_invalid => {
            err_prefix(m);
            m.console.puts("invalid file name: ");
            m.console.puts(name);
            m.console.puts(" (max ");
            m.console.print_u64(esp.name_max);
            m.console.puts(" printable ASCII chars, no '/' or '\\')\n");
            return .invalid_argument;
        },
        .name_too_long => {
            err_prefix(m);
            m.console.puts(name);
            m.console.print_line(": does not fit FAT 8.3 (max 8 chars + 3-char extension)");
            return .invalid_argument;
        },
        .content_too_long => {
            err_prefix(m);
            m.console.puts("content too long (max ");
            m.console.print_hex(esp.write_content_max);
            m.console.puts(" bytes, got ");
            m.console.print_hex(@intCast(n));
            m.console.print_line(")");
            return .invalid_argument;
        },
        .bad_path => {
            err_prefix(m);
            m.console.puts(name);
            m.console.print_line(": parent directory not found");
            return .invalid_argument;
        },
        .disk_full => {
            err_prefix(m);
            m.console.puts(name);
            m.console.print_line(": not persisted - disk full (no free cluster or root-directory slot)");
            return .invalid_argument;
        },
        .write_failed => {
            err_prefix(m);
            m.console.puts(name);
            m.console.puts(": FAT write failed (last lba=");
            m.console.print_hex_min(fat.last_fail_lba());
            m.console.print_line(") - file NOT persisted");
            return .machine_failed;
        },
    }
}

/// M19 P16 (issue #305): create a temporary file with a unique name.
/// Usage: mktemp [prefix] - creates prefix_XXXX.BIN (default TMP_XXXX.BIN).
fn cmd_mktemp(m: *Monitor, args: []const []const u8) ExecError {
    const prefix = if (args.len > 0) args[0] else "TMP";
    // Generate 4 random hex digits.
    var rnd: [2]u8 = undefined;
    csprng.random_bytes(&rnd);
    const hex = "0123456789abcdef";
    var suffix: [4]u8 = undefined;
    suffix[0] = hex[(rnd[0] >> 4) & 0x0f];
    suffix[1] = hex[rnd[0] & 0x0f];
    suffix[2] = hex[(rnd[1] >> 4) & 0x0f];
    suffix[3] = hex[rnd[1] & 0x0f];
    // Build filename: PREFIX_XXXX.BIN
    var name_buf: [32]u8 = undefined;
    var n: usize = 0;
    for (prefix) |b| {
        if (n < name_buf.len - 10) {
            name_buf[n] = b;
            n += 1;
        }
    }
    if (n < name_buf.len - 10) {
        name_buf[n] = '_';
        n += 1;
    }
    @memcpy(name_buf[n..][0..4], &suffix);
    n += 4;
    @memcpy(name_buf[n..][0..4], ".BIN");
    n += 4;
    const name = name_buf[0..n];
    // Create empty file.
    switch (esp.write_file(name, "")) {
        .ok => {
            m.console.puts(name);
            m.console.puts("\n");
            return .none;
        },
        .no_disk => {
            err_prefix(m);
            m.console.puts(name);
            m.console.print_line(": no disk available");
            return .not_implemented;
        },
        .name_invalid => {
            err_prefix(m);
            m.console.puts(name);
            m.console.print_line(": invalid filename");
            return .invalid_argument;
        },
        else => {
            err_prefix(m);
            m.console.puts(name);
            m.console.print_line(": write failed");
            return .invalid_argument;
        },
    }
}

// ---------------------------------------------------------------------------
// M22 Lane-D: filesystem inspection (D8), log viewer (D12), timing (D13),
// command locator (D16)
// ---------------------------------------------------------------------------

/// M22 D8 (issue #331): `stat <file|path>` — print file metadata from the
/// FAT volume: size, type (file/dir), cluster, and path. Bare names check
/// the ESP window; `/`-paths query the FAT directly.
fn cmd_stat(m: *Monitor, args: []const []const u8) ExecError {
    const name = args[0];
    // Path-based stat: resolve through FAT directory listing
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        // Extract parent dir and filename from the path
        const last_slash = std.mem.lastIndexOfScalar(u8, name, '/') orelse 0;
        const parent = if (last_slash > 0) name[0..last_slash] else "/";
        const filename = name[last_slash + 1 ..];
        if (filename.len == 0) {
            err_prefix(m);
            m.console.puts("stat: ");
            m.console.puts(name);
            m.console.print_line(": not a file");
            return .invalid_argument;
        }
        var entries: [esp.entries_max]fat.DirEntry = undefined;
        const n = fat.list_path(parent, &entries);
        var found = false;
        for (entries[0..n]) |e| {
            if (std.mem.eql(u8, e.name[0..e.name_len], filename)) {
                print_stat_entry(m, &e, name);
                found = true;
                break;
            }
        }
        if (!found) {
            err_prefix(m);
            m.console.puts("stat: ");
            m.console.puts(name);
            m.console.print_line(": not found");
            return .invalid_argument;
        }
        return .none;
    }
    // Bare-name stat: check the ESP window first
    if (esp.lookup(name)) |e| {
        m.console.puts("  File:  ");
        m.console.print_line(name);
        m.console.puts("  Size:  ");
        m.console.print_u64(e.size);
        m.console.print_line(" bytes");
        m.console.puts("  Type:  ");
        m.console.print_line(switch (e.kind) {
            .esp_dir => "directory",
            .esp_file => "regular file",
        });
        m.console.puts("  Volume: ");
        m.console.print_line(esp.volume());
        return .none;
    }
    // Not in ESP window — try FAT path (it might be a subdirectory entry)
    var entries: [esp.entries_max]fat.DirEntry = undefined;
    const n = fat.list_path("/", &entries);
    for (entries[0..n]) |e| {
        if (std.mem.eql(u8, e.name[0..e.name_len], name)) {
            print_stat_entry(m, &e, name);
            return .none;
        }
    }
    err_prefix(m);
    m.console.puts("stat: ");
    m.console.puts(name);
    m.console.print_line(": not found");
    return .invalid_argument;
}

fn print_stat_entry(m: *Monitor, e: *const fat.DirEntry, path: []const u8) void {
    m.console.puts("  File:    ");
    m.console.print_line(path);
    m.console.puts("  Size:    ");
    m.console.print_u64(e.size);
    m.console.print_line(" bytes");
    m.console.puts("  Type:    ");
    m.console.print_line(if (e.is_dir) "directory" else "regular file");
    m.console.puts("  Cluster: ");
    m.console.print_hex(e.cluster);
    m.console.puts("\n");
}

/// M25 F4 (issue #384): `du [<path>]` — estimate file space usage recursively
/// (bounded: 3 levels deep).
fn cmd_du(m: *Monitor, args: []const []const u8) ExecError {
    const path = if (args.len > 0) args[0] else "";
    const res = fat.dir_size_recursive(path);
    m.console.puts("du: ");
    m.console.puts(if (path.len > 0) path else "/");
    m.console.puts(" ");
    m.console.print_u64(res.bytes);
    m.console.puts(" bytes (dirs=");
    m.console.print_u64(res.dirs_walked);
    if (res.truncated) {
        m.console.puts(", truncated");
    }
    m.console.print_line(")");
    return .none;
}

/// M22 D8 (issue #331): `find <dir> -name <pattern>` — recursive file
/// search with simple glob patterns (* and ?). Bounded: 3 levels deep,
/// 256 results max.
fn cmd_find(m: *Monitor, args: []const []const u8) ExecError {
    const start_path = args[0];
    // args[1] should be "-name"
    if (!std.mem.eql(u8, args[1], "-name")) {
        err_prefix(m);
        m.console.print_line("find: expected '-name' keyword");
        print_usage(m, lookup("find").?);
        return .usage;
    }
    const pattern = args[2];
    var count: usize = 0;
    find_recursive(m, start_path, pattern, 0, &count);
    if (count == 0) {
        m.console.puts("find: no matches for '");
        m.console.puts(pattern);
        m.console.print_line("'");
    }
    return .none;
}

const find_max_depth: usize = 3;
const find_max_results: usize = 256;

fn find_recursive(m: *Monitor, dir_path: []const u8, pattern: []const u8, depth: usize, count: *usize) void {
    if (depth >= find_max_depth or count.* >= find_max_results) return;
    var entries: [esp.entries_max]fat.DirEntry = undefined;
    const n = fat.list_path(dir_path, &entries);
    for (entries[0..n]) |e| {
        if (count.* >= find_max_results) break;
        const name = e.name[0..e.name_len];
        // Match against pattern
        if (glob_match(name, pattern)) {
            // Build full path
            var path_buf: [128]u8 = undefined;
            var pos: usize = 0;
            if (std.mem.eql(u8, dir_path, "/")) {
                path_buf[0] = '/';
                pos = 1;
            } else {
                const take = @min(dir_path.len, path_buf.len - 1 - name.len);
                @memcpy(path_buf[0..take], dir_path[0..take]);
                pos = take;
                if (pos < path_buf.len and path_buf[pos - 1] != '/') {
                    path_buf[pos] = '/';
                    pos += 1;
                }
            }
            const name_take = @min(name.len, path_buf.len - pos);
            @memcpy(path_buf[pos..][0..name_take], name[0..name_take]);
            pos += name_take;
            m.console.puts(path_buf[0..pos]);
            if (e.is_dir) m.console.putc('/');
            m.console.putc('\n');
            count.* += 1;
        }
        // Recurse into directories
        if (e.is_dir) {
            var sub_path: [128]u8 = undefined;
            var spos: usize = 0;
            if (std.mem.eql(u8, dir_path, "/")) {
                sub_path[0] = '/';
                spos = 1;
            } else {
                const take = @min(dir_path.len, sub_path.len - 1 - name.len);
                @memcpy(sub_path[0..take], dir_path[0..take]);
                spos = take;
                if (spos < sub_path.len and sub_path[spos - 1] != '/') {
                    sub_path[spos] = '/';
                    spos += 1;
                }
            }
            const name_take = @min(name.len, sub_path.len - spos);
            @memcpy(sub_path[spos..][0..name_take], name[0..name_take]);
            spos += name_take;
            find_recursive(m, sub_path[0..spos], pattern, depth + 1, count);
        }
    }
}

/// Simple glob pattern match: * matches any sequence, ? matches one char.
fn glob_match(name: []const u8, pattern: []const u8) bool {
    return glob_match_impl(name, 0, pattern, 0);
}

fn glob_match_impl(name: []const u8, ni: usize, pat: []const u8, pi: usize) bool {
    if (pi == pat.len) return ni == name.len;
    if (pat[pi] == '*') {
        // Try matching zero or more chars
        var j: usize = ni;
        while (j <= name.len) : (j += 1) {
            if (glob_match_impl(name, j, pat, pi + 1)) return true;
        }
        return false;
    }
    if (ni >= name.len) return false;
    if (pat[pi] == '?' or pat[pi] == name[ni]) {
        return glob_match_impl(name, ni + 1, pat, pi + 1);
    }
    return false;
}

/// M22 D12 (issue #335): `dmesg` — print the serial ring buffer contents.
fn cmd_dmesg(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    var buf: [serial_ring.capacity * 2]u8 = undefined;
    const n = serial_ring.snapshot(&buf);
    if (n == 0) {
        m.console.print_line("dmesg: log is empty");
        return .none;
    }
    m.console.puts(buf[0..n]);
    // Ensure trailing newline
    if (n > 0 and buf[n - 1] != '\n') m.console.putc('\n');
    return .none;
}

/// M22 D13 (issue #336): `time <command> [args...]` — measure elapsed
/// ticks and wall-clock time for any command.
fn cmd_time(m: *Monitor, args: []const []const u8) ExecError {
    const start_ticks = timer.ticks;
    const result = exec(m, args);
    const end_ticks = timer.ticks;
    const elapsed = end_ticks - start_ticks;
    // Convert ticks to seconds: the GIC timer fires at 24 MHz, but the
    // kernel counts scheduler ticks (typically ~100 Hz). Use timer.freq
    // if available, else assume 100 ticks/sec.
    const ticks_per_sec: u64 = if (timer.freq > 0) timer.freq else 100;
    const secs = elapsed / ticks_per_sec;
    const rem_ms = (elapsed % ticks_per_sec) * 1000 / ticks_per_sec;
    m.console.puts("real    ");
    m.console.print_u64(secs / 60);
    m.console.puts("m");
    if (rem_ms < 100) m.console.putc('0');
    if (rem_ms < 10) m.console.putc('0');
    m.console.print_u64(rem_ms);
    m.console.print_line("s");
    m.console.puts("ticks   ");
    m.console.print_u64(elapsed);
    m.console.puts("\n");
    return result;
}

/// M22 D16 (issue #339): `which <name>` — locate a command by name.
/// Reports shell builtins, monitor commands, and ESP applications.
fn cmd_which(m: *Monitor, args: []const []const u8) ExecError {
    const name = args[0];
    // Check shell builtins first (the list from shell.zig dispatch_line)
    if (is_shell_builtin(name)) {
        m.console.puts(name);
        m.console.print_line(": shell builtin");
        return .none;
    }
    // Check monitor commands
    if (lookup(name)) |_| {
        m.console.puts(name);
        m.console.print_line(": monitor command");
        return .none;
    }
    // Check ESP file listing (applications)
    const list = esp.entries();
    for (list) |e| {
        if (std.mem.eql(u8, e.name[0..e.name_len], name)) {
            m.console.puts(name);
            m.console.print_line(": ESP application");
            return .none;
        }
    }
    // Not found
    m.console.puts(name);
    m.console.print_line(": not found");
    return .none;
}

/// Check if a name is a shell builtin (from shell.zig dispatch_line).
///
/// ADR 0005: a const []const u8 table would land in rodata holding
/// ABSOLUTE link-time pointers, which the flat kernel loader never
/// relocates — on real hardware the first comparison dereferenced a
/// garbage pointer and took a data abort (observed live 2026-08-25,
/// claim 5220: far=0x4129a on `which type`). `inline for` keeps the list
/// comptime so every literal is referenced PC-relative.
fn is_shell_builtin(name: []const u8) bool {
    inline for (.{
        "export", "set",     "unset", "env",   "printenv",
        "alias",  "unalias", "exit",  "sh",    "prompt",
        "type",   "true",    "false", "jobs",  "fg",
        "if",     "for",     "while", "break", "continue",
        "fn",     "cd",
    }) |b| {
        if (std.mem.eql(u8, name, b)) return true;
    }
    return false;
}

/// M22 D16 (issue #339): `inventory` — list all installed applications
/// from the ESP window with their sizes and types.
fn cmd_inventory(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    const list = esp.entries();
    if (list.len == 0) {
        m.console.print_line("inventory: no applications installed");
        return .none;
    }
    m.console.puts("inventory: ");
    m.console.print_u64(@intCast(list.len));
    m.console.print_line(" application(s):\n");
    var width: usize = 0;
    for (list) |e| width = @max(width, e.name_len);
    for (list) |e| {
        m.console.puts("  ");
        m.console.puts(e.name[0..e.name_len]);
        var pad: usize = e.name_len;
        while (pad < width + 2) : (pad += 1) m.console.putc(' ');
        m.console.puts("  ");
        m.console.print_hex(e.size);
        m.console.puts(" bytes  [");
        m.console.puts(switch (e.kind) {
            .esp_dir => "dir",
            .esp_file => esp.volume(),
        });
        m.console.puts("]\n");
    }
    return .none;
}

// ---------------------------------------------------------------------------
// Physical page allocator command (next-card milestone)
// ---------------------------------------------------------------------------

fn cmd_pages(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 1 and !std.mem.eql(u8, args[0], "selftest")) {
        print_usage(m, lookup("pages").?);
        return .usage;
    }
    const s = alloc.stats();
    if (!s.armed) {
        err_prefix(m);
        if (args.len == 1) {
            m.console.print_line("allocator not armed (no poolable memory in span) — selftest refused");
        } else {
            m.console.print_line("allocator not armed (no poolable memory in span)");
        }
        return .none;
    }
    if (args.len == 1) return pages_selftest(m, s);
    m.console.puts("pages: armed=1 total=");
    m.console.print_hex(s.total_pages);
    m.console.puts(" free=");
    m.console.print_hex(s.free_pages);
    m.console.puts(" excluded=");
    m.console.print_hex(s.excluded_pages);
    m.console.puts(" regions=");
    m.console.print_hex(@intCast(s.region_count));
    m.console.puts(" span=");
    m.console.print_hex(s.span_pages);
    m.console.puts("\n");
    return .none;
}

/// Deterministic bounded alloc/free battery against the module allocator:
/// alloc 1 / free, alloc 8 / free, alloc 3 + alloc 5 (contiguous) / free
/// both, alloc the largest free run / free, alloc total+1 -> none. Leaves
/// the pool exactly as it found it. The pool may be fragmented across
/// regions (real VZ maps are), so the "big" step allocates the largest
/// contiguous free run — which is guaranteed to fit — rather than the
/// whole pool (which need not be contiguous).
fn pages_selftest(m: *Monitor, s: alloc.Stats) ExecError {
    const total = s.total_pages;
    const initial_free = s.free_pages;
    var failed = false;
    if (pages_alloc_line(m, 1)) |base| failed = failed or !pages_free_line(m, base, 1, "free");
    if (pages_alloc_line(m, 8)) |base| failed = failed or !pages_free_line(m, base, 8, "free");
    const a3 = pages_alloc_line(m, 3);
    const a5 = pages_alloc_line(m, 5);
    if (a3 != null and a5 != null) {
        const ok3 = alloc.free_pages(a3.?, 3);
        const ok5 = alloc.free_pages(a5.?, 5);
        m.console.print_line(if (ok3 and ok5) "pages selftest: free both ok" else "pages selftest: free both FAILED");
        failed = failed or !(ok3 and ok5);
    } else {
        failed = true;
    }
    const largest = alloc.largest_free_run();
    if (pages_alloc_line(m, largest)) |base| failed = failed or !pages_free_line(m, base, largest, "free");
    // Allocating one more than the whole pool must fail.
    if (pages_alloc_line(m, total + 1) != null) failed = true;
    const after = alloc.stats();
    // The pool is "restored" when free is back to where the battery found
    // it (with exclusions, free < total by design — claim 5162).
    const restored = after.free_pages == initial_free;
    m.console.puts("pages selftest: ");
    m.console.puts(if (failed or !restored) "FAILED" else "ok");
    m.console.puts(" free=");
    m.console.print_hex(after.free_pages);
    m.console.puts("\n");
    return .none;
}

/// Print "alloc <n> -> <base>" (or "-> none (out of memory)") and return
/// the base on success.
fn pages_alloc_line(m: *Monitor, n: u64) ?u64 {
    m.console.puts("pages selftest: alloc ");
    m.console.print_u64(n);
    m.console.puts(" -> ");
    const base = alloc.alloc_pages(n);
    if (base) |b| {
        m.console.print_hex(b);
    } else {
        m.console.puts("none (out of memory)");
    }
    m.console.puts("\n");
    return base;
}

fn pages_free_line(m: *Monitor, base: u64, n: u64, label: []const u8) bool {
    const ok = alloc.free_pages(base, n);
    m.console.puts("pages selftest: ");
    m.console.puts(label);
    m.console.puts(if (ok) " ok" else " FAILED");
    m.console.puts("\n");
    return ok;
}

// ---------------------------------------------------------------------------
// Shell-style utility commands
// ---------------------------------------------------------------------------

fn cmd_echo(m: *Monitor, args: []const []const u8) ExecError {
    for (args, 0..) |arg, index| {
        if (index > 0) m.console.putc(' ');
        m.console.puts(arg);
    }
    m.console.puts("\n");
    return .none;
}

/// Milestone fourteen card S1 (claim 0169): the terminal half of the shared
/// clipboard. With no args it pastes the current contents (the EL1h read of
/// the SAME buffer the slots 38/39 syscalls use); with args it joins them
/// (space-separated, the `echo` shape) and stores the result — the
/// M18 T5: toggle ANSI terminal colors on or off.
fn cmd_color(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 0) {
        m.console.puts("color: ");
        m.console.print_line(if (settings.get_color()) "on" else "off");
        return .none;
    }
    if (std.mem.eql(u8, args[0], "on") or std.mem.eql(u8, args[0], "1") or std.mem.eql(u8, args[0], "true")) {
        _ = settings.set("color", "on");
        _ = settings.set("color", "on");
        m.console.print_line("color: on");
        return .none;
    }
    if (std.mem.eql(u8, args[0], "off") or std.mem.eql(u8, args[0], "0") or std.mem.eql(u8, args[0], "false")) {
        _ = settings.set("color", "off");
        m.console.print_line("color: off");
        return .none;
    }
    m.console.print_line("usage: color [on|off]");
    return .none;
}

/// bounded-copy proof from the shell. Truncation is honest: the staging
/// buffer is the clipboard capacity, so an over-long paste stores exactly
/// `clipboard.capacity` bytes and reports it.
fn cmd_clip(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 0) {
        var buf: [clipboard.capacity]u8 = undefined;
        const n = clipboard.get(&buf);
        if (n == 0) {
            m.console.puts("clip: empty\n");
        } else {
            m.console.puts("clip: ");
            m.console.puts(buf[0..n]);
            m.console.puts("\n");
        }
        return .none;
    }
    var staging: [clipboard.capacity]u8 = undefined;
    var len: usize = 0;
    for (args, 0..) |arg, index| {
        if (index > 0) {
            if (len < staging.len) {
                staging[len] = ' ';
                len += 1;
            }
        }
        for (arg) |ch| {
            if (len >= staging.len) break;
            staging[len] = ch;
            len += 1;
        }
    }
    const stored = clipboard.set(staging[0..len]);
    m.console.puts("clip: stored ");
    m.console.print_u64(stored);
    m.console.puts(" bytes\n");
    return .none;
}

fn cmd_clear(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    // ANSI erase-in-display + cursor home. On terminals without ANSI
    // support this sequence is ignored harmlessly; the fallback is a
    // documented no-op. Deterministic and testable at the byte level.
    m.console.puts("\x1b[2J\x1b[H");
    return .none;
}

/// `compose` — list available Alt+key compose sequences (Arc5 #245, ADR 0014).
fn cmd_compose(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    input.compose_list(&m.console);
    return .none;
}

/// `crash` — list recent crash tombstones from /data/crash/.
/// Shows process name, PID, exit status, and tick for each tombstone.
/// M22 D11 (issue #334): `crash` — enhanced crash report viewer with
/// symbol resolution, formatted report, and serial snapshot display.
fn cmd_crash(m: *Monitor, args: []const []const u8) ExecError {
    const n = tombstone.count();
    if (n == 0) {
        m.console.print_line("crash: no tombstones recorded");
        return .none;
    }
    // `crash <index>` shows the detailed report for one tombstone
    if (args.len == 1) {
        const idx = parseInt(args[0]) catch {
            err_prefix(m);
            m.console.puts("crash: invalid index: ");
            m.console.puts(args[0]);
            m.console.puts("\n");
            return .invalid_argument;
        };
        if (idx >= n) {
            err_prefix(m);
            m.console.puts("crash: index out of range (max ");
            m.console.print_u64(n - 1);
            m.console.puts(")\n");
            return .invalid_argument;
        }
        if (tombstone.get(@intCast(idx))) |t| {
            var buf: [tombstone.tombstone_max_bytes]u8 = undefined;
            const len = tombstone.format_tombstone(t, &buf);
            m.console.puts(buf[0..len]);
            if (len > 0 and buf[len - 1] != '\n') m.console.putc('\n');
        }
        return .none;
    }
    // Default: list all tombstones with summary
    m.console.puts("crash: ");
    m.console.print_u64(n);
    m.console.print_line(" tombstone(s) (use 'crash <index>' for detail): ");
    _ = tombstone.list_to_console(m.console);
    return .none;
}

fn cmd_hex(m: *Monitor, args: []const []const u8) ExecError {
    for (args) |arg| {
        const value = parseInt(arg) catch {
            err_prefix(m);
            m.console.puts("invalid number: ");
            m.console.puts(arg);
            m.console.puts("\n");
            return .invalid_argument;
        };
        m.console.print_hex_min(value);
        m.console.puts("\n");
    }
    return .none;
}

/// `roadpops` — report the Road Pops tee console (claim 1574, milestone
/// six G3): armed (the framebuffer target is wired — the boot terminal is
/// on the screen), dirty (a console write batch is waiting for the idle
/// loop's drain-present), and the presents pushed since arm.
fn cmd_roadpops(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    const r = road_pops.report();
    m.console.puts("roadpops: armed=");
    m.console.puts(if (r.armed) "1" else "0");
    m.console.puts(" dirty=");
    m.console.puts(if (r.dirty) "1" else "0");
    m.console.puts(" presents=");
    m.console.print_u64(r.presents);
    m.console.puts("\n");
    return .none;
}

/// `dui` — report the Driving Award window manager (claim 1543, milestone
/// six G5): the registry (id/title/kind/rect/z-order/dirty/visible/owner),
/// the focused window, and the composite presents. `dui focus <n>` focuses
/// a window, `dui raise <n>` raises it to the top, `dui move <n> <x> <y>`
/// moves a user window (clamped on-scanout), `dui close <n>` releases a
/// user window, `dui list <pid>` filters the registry to one process's
/// windows, and `dui hit <x> <y>` hit-tests a point (focusing the topmost
/// window there).
fn cmd_dui(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len > 0) {
        if (std.mem.eql(u8, args[0], "focus")) {
            if (args.len != 2) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch {
                err_prefix(m);
                m.console.puts("invalid id: ");
                m.console.puts(args[1]);
                m.console.puts("\n");
                return .invalid_argument;
            };
            if (id > 255) {
                err_prefix(m);
                m.console.print_line("id out of range");
                return .invalid_argument;
            }
            if (!driving_award.focus(@intCast(id))) {
                err_prefix(m);
                m.console.print_line("no such window");
                return .invalid_argument;
            }
            // The focus change may alter the clock's focus line — repaint.
            _ = driving_award.mark_dirty(0);
            _ = driving_award.mark_dirty(1);
            _ = driving_award.composite();
            m.console.puts("dui focus: focused=");
            m.console.print_u64(id);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "raise")) {
            if (args.len != 2) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch {
                err_prefix(m);
                m.console.puts("invalid id: ");
                m.console.puts(args[1]);
                m.console.puts("\n");
                return .invalid_argument;
            };
            if (id > 255) {
                err_prefix(m);
                m.console.print_line("id out of range");
                return .invalid_argument;
            }
            if (!driving_award.raise(@intCast(id))) {
                err_prefix(m);
                m.console.print_line("no such window");
                return .invalid_argument;
            }
            _ = driving_award.composite();
            m.console.puts("dui raise: raised=");
            m.console.print_u64(id);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "lower")) {
            if (args.len != 2) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id2 = parseInt(args[1]) catch {
                err_prefix(m);
                m.console.puts("invalid id: ");
                m.console.puts(args[1]);
                m.console.puts("\n");
                return .invalid_argument;
            };
            if (id2 > 255) {
                err_prefix(m);
                m.console.print_line("id out of range");
                return .invalid_argument;
            }
            if (!driving_award.user_lower_back(@intCast(id2))) {
                err_prefix(m);
                m.console.print_line("no such user window");
                return .invalid_argument;
            }
            _ = driving_award.composite();
            m.console.puts("dui lower: lowered=");
            m.console.print_u64(id2);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "move")) {
            if (args.len != 4) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch {
                err_prefix(m);
                m.console.puts("invalid id: ");
                m.console.puts(args[1]);
                m.console.puts("\n");
                return .invalid_argument;
            };
            const x = parseInt(args[2]) catch {
                err_prefix(m);
                m.console.print_line("invalid x");
                return .invalid_argument;
            };
            const y = parseInt(args[3]) catch {
                err_prefix(m);
                m.console.print_line("invalid y");
                return .invalid_argument;
            };
            if (id > 255 or x > std.math.maxInt(u32) or y > std.math.maxInt(u32)) {
                err_prefix(m);
                m.console.print_line("coordinate out of range");
                return .invalid_argument;
            }
            if (!driving_award.user_move(@intCast(id), @intCast(x), @intCast(y))) {
                err_prefix(m);
                m.console.print_line("no such user window (the terminal + clock are fixed)");
                return .invalid_argument;
            }
            _ = driving_award.composite();
            m.console.puts("dui move: moved=");
            m.console.print_u64(id);
            m.console.puts(" to ");
            m.console.print_u64(x);
            m.console.puts(",");
            m.console.print_u64(y);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "close")) {
            if (args.len != 2) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch {
                err_prefix(m);
                m.console.puts("invalid id: ");
                m.console.puts(args[1]);
                m.console.puts("\n");
                return .invalid_argument;
            };
            if (id > 255) {
                err_prefix(m);
                m.console.print_line("id out of range");
                return .invalid_argument;
            }
            if (!driving_award.user_close(@intCast(id))) {
                err_prefix(m);
                m.console.print_line("no such user window (the terminal + clock are fixed)");
                return .invalid_argument;
            }
            // The close marked the fixed windows dirty — composite now to
            // reveal whatever sat under the released window.
            _ = driving_award.composite();
            m.console.puts("dui close: closed=");
            m.console.print_u64(id);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "list")) {
            if (args.len != 2) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const pid = parseInt(args[1]) catch {
                err_prefix(m);
                m.console.puts("invalid pid: ");
                m.console.puts(args[1]);
                m.console.puts("\n");
                return .invalid_argument;
            };
            const want: usize = @intCast(pid); // aarch64: usize == u64, lossless
            var matches: usize = 0;
            var i: usize = 0;
            while (i < driving_award.count()) : (i += 1) {
                const w = driving_award.window_at(i).?;
                if (w.owner == want) matches += 1;
            }
            m.console.puts("dui list: pid=");
            m.console.print_u64(pid);
            m.console.puts(" matches=");
            m.console.print_u64(matches);
            m.console.puts("\n");
            i = 0;
            while (i < driving_award.count()) : (i += 1) {
                const w = driving_award.window_at(i).?;
                if (w.owner == want) print_win_row(m, i, w);
            }
            return .none;
        }
        if (std.mem.eql(u8, args[0], "cycle")) {
            if (args.len != 1) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            if (driving_award.cycle_focus()) |id| {
                m.console.puts("dui: cycle focused=");
                m.console.print_u64(id);
                m.console.puts("\n");
                return .none;
            }
            err_prefix(m);
            m.console.print_line("no window to cycle");
            return .invalid_argument;
        }
        if (std.mem.eql(u8, args[0], "hit")) {
            if (args.len != 3) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const x = parseInt(args[1]) catch {
                err_prefix(m);
                m.console.print_line("invalid x");
                return .invalid_argument;
            };
            const y = parseInt(args[2]) catch {
                err_prefix(m);
                m.console.print_line("invalid y");
                return .invalid_argument;
            };
            if (x > std.math.maxInt(u32) or y > std.math.maxInt(u32)) {
                err_prefix(m);
                m.console.print_line("coordinate out of range");
                return .invalid_argument;
            }
            const hit = driving_award.hit_test(@intCast(x), @intCast(y));
            m.console.puts("dui hit: ");
            m.console.print_u64(x);
            m.console.puts(",");
            m.console.print_u64(y);
            m.console.puts(" -> ");
            if (hit) |hid| {
                m.console.print_u64(hid);
                _ = driving_award.focus(hid);
            } else {
                m.console.puts("none");
            }
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "tile")) {
            if (args.len != 2) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch {
                err_prefix(m);
                m.console.puts("invalid id: ");
                m.console.puts(args[1]);
                m.console.puts("\n");
                return .invalid_argument;
            };
            if (id > 255) {
                err_prefix(m);
                m.console.print_line("id out of range");
                return .invalid_argument;
            }
            if (!driving_award.focus(@intCast(id))) {
                err_prefix(m);
                m.console.print_line("no such window");
                return .invalid_argument;
            }
            // The EL1h half of M21 W1's Ctrl+T chord: focus the window,
            // then toggle it floating <-> tiled (driving_award owns the
            // max-2 constraint and the layout math).
            driving_award.toggle_tiling();
            _ = driving_award.composite();
            m.console.puts("dui tile: id=");
            m.console.print_u64(id);
            m.console.puts(" mode=");
            m.console.puts(if (driving_award.tile_mode) "on" else "off");
            if (driving_award.tile_master_id) |mid| {
                m.console.puts(" master=");
                m.console.print_u64(mid);
            }
            if (driving_award.tile_stack_id) |sid| {
                m.console.puts(" stack=");
                m.console.print_u64(sid);
            }
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "master")) {
            if (args.len != 1) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            // The EL1h half of M21 W2's Ctrl+M chord: swap master/detail
            // (a no-op unless two windows are tiled).
            driving_award.swap_master();
            _ = driving_award.composite();
            m.console.puts("dui master: side=");
            m.console.puts(if (driving_award.tile_master_side) "left" else "right");
            if (driving_award.tile_master_id) |mid| {
                m.console.puts(" master=");
                m.console.print_u64(mid);
            }
            if (driving_award.tile_stack_id) |sid| {
                m.console.puts(" stack=");
                m.console.print_u64(sid);
            }
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "minimize")) {
            if (args.len != 2) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch return .invalid_argument;
            if (id > 255) return .invalid_argument;
            if (!driving_award.minimize_window(@intCast(id))) {
                err_prefix(m);
                m.console.print_line("minimize failed: no such user window");
                return .invalid_argument;
            }
            _ = driving_award.composite();
            m.console.puts("dui minimize: minimized id=");
            m.console.print_u64(id);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "restore")) {
            if (args.len != 2) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch return .invalid_argument;
            if (id > 255) return .invalid_argument;
            if (!driving_award.restore_from_dock(@intCast(id))) {
                err_prefix(m);
                m.console.print_line("restore failed: window not minimized or unknown");
                return .invalid_argument;
            }
            _ = driving_award.composite();
            m.console.puts("dui restore: restored id=");
            m.console.print_u64(id);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "maximize")) {
            if (args.len != 2) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch return .invalid_argument;
            if (id > 255) return .invalid_argument;
            if (!driving_award.toggle_maximize(@intCast(id))) {
                err_prefix(m);
                m.console.print_line("maximize failed: no such user window");
                return .invalid_argument;
            }
            _ = driving_award.composite();
            const w = driving_award.find_user_window(@intCast(id));
            m.console.puts("dui maximize: id=");
            m.console.print_u64(id);
            m.console.puts(" max=");
            m.console.puts(if (w != null and w.?.maximized) "on" else "off");
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "fullscreen")) {
            if (args.len != 2) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch return .invalid_argument;
            if (id > 255) return .invalid_argument;
            if (!driving_award.toggle_fullscreen(@intCast(id))) {
                err_prefix(m);
                m.console.print_line("fullscreen failed: no such user window");
                return .invalid_argument;
            }
            _ = driving_award.composite();
            m.console.puts("dui fullscreen: id=");
            m.console.print_u64(id);
            m.console.puts(" on=");
            m.console.puts(if (driving_award.fullscreen_active) "yes" else "no");
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "aot")) {
            if (args.len != 2) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch return .invalid_argument;
            if (id > 255) return .invalid_argument;
            if (!driving_award.toggle_always_on_top(@intCast(id))) {
                err_prefix(m);
                m.console.print_line("always-on-top failed: no such user window");
                return .invalid_argument;
            }
            _ = driving_award.composite();
            const w = driving_award.find_user_window(@intCast(id));
            m.console.puts("dui always-on-top: id=");
            m.console.print_u64(id);
            m.console.puts(" flag=");
            m.console.puts(if (w != null and w.?.always_on_top) "on" else "off");
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "kmove")) {
            if (args.len != 4) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch return .invalid_argument;
            const dx = parseSignedInt(args[2]) catch return .invalid_argument;
            const dy = parseSignedInt(args[3]) catch return .invalid_argument;
            if (id > 255) return .invalid_argument;
            if (!driving_award.move_window_keyboard(@intCast(id), @intCast(dx), @intCast(dy))) {
                err_prefix(m);
                m.console.print_line("keyboard move failed: no such user window");
                return .invalid_argument;
            }
            _ = driving_award.composite();
            m.console.puts("dui kmove: id=");
            m.console.print_u64(id);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "kresize")) {
            if (args.len != 4) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch return .invalid_argument;
            const dw = parseSignedInt(args[2]) catch return .invalid_argument;
            const dh = parseSignedInt(args[3]) catch return .invalid_argument;
            if (id > 255) return .invalid_argument;
            if (!driving_award.resize_window_keyboard(@intCast(id), @intCast(dw), @intCast(dh))) {
                err_prefix(m);
                m.console.print_line("keyboard resize failed: no such user window");
                return .invalid_argument;
            }
            _ = driving_award.composite();
            m.console.puts("dui kresize: id=");
            m.console.print_u64(id);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "title")) {
            if (args.len != 3) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch return .invalid_argument;
            if (id > 255) return .invalid_argument;
            if (!driving_award.set_window_title(@intCast(id), args[2])) {
                err_prefix(m);
                m.console.print_line("title update failed: no such user window");
                return .invalid_argument;
            }
            _ = driving_award.composite();
            m.console.puts("dui title: id=");
            m.console.print_u64(id);
            m.console.puts(" title=");
            m.console.puts(args[2]);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "modal")) {
            if (args.len != 3) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch return .invalid_argument;
            const flag = parseInt(args[2]) catch return .invalid_argument;
            if (id > 255) return .invalid_argument;
            if (!driving_award.set_modal(@intCast(id), flag != 0)) {
                err_prefix(m);
                m.console.print_line("modal failed: no such user window");
                return .invalid_argument;
            }
            _ = driving_award.composite();
            m.console.puts("dui modal: id=");
            m.console.print_u64(id);
            m.console.puts(" flag=");
            m.console.print_u64(flag);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "transient")) {
            if (args.len != 3) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch return .invalid_argument;
            const timeout = parseInt(args[2]) catch return .invalid_argument;
            if (id > 255) return .invalid_argument;
            if (!driving_award.set_transient(@intCast(id), @intCast(timeout))) {
                err_prefix(m);
                m.console.print_line("transient failed: no such user window");
                return .invalid_argument;
            }
            _ = driving_award.composite();
            m.console.puts("dui transient: id=");
            m.console.print_u64(id);
            m.console.puts(" timeout=");
            m.console.print_u64(timeout);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "notif")) {
            if (args.len != 2) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            driving_award.notify_push(args[1], 0);
            _ = driving_award.composite();
            m.console.puts("dui notif: pushed=");
            m.console.puts(args[1]);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "notif-center")) {
            if (args.len != 1) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            driving_award.notif_center_toggle();
            _ = driving_award.composite();
            m.console.puts("dui notif-center: open=");
            m.console.puts(if (driving_award.notif_center_open) "yes" else "no");
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "notif-center-state")) {
            // WMS6 Gate B (issue #626): a PURE state report (does not toggle)
            // — the live gate reads the panel's open/closed state after an
            // injected tray click to prove the shim (boot A) or the WM
            // (boot B) opened it.
            if (args.len != 1) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            m.console.puts("dui notif-center-state: open=");
            m.console.puts(if (driving_award.notif_center_open) "yes" else "no");
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "tooltip-state")) {
            // WMS6 Gate C (issue #626): a PURE state report (does not change
            // anything) — the live gate reads the tooltip's visibility + text
            // after an injected hover to prove the WM showed it.
            if (args.len != 1) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            m.console.puts("dui tooltip-state: visible=");
            m.console.puts(if (driving_award.tooltip_visible) "yes" else "no");
            m.console.puts(" text=");
            m.console.puts(driving_award.tooltip_text[0..driving_award.tooltip_text_len]);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "tray-state")) {
            // WMS6 Gate E (issue #626): a PURE state report (does not change
            // anything) — the live gate reads the effective tray widget
            // content after the WM's TRAY decision to prove the WM's values
            // (not the shim's) are what renders.
            if (args.len != 1) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            m.console.puts("dui tray-state: clock=");
            m.console.puts(driving_award.wm_tray_clock_text[0..5]);
            m.console.puts(" clock_set=");
            m.console.puts(if (driving_award.wm_tray_clock_set) "yes" else "no");
            m.console.puts(" theme=");
            var tlet: [1]u8 = .{driving_award.wm_tray_theme};
            m.console.puts(tlet[0..1]);
            m.console.puts(" theme_set=");
            m.console.puts(if (driving_award.wm_tray_theme_set) "yes" else "no");
            m.console.puts(" clip=");
            m.console.puts(if (driving_award.wm_tray_clip) "yes" else "no");
            m.console.puts(" clip_set=");
            m.console.puts(if (driving_award.wm_tray_clip_set) "yes" else "no");
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "notif-dismiss")) {
            if (args.len != 2) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const idx = parseInt(args[1]) catch return .invalid_argument;
            const ok = driving_award.notif_center_dismiss(@intCast(idx));
            _ = driving_award.composite();
            m.console.puts("dui notif-dismiss: idx=");
            m.console.print_u64(idx);
            m.console.puts(" ok=");
            m.console.puts(if (ok) "1" else "0");
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "notif-clear")) {
            if (args.len != 1) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            driving_award.notif_center_clear_all();
            _ = driving_award.composite();
            m.console.puts("dui notif-clear: cleared\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "ws")) {
            if (args.len != 2) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const ws = parseInt(args[1]) catch return .invalid_argument;
            if (ws > 2) return .invalid_argument;
            driving_award.switch_workspace(@intCast(ws));
            _ = driving_award.composite();
            m.console.puts("dui ws: workspace=");
            m.console.print_u64(ws);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "ws-cycle")) {
            if (args.len != 1) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            driving_award.cycle_workspace();
            _ = driving_award.composite();
            m.console.puts("dui ws-cycle: workspace=");
            m.console.print_u64(driving_award.current_workspace);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "unsaved")) {
            if (args.len != 3) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch return .invalid_argument;
            const flag = parseInt(args[2]) catch return .invalid_argument;
            if (id > 255) return .invalid_argument;
            _ = driving_award.user_set_unsaved(@intCast(id), flag != 0);
            _ = driving_award.composite();
            m.console.puts("dui unsaved: id=");
            m.console.print_u64(id);
            m.console.puts(" flag=");
            m.console.print_u64(flag);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "dialog-show")) {
            if (args.len != 2) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const id = parseInt(args[1]) catch return .invalid_argument;
            if (id > 255) return .invalid_argument;
            driving_award.unsaved_dialog_show(@intCast(id));
            _ = driving_award.composite();
            m.console.puts("dui dialog-show: target=");
            m.console.print_u64(id);
            m.console.puts(" open=");
            m.console.puts(if (driving_award.unsaved_dialog_is_open()) "yes" else "no");
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "dialog-click")) {
            if (args.len != 2) {
                print_usage(m, lookup("dui").?);
                return .usage;
            }
            const choice = if (std.mem.eql(u8, args[1], "save"))
                driving_award.unsaved_dialog_click(640 - 100 + 40, 360 + 20)
            else if (std.mem.eql(u8, args[1], "dont_save") or std.mem.eql(u8, args[1], "discard"))
                driving_award.unsaved_dialog_click(640 - 100 + 110, 360 + 20)
            else
                driving_award.unsaved_dialog_click(640 - 100 + 175, 360 + 20);
            _ = driving_award.composite();
            m.console.puts("dui dialog-click: result=");
            m.console.puts(@tagName(choice));
            m.console.puts(" open=");
            m.console.puts(if (driving_award.unsaved_dialog_is_open()) "yes" else "no");
            m.console.puts("\n");
            return .none;
        }
        print_usage(m, lookup("dui").?);
        return .usage;
    }
    if (!driving_award.armed()) {
        m.console.print_line("dui: window manager not armed (no gpu device — the default VM)");
        return .none;
    }
    m.console.puts("dui: windows=");
    m.console.print_u64(driving_award.count());
    m.console.puts(" focused=");
    m.console.print_u64(driving_award.focused_window_id());
    m.console.puts(" presents=");
    m.console.print_u64(driving_award.presents_pushed());
    // M33 SB6 (claim 6864): the composite-cost observables — user windows
    // the kernel blitted vs surface-backed windows skipped (WM-owned).
    m.console.puts(" blits=");
    m.console.print_u64(driving_award.user_blits);
    m.console.puts(" skips=");
    m.console.print_u64(driving_award.migrated_skips);
    m.console.puts("\n");
    // M21 W1/W2 tiling state (the layout the tiled rects obey).
    m.console.puts("dui: tiling=");
    m.console.puts(if (driving_award.tile_mode) "on" else "off");
    if (driving_award.tile_master_id) |mid| {
        m.console.puts(" master=");
        m.console.print_u64(mid);
    }
    if (driving_award.tile_stack_id) |sid| {
        m.console.puts(" stack=");
        m.console.print_u64(sid);
    }
    m.console.puts(" side=");
    m.console.puts(if (driving_award.tile_master_side) "left" else "right");
    m.console.puts("\n");
    var i: usize = 0;
    while (i < driving_award.count()) : (i += 1) {
        print_win_row(m, i, driving_award.window_at(i).?);
    }
    return .none;
}

/// Print one registry row for the window at index `i` — the shared formatter
/// behind the `dui` report and `dui list <pid>`. The trailing `owner=` column
/// is the per-process-ownership visibility (claim 0487 follow-on): a pid for a
/// `.user` window, `-` for the fixed kernel-owned terminal + clock.
fn print_win_row(m: *Monitor, i: usize, w: *const driving_award.Window) void {
    m.console.puts("dui[");
    m.console.print_u64(i);
    m.console.puts("]: ");
    m.console.puts(w.title);
    m.console.puts(" ");
    m.console.puts(driving_award.kind_name(w.kind));
    m.console.puts(" rect=");
    m.console.print_u64(w.x);
    m.console.puts(",");
    m.console.print_u64(w.y);
    m.console.puts(",");
    m.console.print_u64(w.w);
    m.console.puts(",");
    m.console.print_u64(w.h);
    m.console.puts(" dirty=");
    m.console.puts(if (w.dirty) "1" else "0");
    m.console.puts(" visible=");
    m.console.puts(if (w.visible) "1" else "0");
    m.console.puts(" z=");
    m.console.print_u64(i);
    m.console.puts(" owner=");
    if (w.owner) |pid| {
        m.console.print_u64(@intCast(pid));
    } else {
        m.console.puts("-");
    }
    if (w.minimized) m.console.puts(" minimized=1");
    if (w.maximized) m.console.puts(" maximized=1");
    if (w.always_on_top) m.console.puts(" aot=1");
    if (w.modal) m.console.puts(" modal=1");
    if (w.transient) m.console.puts(" transient=1");
    if (w.kind == .user) {
        m.console.puts(" ws=");
        m.console.print_u64(w.workspace);
        // M33 SB4 (claim 2382): the rect-granular damage observable for the
        // damage-tracking gate. `full` when no partial damage is pending
        // (whole-window), else the EXACT pending rect.
        m.console.puts(" damage=");
        if (w.damaged) {
            m.console.print_u64(w.dx);
            m.console.puts(",");
            m.console.print_u64(w.dy);
            m.console.puts(",");
            m.console.print_u64(w.dw);
            m.console.puts(",");
            m.console.print_u64(w.dh);
        } else {
            m.console.puts("full");
        }
        // M33 SB4: the LAST rect composite repainted (consumed damage) —
        // observable even after the drain. 0,0,0,0 = no partial repaint yet.
        m.console.puts(" last=");
        m.console.print_u64(w.last_dx);
        m.console.puts(",");
        m.console.print_u64(w.last_dy);
        m.console.puts(",");
        m.console.print_u64(w.last_dw);
        m.console.puts(",");
        m.console.print_u64(w.last_dh);
    }
    m.console.puts("\n");
}

/// `input` — report the keyboard/pointer event FIFO (claim 6050, milestone
/// seven I3): armed state, FIFO occupancy + drop count, the last decoded
/// keyboard event, and the last recorded pointer report.
fn cmd_input(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    const r = input.report();
    m.console.puts("input: armed=");
    m.console.puts(if (r.armed) "1" else "0");
    m.console.puts(" fifo=");
    m.console.print_u64(r.fifo_used);
    m.console.puts("/");
    m.console.print_u64(r.fifo_max);
    m.console.puts(" dropped=");
    m.console.print_u64(r.dropped);
    m.console.puts(" events=");
    m.console.print_u64(r.events);
    m.console.puts(" kb-mods=");
    m.console.print_hex_min(r.kb_mods);
    m.console.puts(" kb-usage=");
    m.console.print_hex_min(r.kb_last_usage);
    m.console.puts(" kb-byte=");
    if (r.kb_last_byte != 0 and r.kb_last_byte >= 0x20 and r.kb_last_byte <= 0x7e) {
        m.console.putc(r.kb_last_byte);
    } else {
        m.console.print_hex_min(r.kb_last_byte);
    }
    m.console.puts(" ptr-btns=");
    m.console.print_u64(r.ptr_buttons);
    m.console.puts(" ptr-x=");
    m.console.print_u64(r.ptr_x);
    m.console.puts(" ptr-y=");
    m.console.print_u64(r.ptr_y);
    m.console.puts(" ptr-reports=");
    m.console.print_u64(r.ptr_reports);
    m.console.puts("\n");
    return .none;
}

fn cmd_usb(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len > 0 and std.mem.eql(u8, args[0], "devices")) return cmd_usb_devices(m);
    if (args.len > 0 and std.mem.eql(u8, args[0], "report")) return cmd_usb_report(m, args);
    if (!xhci.xhci_ready) {
        m.console.puts("usb: no XHCI device (");
        m.console.puts(if (xhci.xhci_fail.len > 0) xhci.xhci_fail else "DID 0x1a06 not found on bus 0");
        m.console.puts(")\n");
        return .none;
    }
    m.console.puts("usb: did=");
    m.console.print_hex(xhci.xhci_did);
    m.console.puts(" class=");
    m.console.print_hex(xhci.xhci_class);
    m.console.puts(" dev=");
    m.console.print_u64(xhci.xhci_dev);
    m.console.puts("\n");
    m.console.puts("usb: bar0=");
    m.console.print_hex(xhci.xhci_bar0);
    m.console.puts(" bar1=");
    m.console.print_hex(xhci.xhci_bar1);
    m.console.puts(" base=");
    m.console.print_hex(xhci.xhci_base);
    m.console.puts("\n");
    m.console.puts("usb: caplen=");
    m.console.print_hex(xhci.xhci_caplen);
    m.console.puts(" hciver=");
    m.console.print_hex(xhci.xhci_hciver);
    m.console.puts(" dboff=");
    m.console.print_hex(xhci.xhci_dboff);
    m.console.puts(" rtsoff=");
    m.console.print_hex(xhci.xhci_rtsoff);
    m.console.puts("\n");
    m.console.puts("usb: hcsparams1=");
    m.console.print_hex(xhci.xhci_hcsparams1);
    m.console.puts(" hcsparams2=");
    m.console.print_hex(xhci.xhci_hcsparams2);
    m.console.puts(" hcsparams3=");
    m.console.print_hex(xhci.xhci_hcsparams3);
    m.console.puts(" hccparams1=");
    m.console.print_hex(xhci.xhci_hccparams1);
    m.console.puts("\n");
    m.console.puts("usb: maxslots=");
    m.console.print_u64(xhci.hcsparams1_max_slots(xhci.xhci_hcsparams1));
    m.console.puts(" maxintrs=");
    m.console.print_u64(xhci.hcsparams1_max_intrs(xhci.xhci_hcsparams1));
    m.console.puts(" maxports=");
    m.console.print_u64(xhci.hcsparams1_max_ports(xhci.xhci_hcsparams1));
    m.console.puts("\n");
    m.console.puts("usb: pre-reset sts=");
    m.console.print_hex(xhci.xhci_pre_reset_usbsts);
    m.console.puts(" cmd=");
    m.console.print_hex(xhci.xhci_pre_reset_usbcmd);
    m.console.puts("\n");
    m.console.puts("usb: usbsts=");
    m.console.print_hex(xhci.xhci_usbsts());
    m.console.puts(" noop_cc=");
    m.console.print_hex(xhci.xhci_noop_cc);
    m.console.puts(" noop=");
    m.console.puts(if (xhci.xhci_noop_done) "ok" else "fail");
    m.console.puts("\n");
    // Live port status: one line per port, with the connect/enable/power
    // bits decoded (the I1 report — I2 turns these into enumerated devices).
    const max_ports = xhci.hcsparams1_max_ports(xhci.xhci_hcsparams1);
    var port: u8 = 1;
    while (port <= max_ports) : (port += 1) {
        const psc = xhci.xhci_port_status(port);
        m.console.puts("usb: port");
        m.console.print_u64(port);
        m.console.puts("=");
        m.console.print_hex(psc);
        m.console.puts(" ccs=");
        m.console.puts(if ((psc & 0x1) != 0) "1" else "0");
        m.console.puts(" ped=");
        m.console.puts(if ((psc & 0x2) != 0) "1" else "0");
        m.console.puts(" pp=");
        m.console.puts(if ((psc & 0x200) != 0) "1" else "0");
        m.console.puts(" ps=");
        m.console.print_u64((psc >> 10) & 0xf);
        m.console.puts("\n");
    }
    return .none;
}

/// `usb devices` — the enumerated HID device table (I2). One line per
/// enumerated device: slot/port/speed + VID/PID/class/protocol + the
/// interrupt-IN endpoint + the HID boot-protocol negotiation result.
fn cmd_usb_devices(m: *Monitor) ExecError {
    if (!xhci.xhci_ready) {
        m.console.puts("usb devices: no XHCI device\n");
        return .none;
    }
    if (!xhci.enum_done) {
        m.console.puts("usb devices: enumeration incomplete (");
        m.console.puts(if (xhci.enum_fail.len > 0) xhci.enum_fail else "no devices enumerated");
        m.console.puts(")\n");
        return .none;
    }
    m.console.puts("usb devices: count=");
    m.console.print_u64(xhci.enum_count);
    m.console.puts("\n");
    var i: usize = 0;
    while (i < xhci.EnumMax) : (i += 1) {
        const d = xhci.enum_devs[i];
        if (!d.present) continue;
        m.console.puts("usb dev");
        m.console.print_u64(i);
        m.console.puts(": slot=");
        m.console.print_u64(d.slot_id);
        m.console.puts(" port=");
        m.console.print_u64(d.port);
        m.console.puts(" speed=");
        m.console.print_u64(d.speed);
        m.console.puts(" vid=");
        m.console.print_hex_min(d.vid);
        m.console.puts(" pid=");
        m.console.print_hex_min(d.pid);
        m.console.puts(" class=");
        m.console.print_u64(d.class);
        m.console.puts(" protocol=");
        m.console.print_u64(d.protocol);
        m.console.puts(" epin=");
        m.console.print_u64(d.ep_in_num);
        m.console.puts(" maxpkt=");
        m.console.print_u64(d.ep_in_maxpkt);
        m.console.puts(" interval=");
        m.console.print_u64(d.ep_in_interval);
        m.console.puts(" boot=");
        m.console.puts(if (d.hid_boot) "1" else "0");
        m.console.puts("\n");
    }
    return .none;
}

/// `usb report [<dev>]` — poll the device's interrupt-IN endpoint for the
/// last HID report and print it raw + a boot-protocol decode (I2). Defaults
/// to device 0 (the keyboard, if present).
fn cmd_usb_report(m: *Monitor, args: []const []const u8) ExecError {
    if (!xhci.xhci_ready) {
        m.console.puts("usb report: no XHCI device\n");
        return .none;
    }
    var dev_idx: usize = 0;
    if (args.len > 1) {
        dev_idx = parseInt(args[1]) catch 0;
    }
    if (dev_idx >= xhci.EnumMax or !xhci.enum_devs[dev_idx].present) {
        m.console.puts("usb report: no device ");
        m.console.print_u64(dev_idx);
        m.console.puts("\n");
        return .none;
    }
    const d = xhci.enum_devs[dev_idx];
    if (d.ep_in_num == 0) {
        m.console.puts("usb report: device has no interrupt-IN endpoint\n");
        return .none;
    }
    const got = xhci.xhci_poll_intr(d.slot_id);
    if (!got) {
        m.console.puts("usb report: dev");
        m.console.print_u64(dev_idx);
        m.console.puts(" no report (timeout)\n");
        return .none;
    }
    const rep = xhci.xhci_report(d.slot_id);
    m.console.puts("usb report: dev");
    m.console.print_u64(dev_idx);
    m.console.puts(" seq=");
    m.console.print_u64(d.report_seq);
    m.console.puts(" len=");
    m.console.print_u64(rep.len);
    m.console.puts(" bytes=");
    var i: usize = 0;
    while (i < rep.len) : (i += 1) {
        if (i > 0) m.console.puts(" ");
        m.console.print_hex_min(rep.bytes[i]);
    }
    m.console.puts("\n");
    // Boot-protocol decode: keyboard = modifier byte + up to 6 keycodes;
    // mouse = buttons + X + Y. Raw bytes are the ground truth.
    if (xhci.hid_kind[dev_idx] == .keyboard and rep.len >= 8) {
        m.console.puts("usb report: kb mod=");
        m.console.print_hex_min(rep.bytes[0]);
        m.console.puts(" keys=");
        var k: usize = 2;
        while (k < 8) : (k += 1) {
            if (rep.bytes[k] != 0) {
                m.console.print_hex_min(rep.bytes[k]);
                m.console.puts(" ");
            }
        }
        m.console.puts("\n");
    } else if (xhci.hid_kind[dev_idx] == .mouse and rep.len >= 3) {
        m.console.puts("usb report: ptr btn=");
        m.console.print_u64(rep.bytes[0]);
        m.console.puts(" x=");
        m.console.print_u64(rep.bytes[1]);
        m.console.puts(" y=");
        m.console.print_u64(rep.bytes[2]);
        m.console.puts("\n");
    }
    return .none;
}

fn cmd_repeat(m: *Monitor, args: []const []const u8) ExecError {
    const count = parseInt(args[0]) catch {
        err_prefix(m);
        m.console.puts("invalid count: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    if (count < 1 or count > repeat_max_count) {
        err_prefix(m);
        m.console.puts("count must be between 1 and ");
        m.console.print_u64(repeat_max_count);
        m.console.puts("\n");
        return .invalid_argument;
    }
    // Measure the joined text length (saturating) before printing anything.
    const parts = args[1..];
    var text_len: usize = 0;
    for (parts) |part| {
        text_len = @min(repeat_max_bytes, text_len +| part.len);
    }
    if (parts.len > 1) text_len = @min(repeat_max_bytes, text_len + parts.len - 1);
    const per_line = text_len + 1; // + the trailing newline
    if (per_line > repeat_max_bytes or count > @as(u64, repeat_max_bytes / per_line)) {
        err_prefix(m);
        m.console.puts("output too large (max ");
        m.console.print_u64(repeat_max_bytes);
        m.console.puts(" bytes)\n");
        return .invalid_argument;
    }
    var n: u64 = 0;
    while (n < count) : (n += 1) {
        for (parts, 0..) |part, index| {
            if (index > 0) m.console.putc(' ');
            m.console.puts(part);
        }
        m.console.puts("\n");
    }
    return .none;
}

/// `sh` — M18 T16 (issue #419): registered here for discovery (help,
/// tab completion, usage shape). Actual script execution lives in the
/// interactive shell (`shell.zig` intercepts `sh` before this registry
/// is reached, because scripts must execute through the shell's
/// handle_line). Direct `monitor.exec` of `sh` — host tests only — gets
/// an honest refusal rather than a silent no-op.
/// `type` — M19 P1 (issue #290). The real work is a shell builtin
/// (intercepted before monitor.exec); this registry entry exists for
/// help/usage/completion discovery and refuses direct execution the same
/// way `cmd_sh` does.
fn cmd_type(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    err_prefix(m);
    m.console.print_line("type: echoes the pipe source; use it as the right half of `a | type`");
    return .invalid_argument;
}

fn cmd_sh(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    // ADR 0008 D3 shape 2: a refusal wears the `error:` prefix.
    err_prefix(m);
    m.console.print_line("sh: script execution runs through the interactive shell");
    return .invalid_argument;
}

/// `settings` — report and modify persistent configuration (claim 2649,
/// milestone eight card U8). Backed by `SETTINGS.TXT` on the DATA partition.
/// `settings` / `settings list`: print all active key-value pairs.
/// `settings get <key>`: look up a single key.
/// `settings set <key> <val>`: update in memory and persist immediately.
/// `settings reset`: restore default settings and persist.
fn cmd_settings(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 0 or (args.len == 1 and std.mem.eql(u8, args[0], "list"))) {
        m.console.print_line("settings:");
        var i: usize = 0;
        while (i < settings.count()) : (i += 1) {
            if (settings.entry_at(i)) |e| {
                m.console.puts("  ");
                m.console.puts(e.key);
                m.console.puts("=");
                m.console.puts(e.val);
                m.console.puts("\n");
            }
        }
        return .none;
    }
    if (std.mem.eql(u8, args[0], "get")) {
        if (args.len != 2) {
            print_usage(m, lookup("settings").?);
            return .usage;
        }
        if (settings.get(args[1])) |val| {
            m.console.puts("settings: ");
            m.console.puts(args[1]);
            m.console.puts("=");
            m.console.puts(val);
            m.console.puts("\n");
            return .none;
        }
        err_prefix(m);
        m.console.puts("unknown setting: ");
        m.console.puts(args[1]);
        m.console.puts("\n");
        return .invalid_argument;
    }
    if (std.mem.eql(u8, args[0], "set")) {
        if (args.len != 3) {
            print_usage(m, lookup("settings").?);
            return .usage;
        }
        const key = args[1];
        const val = args[2];
        const res = settings.set(key, val);
        if (res != .ok) {
            err_prefix(m);
            m.console.puts("invalid setting key or value: ");
            m.console.puts(key);
            m.console.puts("\n");
            return .invalid_argument;
        }
        const saved = settings.save_to_disk(virtio_blk.disk_ops());
        m.console.puts("settings: ");
        m.console.puts(key);
        m.console.puts("=");
        m.console.puts(val);
        if (saved) {
            m.console.puts(" (persisted)\n");
        } else {
            m.console.puts(" (memory only)\n");
        }
        return .none;
    }
    if (std.mem.eql(u8, args[0], "reset")) {
        if (args.len != 1) {
            print_usage(m, lookup("settings").?);
            return .usage;
        }
        settings.reset();
        const saved = settings.save_to_disk(virtio_blk.disk_ops());
        m.console.puts("settings: reset to defaults");
        if (saved) {
            m.console.puts(" (persisted)\n");
        } else {
            m.console.puts(" (memory only)\n");
        }
        return .none;
    }
    print_usage(m, lookup("settings").?);
    return .usage;
}

// ---------------------------------------------------------------------------
// Machine control commands
// ---------------------------------------------------------------------------

fn cmd_reboot(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    return report_machine(m, "reboot", m.machine.reboot());
}

fn cmd_shutdown(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    m.console.print_line("shutdown: initiating graceful shutdown...");

    // Step 1: Post WIN_CLOSE event to every user window (apps can save
    // via the unsaved dialog from #242). The window stays alive until
    // the process exits or is killed below.
    m.console.print_line("shutdown: closing windows...");
    var i: usize = 0;
    while (i < process.max_processes) : (i += 1) {
        if (process.info(@intCast(i))) |info| {
            if (info.state == .running and info.task_id != null) {
                // Post WIN_CLOSE to each user window owned by this process.
                const pid_val: usize = @intCast(info.id);
                var win_id: u8 = driving_award.user_window_id_base;
                while (win_id < driving_award.user_window_id_base + @as(u8, @intCast(driving_award.user_windows_max))) : (win_id += 1) {
                    if (driving_award.user_owner(win_id)) |owner| {
                        if (owner == pid_val) {
                            events.push(pid_val, .{
                                .kind = events.WIN_CLOSE,
                                .flags = 0,
                                .seq = 0,
                                .arg0 = win_id,
                                .arg1 = 0,
                            });
                        }
                    }
                }
            }
        }
    }

    // Step 2: Wait 50 scheduler ticks (~5 seconds) for graceful exit
    m.console.print_line("shutdown: waiting for apps (50 ticks)...");
    _ = scheduler.sleep_current(50);

    // Step 3: Forcibly kill any remaining user processes
    m.console.print_line("shutdown: killing remaining processes...");
    i = 0;
    while (i < process.max_processes) : (i += 1) {
        if (process.info(@intCast(i))) |info| {
            if (info.state == .running) {
                _ = scheduler.request_kill(@intCast(i));
            }
        }
    }

    // Step 4: Flush clipboard to /data/clipboard.txt (persistence across reboot)
    m.console.print_line("shutdown: flushing clipboard...");
    flush_clipboard_to_disk();

    // Step 5: Write shutdown marker to /data/SHUTDOWN.TXT with tick + reason
    m.console.print_line("shutdown: writing marker...");
    write_shutdown_marker("graceful");

    // Step 6: Halt the CPU (WFI loop — no return)
    m.console.print_line("shutdown: halting...");
    return report_machine(m, "shutdown", m.machine.shutdown());
}

/// Write shutdown marker to /data/SHUTDOWN.TXT on the DATA partition.
/// `reason` is a short label ("graceful", "reboot", etc.).
fn write_shutdown_marker(reason: []const u8) void {
    const ops = virtio_blk.disk_ops();

    if (fat.mount_data(ops) != .ok) return;

    // Format marker content: tick count + reason
    var buf: [128]u8 = undefined;
    var pos: usize = 0;

    const header = "DipshitOS Shutdown\n";
    @memcpy(buf[0..header.len], header);
    pos = header.len;

    const tick_prefix = "Tick: ";
    @memcpy(buf[pos..][0..tick_prefix.len], tick_prefix);
    pos += tick_prefix.len;
    pos += write_u64_to(buf[pos..], timer.ticks);
    buf[pos] = '\n';
    pos += 1;

    const reason_prefix = "Reason: ";
    @memcpy(buf[pos..][0..reason_prefix.len], reason_prefix);
    pos += reason_prefix.len;
    const rlen = @min(reason.len, buf.len - pos);
    @memcpy(buf[pos..][0..rlen], reason[0..rlen]);
    pos += rlen;
    buf[pos] = '\n';
    pos += 1;

    _ = fat.write_file("SHUTDOWN.TXT", buf[0..pos]);

    _ = esp.set_disk(ops);
}

/// Flush the shared clipboard to /data/clipboard.txt for persistence
/// across reboot (Arc5 #244).
fn flush_clipboard_to_disk() void {
    const clip_len = clipboard.current_len();
    if (clip_len == 0) return;
    var buf: [clipboard.capacity]u8 = undefined;
    const n = clipboard.get(&buf);
    if (n == 0) return;
    const ops = virtio_blk.disk_ops();
    if (fat.mount_data(ops) != .ok) return;
    _ = fat.write_file("clipboard.txt", buf[0..n]);
    _ = esp.set_disk(ops);
}

fn write_u64_to(out: []u8, val: u64) usize {
    if (val == 0) {
        if (out.len > 0) out[0] = '0';
        return 1;
    }
    var buf: [20]u8 = undefined;
    var v = val;
    var len: usize = 0;
    while (v > 0) : (len += 1) {
        buf[len] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
    }
    var i: usize = 0;
    while (i < len and i < out.len) : (i += 1) {
        out[i] = buf[len - 1 - i];
    }
    return @min(len, out.len);
}

// ---------------------------------------------------------------------------
// Personality commands
// ---------------------------------------------------------------------------

/// Fixed mascot art (bounded, deterministic, no state). Runtime-built into
/// module storage (not a const table): a const array of string slices would
/// hold link-time absolute pointers, wrong at the kernel's runtime load
/// base (claim 0015 root cause — the flat loader applies no relocations).
var elephant_storage: [12][]const u8 = undefined;
var elephant_ready = false;
pub fn elephant_lines() []const []const u8 {
    if (!elephant_ready) {
        elephant_storage[0] = "      _    _";
        elephant_storage[1] = "     (o)  (o)";
        elephant_storage[2] = "       \\  /";
        elephant_storage[3] = "       _||_";
        elephant_storage[4] = "      /    \\";
        elephant_storage[5] = "     |  __  |";
        elephant_storage[6] = "     | |  | |";
        elephant_storage[7] = "     |_|  |_|";
        elephant_storage[8] = "    /  |  |  \\";
        elephant_storage[9] = "   /   |  |   \\";
        elephant_storage[10] = "  |    |  |    |";
        elephant_storage[11] = "  |____|  |____|";
        elephant_ready = true;
    }
    return &elephant_storage;
}

// ---------------------------------------------------------------------------
// Interrupt-controller + timer command (claim 7948)
// ---------------------------------------------------------------------------

/// Report the GIC + generic-timer state. Hardware-free: reads the discovery
/// globals (pre-exit ACPI values) and the timer counters, so it runs
/// unchanged in a host test process (armed=0, gic=none there).
fn cmd_timer(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    m.console.puts("timer: armed=");
    m.console.print_u64(if (gic.armed() and timer.armed()) 1 else 0);
    m.console.puts(" gic=");
    m.console.puts(gic.kind_name());
    m.console.puts(" dist=");
    m.console.print_hex_min(gic.dist_base);
    m.console.puts(" ppi=");
    m.console.print_hex_min(timer.ppi);
    m.console.puts(" freq=");
    m.console.print_hex_min(timer.freq);
    m.console.puts(" ticks=");
    m.console.print_u64(timer.ticks);
    m.console.puts(" irq=");
    m.console.print_u64(timer.irq_ticks);
    m.console.puts(" poll=");
    m.console.print_u64(timer.poll_ticks);
    m.console.puts(" acked=");
    m.console.print_u64(gic.irqs_acked);
    m.console.puts(" first=");
    m.console.print_hex_min(gic.first_intid);
    m.console.puts("\n");
    return .none;
}

// ---------------------------------------------------------------------------
// Tick-driven task scheduler command (claim 5275)
// ---------------------------------------------------------------------------

/// Report the round-robin scheduler state: enabled/current/switches plus
/// per-task saves/resumes/advances. Deterministic and grep-able; runs
/// unchanged in a host test process (tasks may be registered but never
/// started there, so the counters read 0).
fn cmd_tasks(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    const s = scheduler.stats();
    m.console.puts("tasks: enabled=");
    m.console.print_u64(if (s.enabled) 1 else 0);
    m.console.puts(" current=");
    m.console.print_u64(@intCast(s.current));
    m.console.puts(" switches=");
    m.console.print_u64(s.switches);
    // Claim 6729: the lifecycle's pool/zombie counts (registered slots vs
    // the fixed pool; zombies awaiting the idle task's reap).
    m.console.puts(" pool=");
    m.console.print_u64(@intCast(s.count));
    m.console.puts("/");
    m.console.print_u64(@intCast(scheduler.max_tasks));
    m.console.puts(" zombies=");
    m.console.print_u64(@intCast(s.zombies));
    m.console.puts("\n");
    // Scan the full pool: reaped (free) slots are skipped, so a freed mid
    // slot never hides later-registered tasks.
    var width: usize = 0;
    var i: usize = 0;
    while (i < scheduler.max_tasks) : (i += 1) {
        if (scheduler.task_info(i)) |t| width = @max(width, t.name.len);
    }
    i = 0;
    while (i < scheduler.max_tasks) : (i += 1) {
        const info = scheduler.task_info(i) orelse continue;
        m.console.puts("  ");
        m.console.puts(info.name);
        var pad: usize = info.name.len;
        while (pad <= width) : (pad += 1) m.console.putc(' ');
        m.console.puts("saves=");
        m.console.print_u64(info.saves);
        m.console.puts(" resumes=");
        m.console.print_u64(info.resumes);
        m.console.puts(" advances=");
        m.console.print_u64(info.advances);
        m.console.puts(" state=");
        m.console.puts(scheduler.state_name(info.state));
        m.console.puts("\n");
    }
    return .none;
}

fn cmd_smp(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    m.console.puts("smp: cores=");
    m.console.print_u64(@as(u64, smp.num_cores));
    var online_count: u64 = 0;
    var c: usize = 0;
    while (c < smp.max_cores) : (c += 1) {
        if (smp.core_online[c]) online_count += 1;
    }
    m.console.puts(" online=");
    m.console.print_u64(online_count);
    m.console.puts("\n");

    c = 0;
    while (c < smp.max_cores) : (c += 1) {
        if (c >= smp.num_cores and !smp.core_online[c]) continue;
        m.console.puts("  core ");
        m.console.print_u64(c);
        m.console.puts(": ");
        if (c == 0) m.console.puts("bsp ") else m.console.puts("ap  ");
        m.console.puts("mpidr=");
        m.console.print_hex(smp.core_mpidr[c]);
        m.console.puts(" state=");
        m.console.puts(if (smp.core_online[c]) "online" else "offline");
        m.console.puts(" task=");
        const cur_tid = scheduler.current_task_for_core(c);
        if (scheduler.task_info(cur_tid)) |info| {
            m.console.puts(info.name);
        } else {
            m.console.puts("none");
        }
        m.console.puts("\n");
    }
    return .none;
}

// ---------------------------------------------------------------------------
// Process command (claim 3848)
// ---------------------------------------------------------------------------

/// Report the process table (claim 3848): one line per non-free process
/// descriptor — id, name, lifecycle state, the bound executor task ("reaped"
/// once exited), the user stack VA, and the exit status (only for exited
/// processes). The process owns the PROGRAM (image + address space + state
/// + exit status) above the task pool: after the idle task reaps the
/// executor slot, `procs` still shows the program's exit status — the
/// information the task lifecycle alone throws away. Deterministic and
/// grep-able.
fn cmd_procs(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    m.console.puts("procs: count=");
    m.console.print_u64(@intCast(process.count()));
    m.console.puts("\n");
    var id: usize = 0;
    while (id < process.max_processes) : (id += 1) {
        const info = process.info(id) orelse continue;
        m.console.puts("procs: id=");
        m.console.print_u64(@intCast(info.id));
        m.console.puts(" name=");
        m.console.puts(info.name);
        m.console.puts(" state=");
        m.console.puts(process.state_name(info.state));
        m.console.puts(" task=");
        // Claim 4613: an exited process keeps its executor slot until the
        // lifecycle reap frees its pages — the row still reads `reaped`
        // (the slot is a zombie, no longer executing the program).
        if (info.state == .exited) {
            m.console.puts("reaped");
        } else if (info.task_id) |task_id| {
            m.console.print_u64(@intCast(task_id));
        } else {
            m.console.puts("-");
        }
        m.console.puts(" stack=");
        m.console.print_hex(info.stack_va);
        m.console.puts(" exit=");
        if (info.state == .exited) {
            m.console.print_u64(info.exit_status);
        } else {
            m.console.puts("-");
        }
        m.console.puts("\n");
    }
    return .none;
}

// ---------------------------------------------------------------------------
// Kill command (milestone-four follow-on 3, card 3c — claim 7786)
// ---------------------------------------------------------------------------

/// `kill <pid|name>` — the kernel, not the program, owns process lifetime.
/// The target is looked up in the process registry (by `procs` id or by
/// process name), then ARMED for termination: `scheduler.request_kill`
/// marks its TCB, and the ring converts the target's NEXT selection into
/// the existing exit path with the reserved status 137 (the counter's
/// `exit=137` in `procs` / `tasks user-exec exited status=137`). No new
/// syscall — ADR 0007 stays frozen. Every refusal is clean and exact
/// (host-tested strings).
fn cmd_kill(m: *Monitor, args: []const []const u8) ExecError {
    const arg = args[0];
    // Resolve the target process: by numeric `procs` id, else by name.
    const pid: ?usize = if (parseInt(arg)) |value| blk: {
        if (value < process.max_processes and process.info(@as(usize, @intCast(value))) != null) {
            break :blk @as(usize, @intCast(value));
        }
        break :blk null;
    } else |_| blk: {
        var id: usize = 0;
        while (id < process.max_processes) : (id += 1) {
            const info = process.info(id) orelse continue;
            if (std.mem.eql(u8, info.name, arg)) break :blk id;
        }
        break :blk null;
    };
    const pid_value = pid orelse {
        err_prefix(m);
        m.console.puts("no such process: ");
        m.console.puts(arg);
        m.console.puts("\n");
        return .invalid_argument;
    };
    const info = process.info(pid_value).?;
    if (info.state == .exited) {
        err_prefix(m);
        m.console.puts(info.name);
        m.console.puts(" already exited\n");
        return .invalid_argument;
    }
    // A created-but-unbound process (exec's pre-spawn window) has no
    // executor to terminate; a running process names its executor slot.
    const task_id = info.task_id orelse {
        err_prefix(m);
        m.console.puts(info.name);
        m.console.puts(" not running\n");
        return .invalid_argument;
    };
    switch (scheduler.request_kill(task_id)) {
        .ok => {
            m.console.puts("kill: ");
            m.console.puts(info.name);
            m.console.puts(" armed\n");
            return .none;
        },
        .not_found => {
            err_prefix(m);
            m.console.puts(info.name);
            m.console.puts(" not found\n");
            return .invalid_argument;
        },
        .already_exited => {
            err_prefix(m);
            m.console.puts(info.name);
            m.console.puts(" already exited\n");
            return .invalid_argument;
        },
        .refused => {
            err_prefix(m);
            m.console.print_line("cannot kill the shell or scheduler-owned idle task");
            return .invalid_argument;
        },
    }
}

// ---------------------------------------------------------------------------
// IPC mailbox command (milestone-four follow-on 3, card 3f — claim 5965)
// ---------------------------------------------------------------------------

/// `mbox [<pid>]` — dump the per-process IPC mailboxes: for every live
/// process (or just the one named by `pid`), the pending message count
/// and the enqueue/dequeue counters, then the queued bytes themselves.
/// The counters are the draining proof: a process whose ring is drained
/// has `recv` tracking `sent` and `pending` back at 0. Deterministic and
/// grep-able (the live IPC gate greps `mbox: id=` and `pending=` rows).
fn cmd_mbox(m: *Monitor, args: []const []const u8) ExecError {
    const wanted: ?usize = if (args.len > 0) blk: {
        const value = parseInt(args[0]) catch {
            err_prefix(m);
            m.console.puts("mbox: invalid pid: ");
            m.console.puts(args[0]);
            m.console.puts("\n");
            return .invalid_argument;
        };
        if (value >= process.max_processes or process.info(@as(usize, @intCast(value))) == null) {
            err_prefix(m);
            m.console.puts("mbox: no such process: ");
            m.console.puts(args[0]);
            m.console.puts("\n");
            return .invalid_argument;
        }
        break :blk @as(usize, @intCast(value));
    } else null;
    var id: usize = 0;
    while (id < process.max_processes) : (id += 1) {
        const info = process.info(id) orelse continue;
        if (wanted) |w| if (w != id) continue;
        const mbox_info = mailbox.info(id);
        m.console.puts("mbox: id=");
        m.console.print_u64(@intCast(id));
        m.console.puts(" name=");
        m.console.puts(info.name);
        m.console.puts(" pending=");
        m.console.print_u64(@intCast(mbox_info.pending));
        m.console.puts(" sent=");
        m.console.print_u64(mbox_info.sent);
        m.console.puts(" recv=");
        m.console.print_u64(mbox_info.recv);
        m.console.puts("\n");
        // Raw dump of the queued bytes (messages are text here; the ring
        // bound caps the total at 8 × 64 B per process).
        var index: usize = 0;
        while (mailbox.message(id, index)) |bytes| : (index += 1) {
            m.console.puts("mbox:   ");
            m.console.print_u64(@intCast(index));
            m.console.puts(": ");
            m.console.puts(bytes);
            m.console.puts("\n");
        }
    }
    return .none;
}

// ---------------------------------------------------------------------------
// Net commands (milestone five card N1 — claim 1373)
// ---------------------------------------------------------------------------

/// `net` — report the virtio-net transport: the OBSERVED device DID +
/// class + bus slot, the MAC (with its source: the VIRTIO_NET_F_MAC
/// feature read or the fixed BSS fallback), the negotiated feature bits
/// (low/high), the two queues (q0 RX / q1 TX) with their sizes, the
/// device status + post-exit re-arm state, the TX counters, and (card
/// N2, claim 6076) the RX counters (frames received into the FIFO,
/// filtered/dropped, FIFO overflow + occupancy) + the rx-obs record
/// (last device-written length + first 16 bytes — the claim-time header
/// question). Grep-able and deterministic (the mbox/procs observability
/// shape). Honest when the device is absent: the default runner attaches
/// no network device. `net recv` is the card-N2 subcommand: drain the RX
/// used ring and print the received frame(s) byte-exact.
fn cmd_net(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len > 0) {
        if (std.mem.eql(u8, args[0], "recv")) return cmd_net_recv(m, args[1..]);
        if (std.mem.eql(u8, args[0], "ip")) return cmd_net_ip(m, args[1..]);
        if (std.mem.eql(u8, args[0], "arp")) return cmd_net_arp(m, args[1..]);
        if (std.mem.eql(u8, args[0], "ping")) return cmd_net_ping(m, args[1..]);
        if (std.mem.eql(u8, args[0], "udp")) return cmd_net_udp(m, args[1..]);
        if (std.mem.eql(u8, args[0], "dhcp")) return cmd_net_dhcp(m, args[1..]);
        if (std.mem.eql(u8, args[0], "tcp")) return cmd_net_tcp(m, args[1..]);
        if (std.mem.eql(u8, args[0], "dns")) return cmd_net_dns(m, args[1..]);
        if (std.mem.eql(u8, args[0], "status")) return cmd_net_status(m, args[1..]);
        if (std.mem.eql(u8, args[0], "route")) return cmd_net_route(m, args[1..]);
        if (std.mem.eql(u8, args[0], "log")) return cmd_net_log(m, args[1..]);
        print_usage(m, lookup("net").?);
        return .usage;
    }
    if (!virtio_net.net_ready) {
        m.console.puts("net: no virtio-net device (");
        m.console.puts(if (virtio_net.net_fail.len > 0) virtio_net.net_fail else "DID 0x1041 not found on bus 0");
        m.console.puts(")\n");
        // The offered features as observed (the honest claim-time record
        // when negotiation fails).
        m.console.puts("net: device-features=");
        m.console.print_hex(virtio_net.net_dev_feats_lo);
        m.console.puts("/");
        m.console.print_hex(virtio_net.net_dev_feats_hi);
        m.console.puts("\n");
        // The honest claim-time record when negotiation fails: the status
        // the device returned after the FEATURES_OK write (0x03 = it
        // rejected the accepted features; 0x00 = the status writes never
        // landed), what we actually accepted, and where the regions
        // resolved (so a BAR/capability walk mistake is visible).
        m.console.puts("net: status=");
        m.console.print_hex(virtio_net.net_status_last);
        m.console.puts(" accepted=");
        m.console.print_hex(virtio_net.net_dev.feats_lo);
        m.console.puts("/");
        m.console.print_hex(virtio_net.net_dev.feats_hi);
        m.console.puts("\n");
        m.console.puts("net: common=");
        m.console.print_hex(virtio_net.net_common);
        m.console.puts(" notify=");
        m.console.print_hex(virtio_net.net_notify);
        m.console.puts(" devcfg=");
        m.console.print_hex(virtio_net.net_devcfg);
        m.console.puts(" bar0=");
        m.console.print_hex(virtio_net.net_bar0);
        m.console.puts("\n");
        return .none;
    }
    // print_hex already emits "0x" + full 16 hex digits (the mbox/procs
    // observability shape) — no manual prefix.
    m.console.puts("net: did=");
    m.console.print_hex(virtio_net.net_did);
    m.console.puts(" class=");
    m.console.print_hex(virtio_net.net_class);
    m.console.puts(" dev=");
    m.console.print_u64(@intCast(virtio_net.net_dev_no));
    m.console.puts("\n");
    m.console.puts("net: mac=");
    m.console.puts(&virtio_net.net_mac_text);
    m.console.puts(" source=");
    m.console.puts(switch (virtio_net.net_mac_source) {
        .feature => "feature",
        .fallback => "fallback",
    });
    m.console.puts("\n");
    // The raw device-config MAC bytes captured pre-exit (the claim-1373
    // record: whether the host-set address is exposed at config offset 0
    // even without the MAC feature).
    if (virtio_net.net_devcfg_mac_seen) {
        m.console.puts("net: cfgmac=");
        var ci: usize = 0;
        while (ci < 6) : (ci += 1) {
            if (ci > 0) m.console.puts(":");
            const b = virtio_net.net_devcfg_mac_obs[ci];
            const hex = "0123456789abcdef";
            var two: [2]u8 = .{ hex[b >> 4], hex[b & 0xf] };
            m.console.puts(&two);
        }
        m.console.puts("\n");
    }
    m.console.puts("net: feat=");
    m.console.print_hex(virtio_net.net_dev.feats_lo);
    m.console.puts("/");
    m.console.print_hex(virtio_net.net_dev.feats_hi);
    m.console.puts(" q0=rx:size=");
    m.console.print_u64(@intCast(virtio_net.queue_size));
    m.console.puts(" q1=tx:size=");
    m.console.print_u64(@intCast(virtio_net.queue_size));
    m.console.puts("\n");
    m.console.puts("net: status=");
    m.console.print_hex(virtio_net.net_status_last);
    m.console.puts(" rearm=");
    m.console.print_u64(if (virtio_net.net_rearmed) 1 else 0);
    m.console.puts(" tx=frames=");
    m.console.print_u64(virtio_net.net_dev.tx_frames);
    m.console.puts(",bytes=");
    m.console.print_u64(virtio_net.net_dev.tx_bytes);
    m.console.puts("\n");
    // Card N2 (claim 6076): RX counters + the rx-obs record. The drain is
    // idempotent (also run from the shell idle loop) so the report is
    // current when the frame has already landed.
    virtio_net.net_rx_drain();
    m.console.puts("net: rx=frames=");
    m.console.print_u64(virtio_net.rx_frames);
    m.console.puts(",bytes=");
    m.console.print_u64(virtio_net.rx_bytes);
    m.console.puts(",filtered=");
    m.console.print_u64(virtio_net.rx_filtered);
    m.console.puts(",overflow=");
    m.console.print_u64(virtio_net.rx_overflow);
    m.console.puts(",fifo=");
    m.console.print_u64(@intCast(virtio_net.fifo_occupancy()));
    m.console.puts("\n");
    // The raw ring state (the claim-time record): the guest's avail.idx
    // vs the device's used.idx tell whether a delivery ever completed.
    m.console.puts("net: rx-rings avail=");
    m.console.print_u64(@intCast(virtio_net.net_dev.rx_avail.idx));
    m.console.puts(" used=");
    m.console.print_u64(@intCast(virtio_net.net_dev.rx_used.idx));
    m.console.puts(" armed=");
    m.console.print_u64(if (virtio_net.rx_armed) 1 else 0);
    m.console.puts("\n");
    // The claim-time observation record: the last device-written length +
    // the first 16 bytes pin the RX-header question (12 zero bytes + dst
    // MAC = header present; dst MAC at 0 = none). Recorded even when the
    // filter dropped the frame, so a drop is distinguishable from a
    // failed delivery.
    m.console.puts("net: rx-obs len=");
    m.console.print_u64(virtio_net.rx_last_len);
    m.console.puts(" first16=");
    var oi: usize = 0;
    while (oi < 16) : (oi += 1) {
        if (oi > 0) m.console.puts(" ");
        const b = virtio_net.rx_first16[oi];
        const hex = "0123456789abcdef";
        var two: [2]u8 = .{ hex[b >> 4], hex[b & 0xf] };
        m.console.puts(&two);
    }
    m.console.puts("\n");
    // Card N3 (claim 7293): the ARP layer — our static IP (0.0.0.0 when
    // unset — DHCP is a later card, honest bound) + the counters
    // (requests sent, replies answered, replies learned, dropped,
    // reply TX failures). Grep-able and deterministic.
    m.console.puts("net: ip=");
    var ipbuf: [15]u8 = undefined;
    const ipn = virtio_net.arp.format_ip(virtio_net.arp.own_ip, &ipbuf);
    m.console.puts(ipbuf[0..ipn]);
    m.console.puts(" arp=req=");
    m.console.print_u64(virtio_net.arp.requests_sent);
    m.console.puts(",repl=");
    m.console.print_u64(virtio_net.arp.replies_sent);
    m.console.puts(",learn=");
    m.console.print_u64(virtio_net.arp.replies_learned);
    m.console.puts(",drop=");
    m.console.print_u64(virtio_net.arp.dropped);
    m.console.puts(",fail=");
    m.console.print_u64(virtio_net.arp.reply_tx_fail);
    m.console.puts("\n");
    // Card N4 (claim 0148): the IPv4/ICMP layer — echo requests sent
    // (`net ping`), echo replies answered, pongs observed (an echo
    // reply's id/seq echoed back — the ping proof), drops by cause, and
    // the last observed sequence. Grep-able and deterministic.
    m.console.puts(" icmp=req=");
    m.console.print_u64(virtio_net.ipv4.requests_sent);
    m.console.puts(",repl=");
    m.console.print_u64(virtio_net.ipv4.replies_sent);
    m.console.puts(",pong=");
    m.console.print_u64(virtio_net.ipv4.pongs_observed);
    m.console.puts(",drop=");
    m.console.print_u64(virtio_net.ipv4.dropped_short + virtio_net.ipv4.dropped_frag + virtio_net.ipv4.dropped_checksum + virtio_net.ipv4.dropped_proto + virtio_net.ipv4.dropped_other);
    m.console.puts(",fail=");
    m.console.print_u64(virtio_net.ipv4.reply_tx_fail);
    m.console.puts(",seq=");
    m.console.print_u64(virtio_net.ipv4.last_seq);
    m.console.puts("\n");
    // Card N5 (claim 8552): the UDP layer — datagrams received (into a
    // listener's buffer, incl. loopback), sent (device TX + loopback),
    // loopbacked (the no-device path), and dropped (the sum of the three
    // counted causes). Grep-able and deterministic.
    m.console.puts(" udp=rx=");
    m.console.print_u64(virtio_net.udp.received);
    m.console.puts(",tx=");
    m.console.print_u64(virtio_net.udp.sent);
    m.console.puts(",loop=");
    m.console.print_u64(virtio_net.udp.loopbacked);
    m.console.puts(",drop=");
    m.console.print_u64(virtio_net.udp.dropped_badsum + virtio_net.udp.dropped_closed + virtio_net.udp.dropped_len);
    m.console.puts("\n");
    // Card N8 (claim 0351) + card N9 (claim 9489): the DHCP client — the
    // state (bound/unbound/renewing/rebinding), the lease
    // (ip/mask/gw/server/lease — zeros when unbound), the handshake
    // counters (discover sent, offer recv, request sent, ack recv, nack,
    // timeout, malformed), and the lease-lifecycle counters (renewing
    // REQUESTs sent, rebinding REQUESTs sent, renewals ACKed, expiries
    // enforced). Grep-able and deterministic. The lifecycle counters
    // APPEND at the end — the N8 gate's substring assertions stay green.
    m.console.puts(" dhcp=");
    m.console.puts(switch (virtio_net.dhcp.state) {
        .idle => "idle",
        .selecting => "selecting",
        .requesting => "requesting",
        .bound => "bound",
        .renewing => "renewing",
        .rebinding => "rebinding",
    });
    m.console.puts(",ip=");
    var dibuf: [15]u8 = undefined;
    const din = virtio_net.arp.format_ip(virtio_net.dhcp.lease_ip, &dibuf);
    m.console.puts(dibuf[0..din]);
    m.console.puts(",mask=");
    const dmn = virtio_net.arp.format_ip(virtio_net.dhcp.lease_mask, &dibuf);
    m.console.puts(dibuf[0..dmn]);
    m.console.puts(",gw=");
    const dgn = virtio_net.arp.format_ip(virtio_net.dhcp.lease_gw, &dibuf);
    m.console.puts(dibuf[0..dgn]);
    m.console.puts(",server=");
    const dsn = virtio_net.arp.format_ip(virtio_net.dhcp.lease_server, &dibuf);
    m.console.puts(dibuf[0..dsn]);
    m.console.puts(",lease=");
    m.console.print_u64(virtio_net.dhcp.lease_time);
    m.console.puts(",discover=");
    m.console.print_u64(virtio_net.dhcp.discover_sent);
    m.console.puts(",offer=");
    m.console.print_u64(virtio_net.dhcp.offer_recv);
    m.console.puts(",request=");
    m.console.print_u64(virtio_net.dhcp.request_sent);
    m.console.puts(",ack=");
    m.console.print_u64(virtio_net.dhcp.ack_recv);
    m.console.puts(",nack=");
    m.console.print_u64(virtio_net.dhcp.nack_recv);
    m.console.puts(",timeout=");
    m.console.print_u64(virtio_net.dhcp.timed_out);
    m.console.puts(",mal=");
    m.console.print_u64(virtio_net.dhcp.dropped_malformed);
    // Card N9 (claim 9489): the lease lifecycle counters (append-only).
    m.console.puts(",renew=");
    m.console.print_u64(virtio_net.dhcp.renew_sent);
    m.console.puts(",rebind=");
    m.console.print_u64(virtio_net.dhcp.rebind_sent);
    m.console.puts(",renewed=");
    m.console.print_u64(virtio_net.dhcp.renewed);
    m.console.puts(",expired=");
    m.console.print_u64(virtio_net.dhcp.expired);
    m.console.puts("\n");
    // Card N10 (claim 7026): the bounded TCP client — the state
    // (idle/syn_sent/established/fin_sent/closed), the peer (zeros when
    // unbound), and the counters (SYNs sent, SYN-ACKs recv, ACKs sent,
    // data sent/recv, FINs sent, FIN-ACKs recv, RSTs sent/recv, the
    // connect-timeout refusals, and the drop sum — badsum + malformed).
    // Grep-able and deterministic.
    m.console.puts(" tcp=");
    m.console.puts(switch (virtio_net.tcp.state) {
        .idle => "idle",
        .listen => "listen",
        .syn_sent => "syn_sent",
        .syn_received => "syn_received",
        .established => "established",
        .fin_sent => "fin_sent",
        .closed => "closed",
    });
    m.console.puts(",peer=");
    var tibuf: [15]u8 = undefined;
    const tin = virtio_net.arp.format_ip(virtio_net.tcp.peer_ip, &tibuf);
    m.console.puts(tibuf[0..tin]);
    m.console.puts(":");
    m.console.print_u64(virtio_net.tcp.peer_port);
    m.console.puts(",syn=");
    m.console.print_u64(virtio_net.tcp.syn_sent);
    m.console.puts(",synack=");
    m.console.print_u64(virtio_net.tcp.synack_recv);
    m.console.puts(",ack=");
    m.console.print_u64(virtio_net.tcp.ack_sent);
    m.console.puts(",data_s=");
    m.console.print_u64(virtio_net.tcp.data_sent);
    m.console.puts(",data_r=");
    m.console.print_u64(virtio_net.tcp.data_recv);
    m.console.puts(",fin=");
    m.console.print_u64(virtio_net.tcp.fin_sent);
    m.console.puts(",finack=");
    m.console.print_u64(virtio_net.tcp.finack_recv);
    m.console.puts(",rst_s=");
    m.console.print_u64(virtio_net.tcp.rst_sent);
    m.console.puts(",rst_r=");
    m.console.print_u64(virtio_net.tcp.rst_recv);
    m.console.puts(",timedout=");
    m.console.print_u64(virtio_net.tcp.timed_out);
    m.console.puts(",mal=");
    m.console.print_u64(virtio_net.tcp.dropped_badsum + virtio_net.tcp.dropped_malformed);
    // Card N11 (claim 5357): the retransmission counters APPENDED at the
    // end (the N9 append-never-change convention — the N10 gate's
    // substring assertions stay green). retx = segment retransmissions,
    // abort = the retransmission-bound aborts.
    m.console.puts(",retx=");
    m.console.print_u64(virtio_net.tcp.retransmitted);
    m.console.puts(",abort=");
    m.console.print_u64(virtio_net.tcp.retx_aborted);
    m.console.puts("\n");
    // Milestone 12 Card N2 (claim 7566): DNS resolver counters
    m.console.puts(" dns=");
    m.console.puts(switch (dns.state) {
        .idle => "idle",
        .query_sent => "query_sent",
        .resolved => "resolved",
        .failed => "failed",
    });
    m.console.puts(",q=");
    m.console.print_u64(dns.queries_sent);
    m.console.puts(",r=");
    m.console.print_u64(dns.responses_recv);
    m.console.puts(",err=");
    m.console.print_u64(dns.responses_err);
    m.console.puts(",timeout=");
    m.console.print_u64(dns.timed_out);
    m.console.puts("\n");
    return .none;
}

/// `net dhcp` — card N8 (claim 0351) + card N9 (claim 9489): drive the
/// bounded RFC 2131 client ONE STEP per invocation. INIT (idle): build
/// + transmit the DISCOVER (a CSPRNG transaction id), print it;
/// SELECTING: wait for the OFFER (already processed by a drain if it
/// landed); REQUESTING: transmit the built REQUEST exactly once, then
/// wait for the ACK; BOUND (N9): check the lease timer each invocation
/// — expiry -> release the address (INIT), T2 -> REBINDING (broadcast
/// REQUEST), T1 -> RENEWING (unicast REQUEST to the server), else print
/// the lease (the ACK's drain processing already set `arp.own_ip` — THE
/// one copy). The RX drain processes OFFER/ACK/NAK replies on port 68 (the
/// udp dispatch), so the handshake advances between invocations; each
/// command drains first (the claim-6076 polled-drain contract). Bounded
/// retry: `max_attempts` DISCOVERs without an OFFER -> an honest refuse
/// (the `timeout` counter). Deterministic, monitor-driven, no interrupts.
/// Issue #119 (audit follow-up 3): the autonomous DHCP lease lifecycle —
/// called from the shell idle loop each iteration (AFTER the RX drain,
/// so a pending renewal ACK has restarted the lease clock first):
/// advances T1/T2/expiry WITHOUT a human typing `net dhcp`, printing the
/// SAME transition lines `net dhcp` prints (identical text — the N9
/// gates' regexes/counters/captures are the evidence). Silent on the
/// no-ARP renew path (the client stays BOUND per RFC 2131 §4.4.5;
/// typing `net dhcp` surfaces the diagnostic) and on TX failures (the
/// next `net dhcp` retries — no per-second spam). The re-DISCOVER after
/// expiry stays command-triggered.
pub fn net_dhcp_autonomous(m: *Monitor) void {
    if (!virtio_net.net_ready) return;
    const p = virtio_net.net_dhcp_poll();
    switch (p.step) {
        .none, .renew_no_arp => {},
        .expired => {
            m.console.puts("net dhcp: lease expired (elapsed=");
            m.console.print_u64(p.elapsed);
            m.console.puts(" >= lease=");
            m.console.print_u64(p.lease);
            m.console.puts(") — address released, re-DISCOVER with `net dhcp`\n");
        },
        .rebinding => {
            if (!p.tx_ok) {
                err_prefix(m);
                m.console.print_line("REBINDING TX failed (transport unready)");
                return;
            }
            m.console.puts("net dhcp: rebinding (T2, elapsed=");
            m.console.print_u64(p.elapsed);
            m.console.puts(") request sent (");
            m.console.print_u64(@intCast(p.out_len));
            m.console.puts(" bytes)\n");
        },
        .renewing => {
            if (!p.tx_ok) {
                err_prefix(m);
                m.console.print_line("RENEWING TX failed (transport unready)");
                return;
            }
            m.console.puts("net dhcp: renewing (T1, elapsed=");
            m.console.print_u64(p.elapsed);
            m.console.puts(") request sent to the server (");
            m.console.print_u64(@intCast(p.out_len));
            m.console.puts(" bytes)\n");
        },
    }
}

fn cmd_net_dhcp(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len != 0) {
        print_usage(m, lookup("net").?);
        return .usage;
    }
    if (!virtio_net.net_ready) {
        err_prefix(m);
        m.console.puts("no virtio-net device (");
        m.console.puts(if (virtio_net.net_fail.len > 0) virtio_net.net_fail else "DID 0x1041 not found on bus 0");
        m.console.puts(")\n");
        return .none;
    }
    // Card N9 (claim 9489): stamp the lease clock BEFORE the drain — a
    // pending renewal ACK processed below restarts the lease from THIS
    // instant (the shell idle loop keeps it current between commands).
    virtio_net.dhcp.now_ticks = timer.ticks;
    // Deliver any pending OFFER/ACK before deciding (polled-drain
    // contract — the frame may have landed while the shell idled).
    virtio_net.net_rx_drain();
    switch (virtio_net.dhcp.state) {
        .idle => {
            if (virtio_net.dhcp.attempts >= virtio_net.dhcp.max_attempts) {
                virtio_net.dhcp.timed_out += 1;
                err_prefix(m);
                m.console.puts("refused (no OFFER after ");
                m.console.print_u64(@intCast(virtio_net.dhcp.max_attempts));
                m.console.puts(" DISCOVER attempts)\n");
                return .none;
            }
            // A fresh transaction id from the seeded CSPRNG (claim 2665).
            const xid: u32 = @truncate(csprng.random_u64());
            virtio_net.dhcp.start(&virtio_net.net_mac, xid);
            var out_len: usize = 0;
            switch (virtio_net.net_dhcp_send(virtio_net.dhcp.msg[0..virtio_net.dhcp.msg_len], &out_len)) {
                .ok => {
                    virtio_net.dhcp.discover_sent += 1;
                    virtio_net.dhcp.attempts += 1;
                    m.console.puts("net dhcp: discover sent xid=");
                    m.console.print_hex_min(xid);
                    m.console.puts(" (");
                    m.console.print_u64(@intCast(out_len));
                    m.console.puts(" bytes)\n");
                },
                else => {
                    virtio_net.dhcp.state = .idle; // the DISCOVER never went out
                    err_prefix(m);
                    m.console.print_line("DISCOVER TX failed (transport unready)");
                },
            }
            return .none;
        },
        .selecting => {
            m.console.puts("net dhcp: waiting for OFFER (xid=");
            m.console.print_hex_min(virtio_net.dhcp.xid);
            m.console.puts(")\n");
            return .none;
        },
        .requesting => {
            if (!virtio_net.dhcp.request_transmitted) {
                // The OFFER was accepted (the drain built the REQUEST into
                // dhcp.msg) — transmit it exactly once.
                var out_len: usize = 0;
                switch (virtio_net.net_dhcp_send(virtio_net.dhcp.msg[0..virtio_net.dhcp.msg_len], &out_len)) {
                    .ok => {
                        virtio_net.dhcp.request_transmitted = true;
                        virtio_net.dhcp.request_sent += 1;
                        m.console.puts("net dhcp: request sent xid=");
                        m.console.print_hex_min(virtio_net.dhcp.xid);
                        m.console.puts(" (");
                        m.console.print_u64(@intCast(out_len));
                        m.console.puts(" bytes)\n");
                    },
                    else => {
                        err_prefix(m);
                        m.console.print_line("REQUEST TX failed (transport unready)");
                    },
                }
            } else {
                m.console.puts("net dhcp: waiting for ACK (xid=");
                m.console.print_hex_min(virtio_net.dhcp.xid);
                m.console.puts(")\n");
            }
            return .none;
        },
        .renewing, .rebinding => {
            // Card N9 (claim 9489): the renewal REQUEST went out (or the
            // initial transmit failed — retry once). A pending renewal
            // never outlives its lease: if the ACK has not landed and the
            // lease expired meanwhile, release the address honestly.
            const lease = virtio_net.dhcp.lease_time;
            if (lease > 0 and virtio_net.dhcp.elapsed() >= lease) {
                virtio_net.dhcp.expire();
                m.console.puts("net dhcp: lease expired while waiting for the renewal ACK (elapsed=");
                m.console.print_u64(virtio_net.dhcp.elapsed());
                m.console.puts(" >= lease=");
                m.console.print_u64(lease);
                m.console.puts(") — address released\n");
                return .none;
            }
            if (!virtio_net.dhcp.request_transmitted) {
                var out_len: usize = 0;
                const r = if (virtio_net.dhcp.state == .renewing) blk: {
                    const srv_mac = virtio_net.arp.lookup(virtio_net.dhcp.lease_server) orelse {
                        err_prefix(m);
                        m.console.print_line("renewing needs the server MAC (net arp <server> first)");
                        break :blk .no_peer;
                    };
                    break :blk virtio_net.net_dhcp_send_unicast(virtio_net.dhcp.lease_server, srv_mac, virtio_net.dhcp.msg[0..virtio_net.dhcp.msg_len], &out_len);
                } else virtio_net.net_dhcp_send_bound(virtio_net.dhcp.msg[0..virtio_net.dhcp.msg_len], &out_len);
                if (r == .ok) {
                    virtio_net.dhcp.request_transmitted = true;
                    if (virtio_net.dhcp.state == .renewing) virtio_net.dhcp.renew_sent += 1 else virtio_net.dhcp.rebind_sent += 1;
                    m.console.puts("net dhcp: ");
                    m.console.puts(if (virtio_net.dhcp.state == .renewing) "renewing" else "rebinding");
                    m.console.puts(" request sent (");
                    m.console.print_u64(@intCast(out_len));
                    m.console.puts(" bytes)\n");
                } else {
                    m.console.puts("net dhcp: ");
                    m.console.puts(if (virtio_net.dhcp.state == .renewing) "RENEWING" else "REBINDING");
                    err_prefix(m);
                    m.console.print_line(" TX failed (transport unready)");
                }
            } else {
                m.console.puts("net dhcp: waiting for the renewal ACK (xid=");
                m.console.print_hex_min(virtio_net.dhcp.xid);
                m.console.puts(")\n");
            }
            return .none;
        },
        .bound => {
            // Card N9 (claim 9489): the lease lifecycle (RFC 2131
            // §4.4.5). Each invocation checks the elapsed lease time and
            // advances ONE step: expiry -> release the address (INIT);
            // T2 -> REBINDING (broadcast REQUEST); T1 -> RENEWING
            // (unicast REQUEST to the server — its MAC must be resolved;
            // the seam resolves nothing). The transition + transmit
            // happen in the SAME invocation (the polled-drain contract).
            const lease = virtio_net.dhcp.lease_time;
            const el = virtio_net.dhcp.elapsed();
            if (lease > 0 and el >= lease) {
                virtio_net.dhcp.expire();
                m.console.puts("net dhcp: lease expired (elapsed=");
                m.console.print_u64(el);
                m.console.puts(" >= lease=");
                m.console.print_u64(lease);
                m.console.puts(") — address released, re-DISCOVER with `net dhcp`\n");
                return .none;
            }
            if (lease > 0 and el >= virtio_net.dhcp.t2(lease)) {
                // REBINDING: the broadcast REQUEST (any server on the
                // link can answer — the lease is almost over).
                virtio_net.dhcp.enter_rebinding();
                var out_len: usize = 0;
                switch (virtio_net.net_dhcp_send_bound(virtio_net.dhcp.msg[0..virtio_net.dhcp.msg_len], &out_len)) {
                    .ok => {
                        virtio_net.dhcp.request_transmitted = true;
                        virtio_net.dhcp.rebind_sent += 1;
                        m.console.puts("net dhcp: rebinding (T2, elapsed=");
                        m.console.print_u64(el);
                        m.console.puts(") request sent (");
                        m.console.print_u64(@intCast(out_len));
                        m.console.puts(" bytes)\n");
                    },
                    else => {
                        err_prefix(m);
                        m.console.print_line("REBINDING TX failed (transport unready)");
                    },
                }
                return .none;
            }
            if (lease > 0 and el >= virtio_net.dhcp.t1(lease)) {
                // RENEWING: the unicast REQUEST to the server (RFC 2131
                // §4.4.5). The server MAC must be in the ARP table — the
                // guest resolves it with `net arp <server>` (the host's
                // --net-arp-respond answers); without it the client
                // honestly stays BOUND until T2 (RFC-compliant
                // degradation, never faked).
                const srv_mac = virtio_net.arp.lookup(virtio_net.dhcp.lease_server) orelse {
                    err_prefix(m);
                    m.console.puts("renewing needs the server MAC (net arp ");
                    var srvbuf: [15]u8 = undefined;
                    const sn = virtio_net.arp.format_ip(virtio_net.dhcp.lease_server, &srvbuf);
                    m.console.puts(srvbuf[0..sn]);
                    m.console.puts(" first) — the client stays BOUND until T2\n");
                    return .none;
                };
                virtio_net.dhcp.enter_renewing();
                var out_len: usize = 0;
                switch (virtio_net.net_dhcp_send_unicast(virtio_net.dhcp.lease_server, srv_mac, virtio_net.dhcp.msg[0..virtio_net.dhcp.msg_len], &out_len)) {
                    .ok => {
                        virtio_net.dhcp.request_transmitted = true;
                        virtio_net.dhcp.renew_sent += 1;
                        m.console.puts("net dhcp: renewing (T1, elapsed=");
                        m.console.print_u64(el);
                        m.console.puts(") request sent to the server (");
                        m.console.print_u64(@intCast(out_len));
                        m.console.puts(" bytes)\n");
                    },
                    else => {
                        err_prefix(m);
                        m.console.print_line("RENEWING TX failed (transport unready)");
                    },
                }
                return .none;
            }
            // The lease is still young — the existing bound print
            // (unchanged; the N8 gate asserts it byte-exact).
            m.console.puts("net: dhcp bound ip=");
            var ibuf: [15]u8 = undefined;
            const in = virtio_net.arp.format_ip(virtio_net.dhcp.lease_ip, &ibuf);
            m.console.puts(ibuf[0..in]);
            m.console.puts(" mask=");
            const mn = virtio_net.arp.format_ip(virtio_net.dhcp.lease_mask, &ibuf);
            m.console.puts(ibuf[0..mn]);
            m.console.puts(" gw=");
            const gn = virtio_net.arp.format_ip(virtio_net.dhcp.lease_gw, &ibuf);
            m.console.puts(ibuf[0..gn]);
            m.console.puts(" server=");
            const sn = virtio_net.arp.format_ip(virtio_net.dhcp.lease_server, &ibuf);
            m.console.puts(ibuf[0..sn]);
            m.console.puts(" lease=");
            m.console.print_u64(virtio_net.dhcp.lease_time);
            m.console.puts("\n");
            return .none;
        },
    }
}

/// `net tcp` — card N10 (claim 7026): drive the bounded RFC 793 CLIENT
/// ONE STEP per invocation. `connect <addr> <port>` starts the
/// three-way handshake (build + transmit the SYN — the peer's MAC must
/// be in the ARP table: `net arp <addr>` resolves it first; an own-IP
/// connect is REFUSED — the bounded client is outward-only, no TCP
/// loopback); the bare `net tcp` drives: SYN_SENT — the bounded connect
/// timeout (30 s of guest ticks, the card-N9 timer pattern) refuses
/// honestly (`timed_out`), ESTABLISHED — transmit the pending ACK the
/// drain built (the polled-drain contract) then print the established
/// state, FIN_SENT — wait for the FIN-ACK, CLOSED — transmit the final
/// ACK after the FIN-ACK (or return to IDLE after a reset); `send <len>`
/// transmits a data segment (the deterministic payload 01 02 03…, ack =
/// rcv_nxt); `recv` prints the bounded RX buffer (ONE segment); `close`
/// transmits the FIN (ESTABLISHED -> FIN_SENT); `reset` transmits a RST
/// (the client's abort). The RX drain processes the peer's segments on
/// our port 8000 (the ipv4 protocol-6 dispatch -> tcp), so the
/// connection advances between invocations; each command drains first
/// (the claim-6076 polled-drain contract). Deterministic,
/// monitor-driven, no interrupts.
fn cmd_net_tcp(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 0) return cmd_net_tcp_drive(m);
    if (std.mem.eql(u8, args[0], "connect")) return cmd_net_tcp_connect(m, args[1..]);
    if (std.mem.eql(u8, args[0], "send")) return cmd_net_tcp_send(m, args[1..]);
    if (std.mem.eql(u8, args[0], "recv")) return cmd_net_tcp_recv(m, args[1..]);
    if (std.mem.eql(u8, args[0], "close")) return cmd_net_tcp_close(m, args[1..]);
    if (std.mem.eql(u8, args[0], "reset")) return cmd_net_tcp_reset(m, args[1..]);
    print_usage(m, lookup("net").?);
    return .usage;
}

fn cmd_net_dns(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len < 1 or args.len > 2) {
        print_usage(m, lookup("net").?);
        return .usage;
    }
    const hostname = args[0];
    var server_ip: [4]u8 = .{ 10, 0, 0, 2 }; // default host gateway
    if (args.len == 2) {
        server_ip = virtio_net.arp.parse_ip(args[1]) orelse {
            err_prefix(m);
            m.console.puts("invalid server address: ");
            m.console.puts(args[1]);
            m.console.puts("\n");
            return .invalid_argument;
        };
    } else {
        if (virtio_net.dhcp.state == .bound and (virtio_net.dhcp.lease_server[0] != 0 or virtio_net.dhcp.lease_server[1] != 0 or virtio_net.dhcp.lease_server[2] != 0 or virtio_net.dhcp.lease_server[3] != 0)) {
            server_ip = virtio_net.dhcp.lease_server;
        }
    }

    if (!virtio_net.net_ready) {
        err_prefix(m);
        m.console.print_line("no virtio-net device");
        return .none;
    }
    if (!virtio_net.arp.ip_set()) {
        err_prefix(m);
        m.console.print_line("no IP set (net ip <a.b.c.d> first)");
        return .none;
    }

    if (dns.resolve(hostname, server_ip)) |ip| {
        m.console.puts("net dns: ");
        m.console.puts(hostname);
        m.console.puts(" -> ");
        var ipbuf: [15]u8 = undefined;
        const in = virtio_net.arp.format_ip(ip, &ipbuf);
        m.console.puts(ipbuf[0..in]);
        m.console.puts("\n");
    } else |err| {
        err_prefix(m);
        m.console.puts("net dns error: ");
        m.console.puts(@errorName(err));
        m.console.puts(" for '");
        m.console.puts(hostname);
        m.console.puts("'\n");
    }
    return .none;
}

/// M26 N8 (issue #435): `net status` prints a concise one-line summary:
/// IP, Gateway, DNS server, DHCP state, and link connectivity.
fn cmd_net_status(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    var ipbuf: [15]u8 = undefined;
    var gwbuf: [15]u8 = undefined;
    var dnsbuf: [15]u8 = undefined;

    const ip_s: []const u8 = if (virtio_net.arp.ip_set())
        ipbuf[0..virtio_net.arp.format_ip(virtio_net.arp.own_ip, &ipbuf)]
    else
        "0.0.0.0";

    const gw: [4]u8 = if (virtio_net.dhcp.state == .bound and (virtio_net.dhcp.lease_gw[0] != 0 or virtio_net.dhcp.lease_gw[1] != 0 or virtio_net.dhcp.lease_gw[2] != 0 or virtio_net.dhcp.lease_gw[3] != 0))
        virtio_net.dhcp.lease_gw
    else if (virtio_net.arp.ip_set())
        .{ 10, 0, 0, 2 }
    else
        .{ 0, 0, 0, 0 };
    const gw_s: []const u8 = gwbuf[0..virtio_net.arp.format_ip(gw, &gwbuf)];

    const dns_srv: [4]u8 = if (virtio_net.dhcp.state == .bound and (virtio_net.dhcp.lease_server[0] != 0 or virtio_net.dhcp.lease_server[1] != 0 or virtio_net.dhcp.lease_server[2] != 0 or virtio_net.dhcp.lease_server[3] != 0))
        virtio_net.dhcp.lease_server
    else if (virtio_net.arp.ip_set())
        .{ 10, 0, 0, 2 }
    else
        .{ 0, 0, 0, 0 };
    const dns_s: []const u8 = dnsbuf[0..virtio_net.arp.format_ip(dns_srv, &dnsbuf)];

    const dhcp_str = switch (virtio_net.dhcp.state) {
        .idle => "idle",
        .selecting => "selecting",
        .requesting => "requesting",
        .bound => "bound",
        .renewing => "renewing",
        .rebinding => "rebinding",
    };

    const link_status = if (!virtio_net.net_ready)
        "disconnected"
    else if (virtio_net.arp.ip_set())
        "connected"
    else
        "idle";

    m.console.puts("net status: IP: ");
    m.console.puts(ip_s);
    m.console.puts(" Gateway: ");
    m.console.puts(gw_s);
    m.console.puts(" DNS: ");
    m.console.puts(dns_s);
    m.console.puts(" DHCP: ");
    m.console.puts(dhcp_str);
    m.console.puts(" (");
    m.console.puts(link_status);
    m.console.puts(")\n");
    return .none;
}

/// M26 N16 (issue #443): `net route` displays the active IPv4 routing table.
fn cmd_net_route(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    var gwbuf: [15]u8 = undefined;
    const gw: [4]u8 = if (virtio_net.dhcp.state == .bound and (virtio_net.dhcp.lease_gw[0] != 0 or virtio_net.dhcp.lease_gw[1] != 0 or virtio_net.dhcp.lease_gw[2] != 0 or virtio_net.dhcp.lease_gw[3] != 0))
        virtio_net.dhcp.lease_gw
    else if (virtio_net.arp.ip_set())
        .{ 10, 0, 0, 2 }
    else
        .{ 0, 0, 0, 0 };
    const gw_s: []const u8 = gwbuf[0..virtio_net.arp.format_ip(gw, &gwbuf)];

    m.console.puts("net route: table\n");
    m.console.puts("Destination     Gateway         Interface       Metric\n");
    m.console.puts("0.0.0.0/0       ");
    m.console.puts(gw_s);
    var pad: usize = gw_s.len;
    while (pad < 16) : (pad += 1) m.console.putc(' ');
    m.console.puts("eth0            1\n");
    return .none;
}

/// M26 N15 (issue #442): `net log` displays the in-memory ring buffer of network events.
fn cmd_net_log(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    const count = virtio_net.net_log.get_count();
    m.console.puts("net log: entries=");
    m.console.print_u64(@intCast(count));
    m.console.puts("\n");

    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (virtio_net.net_log.get_entry(i)) |entry| {
            m.console.puts("  [");
            m.console.print_u64(@intCast(i));
            m.console.puts("] ");
            m.console.puts(entry.getText());
            m.console.puts("\n");
        }
    }
    return .none;
}

/// Print the TCP connection's peer as `a.b.c.d:port`.
fn print_tcp_peer(m: *Monitor) void {
    var tibuf: [15]u8 = undefined;
    const tin = virtio_net.arp.format_ip(virtio_net.tcp.peer_ip, &tibuf);
    m.console.puts(tibuf[0..tin]);
    m.console.puts(":");
    m.console.print_u64(virtio_net.tcp.peer_port);
}

/// The bare `net tcp` drive (one step per invocation — see cmd_net_tcp).
fn cmd_net_tcp_drive(m: *Monitor) ExecError {
    if (!virtio_net.net_ready) {
        m.console.print_line("net tcp: no virtio-net device");
        return .none;
    }
    // Card N10: stamp the connect clock BEFORE the drain — a pending
    // SYN-ACK processed below starts the connection from THIS instant
    // (the shell idle loop keeps it current between commands).
    virtio_net.tcp.now_ticks = timer.ticks;
    // Deliver any pending segment before deciding (polled-drain
    // contract — the frame may have landed while the shell idled).
    virtio_net.net_rx_drain();
    switch (virtio_net.tcp.state) {
        .idle => {
            m.console.print_line("net tcp: no connection (net tcp connect <addr> <port>)");
            return .none;
        },
        .listen => {
            m.console.puts("net tcp: listening on port ");
            m.console.print_u64(virtio_net.tcp.listen_port);
            m.console.puts("\n");
            return .none;
        },
        .syn_received => {
            if (virtio_net.tcp.ack_pending) {
                var out_len: usize = 0;
                if (virtio_net.net_tcp_send(virtio_net.tcp.msg[0..virtio_net.tcp.msg_len], &out_len) == .ok) {
                    virtio_net.tcp.ack_pending = false;
                    virtio_net.tcp.ack_sent += 1;
                }
            }
            m.console.puts("net tcp: syn_received (peer=");
            print_tcp_peer(m);
            m.console.puts(")\n");
            return .none;
        },
        .syn_sent => {
            if (virtio_net.tcp.connect_timed_out()) {
                virtio_net.tcp.abort_timeout();
                err_prefix(m);
                m.console.puts("connect refused (no SYN-ACK after ");
                m.console.print_u64(@intCast(virtio_net.tcp.connect_timeout));
                m.console.puts("s) — run 'net tcp connect <addr> <port>' to retry\n");
                return .none;
            }
            m.console.puts("net tcp: waiting for SYN-ACK (peer=");
            print_tcp_peer(m);
            m.console.puts(")\n");
            return .none;
        },
        .established => {
            if (virtio_net.tcp.ack_pending) {
                // The drain built an ACK (the handshake, a data echo, or
                // a server FIN) — transmit it exactly once.
                var out_len: usize = 0;
                switch (virtio_net.net_tcp_send(virtio_net.tcp.msg[0..virtio_net.tcp.msg_len], &out_len)) {
                    .ok => {
                        virtio_net.tcp.ack_pending = false;
                        virtio_net.tcp.ack_sent += 1;
                        m.console.puts("net tcp: ack sent (ack=");
                        m.console.print_hex_min(virtio_net.tcp.rcv_nxt);
                        m.console.puts(", ");
                        m.console.print_u64(@intCast(out_len));
                        m.console.puts(" bytes)\n");
                    },
                    else => {
                        err_prefix(m);
                        m.console.print_line("ACK TX failed (transport unready)");
                    },
                }
            }
            m.console.puts("net tcp: established (peer=");
            print_tcp_peer(m);
            m.console.puts(")\n");
            return .none;
        },
        .fin_sent => {
            // The FIN-ACK, when it lands, is processed by the drain into
            // CLOSED with the final ACK built — the CLOSED branch sends
            // it. While still FIN_SENT, just wait.
            m.console.puts("net tcp: waiting for the FIN-ACK (peer=");
            print_tcp_peer(m);
            m.console.puts(")\n");
            return .none;
        },
        .closed => {
            if (virtio_net.tcp.ack_pending) {
                // The drain processed the FIN-ACK — transmit the final
                // ACK (the close completes).
                var out_len: usize = 0;
                switch (virtio_net.net_tcp_send(virtio_net.tcp.msg[0..virtio_net.tcp.msg_len], &out_len)) {
                    .ok => {
                        virtio_net.tcp.ack_pending = false;
                        virtio_net.tcp.ack_sent += 1;
                        m.console.puts("net tcp: final ack sent (ack=");
                        m.console.print_hex_min(virtio_net.tcp.rcv_nxt);
                        m.console.puts(", ");
                        m.console.print_u64(@intCast(out_len));
                        m.console.puts(" bytes)\n");
                    },
                    else => {
                        err_prefix(m);
                        m.console.print_line("final ACK TX failed (transport unready)");
                    },
                }
                virtio_net.tcp.state = .idle; // the close completed — a fresh connect is possible
                m.console.print_line("net tcp: connection closed");
                return .none;
            }
            // A clean close or a reset already handled — back to IDLE.
            m.console.print_line("net tcp: connection closed — idle again");
            virtio_net.tcp.state = .idle;
            return .none;
        },
    }
}

/// `net tcp connect <addr> <port>` — start the three-way handshake.
fn cmd_net_tcp_connect(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len != 2) {
        print_usage(m, lookup("net").?);
        return .usage;
    }
    const ip = virtio_net.arp.parse_ip(args[0]) orelse {
        err_prefix(m);
        m.console.puts("invalid address: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    const port = parse_port(args[1]) orelse {
        err_prefix(m);
        m.console.puts("invalid port: ");
        m.console.puts(args[1]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    if (!virtio_net.net_ready) {
        err_prefix(m);
        m.console.print_line("no virtio-net device");
        return .none;
    }
    if (virtio_net.tcp.state != .idle) {
        err_prefix(m);
        m.console.print_line("a connection is already in progress (net tcp reset to abort)");
        return .none;
    }
    if (!virtio_net.arp.ip_set()) {
        err_prefix(m);
        m.console.print_line("no IP set (net ip <a.b.c.d> first)");
        return .none;
    }
    if (std.mem.eql(u8, &ip, &virtio_net.arp.own_ip)) {
        err_prefix(m);
        m.console.print_line("own-IP connect refused (no TCP loopback — the bounded client is outward-only)");
        return .none;
    }
    // Drain first (the claim-6076 contract — the ARP reply for `net arp
    // <ip>` may have landed while the shell idled; the peer's MAC must
    // be in the table: the seam resolves nothing).
    virtio_net.net_rx_drain();
    const peer_mac = virtio_net.arp.lookup(ip) orelse {
        err_prefix(m);
        m.console.puts("peer not in ARP table (net arp ");
        var ipbuf: [15]u8 = undefined;
        const in = virtio_net.arp.format_ip(ip, &ipbuf);
        m.console.puts(ipbuf[0..in]);
        m.console.puts(" first)\n");
        return .none;
    };
    // A fresh ISN from the seeded CSPRNG (claim 2665) — real TCP
    // randomizes ISNs; the fixtures assert the seq/ack chain, not values.
    const isn: u32 = @truncate(csprng.random_u64());
    virtio_net.tcp.start(ip, port, isn, peer_mac);
    var out_len: usize = 0;
    switch (virtio_net.net_tcp_send(virtio_net.tcp.msg[0..virtio_net.tcp.msg_len], &out_len)) {
        .ok => {
            virtio_net.tcp.syn_sent += 1;
            virtio_net.tcp.advance_snd(1); // the SYN consumes one sequence number
            virtio_net.tcp.record_pending(); // card N11: the unacked SYN is retransmittable
            m.console.puts("net tcp: syn sent (peer=");
            print_tcp_peer(m);
            m.console.puts(", seq=");
            m.console.print_hex_min(isn);
            m.console.puts(", ");
            m.console.print_u64(@intCast(out_len));
            m.console.puts(" bytes)\n");
        },
        else => {
            virtio_net.tcp.state = .idle; // the SYN never went out
            err_prefix(m);
            m.console.print_line("SYN TX failed (transport unready)");
        },
    }
    return .none;
}

/// `net tcp send <len>` — transmit a data segment (1..payload_max bytes
/// of the deterministic pattern 01 02 03…, ack = rcv_nxt).
fn cmd_net_tcp_send(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len != 1) {
        print_usage(m, lookup("net").?);
        return .usage;
    }
    const len = parseInt(args[0]) catch {
        err_prefix(m);
        m.console.puts("invalid length: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    if (len < 1 or len > virtio_net.tcp.payload_max) {
        err_prefix(m);
        m.console.puts("length must be between 1 and ");
        m.console.print_u64(virtio_net.tcp.payload_max);
        m.console.puts("\n");
        return .invalid_argument;
    }
    if (virtio_net.tcp.state != .established) {
        err_prefix(m);
        m.console.print_line("not established (net tcp connect <addr> <port> first)");
        return .none;
    }
    // The deterministic payload — bytes 01 02 03 04… (byte i + 1,
    // bounded ≤ 64) — the live gate's byte-exact fixtures pin it.
    var payload: [virtio_net.tcp.payload_max]u8 = undefined;
    var pi: usize = 0;
    while (pi < len) : (pi += 1) payload[pi] = @as(u8, @truncate(pi)) +% 1;
    const seq = virtio_net.tcp.snd_una;
    virtio_net.tcp.build_data_msg(payload[0..@intCast(len)]);
    var out_len: usize = 0;
    switch (virtio_net.net_tcp_send(virtio_net.tcp.msg[0..virtio_net.tcp.msg_len], &out_len)) {
        .ok => {
            virtio_net.tcp.data_sent += 1;
            virtio_net.tcp.advance_snd(@intCast(len));
            virtio_net.tcp.record_pending(); // card N11: the unacked data is retransmittable
            m.console.puts("net tcp: data sent (seq=");
            m.console.print_hex_min(seq);
            m.console.puts(", ");
            m.console.print_u64(@intCast(len));
            m.console.puts(" bytes)\n");
        },
        else => {
            err_prefix(m);
            m.console.print_line("DATA TX failed (transport unready)");
        },
    }
    return .none;
}

/// `net tcp recv` — print the bounded RX buffer (ONE segment — the
/// honest bound, no reassembly) byte-exact (hex, the net udp recv
/// style) and consume it.
fn cmd_net_tcp_recv(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len != 0) {
        print_usage(m, lookup("net").?);
        return .usage;
    }
    if (virtio_net.tcp.state != .established) {
        err_prefix(m);
        m.console.print_line("not established (net tcp connect <addr> <port> first)");
        return .none;
    }
    // A segment may have landed while the shell idled — drain first.
    virtio_net.net_rx_drain();
    if (!virtio_net.tcp.rx_pending) {
        m.console.print_line("net tcp recv: no data");
        return .none;
    }
    const p = virtio_net.tcp.take_rx();
    m.console.puts("net tcp recv: ");
    var bi: usize = 0;
    while (bi < p.len) : (bi += 1) {
        if (bi > 0) m.console.puts(" ");
        const b = p[bi];
        const hex = "0123456789abcdef";
        var two: [2]u8 = .{ hex[b >> 4], hex[b & 0xf] };
        m.console.puts(&two);
    }
    m.console.puts("\n");
    return .none;
}

/// `net tcp close` — the client-driven close: transmit the FIN
/// (ESTABLISHED -> FIN_SENT; the FIN-ACK is processed by the drain, the
/// final ACK by the next `net tcp`).
fn cmd_net_tcp_close(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len != 0) {
        print_usage(m, lookup("net").?);
        return .usage;
    }
    if (virtio_net.tcp.state != .established) {
        err_prefix(m);
        m.console.print_line("not established (net tcp connect <addr> <port> first)");
        return .none;
    }
    const seq = virtio_net.tcp.snd_una;
    virtio_net.tcp.build_fin_msg();
    var out_len: usize = 0;
    switch (virtio_net.net_tcp_send(virtio_net.tcp.msg[0..virtio_net.tcp.msg_len], &out_len)) {
        .ok => {
            virtio_net.tcp.fin_sent += 1;
            virtio_net.tcp.advance_snd(1); // the FIN consumes one sequence number
            virtio_net.tcp.record_pending(); // card N11: the unacked FIN is retransmittable
            virtio_net.tcp.state = .fin_sent;
            m.console.puts("net tcp: fin sent (seq=");
            m.console.print_hex_min(seq);
            m.console.puts(", ");
            m.console.print_u64(@intCast(out_len));
            m.console.puts(" bytes)\n");
        },
        else => {
            err_prefix(m);
            m.console.print_line("FIN TX failed (transport unready)");
        },
    }
    return .none;
}

/// `net tcp reset` — the client's abort: transmit a RST (the connection
/// dies; the next `net tcp` returns to IDLE).
fn cmd_net_tcp_reset(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len != 0) {
        print_usage(m, lookup("net").?);
        return .usage;
    }
    if (virtio_net.tcp.state == .idle) {
        err_prefix(m);
        m.console.print_line("no connection to reset");
        return .none;
    }
    const seq = virtio_net.tcp.snd_una;
    virtio_net.tcp.build_rst_msg();
    var out_len: usize = 0;
    switch (virtio_net.net_tcp_send(virtio_net.tcp.msg[0..virtio_net.tcp.msg_len], &out_len)) {
        .ok => {
            virtio_net.tcp.rst_sent += 1;
            virtio_net.tcp.clear_pending(); // card N11: the connection died — the timer stops
            virtio_net.tcp.state = .closed; // the connection died
            m.console.puts("net tcp: reset sent (seq=");
            m.console.print_hex_min(seq);
            m.console.puts(", ");
            m.console.print_u64(@intCast(out_len));
            m.console.puts(" bytes)\n");
        },
        else => {
            err_prefix(m);
            m.console.print_line("RST TX failed (transport unready)");
        },
    }
    return .none;
}

/// `net recv` — the card-N2 receive path: drain the RX used ring (polled
/// — the frame may have landed while the shell idled), then print every
/// frame currently in the bounded FIFO byte-exact (hex, the
/// netsend-style report) and consume it. The frames are the RAW
/// device-written buffer bytes (the 12-byte virtio_net_hdr headroom
/// included — the claim-time header question is pinned by `rx-obs`, not
/// stripped blindly). Honest when empty: a filtered frame shows as `net
/// recv: no frames` + the `net` report's filtered= counter.
fn cmd_net_recv(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    if (!virtio_net.net_ready) {
        m.console.puts("net recv: no virtio-net device (");
        m.console.puts(if (virtio_net.net_fail.len > 0) virtio_net.net_fail else "DID 0x1041 not found on bus 0");
        m.console.puts(")\n");
        return .none;
    }
    virtio_net.net_rx_drain();
    const count = virtio_net.fifo_occupancy();
    m.console.puts("net recv: frames=");
    m.console.print_u64(@intCast(count));
    m.console.puts("\n");
    if (count == 0) {
        m.console.puts("net recv: no frames (filtered or nothing injected)\n");
        return .none;
    }
    var idx: usize = 0;
    while (virtio_net.fifo_peek()) |frame| {
        m.console.puts("net recv: [");
        m.console.print_u64(@intCast(idx));
        m.console.puts("] len=");
        m.console.print_u64(@intCast(frame.len));
        m.console.puts("\n");
        m.console.puts("net recv: ");
        var bi: usize = 0;
        while (bi < frame.len) : (bi += 1) {
            if (bi > 0) m.console.puts(" ");
            const b = frame[bi];
            const hex = "0123456789abcdef";
            var two: [2]u8 = .{ hex[b >> 4], hex[b & 0xf] };
            m.console.puts(&two);
        }
        m.console.puts("\n");
        virtio_net.fifo_pop_advance();
        idx += 1;
    }
    return .none;
}

/// `net ip <a.b.c.d>` — card N3 (claim 7293): set our static IPv4
/// address (fixed BSS, no heap — DHCP is a later card). The echo line
/// `net ip: ip=<a.b.c.d>` is the live gate's injection trigger (the
/// runner's `--net-inject-after` marker — deterministic, not a sleep).
fn cmd_net_ip(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len != 1) {
        print_usage(m, lookup("net").?);
        return .usage;
    }
    const ip = virtio_net.arp.parse_ip(args[0]) orelse {
        err_prefix(m);
        m.console.puts("invalid address: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    virtio_net.arp.own_ip = ip;
    virtio_net.net_log.log_fmt("IP: assigned {d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] });
    m.console.puts("net ip: ip=");
    var ipbuf: [15]u8 = undefined;
    const n = virtio_net.arp.format_ip(ip, &ipbuf);
    m.console.puts(ipbuf[0..n]);
    m.console.puts("\n");
    return .none;
}

/// `net arp [<a.b.c.d>]` — card N3 (claim 7293). With no argument:
/// drain the RX ring (idempotent — a reply may have landed while the
/// shell idled) and print the bounded table + the counters. With an
/// argument: resolve — a table hit prints the peer, a miss transmits an
/// ARP request (the reply is learned asynchronously by the RX drain) and
/// reports it; refused honestly when no static IP is set or the
/// transport is unready.
fn cmd_net_arp(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 0) {
        if (!virtio_net.net_ready) {
            m.console.print_line("net arp: no virtio-net device");
            return .none;
        }
        virtio_net.net_rx_drain();
        var count: usize = 0;
        for (&virtio_net.arp.table) |*e| {
            if (!e.valid) continue;
            count += 1;
        }
        m.console.puts("net arp: entries=");
        m.console.print_u64(@intCast(count));
        m.console.puts("\n");
        var ipbuf: [15]u8 = undefined;
        var macbuf: [17]u8 = undefined;
        for (&virtio_net.arp.table) |*e| {
            if (!e.valid) continue;
            const in = virtio_net.arp.format_ip(e.ip, &ipbuf);
            m.console.puts("net arp: ");
            m.console.puts(ipbuf[0..in]);
            m.console.puts(" -> ");
            virtio_net.format_mac(&e.mac, &macbuf);
            m.console.puts(&macbuf);
            m.console.puts("\n");
        }
        m.console.puts("net arp: req=");
        m.console.print_u64(virtio_net.arp.requests_sent);
        m.console.puts(",repl=");
        m.console.print_u64(virtio_net.arp.replies_sent);
        m.console.puts(",learn=");
        m.console.print_u64(virtio_net.arp.replies_learned);
        m.console.puts(",drop=");
        m.console.print_u64(virtio_net.arp.dropped);
        m.console.puts(",fail=");
        m.console.print_u64(virtio_net.arp.reply_tx_fail);
        m.console.puts("\n");
        return .none;
    }
    if (args.len != 1) {
        print_usage(m, lookup("net").?);
        return .usage;
    }
    const ip = virtio_net.arp.parse_ip(args[0]) orelse {
        err_prefix(m);
        m.console.puts("invalid address: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    if (!virtio_net.net_ready) {
        err_prefix(m);
        m.console.print_line("no virtio-net device");
        return .none;
    }
    virtio_net.net_rx_drain();
    if (virtio_net.arp.lookup(ip)) |mac| {
        m.console.puts("net arp: ");
        var ipbuf: [15]u8 = undefined;
        const in = virtio_net.arp.format_ip(ip, &ipbuf);
        m.console.puts(ipbuf[0..in]);
        m.console.puts(" is at ");
        var macbuf: [17]u8 = undefined;
        virtio_net.format_mac(&mac, &macbuf);
        m.console.puts(&macbuf);
        m.console.puts("\n");
        return .none;
    }
    var frame_len: usize = 0;
    switch (virtio_net.net_arp_request(ip, &frame_len)) {
        .ok => {
            virtio_net.arp.requests_sent += 1;
            virtio_net.net_log.log_fmt("ARP: request {d}.{d}.{d}.{d}", .{ ip[0], ip[1], ip[2], ip[3] });
            m.console.puts("net arp: request for ");
            var ipbuf: [15]u8 = undefined;
            const in = virtio_net.arp.format_ip(ip, &ipbuf);
            m.console.puts(ipbuf[0..in]);
            m.console.puts(" sent (");
            m.console.print_u64(@intCast(frame_len));
            m.console.puts(" bytes)\n");
        },
        .not_ready => {
            err_prefix(m);
            m.console.print_line("no IP set (net ip <a.b.c.d> first) or transport unready");
        },
        .timeout => {
            err_prefix(m);
            m.console.print_line("request TX timeout (device did not complete within the poll budget)");
        },
        .no_peer => unreachable,
    }
    return .none;
}

/// `net ping <a.b.c.d>` — card N4 (claim 0148): transmit an ICMP echo
/// request to a peer already in the ARP table (the table is drained
/// first — a reply may have landed while the shell idled). The peer's
/// MAC must be known (`net arp <ip>` resolves it first — an echo needs a
/// unicast dst; refused honestly otherwise). The reply is observed
/// asynchronously by the RX drain (`pongs_observed` + the `net` report's
/// `seq=`).
fn cmd_net_ping(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len != 1) {
        print_usage(m, lookup("net").?);
        return .usage;
    }
    const ip = virtio_net.arp.parse_ip(args[0]) orelse {
        err_prefix(m);
        m.console.puts("invalid address: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    if (!virtio_net.net_ready) {
        err_prefix(m);
        m.console.print_line("no virtio-net device");
        return .none;
    }
    virtio_net.net_rx_drain();
    var frame_len: usize = 0;
    switch (virtio_net.net_ping_request(ip, &frame_len)) {
        .ok => {
            virtio_net.ipv4.requests_sent += 1;
            virtio_net.ipv4.ping_seq +%= 1;
            m.console.puts("net ping: echo request to ");
            var ipbuf: [15]u8 = undefined;
            const in = virtio_net.arp.format_ip(ip, &ipbuf);
            m.console.puts(ipbuf[0..in]);
            m.console.puts(" sent (");
            m.console.print_u64(@intCast(frame_len));
            m.console.puts(" bytes)\n");
        },
        .not_ready => {
            err_prefix(m);
            m.console.print_line("no IP set (net ip <a.b.c.d> first) or transport unready");
        },
        .timeout => {
            err_prefix(m);
            m.console.print_line("echo request TX timeout (device did not complete within the poll budget)");
        },
        .no_peer => {
            err_prefix(m);
            m.console.print_line("peer not in ARP table (net arp <a.b.c.d> first)");
        },
    }
    return .none;
}

/// `net udp [...]` — card N5 (claim 8552). No argument: the bounded
/// listen table + the counters. `listen <port>` / `close <port>`: add /
/// remove a listener (a full or duplicate table is refused honestly).
/// `send <ip> <port> <len>`: transmit ONE UDP datagram to the peer (peer
/// MAC from the ARP table; `.no_peer` refused — `net arp <ip>` resolves
/// first) from the fixed source port 7000, the byte-index payload (≤ 64,
/// honest truncation); a send to OUR OWN IP takes the LOOPBACK path (no
/// device round trip). `recv [<port>]`: drain the RX ring (a datagram
/// may have landed while the shell idled) and print + consume the
/// datagram(s) in the listener's bounded buffer byte-exact (hex, the
/// net-recv style).
fn cmd_net_udp(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 0) {
        var count: usize = 0;
        for (&virtio_net.udp.listen) |e| {
            if (e.valid) count += 1;
        }
        m.console.puts("net udp: entries=");
        m.console.print_u64(@intCast(count));
        m.console.puts("\n");
        for (&virtio_net.udp.listen) |e| {
            if (!e.valid) continue;
            m.console.puts("net udp: port=");
            m.console.print_u64(e.port);
            m.console.puts("\n");
        }
        m.console.puts("net udp: rx=");
        m.console.print_u64(virtio_net.udp.received);
        m.console.puts(",tx=");
        m.console.print_u64(virtio_net.udp.sent);
        m.console.puts(",loop=");
        m.console.print_u64(virtio_net.udp.loopbacked);
        m.console.puts(",drop=");
        m.console.print_u64(virtio_net.udp.dropped_badsum + virtio_net.udp.dropped_closed + virtio_net.udp.dropped_len);
        m.console.puts("\n");
        return .none;
    }
    if (std.mem.eql(u8, args[0], "listen")) {
        if (args.len != 2) {
            print_usage(m, lookup("net").?);
            return .usage;
        }
        const port = parse_port(args[1]) orelse {
            err_prefix(m);
            m.console.puts("invalid port: ");
            m.console.puts(args[1]);
            m.console.puts("\n");
            return .invalid_argument;
        };
        if (!virtio_net.udp.listen_port(port)) {
            err_prefix(m);
            m.console.print_line("listen failed (table full or duplicate)");
            return .none;
        }
        m.console.puts("net udp: listening on ");
        m.console.print_u64(port);
        m.console.puts("\n");
        return .none;
    }
    if (std.mem.eql(u8, args[0], "close")) {
        if (args.len != 2) {
            print_usage(m, lookup("net").?);
            return .usage;
        }
        const port = parse_port(args[1]) orelse {
            err_prefix(m);
            m.console.puts("invalid port: ");
            m.console.puts(args[1]);
            m.console.puts("\n");
            return .invalid_argument;
        };
        if (!virtio_net.udp.close_port(port)) {
            err_prefix(m);
            m.console.puts("not listening on ");
            m.console.print_u64(port);
            m.console.puts("\n");
            return .none;
        }
        m.console.puts("net udp: closed ");
        m.console.print_u64(port);
        m.console.puts("\n");
        return .none;
    }
    if (std.mem.eql(u8, args[0], "send")) {
        if (args.len != 4) {
            print_usage(m, lookup("net").?);
            return .usage;
        }
        const ip = virtio_net.arp.parse_ip(args[1]) orelse {
            err_prefix(m);
            m.console.puts("invalid address: ");
            m.console.puts(args[1]);
            m.console.puts("\n");
            return .invalid_argument;
        };
        const port = parse_port(args[2]) orelse {
            err_prefix(m);
            m.console.puts("invalid port: ");
            m.console.puts(args[2]);
            m.console.puts("\n");
            return .invalid_argument;
        };
        const len = parseInt(args[3]) catch {
            err_prefix(m);
            m.console.puts("invalid length: ");
            m.console.puts(args[3]);
            m.console.puts("\n");
            return .invalid_argument;
        };
        if (len < 1 or len > virtio_net.udp.payload_max) {
            err_prefix(m);
            m.console.puts("length must be between 1 and ");
            m.console.print_u64(virtio_net.udp.payload_max);
            m.console.puts("\n");
            return .invalid_argument;
        }
        // The deterministic payload — bytes 01 02 03 04… (byte i + 1,
        // bounded ≤ 64) — the live gate's byte-exact fixtures pin it.
        var payload: [virtio_net.udp.payload_max]u8 = undefined;
        var pi: usize = 0;
        while (pi < len) : (pi += 1) payload[pi] = @as(u8, @truncate(pi)) +% 1;
        var frame_len: usize = 0;
        switch (virtio_net.net_udp_send(ip, port, payload[0..@intCast(len)], &frame_len)) {
            .ok => {
                m.console.puts("net udp: sent ");
                m.console.print_u64(len);
                m.console.puts(" bytes to ");
                var ipbuf: [15]u8 = undefined;
                const in = virtio_net.arp.format_ip(ip, &ipbuf);
                m.console.puts(ipbuf[0..in]);
                m.console.puts(":");
                m.console.print_u64(port);
                m.console.puts(" (");
                m.console.print_u64(@intCast(frame_len));
                m.console.puts(" bytes)\n");
            },
            .not_ready => {
                err_prefix(m);
                m.console.print_line("no IP set (net ip <a.b.c.d> first) or transport unready");
            },
            .timeout => {
                err_prefix(m);
                m.console.print_line("datagram TX timeout (device did not complete within the poll budget)");
            },
            .no_peer => {
                err_prefix(m);
                m.console.print_line("peer not in ARP table (net arp <a.b.c.d> first)");
            },
        }
        return .none;
    }
    if (std.mem.eql(u8, args[0], "recv")) {
        if (args.len > 2) {
            print_usage(m, lookup("net").?);
            return .usage;
        }
        // A datagram may have landed while the shell idled — drain first.
        virtio_net.net_rx_drain();
        if (args.len == 2) {
            const port = parse_port(args[1]) orelse {
                m.console.puts("net udp: invalid port: ");
                m.console.puts(args[1]);
                m.console.puts("\n");
                return .invalid_argument;
            };
            _ = cmd_net_udp_recv_port(m, port);
            return .none;
        }
        var total: usize = 0;
        for (&virtio_net.udp.listen) |e| {
            if (!e.valid) continue;
            total += cmd_net_udp_recv_port(m, e.port);
        }
        m.console.puts("net udp recv: total=");
        m.console.print_u64(@intCast(total));
        m.console.puts("\n");
        return .none;
    }
    print_usage(m, lookup("net").?);
    return .usage;
}

/// Drain + print the datagrams buffered for ONE listener, byte-exact
/// (hex, the net-recv style). Returns how many were printed.
fn cmd_net_udp_recv_port(m: *Monitor, port: u16) usize {
    var count: usize = 0;
    while (virtio_net.udp.pop(port)) |d| {
        if (count == 0) {
            m.console.puts("net udp recv: port=");
            m.console.print_u64(port);
            m.console.puts("\n");
        }
        m.console.puts("net udp recv: [");
        m.console.print_u64(@intCast(count));
        m.console.puts("] len=");
        m.console.print_u64(@intCast(d.len));
        m.console.puts("\n");
        m.console.puts("net udp recv: ");
        var bi: usize = 0;
        while (bi < d.len) : (bi += 1) {
            if (bi > 0) m.console.puts(" ");
            const b = d.bytes[bi];
            const hex = "0123456789abcdef";
            var two: [2]u8 = .{ hex[b >> 4], hex[b & 0xf] };
            m.console.puts(&two);
        }
        m.console.puts("\n");
        count += 1;
    }
    if (count == 0) {
        m.console.puts("net udp recv: no datagrams for port ");
        m.console.print_u64(port);
        m.console.puts("\n");
    }
    return count;
}

/// Parse a decimal (or 0x-prefixed hex) port in 0..65535, the `net udp`
/// subcommands' bound.
fn parse_port(text: []const u8) ?u16 {
    const v = parseInt(text) catch return null;
    if (v > 0xffff) return null;
    return @intCast(v);
}

/// `netsend <bytes>` — build the N1 known frame in the fixed staging
/// buffer (broadcast dst, own MAC src, ethertype 0x0800, a deterministic
/// byte-index payload), submit it on the TX queue, drain the used ring
/// (polled), and report exact byte counts. Over-limit requests truncate
/// honestly at the 1500-byte payload bound (the reply names the drop);
/// an absent/unarmed transport is refused honestly. This is the live
/// gate's byte-exact TX proof: the host's file-handle attachment captures
/// exactly the frame bytes reported here.
fn cmd_netsend(m: *Monitor, args: []const []const u8) ExecError {
    const requested = parseInt(args[0]) catch {
        err_prefix(m);
        m.console.puts("invalid byte count: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    if (!virtio_net.net_ready) {
        err_prefix(m);
        m.console.print_line("transport not ready (no virtio-net device)");
        return .none;
    }
    m.console.puts("netsend: n=");
    m.console.print_u64(requested);
    if (requested > virtio_net.payload_max) {
        m.console.puts(" truncated to ");
        m.console.print_u64(virtio_net.payload_max);
        m.console.puts(" (payload bound)");
    }
    m.console.puts("\n");
    var frame_len: usize = 0;
    switch (virtio_net.net_send_frame(requested, &frame_len)) {
        .ok => {
            m.console.puts("netsend: tx ok frames=");
            m.console.print_u64(virtio_net.net_dev.tx_frames);
            m.console.puts(" bytes=");
            m.console.print_u64(@intCast(frame_len));
            m.console.puts("\n");
            m.console.puts("netsend: sent ");
            m.console.print_u64(@intCast(frame_len));
            m.console.puts(" bytes\n");
        },
        .not_ready => {
            err_prefix(m);
            m.console.print_line("transport not ready (no virtio-net device)");
        },
        .timeout => {
            err_prefix(m);
            m.console.print_line("tx timeout (device did not complete within the poll budget)");
        },
        .no_peer => unreachable,
    }
    return .none;
}

// ---------------------------------------------------------------------------
// Milestone six card G1 (claim 6053) — `screen` / `screen fill`
// ---------------------------------------------------------------------------

fn print_cmd_result(m: *Monitor, r: virtio_gpu.CmdResult) void {
    m.console.puts(switch (r) {
        .ok => "ok",
        .not_ready => "not-ready",
        .timeout => "timeout",
        .bad_response => "bad-response",
    });
}

/// `screen` — report the virtio-gpu transport: the OBSERVED device DID +
/// class + bus slot, the negotiated feature bits (low/high), the device's
/// num_scanouts, the scanout mode GET_DISPLAY_INFO reported (width x
/// height, enabled), the device status + post-exit re-arm state, the 2D
/// setup state, and the command counters. Grep-able and deterministic
/// (the net/mbox/procs observability shape). Honest when the device is
/// absent: the default runner attaches no graphics device. `screen fill
/// <rrggbb>` is the card-G1 subcommand: fill the framebuffer with the
/// 0xRRGGBB color, then TRANSFER_TO_HOST_2D + RESOURCE_FLUSH — the first
/// non-blank framebuffer the host `--screenshot` captures.
fn cmd_screen(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len > 0) {
        if (std.mem.eql(u8, args[0], "fill")) return cmd_screen_fill(m, args[1..]);
        if (std.mem.eql(u8, args[0], "peek")) return cmd_screen_peek(m);
        print_usage(m, lookup("screen").?);
        return .usage;
    }
    if (!virtio_gpu.gpu_ready) {
        m.console.puts("screen: no virtio-gpu device (");
        m.console.puts(if (virtio_gpu.gpu_fail.len > 0) virtio_gpu.gpu_fail else "DID 0x1050 not found on bus 0");
        m.console.puts(")\n");
        m.console.puts("screen: device-features=");
        m.console.print_hex(virtio_gpu.gpu_dev_feats_lo);
        m.console.puts("/");
        m.console.print_hex(virtio_gpu.gpu_dev_feats_hi);
        m.console.puts("\n");
        m.console.puts("screen: status=");
        m.console.print_hex(virtio_gpu.gpu_status_last);
        m.console.puts(" accepted=");
        m.console.print_hex(virtio_gpu.gpu_feats_lo);
        m.console.puts("/");
        m.console.print_hex(virtio_gpu.gpu_feats_hi);
        m.console.puts("\n");
        m.console.puts("screen: common=");
        m.console.print_hex(virtio_gpu.gpu_common);
        m.console.puts(" notify=");
        m.console.print_hex(virtio_gpu.gpu_notify);
        m.console.puts(" devcfg=");
        m.console.print_hex(virtio_gpu.gpu_devcfg);
        m.console.puts(" bar0=");
        m.console.print_hex(virtio_gpu.gpu_bar0);
        m.console.puts("\n");
        return .none;
    }
    m.console.puts("screen: did=");
    m.console.print_hex(virtio_gpu.gpu_did);
    m.console.puts(" class=");
    m.console.print_hex(virtio_gpu.gpu_class);
    m.console.puts(" dev=");
    m.console.print_u64(virtio_gpu.gpu_dev);
    m.console.puts("\n");
    m.console.puts("screen: devfeat=");
    m.console.print_hex(virtio_gpu.gpu_dev_feats_lo);
    m.console.puts("/");
    m.console.print_hex(virtio_gpu.gpu_dev_feats_hi);
    m.console.puts("\n");
    m.console.puts("screen: feat=");
    m.console.print_hex(virtio_gpu.gpu_feats_lo);
    m.console.puts("/");
    m.console.print_hex(virtio_gpu.gpu_feats_hi);
    m.console.puts(" scanouts=");
    m.console.print_hex(virtio_gpu.gpu_num_scanouts);
    m.console.puts("\n");
    m.console.puts("screen: scanout=");
    m.console.print_hex(virtio_gpu.gpu_scanout_w);
    m.console.puts("x");
    m.console.print_hex(virtio_gpu.gpu_scanout_h);
    m.console.puts(" enabled=");
    m.console.print_hex(virtio_gpu.gpu_scanout_enabled);
    m.console.puts("\n");
    m.console.puts("screen: status=");
    m.console.print_hex(virtio_gpu.gpu_status_last);
    m.console.puts(" rearm=");
    m.console.print_u64(if (virtio_gpu.gpu_rearmed) 1 else 0);
    m.console.puts(" setup=");
    m.console.print_u64(if (virtio_gpu.gpu_setup_ok) 1 else 0);
    m.console.puts(" cmds=");
    m.console.print_u64(virtio_gpu.gpu_cmds);
    m.console.puts(" errors=");
    m.console.print_u64(virtio_gpu.gpu_errors);
    m.console.puts(" timeouts=");
    m.console.print_u64(virtio_gpu.gpu_timeouts);
    m.console.puts("\n");
    // The timeout diagnostics (the claim-time record of a stuck queue).
    m.console.puts("screen: diag avail=");
    m.console.print_u64(virtio_gpu.gpu_diag_avail);
    m.console.puts(" used=");
    m.console.print_u64(virtio_gpu.gpu_diag_used);
    m.console.puts(" st=");
    m.console.print_hex(virtio_gpu.gpu_diag_st);
    m.console.puts(" qen=");
    m.console.print_u64(virtio_gpu.gpu_diag_qen);
    m.console.puts(" qoff=");
    m.console.print_u64(virtio_gpu.gpu_diag_qoff);
    m.console.puts(" mult=");
    m.console.print_u64(virtio_gpu.gpu_diag_mult);
    m.console.puts(" notify=");
    m.console.print_hex(virtio_gpu.gpu_diag_notify);
    m.console.puts("\n");
    m.console.puts("screen: rings desc=");
    m.console.print_hex(virtio_gpu.gpu_diag_desc_phys);
    m.console.puts(" avail=");
    m.console.print_hex(virtio_gpu.gpu_diag_avail_phys);
    m.console.puts(" used=");
    m.console.print_hex(virtio_gpu.gpu_diag_used_phys);
    m.console.puts("\n");
    m.console.puts("screen: diag cmd0=");
    m.console.print_hex(virtio_gpu.gpu_diag_cmd0);
    m.console.puts(" cmd1=");
    m.console.print_hex(virtio_gpu.gpu_diag_cmd1);
    m.console.puts(" isr=");
    m.console.print_hex(virtio_gpu.gpu_diag_isr);
    m.console.puts(" qsz=");
    m.console.print_u64(virtio_gpu.gpu_diag_qsz);
    m.console.puts(" bar0=");
    m.console.print_hex(virtio_gpu.gpu_bar0);
    m.console.puts(" common=");
    m.console.print_hex(virtio_gpu.gpu_common);
    m.console.puts(" devcfg=");
    m.console.print_hex(virtio_gpu.gpu_devcfg);
    m.console.puts(" fb=");
    m.console.print_hex(virtio_gpu.gpu_fb_phys);
    m.console.puts("\n");
    return .none;
}

/// `screen fill <rrggbb>` — fill the framebuffer with the 0xRRGGBB color
/// (out-of-range colors are refused honestly), then TRANSFER_TO_HOST_2D +
/// RESOURCE_FLUSH so the host scanout shows it. The live gate's marker:
/// the `--screenshot` pixels then match the fill.
fn cmd_screen_fill(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len != 1) {
        print_usage(m, lookup("screen").?);
        return .usage;
    }
    const rgb = parseHex(args[0]) catch {
        err_prefix(m);
        m.console.puts("invalid color: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    if (rgb > 0xffffff) {
        err_prefix(m);
        m.console.print_line("color out of range (max 0xffffff)");
        return .invalid_argument;
    }
    if (!virtio_gpu.gpu_ready) {
        err_prefix(m);
        m.console.print_line("transport not ready (no virtio-gpu device)");
        return .none;
    }
    virtio_gpu.fill_framebuffer(@truncate(rgb));
    const tx = virtio_gpu.gpu_transfer();
    const fl = virtio_gpu.gpu_flush();
    m.console.puts("screen fill: fill=");
    m.console.print_hex(rgb);
    m.console.puts(" transfer=");
    print_cmd_result(m, tx);
    m.console.puts(" flush=");
    print_cmd_result(m, fl);
    m.console.puts("\n");
    return .none;
}

/// `screen peek` — dump the first 8 bytes of the framebuffer (B,G,R,X for
/// the first pixel) + a checksum of the first 4096 bytes, so the gate can
/// prove the GUEST-side fill landed before blaming the host display.
fn cmd_screen_peek(m: *Monitor) ExecError {
    if (!virtio_gpu.gpu_ready) {
        err_prefix(m);
        m.console.print_line("transport not ready (no virtio-gpu device)");
        return .none;
    }
    m.console.puts("screen peek: fb=");
    m.console.print_hex(virtio_gpu.gpu_fb_phys);
    m.console.puts(" bytes=");
    var sum: u32 = 0;
    var i: usize = 0;
    while (i < 4096 and i < virtio_gpu.fb_size) : (i += 1) {
        sum +%= virtio_gpu.gpu_fb[i];
    }
    m.console.print_hex(sum);
    m.console.puts(" p0=");
    m.console.print_hex(virtio_gpu.gpu_fb[0]);
    m.console.puts(" p1=");
    m.console.print_hex(virtio_gpu.gpu_fb[1]);
    m.console.puts(" p2=");
    m.console.print_hex(virtio_gpu.gpu_fb[2]);
    m.console.puts(" p3=");
    m.console.print_hex(virtio_gpu.gpu_fb[3]);
    m.console.puts("\n");
    return .none;
}

/// M27 G27 (Issue #470): capture current framebuffer and save as BMP to FAT.
fn cmd_screenshot(m: *Monitor, args: []const []const u8) ExecError {
    if (!virtio_gpu.gpu_ready) {
        err_prefix(m);
        m.console.print_line("screenshot: GPU framebuffer not ready");
        return .none;
    }
    const path = if (args.len > 0) args[0] else "SCREEN.BMP";
    const res = fat.write_fb_bmp(path, virtio_gpu.fb_width, virtio_gpu.fb_height, @ptrCast(&virtio_gpu.gpu_fb));
    if (res != .ok) {
        err_prefix(m);
        m.console.puts("screenshot: write failed: ");
        m.console.puts(@tagName(res));
        m.console.puts("\n");
        return .none;
    }
    const row_raw: usize = @as(usize, virtio_gpu.fb_width) * 3;
    const row_pad: usize = (4 - (row_raw % 4)) % 4;
    const row_stride: usize = row_raw + row_pad;
    const total_bytes: usize = 54 + row_stride * @as(usize, virtio_gpu.fb_height);
    m.console.puts("screenshot: saved ");
    m.console.print_u64(virtio_gpu.fb_width);
    m.console.puts("x");
    m.console.print_u64(virtio_gpu.fb_height);
    m.console.puts(" BMP to ");
    m.console.puts(path);
    m.console.puts(" (");
    m.console.print_u64(total_bytes);
    m.console.puts(" bytes)\n");
    return .none;
}

/// M27 G29 (Issue #472): display keyboard shortcuts reference table.
fn cmd_shortcuts(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    m.console.print_line("Keyboard Shortcut Reference:");
    m.console.print_line("  Global:");
    m.console.print_line("    Ctrl+Shift+A   About DipshitOS dialog");
    m.console.print_line("    Ctrl+Shift+/   Display this shortcut reference");
    m.console.print_line("    Alt+Tab        Cycle open windows (Hold Alt, press Tab/Shift+Tab)");
    m.console.print_line("    Alt+F4         Close active window");
    m.console.print_line("    F11            Toggle window fullscreen / tile");
    m.console.print_line("    Ctrl+Alt+Del   Reboot system");
    m.console.print_line("  Window & Navigation:");
    m.console.print_line("    Tab            Focus next control");
    m.console.print_line("    Shift+Tab      Focus previous control");
    m.console.print_line("    Enter / Space  Activate focused button or toggle control");
    m.console.print_line("    Escape         Dismiss modal dialog / cancel action");
    m.console.print_line("    Ctrl+Q / Ctrl+W Close current window / quit application");
    m.console.print_line("  Editing & Clipboard:");
    m.console.print_line("    Ctrl+C         Copy selected text to clipboard");
    m.console.print_line("    Ctrl+X         Cut selected text to clipboard");
    m.console.print_line("    Ctrl+V         Paste text from clipboard");
    m.console.print_line("    Ctrl+Z         Undo last action");
    m.console.print_line("    Ctrl+Y         Redo last undone action");
    m.console.print_line("    Ctrl+S         Save file");
    m.console.print_line("    Ctrl+O         Open file");
    m.console.print_line("    Ctrl+N         New file");
    m.console.print_line("    Ctrl+F         Find in file");
    m.console.print_line("  Shell / Console:");
    m.console.print_line("    Ctrl+L         Clear screen");
    m.console.print_line("    Ctrl+C         Interrupt current command");
    m.console.print_line("    Up / Down      Navigate command history");
    m.console.print_line("    Ctrl+R         Reverse search command history");
    return .none;
}

/// `sound` — report the virtio-snd transport: the OBSERVED device ID and
/// class (a differing DID is a claim-time finding, recorded as the
/// hardware truth), the device status (0x0f = DRIVER_OK post-rearm; 0xff =
/// never discovered), the control-queue state, and the device-config
/// counts (jacks/streams/channel-maps — only when actually captured,
/// never guessed). Honest without the device: `ready=no` with the failure
/// reason.
fn cmd_sound(m: *Monitor, args: []const []const u8) ExecError {
    // Stream-state control (claim 9297): `sound volume <0-100>` sets the
    // bounded playback gain; `sound mute <on|off>` silences the stream.
    // Both are pure kernel state — they work without a device, and the
    // report below shows them. `sound` with no args is the transport
    // report.
    if (args.len == 2) {
        if (std.mem.eql(u8, args[0], "volume")) {
            const vol = parseInt(args[1]) catch {
                m.console.puts("sound: volume must be 0..100\n");
                return .none;
            };
            if (vol > 100) {
                m.console.puts("sound: volume must be 0..100\n");
                return .none;
            }
            const set = virtio_snd.snd_set_volume(@intCast(vol));
            m.console.puts("sound: volume=");
            m.console.print_u64(set);
            m.console.puts("\n");
            return .none;
        }
        if (std.mem.eql(u8, args[0], "mute")) {
            const on = std.mem.eql(u8, args[1], "on");
            const off = std.mem.eql(u8, args[1], "off");
            if (!on and !off) {
                m.console.puts("sound: mute must be 'on' or 'off'\n");
                return .none;
            }
            _ = virtio_snd.snd_set_mute(on);
            m.console.puts(if (on) "sound: mute=on\n" else "sound: mute=off\n");
            return .none;
        }
        print_usage(m, lookup("sound").?);
        return .usage;
    }
    if (args.len > 2) {
        print_usage(m, lookup("sound").?);
        return .usage;
    }
    if (!virtio_snd.snd_ready) {
        m.console.puts("sound: no virtio-snd device (");
        m.console.puts(if (virtio_snd.snd_fail.len > 0) virtio_snd.snd_fail else "DID 0x1059 not found on bus 0");
        m.console.puts(")\n");
    } else {
        m.console.puts("sound: ready\n");
    }
    m.console.puts("sound: did=");
    m.console.print_hex(virtio_snd.snd_did);
    m.console.puts(" cls=");
    m.console.print_hex(virtio_snd.snd_class);
    m.console.puts(" st=");
    m.console.print_hex(virtio_snd.snd_status());
    m.console.puts("\n");
    m.console.puts("sound: feats=");
    m.console.print_hex(virtio_snd.snd_feats);
    m.console.puts(" qsz=");
    m.console.print_hex(virtio_snd.queue_size);
    m.console.puts(" qoff=");
    m.console.print_hex(virtio_snd.snd_queue_notify_off);
    m.console.puts(" common=");
    m.console.print_hex(virtio_snd.snd_common);
    m.console.puts(" notify=");
    m.console.print_hex(virtio_snd.snd_notify);
    m.console.puts(" devcfg=");
    m.console.print_hex(virtio_snd.snd_devcfg);
    m.console.puts("\n");
    m.console.puts("sound: ctrl_armed=");
    m.console.print_u64(if (virtio_snd.ctrl_armed) 1 else 0);
    m.console.puts(" tx_armed=");
    m.console.print_u64(if (virtio_snd.tx_armed) 1 else 0);
    m.console.puts(" notify_mult=");
    m.console.print_hex(virtio_snd.snd_notify_mult);
    m.console.puts(" ctl_qoff=");
    m.console.print_hex(virtio_snd.snd_queue_notify_off);
    m.console.puts(" tx_qoff=");
    m.console.print_hex(virtio_snd.tx_queue_notify_off);
    m.console.puts(" fail_stage=");
    m.console.print_u64(virtio_snd.ctl_fail_stage);
    m.console.puts(" spins=");
    m.console.print_u64(virtio_snd.ctl_spins);
    m.console.puts(" used_idx=");
    m.console.print_u64(virtio_snd.ctl_used_idx);
    m.console.puts(" used_id=");
    m.console.print_u64(virtio_snd.ctl_used_id);
    m.console.puts(" used_len=");
    m.console.print_u64(virtio_snd.ctl_used_len);
    m.console.puts("\n");
    m.console.puts("sound: cfg=");
    if (virtio_snd.snd_cfg()) |cfg| {
        m.console.puts("jacks=");
        m.console.print_u64(cfg.jacks);
        m.console.puts(" streams=");
        m.console.print_u64(cfg.streams);
        m.console.puts(" chmaps=");
        m.console.print_u64(cfg.chmaps);
    } else {
        m.console.puts("not-captured (config read never landed)");
    }
    // Fresh post-exit read of the devcfg window (safe: the identity map
    // covers snd_bar0..+0x10000 and the devcfg capability resolved inside
    // it — 0x100001000 on the live runs). Pre-exit vs post-exit values
    // are compared so a firmware-mapping artifact is distinguishable from
    // the device's true report.
    m.console.puts(" fresh=");
    if (virtio_snd.snd_devcfg >= virtio_snd.snd_bar0 and
        virtio_snd.snd_devcfg + virtio_snd.cfg_bytes < virtio_snd.snd_bar0 + 0x10000)
    {
        m.console.puts("jacks=");
        m.console.print_u64(virtio_snd.snd_read32(virtio_snd.cfg_jacks_off));
        m.console.puts(" streams=");
        m.console.print_u64(virtio_snd.snd_read32(virtio_snd.cfg_streams_off));
        m.console.puts(" chmaps=");
        m.console.print_u64(virtio_snd.snd_read32(virtio_snd.cfg_chmaps_off));
    } else {
        m.console.puts("devcfg-outside-bar0 (not re-readable post-exit)");
    }
    // The bounded stream-state (claim 9297): vol=0..100, mute=0|1.
    m.console.puts("\nsound: vol=");
    m.console.print_u64(virtio_snd.stream_volume);
    m.console.puts(" mute=");
    m.console.print_u64(if (virtio_snd.stream_muted) 1 else 0);
    m.console.puts("\n");
    return .none;
}

/// `beep <freq> <ms>` — synthesize a sine and play it through the
/// virtio-snd PCM path (claim 5877, milestone fifteen card A2). The full
/// flow runs: PCM_INFO (the A1-finding workaround — VZ does not populate
/// the config counts, so the stream is enumerated by asking) →
/// SET_PARAMS → PREPARE → START → TX-queue submit → used-ring drain →
/// STOP → RELEASE. Every step's status + the submitted/drained accounting
/// are printed — the live gate's evidence. Honest without the device:
/// `beep` refuses with a clear reason.
fn cmd_beep(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len != 2) {
        print_usage(m, lookup("beep").?);
        return .usage;
    }
    const freq = parseInt(args[0]) catch {
        err_prefix(m);
        m.console.puts("beep: invalid frequency: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    const ms = parseInt(args[1]) catch {
        err_prefix(m);
        m.console.puts("beep: invalid duration: ");
        m.console.puts(args[1]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    if (freq < 1 or freq > 20000 or ms < 1 or ms > 650) {
        err_prefix(m);
        m.console.puts("beep: freq must be 1..20000 Hz and ms 1..650\n");
        return .invalid_argument;
    }
    if (!virtio_snd.snd_ready) {
        err_prefix(m);
        m.console.puts("beep: no virtio-snd device (");
        m.console.puts(if (virtio_snd.snd_fail.len > 0) virtio_snd.snd_fail else "DID 0x1059 not found on bus 0");
        m.console.puts(")\n");
        return .none;
    }
    const st = virtio_snd.snd_beep(@intCast(freq), @intCast(ms));
    m.console.puts("beep: reply=");
    var ri: usize = 0;
    while (ri < 9) : (ri += 1) {
        if (ri > 0) m.console.puts(" ");
        m.console.print_hex(std.mem.readInt(u32, virtio_snd.ctl_reply_buf[ri * 4 ..][0..4], .little));
    }
    m.console.puts("\n");
    m.console.puts("beep: info st=");
    m.console.print_hex(virtio_snd.beep_info_status);
    m.console.puts(" formats=");
    m.console.print_hex(virtio_snd.beep_obs_formats);
    m.console.puts(" rates=");
    m.console.print_hex(virtio_snd.beep_obs_rates);
    m.console.puts(" ch=");
    m.console.print_u64(virtio_snd.beep_obs_ch_min);
    m.console.puts("..");
    m.console.print_u64(virtio_snd.beep_obs_ch_max);
    m.console.puts(" dir=");
    m.console.print_u64(virtio_snd.beep_obs_dir);
    m.console.puts("\n");
    m.console.puts("beep: params fmt=");
    m.console.print_u64(virtio_snd.beep_format);
    m.console.puts(" rate=");
    m.console.print_u64(virtio_snd.beep_rate);
    m.console.puts(" ch=");
    m.console.print_u64(virtio_snd.beep_channels);
    m.console.puts(" st=");
    m.console.print_hex(virtio_snd.beep_params_status);
    m.console.puts(" prepare=");
    m.console.print_hex(virtio_snd.beep_prepare_status);
    m.console.puts(" start=");
    m.console.print_hex(virtio_snd.beep_start_status);
    m.console.puts("\n");
    m.console.puts("beep: tx submitted=");
    m.console.print_u64(virtio_snd.beep_submitted);
    m.console.puts(" drained=");
    m.console.print_u64(virtio_snd.beep_drained);
    m.console.puts(" frames=");
    m.console.print_u64(virtio_snd.beep_frames);
    m.console.puts(" pcm_status=");
    m.console.print_hex(virtio_snd.beep_last_status);
    m.console.puts(" latency=");
    m.console.print_u64(virtio_snd.beep_last_latency);
    m.console.puts("\n");
    m.console.puts("beep: stop=");
    m.console.print_hex(virtio_snd.beep_stop_status);
    m.console.puts(" release=");
    m.console.print_hex(virtio_snd.beep_release_status);
    m.console.puts("\n");
    if (st != virtio_snd.S_OK) {
        m.console.puts("beep: FAILED (");
        m.console.puts(if (virtio_snd.beep_fail.len > 0) virtio_snd.beep_fail else "unknown");
        m.console.puts(")\n");
    } else {
        m.console.puts("beep: ok\n");
    }
    return .none;
}

/// `font` — report or switch the terminal's font size (M20-U1). The
/// same setter slot 58 drives; the compositor repaints immediately.
fn cmd_font(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 0) {
        m.console.print_line("font:");
        m.console.puts("  size=");
        m.console.print_line(switch (fbtext.font_size) {
            .small => "small (8x8)",
            .medium => "medium (16x16)",
            .large => "large (24x24)",
        });
        return .none;
    }
    const target: ?fbtext.FontSize = if (std.mem.eql(u8, args[0], "small"))
        .small
    else if (std.mem.eql(u8, args[0], "medium"))
        .medium
    else if (std.mem.eql(u8, args[0], "large"))
        .large
    else
        null;
    if (target == null) {
        print_usage(m, lookup("font").?);
        return .usage;
    }
    fbtext.set_font_size(target.?);
    _ = settings.set("font_size", @tagName(target.?));
    // Repaint through the compositor when the gpu is up.
    if (virtio_gpu.gpu_ready) {
        driving_award.mark_terminal_dirty();
        _ = driving_award.composite();
    }
    m.console.print_line("font: set to the terminal");
    return .none;
}

/// `text` — report the framebuffer text layer: the region (rows/cols at
/// the cell size), the cursor (row/col), the scrollback depth, and the
/// colors. `text put <string...>` renders the string and pushes it to
/// the scanout (transfer + flush — the live gate's driver); `text clear`
/// clears + pushes. Honest without the gpu: the report works with no
/// device, `put`/`clear` refuse.
fn cmd_text(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 0) {
        // M20-U1: rows/cols/cell report the LIVE font-size geometry
        // (visible grid at the current size), not the ring constants.
        m.console.puts("text: rows=");
        m.console.print_u64(fbtext.visible_rows());
        m.console.puts(" cols=");
        m.console.print_u64(fbtext.visible_cols());
        m.console.puts(" cell=");
        m.console.print_u64(fbtext.cur_cell_w());
        m.console.puts("x");
        m.console.print_u64(fbtext.cur_cell_h());
        m.console.puts(" cur=");
        m.console.print_u64(fbtext.cursor_row());
        m.console.puts(",");
        m.console.print_u64(fbtext.cursor_col());
        m.console.puts(" lines=");
        m.console.print_u64(fbtext.line_count());
        m.console.puts(" fg=");
        m.console.print_hex(fbtext.fg_rgb);
        m.console.puts(" bg=");
        m.console.print_hex(fbtext.bg_rgb);
        m.console.puts("\n");
        return .none;
    }
    if (std.mem.eql(u8, args[0], "put") or std.mem.eql(u8, args[0], "putraw")) {
        // M20-U14 gate seam: `putraw` skips the trailing newline so a
        // follow-up `text` report shows the exact landing column.
        const raw = std.mem.eql(u8, args[0], "putraw");
        if (args.len < 2) {
            print_usage(m, lookup("text").?);
            return .usage;
        }
        if (!virtio_gpu.gpu_ready) {
            err_prefix(m);
            m.console.print_line("transport not ready (no virtio-gpu device)");
            return .none;
        }
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (i > 1) fbtext.putc(' ');
            // M20-U10 gate seam: "\t" expands to a real TAB — raw TAB
            // bytes cannot survive the line editor's completion.
            const arg = args[i];
            var j: usize = 0;
            while (j < arg.len) : (j += 1) {
                if (arg[j] == '\\' and j + 1 < arg.len and arg[j + 1] == 't') {
                    fbtext.putc('\t');
                    j += 1;
                } else {
                    fbtext.putc(arg[j]);
                }
            }
        }
        if (!raw) fbtext.putc('\n');
        // Card G5 (claim 1543): present through the Driving Award
        // compositor so the clock overlay stays composited over the
        // repainted terminal.
        driving_award.mark_terminal_dirty();
        const r = driving_award.composite();
        m.console.puts("text put: ");
        print_cmd_result(m, r);
        m.console.puts("\n");
        return .none;
    }
    if (std.mem.eql(u8, args[0], "clear")) {
        if (!virtio_gpu.gpu_ready) {
            err_prefix(m);
            m.console.print_line("transport not ready (no virtio-gpu device)");
            return .none;
        }
        fbtext.clear();
        // Card G5 (claim 1543): present through the compositor (see put).
        driving_award.mark_terminal_dirty();
        const r = driving_award.composite();
        m.console.puts("text clear: ");
        print_cmd_result(m, r);
        m.console.puts("\n");
        return .none;
    }
    if (std.mem.eql(u8, args[0], "fontdebug")) {
        // M20-U11: toggle the missing-glyph dev setting and report stats.
        if (args.len > 1) {
            if (std.mem.eql(u8, args[1], "on")) {
                fbtext.debug_font = true;
            } else if (std.mem.eql(u8, args[1], "off")) {
                fbtext.debug_font = false;
            } else {
                print_usage(m, lookup("text").?);
                return .usage;
            }
        }
        m.console.print_line("fontdebug:");
        m.console.puts("  state=");
        m.console.print_line(if (fbtext.debug_font) "on" else "off");
        m.console.puts("  missing=");
        m.console.print_u64(fbtext.missing_glyph_count);
        // U+XXXX, four hex digits, matching the serial log format of the
        // missing-glyph hook ("text: no glyph for U+XXXX").
        m.console.puts(" last=U+");
        const shifts = [_]u4{ 12, 8, 4, 0 };
        for (shifts) |sh| {
            const d: u8 = @intCast((fbtext.last_missing_cp >> sh) & 0xf);
            m.console.putc(if (d < 10) '0' + d else 'a' + d - 10);
        }
        m.console.puts("\n");
        return .none;
    }
    print_usage(m, lookup("text").?);
    return .usage;
}

// ---------------------------------------------------------------------------
// Task lifecycle command (claim 6729)
// ---------------------------------------------------------------------------

/// Spawn the lifecycle demo task (the scheduler owns the demo stack and
/// refuses a second spawn). Proves a runtime spawn enters the ring: the
/// demo task's `tasks spawn-demo advances=N` report lines follow. The
/// EL0 task's own exit + the idle task's reap prove the rest of the
/// lifecycle.
fn cmd_spawn(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    if (scheduler.spawn_demo()) |id| {
        m.console.puts("spawn: spawn-demo id=");
        m.console.print_u64(@intCast(id));
        m.console.puts("\n");
    } else {
        m.console.puts("spawn: pool full or demo already running\n");
    }
    return .none;
}

// ---------------------------------------------------------------------------
// ESP exec command (claim 6783 — milestone-three card 6)
// ---------------------------------------------------------------------------

/// Load a user program from the ESP and enter it at EL0. `exec [<file>
/// [arg...]]` defaults to `USER.BIN` (the image builder embeds it at the
/// volume root; it can also be written at runtime through the FAT `write`
/// path). The program must be a DSK1 flat image; the kernel reads it
/// through the claim-6420 FAT path, rebuilds the EL0 user root around its
/// page, and spawns it as an EL0t task. Arguments (card 3e, claim 4636)
/// are packed into the program's text page and passed at entry (argc in
/// x0, argv block VA in x1) — bounded to `max_exec_args`; more than that
/// is refused honestly. Every failure mode is reported honestly.
fn cmd_exec(m: *Monitor, args: []const []const u8) ExecError {
    const name = if (args.len >= 1) args[0] else esp_exec.default_name;
    const prog_args = if (args.len >= 2) args[1..] else &.{};
    switch (esp_exec.exec_file(name, prog_args)) {
        .ok => {
            const info = esp_exec.loaded().?;
            m.console.puts("exec: loaded ");
            m.console.puts(info.name);
            m.console.puts(" size=");
            m.console.print_hex(@intCast(info.content_len));
            m.console.puts(" entry=");
            m.console.print_hex(info.entry_va);
            // Claim 0826: the process's OWN stack placement, not the
            // static boot stack's.
            m.console.puts(" stack=");
            m.console.print_hex(info.stack_va);
            const head = esp_exec.head();
            var head_value: u64 = 0;
            for (head, 0..) |byte, i| head_value |= @as(u64, byte) << @intCast(56 - i * 8);
            m.console.puts(" head=");
            m.console.print_hex(head_value);
            // Claim 3805 (milestone sixteen C1): a segmented image's data+bss
            // region is reported so the live gate can assert the kernel's own
            // page accounting is exact. Flat DSK1 images omit it (byte-identical).
            if (info.data_len > 0) {
                m.console.puts(" data=");
                m.console.print_hex(info.data_len);
                m.console.puts(" datapages=");
                m.console.print_u64(info.data_pages);
            }
            m.console.puts("\n");
            return .none;
        },
        .no_disk => {
            err_prefix(m);
            m.console.print_line("no disk (ESP FAT volume unavailable)");
            return .not_implemented;
        },
        .not_found => {
            err_prefix(m);
            m.console.puts(name);
            m.console.print_line(": not found on the ESP (must be a DSK1 flat image)");
            return .invalid_argument;
        },
        .too_large => {
            err_prefix(m);
            m.console.puts(name);
            m.console.puts(": image larger than the ");
            m.console.print_hex(esp_exec.exec_program_max);
            m.console.print_line("-byte load buffer");
            return .invalid_argument;
        },
        .bad_magic => {
            err_prefix(m);
            m.console.puts(name);
            m.console.print_line(": not a DSK1 program image (bad magic)");
            return .invalid_argument;
        },
        .bad_entry => {
            err_prefix(m);
            m.console.puts(name);
            m.console.print_line(": bad entry offset (outside the loaded content)");
            return .invalid_argument;
        },
        .out_of_memory => {
            err_prefix(m);
            m.console.print_line("out of physical pages (text/stack/exception stack)");
            return .machine_failed;
        },
        .pool_full => {
            err_prefix(m);
            m.console.print_line("no free scheduler pool slot");
            return .machine_failed;
        },
        .table_full => {
            err_prefix(m);
            m.console.print_line("page-table carve-out exhausted (too many user-root rebuilds)");
            return .machine_failed;
        },
        .process_full => {
            err_prefix(m);
            m.console.print_line("process registry exhausted (all processes live; wait for one to exit)");
            return .machine_failed;
        },
        .too_many_args => {
            err_prefix(m);
            m.console.puts("too many arguments (max ");
            m.console.print_u64(esp_exec.max_exec_args);
            m.console.print_line(")");
            return .invalid_argument;
        },
        .no_args_room => {
            err_prefix(m);
            m.console.print_line("image leaves no room for the argv block (256 bytes)");
            return .invalid_argument;
        },
        // M22 D1 (issue #324): honest ELF refusals.
        .bad_elf => {
            err_prefix(m);
            m.console.puts(name);
            m.console.print_line(": not a valid ELF file");
            return .invalid_argument;
        },
        .unsupported_arch => {
            err_prefix(m);
            m.console.puts(name);
            m.console.print_line(": unsupported architecture (AArch64 only)");
            return .invalid_argument;
        },
        .no_pt_load => {
            err_prefix(m);
            m.console.puts(name);
            m.console.print_line(": no PT_LOAD segments");
            return .invalid_argument;
        },
        .too_many_segments => {
            err_prefix(m);
            m.console.puts(name);
            m.console.print_line(": too many segments (max 2)");
            return .invalid_argument;
        },
        .segment_too_large => {
            err_prefix(m);
            m.console.puts(name);
            m.console.print_line(": segment too large or bad segment layout");
            return .invalid_argument;
        },
    }
}

// ---------------------------------------------------------------------------
// Syscall ABI command (claim 3594)
// ---------------------------------------------------------------------------

/// M22 D3 (issue #326): `sym` — list the crash-report symbol table loaded
/// by the most recent ELF exec, or parse an ELF's symtab straight from the
/// volume without loading it.
fn cmd_sym(m: *Monitor, args: []const []const u8) ExecError {
    const symbol = @import("symbol.zig");
    const elf_mod = @import("elf.zig");
    if (args.len == 0) {
        const n = symbol.count();
        if (n == 0) {
            m.console.print_line("sym: no symbols loaded (exec an ELF image)");
            return .none;
        }
        m.console.puts("sym: ");
        m.console.print_u64(n);
        m.console.print_line(" symbol(s):");
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const sym = symbol.get(i).?;
            m.console.puts("  ");
            m.console.puts(sym.name_slice());
            m.console.puts(" addr=");
            m.console.print_hex(sym.addr);
            m.console.puts(" size=");
            m.console.print_hex(sym.size);
            m.console.print_line("");
        }
        return .none;
    }

    // File inspection: read up to sym_file_max bytes and walk sections.
    const name = args[0];
    const got = fat.read_file(name, &sym_file_buf) orelse {
        err_prefix(m);
        m.console.puts(name);
        m.console.print_line(": not found on the active volume");
        return .invalid_argument;
    };
    var infos: [symbol.max_symbols]elf_mod.SymInfo = undefined;
    const n = elf_mod.collect_symbols(sym_file_buf[0..got], &infos);
    if (n == 0) {
        m.console.puts(name);
        m.console.print_line(": no symbols (stripped or not an AArch64 ELF)");
        return .none;
    }
    m.console.puts(name);
    m.console.puts(": ");
    m.console.print_u64(n);
    m.console.print_line(" symbol(s):");
    for (infos[0..n]) |si| {
        m.console.puts("  ");
        m.console.puts(si.name);
        m.console.puts(" addr=");
        m.console.print_hex(si.addr);
        m.console.puts(" size=");
        m.console.print_hex(si.size);
        m.console.print_line("");
    }
    return .none;
}

/// Staging buffer for `sym <file>` disk inspection.
var sym_file_buf: [sym_file_max]u8 = undefined;

/// M22 D5 (issue #328): `strace exec <file> [args...]` arms the kernel
/// tracer for the process the exec spawns (the loader records its pid at
/// the success point, before the task first runs, so every syscall is
/// seen). `strace off` disarms. Anything else prints usage honestly.
fn cmd_strace(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 1 and std.mem.eql(u8, args[0], "off")) {
        syscall_mod.strace_pid = null;
        m.console.print_line("strace: off");
        return .none;
    }
    if (args.len >= 2 and std.mem.eql(u8, args[0], "exec")) {
        const res = esp_exec.exec_file(args[1], args[2..]);
        if (res != .ok) {
            err_prefix(m);
            m.console.puts("strace: exec refused (");
            m.console.print_u64(@intFromEnum(res));
            m.console.print_line(")");
            return .invalid_argument;
        }
        syscall_mod.strace_pid = esp_exec.last_exec_pid();
        m.console.print_line("strace: armed");
        return .none;
    }
    err_prefix(m);
    m.console.print_line("usage: strace exec <file> [args...] | strace off");
    return .invalid_argument;
}

/// M22 D6 (issue #329): `ps` — the process status table. One row per
/// non-free registry entry: PID, name, state, memory footprint (text +
/// data + stack + kernel-stack pages), CPU ticks (via the executor task
/// when bound), and the task id. `procs` remains the verbose view; this is
/// the scannable table.
fn cmd_ps(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    m.console.puts("  PID  NAME                 STATE     MEM       CPU  TASK\n");
    var id: usize = 0;
    var rows: usize = 0;
    while (id < process.max_processes) : (id += 1) {
        const info = process.info(id) orelse continue;
        if (info.state == .free) continue;
        rows += 1;
        var line: [96]u8 = undefined;
        var pos: usize = 0;
        pos = pad_left(&line, pos, id, 5);
        pos = append_str(&line, pos, "  ");
        pos = pad_right(&line, pos, info.name, 20);
        pos = append_str(&line, pos, " ");
        pos = pad_right(&line, pos, @tagName(info.state), 9);
        pos = append_str(&line, pos, " ");
        // Memory: owned pages only (boot payload reports its static stack).
        const mem_kib = ((info.text_pages + info.data_pages + info.stack_pages + info.kernel_stack_pages) * 4);
        pos = pad_left(&line, pos, mem_kib, 5);
        line[pos] = 'K';
        pos += 1;
        pos = append_str(&line, pos, "   ");
        pos = pad_left_u64(&line, pos, info.cpu_usage, 6);
        pos = append_str(&line, pos, "  ");
        if (info.task_id) |tid| {
            pos = pad_left(&line, pos, tid, 4);
        } else {
            pos = append_str(&line, pos, "   -");
        }
        if (pos < line.len) {
            line[pos] = '\n';
            m.console.write(line[0 .. pos + 1]);
        } else {
            m.console.write(line[0..pos]);
            m.console.print_line("");
        }
    }
    if (rows == 0) m.console.print_line("ps: no processes");
    return .none;
}

fn append_str(buf: []u8, pos: usize, src: []const u8) usize {
    const take = @min(src.len, buf.len - pos);
    @memcpy(buf[pos..][0..take], src[0..take]);
    return pos + take;
}

fn pad_left(buf: []u8, pos: usize, v: usize, width: usize) usize {
    var tmp: [20]u8 = undefined;
    var n: usize = 0;
    var v2 = v;
    if (v2 == 0) {
        tmp[0] = '0';
        n = 1;
    }
    while (v2 > 0) : (v2 /= 10) {
        tmp[n] = @intCast('0' + v2 % 10);
        n += 1;
    }
    var written: usize = 0;
    while (n + written < width) : (written += 1) buf[pos + written] = ' ';
    var i: usize = 0;
    while (i < n) : (i += 1) buf[pos + written + i] = tmp[n - 1 - i];
    return pos + written + n;
}

fn pad_left_u64(buf: []u8, pos: usize, v_in: u64, width: usize) usize {
    var tmp: [20]u8 = undefined;
    var n: usize = 0;
    var v = v_in;
    if (v == 0) {
        tmp[0] = '0';
        n = 1;
    }
    while (v > 0) : (v /= 10) {
        tmp[n] = @intCast('0' + v % 10);
        n += 1;
    }
    var written: usize = 0;
    while (n + written < width) : (written += 1) buf[pos + written] = ' ';
    var i: usize = 0;
    while (i < n) : (i += 1) buf[pos + written + i] = tmp[n - 1 - i];
    return pos + written + n;
}

fn pad_right(buf: []u8, pos: usize, src: []const u8, width: usize) usize {
    const take = @min(src.len, width);
    @memcpy(buf[pos..][0..take], src[0..take]);
    var written = take;
    while (written < width) : (written += 1) buf[pos + written] = ' ';
    return pos + written;
}

fn cmd_syscalls(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    syscall.report(&m.console);
    return .none;
}

/// M32 WMS2 (issue #622): the render-server register report row. The
/// present-sequence counter is the parity-cards' observability primitive
/// (WMS4–WMS6 assert against it), so `wm` reports it from day one. When no
/// WM is registered it reports shim mode ("/ none").
fn cmd_wm(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    const info = wm_server.info();
    if (info.pid) |pid| {
        m.console.puts("wm: registered pid=");
        m.console.print_u64(pid);
        m.console.puts(" present=");
        m.console.puts("\n");
        // present_seq is u32; report it as a fixed decimal for grep-ability.
        m.console.puts("wm: present_seq=");
        m.console.print_u64(info.present_seq);
        m.console.puts(" presents=");
        m.console.print_u64(info.present_count);
        m.console.puts(" ticks=");
        m.console.print_u64(info.tick_count);
        m.console.puts("\n");
        // M32 WMS4 (issue #624): chrome observability — SET_WINDOW
        // submissions counted, the broadcast policy's chrome kind, and the
        // effective last chrome kind of every user window (0 = shim rules).
        m.console.puts("wm: chrome submissions=");
        m.console.print_u64(info.set_window_count);
        m.console.puts(" policy_kind=");
        m.console.print_hex_min(driving_award.wm_chrome_policy_kind());
        m.console.puts("\n");
        // M32 WMS5 (issue #625): the input-seam observability — how many
        // raw pointer samples (kind 19) and registry mirrors (kind 20) the
        // kernel has fanned out to the registered WM. The gate greps these
        // to prove the WM — not the kernel — received the stream.
        m.console.puts("wm: ptr_fan=");
        m.console.print_u64(info.pointer_fan_count);
        m.console.puts(" win_mirror=");
        m.console.print_u64(info.window_mirror_count);
        // M32 WMS5 Gate 2 (issue #625, claim 4278): the keyboard half of
        // the input seam — raw key fan-out (kind 21) and SET_STATE (cmd 4)
        // visibility/workspace changes applied by the registered WM.
        m.console.puts(" key_fan=");
        m.console.print_u64(info.key_fan_count);
        m.console.puts(" set_state=");
        m.console.print_u64(info.set_state_count);
        // M32 WMS6 Gate A (issue #626): the desktop-chrome observability —
        // ALT_TAB (cmd 5) decisions the WM made (activate/cycle/commit/
        // dismiss), applied by the kernel (the gate greps `alt_tab=`).
        m.console.puts(" alt_tab=");
        m.console.print_u64(info.alt_tab_apply_count);
        // M32 WMS6 Gate B (issue #626): the notification-center observability
        // — NOTIF_CENTER (cmd 6) and NOTIF_DISMISS (cmd 7) decisions applied.
        m.console.puts(" notif=");
        m.console.print_u64(info.notif_center_count);
        m.console.puts(" notif_dismiss=");
        m.console.print_u64(info.notif_dismiss_count);
        // M32 WMS6 Gate C (issue #626): the tooltip observability — TOOLTIP
        // (cmd 8) show/hide decisions applied.
        m.console.puts(" tooltip=");
        m.console.print_u64(info.tooltip_count);
        // M32 WMS6 Gate D (issue #626): the dock observability — DOCK (cmd 9)
        // icon-click decisions applied.
        m.console.puts(" dock=");
        m.console.print_u64(info.dock_count);
        // M32 WMS6 Gate E (issue #626): the tray observability — TRAY (cmd 10)
        // widget-content decisions applied (the gate greps `tray=`).
        m.console.puts(" tray=");
        m.console.print_u64(info.tray_count);
        // M32 WMS8 Gate 2 (issue #628): the dialog observability — DIALOG
        // (cmd 11) modal-dialog decisions (about open/close/toggle) applied.
        m.console.puts(" dialog=");
        m.console.print_u64(info.dialog_count);
        m.console.puts("\n");
        var rows: [driving_award.max_windows]driving_award.ChromeRow = undefined;
        const n = driving_award.wm_chrome_rows(&rows);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            m.console.puts("wm: chrome window id=");
            m.console.print_u64(rows[i].id);
            m.console.puts(" kind=");
            m.console.print_hex_min(rows[i].kind);
            m.console.puts("\n");
        }
    } else {
        m.console.print_line("wm: none (shim compositing)");
    }
    return .none;
}

/// M32 WMS3 (issue #623): the WM-server command. `wnd start` execs the
/// long-lived EL0 WND.BIN server (the DEFINED bootstrap — infrastructure,
/// not in APPS.TXT; the default VM stays shim-only because nothing
/// auto-starts it). Bare `wnd` reports the same seated-server state as
/// `wm` (registered pid + present/tick counters; `wnd: none` when the
/// shell idle shim is still compositing). Because WND.BIN never exits, the
/// crash story uses `kill <pid>` (claim 7786) + WMS2 exit-path teardown
/// (claim 0622) + a fresh `wnd start` — re-registering into the freed seat.
fn cmd_wnd(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len >= 1 and std.mem.eql(u8, args[0], "start")) {
        // The bootstrap: launch the long-lived WM server. Go through the
        // exec seam DIRECTLY with a fixed file name — the same pattern as
        // `calc`'s exec_file("CALC.BIN", args) (a direct string literal,
        // no argv indirection): an argv handoff to cmd_exec showed garbage
        // in the exec error path under ReleaseSmall, so this is the honest,
        // proven shape. WND.BIN becomes process WND.BIN on the ESP.
        switch (esp_exec.exec_file("WND.BIN", &.{})) {
            .ok => {
                m.console.puts("wnd: starting ");
                const info = esp_exec.loaded().?;
                m.console.puts(info.name);
                m.console.puts("\n");
                return .none;
            },
            .no_disk => {
                err_prefix(m);
                m.console.print_line("no disk (ESP FAT volume unavailable)");
                return .not_implemented;
            },
            .not_found => {
                err_prefix(m);
                m.console.print_line("WND.BIN not found on the ESP (must be a DSK1 flat image)");
                return .invalid_argument;
            },
            else => {
                err_prefix(m);
                m.console.print_line("WND.BIN failed to load (see `exec WND.BIN` for the full diagnosis)");
                return .invalid_argument;
            },
        }
    }
    const info = wm_server.info();
    if (info.pid) |pid| {
        m.console.puts("wnd: registered pid=");
        m.console.print_u64(pid);
        m.console.puts(" present_seq=");
        m.console.print_u64(info.present_seq);
        m.console.puts(" presents=");
        m.console.print_u64(info.present_count);
        m.console.puts(" ticks=");
        m.console.print_u64(info.tick_count);
        m.console.puts("\n");
    } else {
        m.console.print_line("wnd: none (shim compositing)");
    }
    return .none;
}

// ---------------------------------------------------------------------------
// Per-task address-space command (claim 5804)
// ---------------------------------------------------------------------------

/// Report the address-space split (claim 5804, VZ fallback): TTBR1 must
/// be 0 (unused — the kernel is identity-mapped in TTBR0), every task's
/// TTBR0 root, and the user root's leaf inventory. The user root is the
/// identity clone + user leaves: `el0` leaves must be EXACTLY the
/// text+stack leaves, and `el0_device` must be 0 (MMIO excluded from EL0
/// by the EL1-only AP bits on the overlay's Device leaves). Deterministic
/// and grep-able; on host test processes the roots are never built, so it
/// honestly prints zeros for the register/root values and 0 leaves.
fn cmd_addrspaces(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    m.console.puts("addrspaces: ttbr1=");
    m.console.print_hex(mmu.read_ttbr1());
    m.console.puts(" root=");
    m.console.print_hex(mmu.kernel_root_phys());
    m.console.puts(" tcr=");
    m.console.print_hex(mmu.read_tcr());
    m.console.puts(" t0sz=16\n");
    var i: usize = 0;
    while (i < scheduler.max_tasks) : (i += 1) {
        const info = scheduler.task_info(i) orelse continue;
        m.console.puts("addrspaces: task ");
        m.console.puts(info.name);
        m.console.puts(" ttbr0=");
        m.console.print_hex(scheduler.task_ttbr0(i));
        m.console.puts("\n");
    }
    // Claim 6729: the user task's root is a fixed MMU fact (built at boot),
    // not a task-table fact — the lifecycle's idle task reaps the exited
    // user task, so the `task user-el0` row above may legitimately be gone
    // by the time this command runs. Report the root directly so the
    // ownership assertion (user root != kernel root) survives the reap.
    m.console.puts("addrspaces: user root=");
    m.console.print_hex(mmu.user_root_phys());
    m.console.puts("\n");
    // Claim 0826: the per-process-root budget — table pages consumed out of
    // the fixed 512-page carve-out (grown by claim 2714 for the M16
    // composition). Card 3g (claim 5795): FOUR live user roots (~15 each +
    // leaf tables) stay well inside it; the scale live gate reads this line
    // for the headroom assertion.
    m.console.puts("addrspaces: tables=");
    m.console.print_u64(@intCast(mmu.tables_used()));
    m.console.puts("/");
    m.console.print_u64(@intCast(mmu.tables_capacity()));
    m.console.puts("\n");
    const leaves = mmu.walk_leaves(mmu.user_root_phys());
    m.console.puts("addrspaces: user text=");
    m.console.print_hex(userspace.text_va);
    m.console.puts(" stack=");
    m.console.print_hex(userspace.user_stack_va());
    m.console.puts(" leaves=");
    m.console.print_u64(leaves.leaves);
    m.console.puts(" device=");
    m.console.print_u64(leaves.device_leaves);
    m.console.puts(" el0=");
    m.console.print_u64(leaves.el0_leaves);
    m.console.puts(" el0_device=");
    m.console.print_u64(leaves.el0_device_leaves);
    m.console.puts("\n");
    return .none;
}

// ---------------------------------------------------------------------------
// Resources command (milestone sixteen C3, claim 0339)
// ---------------------------------------------------------------------------

/// The fixed-pool audit: one line per bounded kernel pool with its live
/// occupancy vs its comptime bound. This is the C3 "measure, then grow
/// only what the apps exhaust" evidence — the live gate reads these lines
/// BEFORE filling the pool and AFTER, so the growth is pinned in the serial
/// log rather than asserted from code alone. The pools left bounded
/// (windows, mailbox rings, event queues, file handles, app timers, the
/// single TCP client) are printed with their bounds so the audit records
/// that they were checked and NOT grown (no demo app exhausts them).
fn cmd_resources(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    const s = scheduler.stats();
    m.console.puts("resources: tasks=");
    m.console.print_u64(@intCast(s.count));
    m.console.puts("/");
    m.console.print_u64(@intCast(scheduler.max_tasks));
    m.console.puts(" zombies=");
    m.console.print_u64(@intCast(s.zombies));
    m.console.puts("\n");
    m.console.puts("resources: procs=");
    m.console.print_u64(@intCast(process.count()));
    m.console.puts("/");
    m.console.print_u64(@intCast(process.max_processes));
    m.console.puts("\n");
    m.console.puts("resources: windows=");
    m.console.print_u64(@intCast(driving_award.count()));
    m.console.puts("/");
    m.console.print_u64(@intCast(driving_award.max_windows));
    m.console.puts("\n");
    m.console.puts("resources: tables=");
    m.console.print_u64(@intCast(mmu.tables_used()));
    m.console.puts("/");
    m.console.print_u64(@intCast(mmu.tables_capacity()));
    m.console.puts("\n");
    m.console.puts("resources: events=");
    m.console.print_u64(@intCast(events.max_events));
    m.console.puts(" mbox=");
    m.console.print_u64(@intCast(mailbox.max_messages));
    m.console.puts(" fds=");
    m.console.print_u64(@intCast(file_table.max_handles_per_process));
    m.console.puts(" timers=1 tcp=1\n");
    // Arc5 issue #246: per-process resource usage vs limits
    var id: usize = 0;
    while (id < process.max_processes) : (id += 1) {
        if (process.getrusage(id)) |ru| {
            if (ru.mem_limit != 0 or ru.cpu_limit != 0 or ru.mem_usage != 0 or ru.cpu_usage != 0) {
                m.console.puts("resources: pid=");
                m.console.print_u64(@intCast(id));
                const info = process.info(id).?;
                m.console.puts(" ");
                m.console.print_line(info.name);
                m.console.puts("  mem=");
                m.console.print_u64(ru.mem_usage);
                m.console.puts("/");
                if (ru.mem_limit != 0) {
                    m.console.print_u64(ru.mem_limit);
                } else {
                    m.console.puts("unlimited");
                }
                m.console.puts(" cpu=");
                m.console.print_u64(ru.cpu_usage);
                m.console.puts("/");
                if (ru.cpu_limit != 0) {
                    m.console.print_u64(ru.cpu_limit);
                } else {
                    m.console.puts("unlimited");
                }
                m.console.puts("\n");
            }
        }
    }
    return .none;
}

// ---------------------------------------------------------------------------
// Uaccess diagnostic command (claim 6120)
// ---------------------------------------------------------------------------

/// Prove both uaccess paths on live hardware: the validated copy from the
/// user text aperture succeeds, and a raw copy from an unmapped address
/// above the identity blanket takes a REAL EL1 data abort that the
/// exception path recovers into EFAULT (recoveries >= 1). Honest on host
/// test processes (no vectors): `recovered=0` there. Gates on the real
/// recovery count, so the class-B gate can assert `recovered=1` exactly
/// when it drives this command once.
fn cmd_uaccess(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    const d = uaccess.diag();
    m.console.puts("uaccess: valid=");
    m.console.print_u64(if (d.valid_copy) 1 else 0);
    m.console.puts(" fault=");
    m.console.print_u64(if (d.fault_copy) 1 else 0);
    m.console.puts(" recovered=");
    m.console.print_u64(d.recoveries);
    m.console.puts(" copies=");
    m.console.print_u64(d.copies);
    m.console.puts(" validation_faults=");
    m.console.print_u64(d.validation_faults);
    m.console.puts("\n");
    return .none;
}

// ---------------------------------------------------------------------------
// Randomness command (milestone four, claim 2665)
// ---------------------------------------------------------------------------

/// Print `n` (1..256, default 16) random bytes from the seeded CSPRNG as
/// lowercase hex on one grep-able line: `random: n=<count> hex=<2n hex>`.
/// The CSPRNG is seeded at boot from the REAL virtio entropy device; the
/// class-B gate proves the real path by requiring two boots to produce
/// different output.
fn cmd_random(m: *Monitor, args: []const []const u8) ExecError {
    var count: usize = 16; // fixed-size sample when no argument
    if (args.len == 1) {
        count = @intCast(parseInt(args[0]) catch {
            m.console.puts("random: invalid count: ");
            m.console.puts(args[0]);
            m.console.puts("\n");
            return .invalid_argument;
        });
        if (count < 1 or count > random_max_bytes) {
            m.console.puts("random: count must be between 1 and ");
            m.console.print_u64(random_max_bytes);
            m.console.puts("\n");
            return .invalid_argument;
        }
    }
    var buf: [random_max_bytes]u8 = undefined;
    csprng.random_bytes(buf[0..count]);
    m.console.puts("random: n=");
    m.console.print_u64(count);
    m.console.puts(" hex=");
    const hex = "0123456789abcdef";
    var i: usize = 0;
    while (i < count) : (i += 1) {
        m.console.putc(hex[@as(usize, buf[i] >> 4)]);
        m.console.putc(hex[@as(usize, buf[i] & 0xf)]);
    }
    m.console.puts("\n");
    return .none;
}

// ---------------------------------------------------------------------------
// PCI enumeration command (macOS 27 custom-virtio spike, audit step 3)
// ---------------------------------------------------------------------------

/// Live bus-0 PCI enumeration through the ECAM window discovered pre-exit
/// (claim 0013). Post-exit ECAM reads work — the virtio console transport
/// does config-space reads post-MMU (claims 1517/6684); the historical
/// "pre-exit only" note predates the T0SZ=16 + TLBI fix. Aligned u32 reads
/// only (claim 0013: byte reads of config space return shifted/garbage
/// fields on VZ). This is the guest-side evidence for the custom virtio
/// spike device at DID 0x1082 (deviceID 0x42; host runner: `zig build
/// spike-virtio`).
fn cmd_pci(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    const ecam = pci.pci_ecam;
    m.console.puts("pci: ecam=");
    m.console.print_hex(ecam);
    m.console.puts("\n");
    if (ecam == 0 or ecam > 4 * 1024 * 1024 * 1024) {
        m.console.print_line("pci: no ECAM (not discovered pre-exit)");
        return .none;
    }
    var found: usize = 0;
    var dev: u32 = 0;
    while (dev < 32 and found < 48) : (dev += 1) {
        var func: u32 = 0;
        var funcs: u32 = 1;
        while (func < funcs and found < 48) : (func += 1) {
            const id = pci.pci_read32(ecam, 0, dev, func, 0);
            const vid = id & 0xffff;
            if (vid == 0xffff) continue;
            const hdr = pci.pci_read32(ecam, 0, dev, func, 0x0c);
            const ht = (hdr >> 8) & 0xff;
            if (func == 0 and (ht & 0x80) != 0) funcs = 8;
            const did = id >> 16;
            m.console.puts("PCI D=");
            m.console.print_hex(@intCast(dev));
            m.console.puts(" F=");
            m.console.print_hex(@intCast(func));
            m.console.puts(" VID=");
            m.console.print_hex(vid);
            m.console.puts(" DID=");
            m.console.print_hex(did);
            m.console.puts(" CLS=");
            m.console.print_hex((pci.pci_read32(ecam, 0, dev, func, 8) >> 8) & 0xffffff);
            var b: u32 = 0;
            while (b < 6) : (b += 1) {
                m.console.puts(" B");
                m.console.print_hex(@intCast(b));
                m.console.puts("=");
                m.console.print_hex(pci.pci_read32(ecam, 0, dev, func, 0x10 + b * 4));
            }
            m.console.puts("\n");
            found += 1;
        }
    }
    m.console.puts("pci: found=");
    m.console.print_hex(@intCast(found));
    m.console.puts("\n");
    return .none;
}

// ---------------------------------------------------------------------------
// Exception-vector diagnostic command (claim 9746)
// ---------------------------------------------------------------------------

/// Deliberately trigger a synchronous exception (`udf`) with the resume
/// flag armed: the kernel's exception handler (installed at boot, claim
/// 9746) reports the fault, skips the faulting instruction, and the shell
/// resumes. Gates on `exceptions.installed()` — a host test process has no
/// vectors (even on an aarch64 host, where executing `udf` would SIGILL),
/// so the command honestly reports that instead.
fn cmd_fault(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    if (!exceptions.installed()) {
        m.console.print_line("fault: exception vectors not installed; nothing to trigger");
        return .not_implemented;
    }
    m.console.print_line("fault: triggering udf (synchronous exception)...");
    exceptions.trigger_test_fault();
    m.console.print_line("fault: handled, resumed after faulting instruction");
    return .none;
}

fn cmd_elephant(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    for (elephant_lines()) |line| m.console.print_line(line);
    m.console.print_line("ELEPHANT ONLINE");
    print_plain_field(m, "trunk", "up");
    m.console.puts("\n");
    print_plain_field(m, "ears", "floppy");
    m.console.puts("\n");
    print_plain_field(m, "console", m.state.console_name);
    m.console.puts("\n");
    const err = handoff.validate(&m.state.handoff);
    if (err == .none) {
        print_plain_field(m, "handoff", "valid");
    } else {
        m.console.puts("  handoff: invalid (");
        m.console.puts(handoff.error_name(err));
        m.console.puts(")");
    }
    m.console.puts("\n");
    print_plain_field(m, "memory", "descriptors=");
    m.console.print_hex(@intCast(m.state.map.count));
    m.console.puts("\n");
    return .none;
}

fn cmd_beans(m: *Monitor, args: []const []const u8) ExecError {
    var count: u64 = 42;
    if (args.len == 1) {
        count = parseInt(args[0]) catch {
            err_prefix(m);
            m.console.puts("beans: invalid count: ");
            m.console.puts(args[0]);
            m.console.puts("\n");
            return .invalid_argument;
        };
        if (count < 1 or count > beans_max_count) {
            err_prefix(m);
            m.console.puts("beans: count must be between 1 and ");
            m.console.print_u64(beans_max_count);
            m.console.puts("\n");
            return .invalid_argument;
        }
    }
    m.console.print_line("beans");
    m.console.puts("counting beans... ");
    m.console.print_u64(count);
    m.console.print_line(" beans in a trench coat.");
    m.console.print_line("that's it. that's the command.");
    return .none;
}

// ---------------------------------------------------------------------------
// Boot-message personality and banner (step 18)
// ---------------------------------------------------------------------------

pub const BootMessages = struct {
    /// Runtime-built message table into module storage (not a const array
    /// of string slices: those hold link-time absolute pointers, wrong at
    /// the kernel's runtime load base — claim 0015 root cause).
    var storage: [6][]const u8 = undefined;
    var ready = false;
    pub fn messages() []const []const u8 {
        if (!ready) {
            storage[0] = "DipshitOS: the elephant has left the building.";
            storage[1] = "DipshitOS: 42 beans, zero dignity.";
            storage[2] = "DipshitOS: memory is a map, not a territory.";
            storage[3] = "DipshitOS: no libc was harmed in the making of this kernel.";
            storage[4] = "DipshitOS: terminal loop, meet the monitor.";
            storage[5] = "DipshitOS: from scratch, with love and beans.";
            ready = true;
        }
        return &storage;
    }

    /// Deterministic, stateless "rotation": the choice depends only on the
    /// boot's image handle, so it is stable within a boot, varies across
    /// boots, and needs no hidden mutable state.
    pub fn pick(image_handle: u64) []const u8 {
        const msgs = messages();
        return msgs[@as(usize, @intCast(image_handle % msgs.len))];
    }
};

/// Banner text the later shell-core stream prints at boot. Deliberately
/// does not print "DIPSHITOS 0.1" (the repository defines no release
/// number) or a hardcoded "256 MiB detected" (memory must be derived from
/// the captured map — `mem` does exactly that).
/// Arc5 #244: read /data/SHUTDOWN.TXT and print the last shutdown reason
/// on boot. Silent no-op when the file is absent or empty.
fn show_last_shutdown(m: *Monitor) void {
    const ops = virtio_blk.disk_ops();
    if (fat.mount_data(ops) != .ok) return;
    var file_buf: [256]u8 = undefined;
    const n = fat.read_file("SHUTDOWN.TXT", &file_buf);
    _ = esp.set_disk(ops);
    if (n == null) return;
    const bytes = file_buf[0..n.?];
    // Extract the Reason: line if present
    var found_reason = false;
    var pos: usize = 0;
    while (pos < bytes.len) {
        var end = pos;
        while (end < bytes.len and bytes[end] != '\n') : (end += 1) {}
        const line = file_buf[pos..end];
        if (std.mem.startsWith(u8, line, "Reason: ")) {
            m.console.puts("Last shutdown: ");
            m.console.print_line(line[8..]);
            found_reason = true;
            break;
        }
        pos = end + 1;
    }
    if (!found_reason and bytes.len > 0) {
        m.console.print_line("Last shutdown: unknown (marker present)");
    }
}

pub fn banner(m: *Monitor) void {
    m.console.print_line("DipshitOS - AArch64 firmware-assisted kernel monitor");
    m.console.puts(BootMessages.pick(m.state.handoff.image_handle));
    m.console.puts("\n");
    m.console.print_line("motd: aarch64 el1 kernel live; scheduler, uaccess, fs, net, gfx, xhci armed.");
    // Arc5 #244: display last shutdown reason on boot if SHUTDOWN.TXT exists
    show_last_shutdown(m);
    m.console.print_line("Type 'help' before touching anything expensive.");
}

// ===========================================================================
// Tests (host-side; no hardware, no Virtualization.framework)
// ===========================================================================

fn make_handoff() handoff.HandoffV2 {
    return .{
        .magic = handoff.magic,
        .version = handoff.version,
        .kernel_base = 0x7e4df000,
        .kernel_size = 0x823e8,
        .system_table = 0xfeed000,
        .image_handle = 0x2,
        .stack_base = 0x7e520000,
        .stack_size = handoff.expected_stack_size,
        .flags = 0,
    };
}

const MapFixture = struct {
    descriptors: [6]memmap.MemoryDescriptor,
    view: memmap.MapView,

    fn init() MapFixture {
        var f: MapFixture = undefined;
        f.descriptors = .{
            .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 960, .attribute = 0 },
            .{ .type = .loader_code, .physical_start = 0x7000000, .virtual_start = 0, .number_of_pages = 64, .attribute = 0 },
            .{ .type = .boot_services_data, .physical_start = 0x8000000, .virtual_start = 0, .number_of_pages = 128, .attribute = 0 },
            .{ .type = .runtime_services_data, .physical_start = 0x9000000, .virtual_start = 0, .number_of_pages = 8, .attribute = 0 },
            .{ .type = .memory_mapped_io, .physical_start = 0x1000000, .virtual_start = 0, .number_of_pages = 16, .attribute = 0 },
            .{ .type = .reserved_memory_type, .physical_start = 0x1ff00000, .virtual_start = 0, .number_of_pages = 1, .attribute = 0 },
        };
        f.view = memmap.MapView.init(std.mem.asBytes(&f.descriptors), @sizeOf(memmap.MemoryDescriptor), f.descriptors.len);
        f.view.key = 0x42;
        f.view.descriptor_version = 2;
        return f;
    }
};

const TestEnv = struct {
    // 8192: the `help` listing of the full command registry (46 commands,
    // milestone fifteen card A1 added `sound`) must fit with its footer.
    mock: console.MockConsole(8192) = .{},
    machine: MockMachineControl = .{},
    fixture: MapFixture = undefined,

    fn init() TestEnv {
        var env = TestEnv{};
        env.fixture = MapFixture.init();
        return env;
    }

    fn monitor(self: *TestEnv) Monitor {
        return Monitor.init(
            self.mock.console(),
            .{ .handoff = make_handoff(), .map = self.fixture.view, .console_name = "mock" },
            self.machine.control(),
        );
    }
};

fn test_syscall_writer(_: []const u8) void {}

test "monitor: command lookup" {
    try std.testing.expect(lookup("echo") != null);
    try std.testing.expectEqualStrings("echo", lookup("echo").?.name);
    try std.testing.expect(lookup("beans") != null);
    try std.testing.expect(lookup("help") != null);
    try std.testing.expect(lookup("frobnicate") == null);
}

test "monitor: tab completion completes command names and sub-verbs (ADR 0008 D2)" {
    // Unique command-name completion: "ver" -> "sion".
    try std.testing.expectEqualStrings("sion", complete("ver", 3).?);
    // Ambiguous command prefix: "s" matches several commands -> null.
    try std.testing.expect(complete("s", 1) == null);
    // No match -> null.
    try std.testing.expect(complete("zz", 2) == null);
    // Sub-verb completion on the second token: "net t" -> "cp".
    try std.testing.expectEqualStrings("cp", complete("net t", 5).?);
    // "text c" -> "lear" (clear); a sub-verb with no match -> null.
    try std.testing.expectEqualStrings("lear", complete("text c", 6).?);
    try std.testing.expect(complete("dui z", 5) == null);
    // `help <topic>` completes against the topic pages.
    try std.testing.expectEqualStrings("etworking", complete("help n", 6).?);
    // Empty token -> null.
    try std.testing.expect(complete("", 0) == null);
}

test "monitor: mbox dumps pending messages and drain counters" {
    // Card 3f (claim 5965): the `mbox [<pid>]` monitor view. Rings are
    // seeded directly here (the live send/recv flow is the class-B gate);
    // the dump proves pending depth, the sent/recv drain counters, the
    // single-pid view, and the exact refusals.
    mailbox.init();
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expect(lookup("mbox") != null);
    try std.testing.expectEqualStrings("per-process IPC mailbox: pending messages and drain counters", lookup("mbox").?.help);
    // The pids are whatever `process.create` returns (earlier tests may
    // already occupy low ids — never assume a fixed pid).
    const counter_pid = process.create("COUNTER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    const peer_pid = process.create("PEER.BIN", .{ .entry_va = 0x400000, .content_len = 64 }, .{}, .{}).?;
    _ = mailbox.send(counter_pid, "ipc: ping 1\n");
    _ = mailbox.send(counter_pid, "ipc: ping 2\n");
    _ = mailbox.send(peer_pid, "ipc: ping 3\n");
    mailbox.drop(peer_pid); // the peer consumed one: recv=1
    _ = mailbox.send(peer_pid, "ipc: ping 4\n"); // then a fresh send: sent=2, pending=1
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"mbox"}));
    const out = env.mock.contents();
    const counter_row = std.fmt.allocPrint(std.testing.allocator, "mbox: id={d} name=COUNTER.BIN pending=2 sent=2 recv=0\n", .{counter_pid}) catch unreachable;
    defer std.testing.allocator.free(counter_row);
    const peer_row = std.fmt.allocPrint(std.testing.allocator, "mbox: id={d} name=PEER.BIN pending=1 sent=2 recv=1\n", .{peer_pid}) catch unreachable;
    defer std.testing.allocator.free(peer_row);
    try std.testing.expect(std.mem.indexOf(u8, out, counter_row) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "mbox:   0: ipc: ping 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "mbox:   1: ipc: ping 2\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, peer_row) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "mbox:   0: ipc: ping 4\n") != null);
    // Single-pid view.
    env.mock.reset();
    const single_arg = std.fmt.allocPrint(std.testing.allocator, "{d}", .{counter_pid}) catch unreachable;
    defer std.testing.allocator.free(single_arg);
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "mbox", single_arg }));
    const single = env.mock.contents();
    // The single-pid view prints exactly the counter's row (the same
    // formatted row asserted above) and nothing for the peer.
    try std.testing.expect(std.mem.indexOf(u8, single, counter_row) != null);
    try std.testing.expect(std.mem.indexOf(u8, single, "name=PEER.BIN") == null);
    // Unknown and malformed pids refuse exactly.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "mbox", "7" }));
    try std.testing.expectEqualStrings("error: mbox: no such process: 7\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "mbox", "nope" }));
    try std.testing.expectEqualStrings("error: mbox: invalid pid: nope\n", env.mock.contents());
}

test "monitor: registry is well-formed" {
    const reg = ensure_registry();
    try std.testing.expect(reg.len >= 10);
    for (reg, 0..) |cmd, index| {
        try std.testing.expect(cmd.name.len > 0);
        try std.testing.expect(cmd.help.len > 0);
        try std.testing.expect(cmd.usage.len > 0);
        try std.testing.expect(cmd.min_args <= cmd.max_args);
        try std.testing.expect(cmd.max_args <= max_args_limit);
        for (reg[0..index]) |other| {
            try std.testing.expect(!std.mem.eql(u8, cmd.name, other.name));
        }
    }
}

test "monitor: every misusable command prints exactly the D3 misuse shape (registry walk)" {
    // ADR 0008 D3: misuse is `usage: <cmd> <args>` PLUS a one-line hint,
    // and "a new command that prints a fourth shape fails CI". A curated
    // list of commands cannot enforce that — a command added later would
    // simply not be on it. This walks the registry instead, so the
    // enforcement covers every present and future command.
    //
    // Only INVALID arities are fed: `exec` checks arity before dispatch, so
    // no handler body runs and the walk has no side effects.
    var env = TestEnv.init();
    var mon = env.monitor();
    const filler = [_][]const u8{ "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0", "0" };
    var argv_buf: [max_args_limit + 2][]const u8 = undefined;
    var checked: usize = 0;
    for (ensure_registry()) |*cmd| {
        // Too FEW arguments (only possible when the command requires some).
        if (cmd.min_args > 0) {
            env.mock.reset();
            argv_buf[0] = cmd.name;
            try std.testing.expectEqual(ExecError.usage, exec(&mon, argv_buf[0..1]));
            try expectMisuseShape(env.mock.contents(), cmd);
            checked += 1;
        }
        // Too MANY arguments (only possible below the global token limit).
        if (cmd.max_args < max_args_limit) {
            env.mock.reset();
            argv_buf[0] = cmd.name;
            const extra = @as(usize, cmd.max_args) + 1;
            for (0..extra) |i| argv_buf[1 + i] = filler[i];
            try std.testing.expectEqual(ExecError.usage, exec(&mon, argv_buf[0 .. 1 + extra]));
            try expectMisuseShape(env.mock.contents(), cmd);
            checked += 1;
        }
    }
    // The walk is only evidence if it actually exercised commands.
    try std.testing.expect(checked >= 20);
}

/// Assert one misuse transcript is EXACTLY shape 1: the registry's usage
/// line, then the registry's blurb as the hint, and nothing else.
fn expectMisuseShape(out: []const u8, cmd: *const Command) !void {
    var buf: [1024]u8 = undefined;
    const expected = try std.fmt.bufPrint(&buf, "usage: {s}\n{s}\n", .{ cmd.usage, cmd.help });
    try std.testing.expectEqualStrings(expected, out);
}

test "monitor: every REFUSAL wears a D3 shape (registry x garbage argv)" {
    // ADR 0008 D3's CI clause: "a new command that prints a fourth shape
    // fails CI". A no-panic fuzz cannot enforce that, and a curated list of
    // commands silently exempts whatever is added next -- which is how
    // `mbox` (claim 5965, added after U3's sweep) came to print a bare
    // `mbox: invalid pid: ...` line. This walks the registry with garbage
    // argv and shape-checks EVERY line of output from any invocation that
    // actually refused. Invocations that succeed are skipped: an honest
    // STATUS report is not a D3 shape and is not meant to be.
    var env = TestEnv.init();
    var mon = env.monitor();
    // Side-effecting commands are excluded by name: they reboot, spawn,
    // write, or consume entropy rather than refuse.
    const skip = [_][]const u8{
        "reboot", "shutdown", "spawn",  "kill", "exec", "write",
        "mount",  "fault",    "random", "time",
    };
    const garbage = [_][]const u8{ "zzz", "-1", "0x", "99999999999999999999", "" };
    var refusals: usize = 0;
    for (ensure_registry()) |*cmd| {
        var skipped = false;
        for (skip) |s| {
            if (std.mem.eql(u8, s, cmd.name)) skipped = true;
        }
        if (skipped) continue;
        for (garbage) |g| {
            var argv: [3][]const u8 = .{ cmd.name, g, g };
            const n: usize = if (cmd.max_args >= 2) 3 else if (cmd.max_args >= 1) 2 else 1;
            env.mock.reset();
            const rc = exec(&mon, argv[0..n]);
            if (rc == .none) continue;
            refusals += 1;
            var it = std.mem.splitScalar(u8, env.mock.contents(), '\n');
            while (it.next()) |line| {
                if (line.len == 0) continue;
                const ok = std.mem.startsWith(u8, line, "usage: ") or
                    std.mem.startsWith(u8, line, "error: ") or
                    std.mem.startsWith(u8, line, "unknown command '") or
                    std.mem.eql(u8, line, cmd.help); // the shape-1 hint line
                if (!ok) {
                    std.debug.print("non-D3 line from `{s} {s}`: {s}\n", .{ cmd.name, g, line });
                    return error.FourthShape;
                }
            }
        }
    }
    try std.testing.expect(refusals >= 10);
}

test "monitor: dispatch-level refusals wear a sanctioned D3 prefix" {
    // The shell's own diagnostics are not exempt from D3: an empty line and
    // an over-long argv are failures, so they take shape 2 rather than a
    // bare sentence (which is what a fourth shape looks like in practice).
    var env = TestEnv.init();
    var mon = env.monitor();
    env.mock.reset();
    try std.testing.expectEqual(ExecError.usage, exec(&mon, &.{}));
    try std.testing.expectEqualStrings("error: no command given; type 'help' for a list of commands\n", env.mock.contents());
    env.mock.reset();
    var many: [max_args_limit + 2][]const u8 = undefined;
    for (&many) |*slot| slot.* = "x";
    try std.testing.expectEqual(ExecError.usage, exec(&mon, many[0..]));
    try std.testing.expectEqualStrings("error: too many arguments (max 17 tokens)\n", env.mock.contents());
}

test "monitor: help listing is generated from the registry" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"help"}));
    const out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "available commands:") != null);
    for (ensure_registry()) |cmd| {
        try std.testing.expect(std.mem.indexOf(u8, out, cmd.name) != null);
        try std.testing.expect(std.mem.indexOf(u8, out, cmd.help) != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, out, "type 'help <command>' for details on a single command.") != null);
}

test "monitor: help for a specific command" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "help", "echo" }));
    try std.testing.expectEqualStrings("echo - repeat your regrettable decisions\nusage: echo <text...>\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "help", "bogus" }));
    try std.testing.expectEqualStrings("error: no such command or topic: bogus\n", env.mock.contents());
}

test "monitor: help opens topic pages (and commands win over topics)" {
    var env = TestEnv.init();
    var mon = env.monitor();
    // Each documented topic opens its page, headered by the topic name.
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "help", "networking" }));
    try std.testing.expect(std.mem.startsWith(u8, env.mock.contents(), "networking\n"));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "virtio-net (DID 0x1041)") != null);
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "help", "windows" }));
    try std.testing.expect(std.mem.startsWith(u8, env.mock.contents(), "windows\n"));
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "help", "storage" }));
    try std.testing.expect(std.mem.startsWith(u8, env.mock.contents(), "storage\n"));
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "help", "graphics" }));
    try std.testing.expect(std.mem.startsWith(u8, env.mock.contents(), "graphics\n"));
    // `syscalls` and `input` are commands, not topics: their detail wins.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "help", "syscalls" }));
    try std.testing.expect(std.mem.startsWith(u8, env.mock.contents(), "syscalls - "));
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "help", "input" }));
    try std.testing.expect(std.mem.startsWith(u8, env.mock.contents(), "input - "));
}

test "monitor: help listing is grouped by category in the ADR 0008 order" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"help"}));
    const out = env.mock.contents();
    // Group headers appear in the fixed D1 order.
    var prev: usize = 0;
    for (category_order) |cat| {
        // Headers sit at the start of a line; a bare substring search would
        // collide with help text (e.g. "system" inside `about`), so anchor on
        // the newline before and after the header.
        var buf: [32]u8 = undefined;
        const needle = std.fmt.bufPrint(&buf, "\n{s}\n", .{category_name(cat)}) catch unreachable;
        const idx = std.mem.indexOf(u8, out, needle) orelse
            return error.TestExpectedEqual;
        try std.testing.expect(idx >= prev);
        prev = idx;
    }
    // The footer still names the topic surface.
    try std.testing.expect(std.mem.indexOf(u8, out, "type 'help <topic>' for a topic page") != null);
}

test "monitor: pci command reports no-ECAM honestly" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"pci"}));
    const out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "pci: ecam=0x0000000000000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pci: no ECAM") != null);
}

test "monitor: unknown command is diagnosed" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.unknown_command, exec(&mon, &.{"frobnicate"}));
    try std.testing.expectEqualStrings("unknown command 'frobnicate' -- try 'help'\n", env.mock.contents());
}

test "monitor: empty and over-long argv" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.usage, exec(&mon, &.{}));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "no command given") != null);
}

test "monitor: argument-count validation" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.usage, exec(&mon, &.{"hex"}));
    try std.testing.expectEqualStrings("usage: hex <number>...\nformat an integer in hexadecimal\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.usage, exec(&mon, &.{"repeat"}));
    try std.testing.expectEqualStrings("usage: repeat <count> <text...>\nrepeat text, safely bounded\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.usage, exec(&mon, &.{ "beans", "1", "2" }));
    try std.testing.expectEqualStrings("usage: beans [count]\ncount beans, probably\n", env.mock.contents());
}

// Monitor-test mock transport for the armed netsend path (the virtio_net
// module's own tests cover the same path with their fuller mock; here the
// fake device completes every TX by advancing the driver's real used ring
// on the kick, so the full build -> submit -> drain -> report shape runs on
// the host).
fn mnet_dev_read32(_: u32) u32 {
    return 0;
}
fn mnet_cfg_read8(_: u32) u8 {
    return 0;
}
fn mnet_cfg_read16(_: u32) u16 {
    return 0;
}
fn mnet_cfg_read32(_: u32) u32 {
    return 0;
}
fn mnet_cfg_write8(_: u32, _: u8) void {}
fn mnet_cfg_write16(_: u32, _: u16) void {}
fn mnet_cfg_write32(_: u32, _: u32) void {}
fn mnet_notify(_: u16) void {
    // The fake device completes the TX: advance the driver's real used
    // ring so the drain poll sees the completion.
    virtio_net.net_dev.tx_used.idx +%= 1;
}
fn mnet_to_phys(va: usize) u64 {
    return va; // host test: identity
}
fn mnet_clean(_: usize, _: usize) void {}
fn mnet_invalidate(_: usize, _: usize) void {}

fn mnet_ops() virtio_net.Ops {
    return .{
        .dev_read32 = mnet_dev_read32,
        .cfg_read8 = mnet_cfg_read8,
        .cfg_read16 = mnet_cfg_read16,
        .cfg_read32 = mnet_cfg_read32,
        .cfg_write8 = mnet_cfg_write8,
        .cfg_write16 = mnet_cfg_write16,
        .cfg_write32 = mnet_cfg_write32,
        .notify = mnet_notify,
        .to_phys = mnet_to_phys,
        .clean = mnet_clean,
        .invalidate = mnet_invalidate,
    };
}

test "monitor: net reports no device honestly when the transport is absent" {
    var env = TestEnv.init();
    var mon = env.monitor();
    virtio_net.net_ready = false;
    virtio_net.net_devcfg_mac_seen = false;
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"net"}));
    try std.testing.expectEqualStrings(
        "net: no virtio-net device (DID 0x1041 not found on bus 0)\n" ++
            "net: device-features=0x0000000000000000/0x0000000000000000\n" ++
            "net: status=0x00000000000000ff accepted=0x0000000000000000/0x0000000000000000\n" ++
            "net: common=0x0000000000000000 notify=0x0000000000000000 devcfg=0x0000000000000000 bar0=0x0000000000000000\n",
        env.mock.contents(),
    );
    // `net` is registered (the prompt's registry-row shape).
    try std.testing.expect(lookup("net") != null);
    try std.testing.expectEqualStrings("virtio-net transport + RX + ARP + ICMP + UDP + DHCP + TCP + DNS: device DID, MAC, queues, feature bits, RX counters ('net recv' prints received frames; 'net ip <a.b.c.d>' sets the static IP; 'net arp [<a.b.c.d>]' shows/resolves the ARP table; 'net ping <a.b.c.d>' sends an ICMP echo request; 'net udp [listen <port>|close <port>|send <addr> <port> <len>|recv [<port>]]' drives UDP; 'net dhcp' runs the bounded DHCP client one step per invocation; 'net tcp [connect <addr> <port>|send <len>|recv|close|reset]' drives the bounded TCP client; 'net dns <hostname> [<server>]' resolves DNS A-records)", lookup("net").?.help);
    try std.testing.expect(lookup("netsend") != null);
}

test "monitor: screen reports no device honestly when the transport is absent" {
    var env = TestEnv.init();
    var mon = env.monitor();
    virtio_gpu.gpu_ready = false;
    virtio_gpu.gpu_fail = "";
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"screen"}));
    try std.testing.expectEqualStrings(
        "screen: no virtio-gpu device (DID 0x1050 not found on bus 0)\n" ++
            "screen: device-features=0x0000000000000000/0x0000000000000000\n" ++
            "screen: status=0x00000000000000ff accepted=0x0000000000000000/0x0000000000000000\n" ++
            "screen: common=0x0000000000000000 notify=0x0000000000000000 devcfg=0x0000000000000000 bar0=0x0000000000000000\n",
        env.mock.contents(),
    );
    // `screen fill` is refused honestly with no transport.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "screen", "fill", "0x112233" }));
    try std.testing.expectEqualStrings("error: transport not ready (no virtio-gpu device)\n", env.mock.contents());
    // An out-of-range color is refused honestly even before the transport
    // check.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "screen", "fill", "0x1000000" }));
    try std.testing.expectEqualStrings("error: color out of range (max 0xffffff)\n", env.mock.contents());
    // `screen` is registered (the registry-row shape).
    try std.testing.expect(lookup("screen") != null);
    try std.testing.expectEqualStrings("virtio-gpu transport + framebuffer: device DID, features, scanout, status, re-arm ('screen fill <rrggbb>' fills the framebuffer and flushes it to the scanout)", lookup("screen").?.help);
}

test "monitor: text reports the region and refuses put/clear without the transport" {
    var env = TestEnv.init();
    var mon = env.monitor();
    virtio_gpu.gpu_ready = false;
    // The report is device-independent: it names the region + cursor.
    fbtext.init();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"text"}));
    try std.testing.expectEqualStrings(
        "text: rows=90 cols=160 cell=8x8 cur=0,0 lines=0 fg=0x000000000000ff00 bg=0x0000000000101418\n",
        env.mock.contents(),
    );
    // `text put` / `text clear` are refused honestly with no transport.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "text", "put", "hello" }));
    try std.testing.expectEqualStrings("error: transport not ready (no virtio-gpu device)\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "text", "clear" }));
    try std.testing.expectEqualStrings("error: transport not ready (no virtio-gpu device)\n", env.mock.contents());
    // An unknown subcommand is refused honestly.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.usage, exec(&mon, &.{ "text", "bogus" }));
    // `text` is registered (the registry-row shape).
    try std.testing.expect(lookup("text") != null);
    try std.testing.expectEqualStrings("framebuffer text: text region, cursor, scrollback ('text put <string...>' renders + flushes to the scanout; 'text clear' clears; 'text putraw' skips the trailing newline; 'text fontdebug [on|off]' missing-glyph stats)", lookup("text").?.help);
}

test "monitor: roadpops reports the tee state honestly" {
    var env = TestEnv.init();
    var mon = env.monitor();
    // The global tee is unarmed in host tests → serial-only degradation
    // (the default VM's behavior).
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"roadpops"}));
    try std.testing.expectEqualStrings("roadpops: armed=0 dirty=0 presents=0\n", env.mock.contents());
    // `roadpops` is registered (the registry-row shape).
    try std.testing.expect(lookup("roadpops") != null);
    try std.testing.expectEqualStrings("Road Pops framebuffer console: armed/dirty/present counters (the boot terminal on the screen)", lookup("roadpops").?.help);
}

test "monitor: usb reports no device honestly when the XHCI transport is absent" {
    var env = TestEnv.init();
    var mon = env.monitor();
    xhci.xhci_ready = false;
    xhci.xhci_fail = "";
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"usb"}));
    try std.testing.expectEqualStrings("usb: no XHCI device (DID 0x1a06 not found on bus 0)\n", env.mock.contents());
    // `usb` is registered (the registry-row shape).
    try std.testing.expect(lookup("usb") != null);
    try std.testing.expectEqualStrings("XHCI host controller: `usb` transport report, `usb devices` enumerated HID devices, `usb report` last HID report", lookup("usb").?.help);
}

test "monitor: net report shape with an armed transport" {
    var env = TestEnv.init();
    var mon = env.monitor();
    // Populate the driver state as the live init + re-arm would: observed
    // DID 0x1041, class 0x020000, dev 6, the host-set MAC from the feature
    // path, VER1|MAC negotiated, both queues armed, DRIVER_OK (0xf) after
    // the re-arm, one drained TX of 46 bytes.
    virtio_net.net_ready = true;
    virtio_net.net_rearmed = true;
    virtio_net.net_did = 0x1041;
    virtio_net.net_class = 0x020000;
    virtio_net.net_dev_no = 6;
    virtio_net.net_mac = .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    virtio_net.net_mac_source = .feature;
    virtio_net.format_mac(&virtio_net.net_mac, &virtio_net.net_mac_text);
    virtio_net.net_dev.feats_lo = 0x20;
    virtio_net.net_dev.feats_hi = 0x1;
    virtio_net.net_dev.q0_enabled = true;
    virtio_net.net_dev.q1_enabled = true;
    virtio_net.net_status_last = 0xf;
    virtio_net.net_dev.tx_frames = 1;
    virtio_net.net_dev.tx_bytes = 46;
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"net"}));
    const out = env.mock.contents();
    // The grep-able shape the live gate asserts (full 16-digit hex, the
    // mbox/procs observability shape).
    try std.testing.expect(std.mem.indexOf(u8, out, "net: did=0x0000000000001041 class=0x0000000000020000 dev=6\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "net: mac=02:00:00:00:00:01 source=feature\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "net: feat=0x0000000000000020/0x0000000000000001 q0=rx:size=4 q1=tx:size=4\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "net: status=0x000000000000000f rearm=1 tx=frames=1,bytes=46\n") != null);
    // The fallback source is reported honestly too.
    env.mock.reset();
    virtio_net.net_mac_source = .fallback;
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"net"}));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "source=fallback") != null);
    // Card N3: the ARP layer line (static IP + counters) is part of the
    // report — 0.0.0.0 when unset, the counters reported honestly.
    env.mock.reset();
    virtio_net.arp.own_ip = .{ 10, 0, 0, 1 };
    virtio_net.arp.requests_sent = 2;
    virtio_net.arp.replies_sent = 3;
    virtio_net.arp.replies_learned = 1;
    virtio_net.arp.dropped = 4;
    virtio_net.arp.reply_tx_fail = 0;
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"net"}));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "net: ip=10.0.0.1 arp=req=2,repl=3,learn=1,drop=4,fail=0\n") != null);
    virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
    virtio_net.net_ready = false;
}

test "monitor: net ip sets the static address and echoes the marker" {
    var env = TestEnv.init();
    var mon = env.monitor();
    virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "ip", "10.0.0.1" }));
    try std.testing.expectEqualStrings("net ip: ip=10.0.0.1\n", env.mock.contents());
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 0, 0, 1 }, &virtio_net.arp.own_ip);
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "net", "ip", "999.0.0.1" }));
    try std.testing.expectEqualStrings("error: invalid address: 999.0.0.1\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.usage, exec(&mon, &.{ "net", "ip" }));
    try std.testing.expectEqualStrings("usage: net [recv|ip <addr>|arp [<addr>]|ping <addr>|udp [listen <port>|close <port>|send <addr> <port> <len>|recv [<port>]]|dhcp|tcp [connect <addr> <port>|send <len>|recv|close|reset]|dns <host> [<server>]]\nvirtio-net transport + RX + ARP + ICMP + UDP + DHCP + TCP + DNS: device DID, MAC, queues, feature bits, RX counters ('net recv' prints received frames; 'net ip <a.b.c.d>' sets the static IP; 'net arp [<a.b.c.d>]' shows/resolves the ARP table; 'net ping <a.b.c.d>' sends an ICMP echo request; 'net udp [listen <port>|close <port>|send <addr> <port> <len>|recv [<port>]]' drives UDP; 'net dhcp' runs the bounded DHCP client one step per invocation; 'net tcp [connect <addr> <port>|send <len>|recv|close|reset]' drives the bounded TCP client; 'net dns <hostname> [<server>]' resolves DNS A-records)\n", env.mock.contents());
    // The echo line is the live gate's injection trigger marker.
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "ip", "10.0.0.2" }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "net ip: ip=10.0.0.2\n") != null);
    virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
}

test "monitor: net arp prints the table + counters" {
    var env = TestEnv.init();
    var mon = env.monitor();
    virtio_net.net_ready = true;
    virtio_net.rx_armed = false; // the drain is a no-op without a supplied buffer
    virtio_net.arp.table = [_]virtio_net.arp.ArpEntry{.{}} ** virtio_net.arp.table_slots;
    virtio_net.arp.upsert(.{ 10, 0, 0, 2 }, .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x02 });
    virtio_net.arp.requests_sent = 1;
    virtio_net.arp.replies_sent = 0;
    virtio_net.arp.replies_learned = 1;
    virtio_net.arp.dropped = 0;
    virtio_net.arp.reply_tx_fail = 0;
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "arp" }));
    const out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "net arp: entries=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "net arp: 10.0.0.2 -> 02:00:00:00:00:02\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "net arp: req=1,repl=0,learn=1,drop=0,fail=0\n") != null);
    // A table hit reports the peer without sending anything.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "arp", "10.0.0.2" }));
    try std.testing.expectEqualStrings("net arp: 10.0.0.2 is at 02:00:00:00:00:02\n", env.mock.contents());
    virtio_net.net_ready = false;
    virtio_net.arp.table = [_]virtio_net.arp.ArpEntry{.{}} ** virtio_net.arp.table_slots;
}

test "monitor: net arp resolve — miss sends the request, no-IP refuses honestly" {
    var env = TestEnv.init();
    var mon = env.monitor();
    const saved_ops = virtio_net.net_ops;
    virtio_net.net_ops = mnet_ops();
    virtio_net.net_ready = true;
    virtio_net.net_mac = .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    virtio_net.arp.own_ip = .{ 10, 0, 0, 1 };
    virtio_net.arp.table = [_]virtio_net.arp.ArpEntry{.{}} ** virtio_net.arp.table_slots;
    virtio_net.arp.requests_sent = 0;
    virtio_net.net_dev = .{};
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "arp", "10.0.0.2" }));
    try std.testing.expectEqualStrings("net arp: request for 10.0.0.2 sent (42 bytes)\n", env.mock.contents());
    try std.testing.expectEqual(@as(u64, 1), virtio_net.arp.requests_sent);
    // Without a static IP the resolve is refused honestly (no 0.0.0.0
    // sender — we cannot answer for an address we do not own).
    env.mock.reset();
    virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "arp", "10.0.0.3" }));
    try std.testing.expectEqualStrings("error: no IP set (net ip <a.b.c.d> first) or transport unready\n", env.mock.contents());
    try std.testing.expectEqual(@as(u64, 1), virtio_net.arp.requests_sent); // nothing sent
    // Malformed addresses refuse exactly.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "net", "arp", "nope" }));
    try std.testing.expectEqualStrings("error: invalid address: nope\n", env.mock.contents());
    virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
    virtio_net.net_ops = saved_ops;
    virtio_net.net_ready = false;
}

test "monitor: net ping sends an echo request to a resolved peer" {
    var env = TestEnv.init();
    var mon = env.monitor();
    const saved_ops = virtio_net.net_ops;
    virtio_net.net_ops = mnet_ops();
    virtio_net.net_ready = true;
    virtio_net.net_mac = .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    virtio_net.arp.own_ip = .{ 10, 0, 0, 1 };
    virtio_net.arp.table = [_]virtio_net.arp.ArpEntry{.{}} ** virtio_net.arp.table_slots;
    virtio_net.arp.upsert(.{ 10, 0, 0, 2 }, .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x02 });
    virtio_net.ipv4.requests_sent = 0;
    virtio_net.ipv4.ping_seq = 1;
    virtio_net.net_dev = .{};
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "ping", "10.0.0.2" }));
    try std.testing.expectEqualStrings("net ping: echo request to 10.0.0.2 sent (46 bytes)\n", env.mock.contents());
    try std.testing.expectEqual(@as(u64, 1), virtio_net.ipv4.requests_sent);
    try std.testing.expectEqual(@as(u16, 2), virtio_net.ipv4.ping_seq);
    // A peer NOT in the ARP table refuses honestly (an echo needs a
    // unicast dst — `net arp <ip>` resolves first).
    env.mock.reset();
    virtio_net.arp.table = [_]virtio_net.arp.ArpEntry{.{}} ** virtio_net.arp.table_slots;
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "ping", "10.0.0.3" }));
    try std.testing.expectEqualStrings("error: peer not in ARP table (net arp <a.b.c.d> first)\n", env.mock.contents());
    // Without a static IP the ping is refused honestly.
    env.mock.reset();
    virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "ping", "10.0.0.2" }));
    try std.testing.expectEqualStrings("error: no IP set (net ip <a.b.c.d> first) or transport unready\n", env.mock.contents());
    // Malformed addresses refuse exactly.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "net", "ping", "nope" }));
    try std.testing.expectEqualStrings("error: invalid address: nope\n", env.mock.contents());
    virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
    virtio_net.arp.table = [_]virtio_net.arp.ArpEntry{.{}} ** virtio_net.arp.table_slots;
    virtio_net.net_ops = saved_ops;
    virtio_net.net_ready = false;
}

test "monitor: net udp — listen, close, and the report" {
    var env = TestEnv.init();
    var mon = env.monitor();
    virtio_net.udp.reset();
    defer virtio_net.udp.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "udp", "listen", "7000" }));
    try std.testing.expectEqualStrings("net udp: listening on 7000\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "udp" }));
    const out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "net udp: entries=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "net udp: port=7000\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "net udp: rx=0,tx=0,loop=0,drop=0\n") != null);
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "udp", "close", "7000" }));
    try std.testing.expectEqualStrings("net udp: closed 7000\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "udp", "close", "7000" }));
    try std.testing.expectEqualStrings("error: not listening on 7000\n", env.mock.contents());
    // A duplicate listen and a malformed port refuse exactly.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "udp", "listen", "7000" }));
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "udp", "listen", "7000" }));
    try std.testing.expectEqualStrings("error: listen failed (table full or duplicate)\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "net", "udp", "listen", "nope" }));
    try std.testing.expectEqualStrings("error: invalid port: nope\n", env.mock.contents());
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "net", "udp", "listen", "70000" }));
}

test "monitor: net udp send — loopback to our own IP, no device" {
    var env = TestEnv.init();
    var mon = env.monitor();
    virtio_net.udp.reset();
    defer virtio_net.udp.reset();
    virtio_net.arp.own_ip = .{ 10, 0, 0, 1 };
    virtio_net.net_ready = false; // the loopback path must NOT need a device
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "udp", "listen", "7000" }));
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "udp", "send", "10.0.0.1", "7000", "4" }));
    try std.testing.expectEqualStrings("net udp: sent 4 bytes to 10.0.0.1:7000 (12 bytes)\n", env.mock.contents());
    try std.testing.expectEqual(@as(u64, 1), virtio_net.udp.sent);
    try std.testing.expectEqual(@as(u64, 1), virtio_net.udp.loopbacked);
    try std.testing.expectEqual(@as(u64, 1), virtio_net.udp.received);
    // The loopbacked datagram is observable via net udp recv.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "udp", "recv", "7000" }));
    const out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "net udp recv: port=7000\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "net udp recv: [0] len=12\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "1b 58 1b 58 00 0c ") != null); // src 7000, dst 7000, len 12
    // A loopback to a CLOSED port is dropped (counted), never assumed away.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "udp", "send", "10.0.0.1", "9998", "1" }));
    try std.testing.expectEqual(@as(u64, 1), virtio_net.udp.dropped_closed);
    // Without a static IP the send is refused honestly.
    env.mock.reset();
    virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "udp", "send", "10.0.0.2", "9999", "4" }));
    try std.testing.expectEqualStrings("error: no IP set (net ip <a.b.c.d> first) or transport unready\n", env.mock.contents());
    virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
}

test "monitor: net udp send — to a resolved peer on the mock transport" {
    var env = TestEnv.init();
    var mon = env.monitor();
    const saved_ops = virtio_net.net_ops;
    virtio_net.net_ops = mnet_ops();
    virtio_net.net_ready = true;
    virtio_net.net_mac = .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    virtio_net.arp.own_ip = .{ 10, 0, 0, 1 };
    virtio_net.arp.table = [_]virtio_net.arp.ArpEntry{.{}} ** virtio_net.arp.table_slots;
    virtio_net.arp.upsert(.{ 10, 0, 0, 2 }, .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x02 });
    virtio_net.udp.reset();
    defer virtio_net.udp.reset();
    virtio_net.net_dev = .{};
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "udp", "send", "10.0.0.2", "9999", "4" }));
    try std.testing.expectEqualStrings("net udp: sent 4 bytes to 10.0.0.2:9999 (46 bytes)\n", env.mock.contents());
    try std.testing.expectEqual(@as(u64, 1), virtio_net.udp.sent);
    try std.testing.expectEqual(@as(u64, 0), virtio_net.udp.loopbacked);
    // An unresolved peer refuses honestly (an echo/udp needs a unicast dst).
    env.mock.reset();
    virtio_net.arp.table = [_]virtio_net.arp.ArpEntry{.{}} ** virtio_net.arp.table_slots;
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "udp", "send", "10.0.0.3", "9999", "4" }));
    try std.testing.expectEqualStrings("error: peer not in ARP table (net arp <a.b.c.d> first)\n", env.mock.contents());
    // Length bounds refuse exactly.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "net", "udp", "send", "10.0.0.2", "9999", "0" }));
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "net", "udp", "send", "10.0.0.2", "9999", "65" }));
    virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };
    virtio_net.arp.table = [_]virtio_net.arp.ArpEntry{.{}} ** virtio_net.arp.table_slots;
    virtio_net.net_ops = saved_ops;
    virtio_net.net_ready = false;
}

test "monitor: netsend refuses cleanly without a transport" {
    var env = TestEnv.init();
    var mon = env.monitor();
    virtio_net.net_ready = false;
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "netsend", "32" }));
    try std.testing.expectEqualStrings("error: transport not ready (no virtio-net device)\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "netsend", "abc" }));
    try std.testing.expectEqualStrings("error: invalid byte count: abc\n", env.mock.contents());
}

test "monitor: netsend builds + submits a known frame (armed, mock transport)" {
    var env = TestEnv.init();
    var mon = env.monitor();
    const saved_ops = virtio_net.net_ops;
    virtio_net.net_ops = mnet_ops();
    virtio_net.net_ready = true;
    virtio_net.net_mac = .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    // Reset the driver's TX counters/rings so earlier tests' state cannot
    // leak into the exact assertions.
    virtio_net.net_dev = .{};
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "netsend", "32" }));
    const out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "netsend: n=32\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "netsend: tx ok frames=1 bytes=46\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "netsend: sent 46 bytes\n") != null);
    // Over-limit requests truncate honestly at the 1500-byte payload bound.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "netsend", "5000" }));
    const out2 = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out2, "netsend: n=5000 truncated to 1500 (payload bound)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out2, "netsend: tx ok frames=2 bytes=1514\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out2, "netsend: sent 1514 bytes\n") != null);
    virtio_net.net_ops = saved_ops;
    virtio_net.net_ready = false;
}

test "monitor: net recv prints the received frame byte-exact and drains the FIFO" {
    var env = TestEnv.init();
    var mon = env.monitor();
    virtio_net.net_ready = true;
    virtio_net.net_fail = "";
    virtio_net.rx_fifo_head = 0;
    virtio_net.rx_fifo_count = 0;
    // The claim-time RX contract: the OBSERVED 12-byte virtio_net_hdr
    // (all zero except num_buffers=1 at bytes 10-11) + a 46-byte
    // broadcast frame (dst ff*6, src 02:00:00:00:00:01, ethertype 0x0800,
    // payload 00..1f) — the exact layout the class-B gate pins from
    // observation (net recv prints the RAW device-written bytes).
    var frame: [virtio_net.rx_buf_len]u8 = .{0} ** virtio_net.rx_buf_len;
    frame[10] = 0x01; // virtio_net_hdr num_buffers = 1 (observed)
    const dst = [6]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
    const src = [6]u8{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    @memcpy(frame[virtio_net.rx_hdr_len .. virtio_net.rx_hdr_len + 6], &dst);
    @memcpy(frame[virtio_net.rx_hdr_len + 6 .. virtio_net.rx_hdr_len + 12], &src);
    frame[virtio_net.rx_hdr_len + 12] = 0x08;
    frame[virtio_net.rx_hdr_len + 13] = 0x00;
    var i: usize = 0;
    while (i < 32) : (i += 1) frame[virtio_net.rx_hdr_len + 14 + i] = @truncate(i);
    try std.testing.expect(virtio_net.fifo_push(frame[0 .. virtio_net.rx_hdr_len + 46]));
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "recv" }));
    const out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "net recv: frames=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "net recv: [0] len=58\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "net recv: 00 00 00 00 00 00 00 00 00 00 01 00 ff ff ff ff ff ff 02 00 00 00 00 01 08 00 00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10 11 12 13 14 15 16 17 18 19 1a 1b 1c 1d 1e 1f\n") != null);
    // Consumed: the FIFO is empty again (recv drains it).
    try std.testing.expectEqual(@as(usize, 0), virtio_net.fifo_occupancy());
    // Empty case: honest report.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "recv" }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "net recv: frames=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "net recv: no frames (filtered or nothing injected)\n") != null);
    // Unknown subcommand: documented refusal.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.usage, exec(&mon, &.{ "net", "bogus" }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "usage: net [recv|ip <addr>|arp [<addr>]|ping <addr>|udp [listen <port>|close <port>|send <addr> <port> <len>|recv [<port>]]|dhcp|tcp [connect <addr> <port>|send <len>|recv|close|reset]|dns <host> [<server>]]\nvirtio-net transport + RX + ARP + ICMP + UDP + DHCP + TCP + DNS: device DID, MAC, queues, feature bits, RX counters ('net recv' prints received frames; 'net ip <a.b.c.d>' sets the static IP; 'net arp [<a.b.c.d>]' shows/resolves the ARP table; 'net ping <a.b.c.d>' sends an ICMP echo request; 'net udp [listen <port>|close <port>|send <addr> <port> <len>|recv [<port>]]' drives UDP; 'net dhcp' runs the bounded DHCP client one step per invocation; 'net tcp [connect <addr> <port>|send <len>|recv|close|reset]' drives the bounded TCP client; 'net dns <hostname> [<server>]' resolves DNS A-records)\n") != null);
    virtio_net.net_ready = false;
    virtio_net.rx_fifo_head = 0;
    virtio_net.rx_fifo_count = 0;
}

test "monitor: identity commands produce fixed output" {
    var env = TestEnv.init();
    var mon = env.monitor();

    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"version"}));
    try std.testing.expectEqualStrings(
        "dipshit-kernel\nmilestone-two kernel proper (ADR 0004)\nhandoff ABI v2\nbuild label: m1.5 commands & personality (mock console)\n",
        env.mock.contents(),
    );
    env.mock.reset();

    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"uname"}));
    try std.testing.expectEqualStrings("DipshitOS aarch64\nfreestanding kernel; no POSIX compatibility\n", env.mock.contents());
    env.mock.reset();

    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"about"}));
    const out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "from-scratch AArch64 operating system") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "no libc, no POSIX") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Apple Virtualization.framework") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Driving Award") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Type 'help' for the grouped command catalog, or 'welcome' for a tour.") != null);
    env.mock.reset();

    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"welcome"}));
    const tour_out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, tour_out, "Welcome to DipshitOS!") != null);
    try std.testing.expect(std.mem.indexOf(u8, tour_out, "1. Discovery: Type 'help'") != null);
    try std.testing.expect(std.mem.indexOf(u8, tour_out, "docs/") != null);
    env.mock.reset();

    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"tour"}));
    try std.testing.expectEqualStrings(tour_out, env.mock.contents());
    env.mock.reset();

    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"sysinfo"}));
    const sys_out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, sys_out, "sysinfo: DipshitOS AArch64 support snapshot") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys_out, "kernel=dipshit-kernel handoff=v2 status=valid") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys_out, "arch=aarch64") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys_out, "descriptors=") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys_out, "scheduler:") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys_out, "processes:") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys_out, "storage:") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys_out, "network:") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys_out, "graphics:") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys_out, "input:") != null);
    env.mock.reset();

    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"settings"}));
    const set_out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, set_out, "settings:") != null);
    try std.testing.expect(std.mem.indexOf(u8, set_out, "hostname=") != null);
    try std.testing.expect(std.mem.indexOf(u8, set_out, "prompt=") != null);
    env.mock.reset();

    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "settings", "get", "hostname" }));
    try std.testing.expectEqualStrings("settings: hostname=dipshit\n", env.mock.contents());
    env.mock.reset();

    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "settings", "set", "hostname", "testnode" }));
    try std.testing.expectEqualStrings("settings: hostname=testnode (memory only)\n", env.mock.contents());
    env.mock.reset();

    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "settings", "get", "hostname" }));
    try std.testing.expectEqualStrings("settings: hostname=testnode\n", env.mock.contents());
    env.mock.reset();

    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "settings", "reset" }));
    try std.testing.expectEqualStrings("settings: reset to defaults (memory only)\n", env.mock.contents());
    env.mock.reset();
}

test "monitor: handoff formatting is deterministic and validated" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"handoff"}));
    try std.testing.expectEqualStrings(
        "handoff v2\n" ++
            "  magic        0x00000000324b5344\n" ++
            "  version      0x0000000000000002\n" ++
            "  kernel_base  0x000000007e4df000\n" ++
            "  kernel_size  0x00000000000823e8\n" ++
            "  system_table 0x000000000feed000\n" ++
            "  image_handle 0x0000000000000002\n" ++
            "  stack_base   0x000000007e520000\n" ++
            "  stack_size   0x0000000000004000\n" ++
            "  flags        0x0000000000000000\n" ++
            "  status       valid\n",
        env.mock.contents(),
    );

    // A corrupted handoff is reported, not silently trusted.
    const fixture = MapFixture.init();
    var bad = make_handoff();
    bad.magic = 0xdeadbeef;
    var mon2 = Monitor.init(
        env.mock.console(),
        .{ .handoff = bad, .map = fixture.view, .console_name = "mock" },
        env.machine.control(),
    );
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon2, &.{"handoff"}));
    try std.testing.expect(std.mem.endsWith(u8, env.mock.contents(), "  status       invalid (bad magic)\n"));
}

test "monitor: mem summarizes the captured map deterministically" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"mem"}));
    try std.testing.expectEqualStrings(
        "mem: descriptors=0x0000000000000006 size=0x0000000000000028 version=0x0000000000000002 key=0x0000000000000042\n" ++
            "  usable: 0x0000000000480000 bytes (0x0000000000000480 pages)\n" ++
            "  conventional: 0x00000000003c0000 bytes (0x00000000000003c0 pages)\n" ++
            "  loader: 0x0000000000040000 bytes (0x0000000000000040 pages)\n" ++
            "  boot_services: 0x0000000000080000 bytes (0x0000000000000080 pages)\n" ++
            "  runtime: 0x0000000000008000 bytes (0x0000000000000008 pages)\n" ++
            "  reserved: 0x0000000000009000 bytes (0x0000000000000009 pages)\n" ++
            "  mmio: 0x0000000000010000 bytes (0x0000000000000010 pages)\n" ++
            "  kernel: 0x000000007e4df000..0x000000007e5613e8 (0x00000000000823e8 bytes)\n",
        env.mock.contents(),
    );
}

test "monitor: mem handles an overflowing handoff without wrapping" {
    var env = TestEnv.init();
    var bad = make_handoff();
    bad.kernel_base = std.math.maxInt(u64) - 0xfff;
    bad.kernel_size = 0x2000; // base + size overflows u64
    var mon = Monitor.init(
        env.mock.console(),
        .{ .handoff = bad, .map = env.fixture.view, .console_name = "mock" },
        env.machine.control(),
    );
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"mem"}));
    const out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "  kernel: 0xfffffffffffff000..0xffffffffffffffff") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "0x0000000000002000 bytes") != null);
}

test "monitor: echo joins arguments" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "echo", "hello", "world" }));
    try std.testing.expectEqualStrings("hello world\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"echo"}));
    try std.testing.expectEqualStrings("\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "echo", "a", "", "b" }));
    try std.testing.expectEqualStrings("a  b\n", env.mock.contents());
}

test "monitor: clear emits the documented ANSI sequence" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"clear"}));
    try std.testing.expectEqualStrings("\x1b[2J\x1b[H", env.mock.contents());
}

test "monitor: hex parses and formats with explicit errors" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "hex", "255" }));
    try std.testing.expectEqualStrings("0xff\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "hex", "0xff", "0X10", "0" }));
    try std.testing.expectEqualStrings("0xff\n0x10\n0x0\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "hex", "zz" }));
    try std.testing.expectEqualStrings("error: invalid number: zz\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "hex", "-1" }));
    try std.testing.expectEqualStrings("error: invalid number: -1\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "hex", "18446744073709551616" }));
    try std.testing.expectEqualStrings("error: invalid number: 18446744073709551616\n", env.mock.contents());
}

test "monitor: repeat enforces count and byte bounds" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "repeat", "2", "hello", "world" }));
    try std.testing.expectEqualStrings("hello world\nhello world\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "repeat", "1", "x" }));
    try std.testing.expectEqualStrings("x\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "repeat", "0", "x" }));
    try std.testing.expectEqualStrings("error: count must be between 1 and 64\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "repeat", "65", "x" }));
    try std.testing.expectEqualStrings("error: count must be between 1 and 64\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "repeat", "zz", "x" }));
    try std.testing.expectEqualStrings("error: invalid count: zz\n", env.mock.contents());
    env.mock.reset();
    // Count with no text repeats blank lines, deterministically.
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "repeat", "3" }));
    try std.testing.expectEqualStrings("\n\n\n", env.mock.contents());

    // 70-char line: 57 repetitions fit (57*71 = 4047 <= 4096), 58 do not.
    const long = "a" ** 70;
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "repeat", "57", long }));
    try std.testing.expectEqual(@as(usize, 57 * 71), env.mock.contents().len);
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "repeat", "58", long }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "error: output too large (max 4096 bytes)") != null);
}

test "monitor: reboot and shutdown through a mock machine control" {
    var env = TestEnv.init();
    env.machine.reboot_result = .ok;
    env.machine.shutdown_result = .ok;
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"reboot"}));
    try std.testing.expectEqualStrings("reboot: ok\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"shutdown"}));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "shutdown: ok") != null);
    try std.testing.expectEqual(@as(usize, 1), env.machine.reboot_calls);
    try std.testing.expectEqual(@as(usize, 1), env.machine.shutdown_calls);
}

test "monitor: machine control failures are reported honestly" {
    var env = TestEnv.init();
    env.machine.reboot_result = .not_implemented;
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.not_implemented, exec(&mon, &.{"reboot"}));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "reboot: not implemented") != null);
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "no proven post-ExitBootServices machine-control mechanism") != null);

    env.machine.reboot_result = .failed;
    env.mock.reset();
    try std.testing.expectEqual(ExecError.machine_failed, exec(&mon, &.{"reboot"}));
    try std.testing.expectEqualStrings("error: reboot: failed\n", env.mock.contents());
}

test "monitor: disabled machine control is the honest default" {
    var mock = console.MockConsole(4096){};
    const fixture = MapFixture.init();
    var mon = Monitor.init(
        mock.console(),
        .{ .handoff = make_handoff(), .map = fixture.view, .console_name = "mock" },
        MachineControl.disabled(),
    );
    try std.testing.expectEqual(ExecError.not_implemented, exec(&mon, &.{"shutdown"}));
    try std.testing.expect(std.mem.indexOf(u8, mock.contents(), "shutdown: not implemented") != null);
}

test "monitor: elephant is deterministic and reports diagnostics" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"elephant"}));
    const first = env.mock.contents();
    try std.testing.expect(std.mem.startsWith(u8, first, elephant_lines()[0]));
    const expected_tail = "ELEPHANT ONLINE\n" ++
        "  trunk: up\n" ++
        "  ears: floppy\n" ++
        "  console: mock\n" ++
        "  handoff: valid\n" ++
        "  memory: descriptors=0x0000000000000006\n";
    try std.testing.expect(std.mem.endsWith(u8, first, expected_tail));

    // Same input, same output: fully deterministic.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"elephant"}));
    try std.testing.expectEqualStrings(first, env.mock.contents());
}

test "monitor: beans is deterministic and bounded" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"beans"}));
    try std.testing.expectEqualStrings(
        "beans\ncounting beans... 42 beans in a trench coat.\nthat's it. that's the command.\n",
        env.mock.contents(),
    );
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "beans", "7" }));
    try std.testing.expectEqualStrings(
        "beans\ncounting beans... 7 beans in a trench coat.\nthat's it. that's the command.\n",
        env.mock.contents(),
    );
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "beans", "0" }));
    try std.testing.expectEqualStrings("error: beans: count must be between 1 and 100\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "beans", "101" }));
    try std.testing.expectEqualStrings("error: beans: count must be between 1 and 100\n", env.mock.contents());
}

test "monitor: random prints a deterministic hex line from the seeded CSPRNG and bounds count" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expect(lookup("random") != null);
    try std.testing.expectEqualStrings("print n random bytes from the seeded CSPRNG (hex)", lookup("random").?.help);
    // Seed with a fixed value so the output is deterministic in the test.
    csprng.seed(&[_]u8{0x5a} ** csprng.seed_len);
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "random", "32" }));
    const out = env.mock.contents();
    try std.testing.expect(std.mem.startsWith(u8, out, "random: n=32 hex="));
    const hex = out["random: n=32 hex=".len..];
    // 64 hex chars then the line terminator.
    try std.testing.expectEqual(@as(usize, 65), hex.len);
    try std.testing.expectEqual(@as(u8, '\n'), hex[64]);
    for (hex[0..64]) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try std.testing.expect(ok);
    }
    // No-arg prints the fixed 16-byte sample (32 hex chars).
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"random"}));
    try std.testing.expect(std.mem.startsWith(u8, env.mock.contents(), "random: n=16 hex="));
    // Bounds: 1..256.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "random", "0" }));
    try std.testing.expectEqualStrings("random: count must be between 1 and 256\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "random", "257" }));
    try std.testing.expectEqualStrings("random: count must be between 1 and 256\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "random", "zz" }));
    try std.testing.expect(std.mem.startsWith(u8, env.mock.contents(), "random: invalid count: "));
}

test "monitor: fault is registered and honestly reports no vectors in a test process" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expect(lookup("fault") != null);
    try std.testing.expectEqualStrings("trigger a synchronous exception (diagnostic)", lookup("fault").?.help);
    // Test processes never install the vectors (even on an aarch64 host,
    // where executing `udf` would SIGILL); the command must say so and must
    // not fault the test process.
    try std.testing.expectEqual(ExecError.not_implemented, exec(&mon, &.{"fault"}));
    try std.testing.expectEqualStrings(
        "fault: exception vectors not installed; nothing to trigger\n",
        env.mock.contents(),
    );
}

test "monitor: timer is registered and reports the unarmed host state" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expect(lookup("timer") != null);
    try std.testing.expectEqualStrings("interrupt controller + timer status", lookup("timer").?.help);
    // In a test process the GIC/timer are never programmed (the init paths
    // are aarch64-only); the command must report the honest unarmed state
    // with the conventional PPI default.
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"timer"}));
    try std.testing.expectEqualStrings(
        "timer: armed=0 gic=none dist=0x0 ppi=0x1e freq=0x0 ticks=0 irq=0 poll=0 acked=0 first=0xffffffff\n",
        env.mock.contents(),
    );
}

test "monitor: tasks is registered and reports the deterministic host state" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expect(lookup("tasks") != null);
    try std.testing.expectEqualStrings("tick-driven task scheduler status", lookup("tasks").?.help);
    // Register the tasks exactly as kernel_main does (the idle task is
    // scheduler-owned and auto-registered by init); without `start` the
    // scheduler never preempts, so every counter reads 0 — the same shape
    // a live boot reports once ticks begin.
    _ = scheduler.init();
    _ = scheduler.register_worker(0);
    _ = scheduler.register_user(0, 0);
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"tasks"}));
    try std.testing.expectEqualStrings(
        "tasks: enabled=0 current=0 switches=0 pool=4/11 zombies=0\n" ++
            "  shell    saves=0 resumes=0 advances=0 state=ready\n" ++
            "  worker   saves=0 resumes=0 advances=0 state=ready\n" ++
            "  user-el0 saves=0 resumes=0 advances=0 state=ready\n" ++
            "  idle     saves=0 resumes=0 advances=0 state=ready\n",
        env.mock.contents(),
    );
}

test "monitor: resources audits the fixed pools at their bounds (C3 claim 0339)" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expect(lookup("resources") != null);
    try std.testing.expectEqualStrings("fixed-pool audit: scheduler tasks, process registry, windows, page-table carve-out, and per-process ring bounds", lookup("resources").?.help);
    // Reset the pools the way kernel_main + a fresh boot do (scheduler.init
    // also clears the process registry; mmu.reset clears the table cursor),
    // then register the same shell/worker/user shape the `tasks` test uses.
    _ = scheduler.init();
    _ = scheduler.register_worker(0);
    _ = scheduler.register_user(0, 0);
    mmu.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"resources"}));
    const out = env.mock.contents();
    // The occupancy lines are exact (4 tasks, 0 procs, 0 tables); the
    // windows line only asserts the shape (other tests in this binary may
    // have armed the window manager, leaving a non-zero win_count).
    try std.testing.expect(std.mem.indexOf(u8, out, "resources: tasks=4/11 zombies=0\n") != null);
    // register_user also registers the boot payload as a PROCESS (claim
    // 3848), so the registry holds exactly one descriptor here.
    try std.testing.expect(std.mem.indexOf(u8, out, "resources: procs=1/16\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "resources: windows=") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "/9\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "resources: tables=0/512\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "resources: events=16 mbox=8 fds=8 timers=1 tcp=1\n") != null);
}

test "monitor: procs reports the process table with lifecycle and exit status" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expect(lookup("procs") != null);
    try std.testing.expectEqualStrings("process registry: image, address space, lifecycle, exit status", lookup("procs").?.help);
    // Seed the registry deterministically: an EXITED boot payload (status 7,
    // executor reaped) and a RUNNING exec'd program bound to task 2 — the
    // exact two-process table a live boot shows right after `exec`.
    process.init();
    const p0 = process.create("user-el0", .{ .entry_va = 0x400000, .content_len = 0x100 }, .{ .stack_va = 0x80000000, .stack_len = 8192 }, .{}).?;
    _ = process.bind(p0, 2);
    _ = process.on_task_exit(2, 7);
    _ = process.take_exit_report();
    const p1 = process.create("USER.BIN", .{ .entry_va = 0x400000, .content_len = 0xea }, .{ .stack_va = 0x1a400000, .stack_len = 8192 }, .{}).?;
    _ = process.bind(p1, 2);
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"procs"}));
    // The exited process keeps its status past the executor's reap; the
    // running one shows its bound task and stack VA.
    try std.testing.expectEqualStrings(
        "procs: count=2\n" ++
            "procs: id=0 name=user-el0 state=exited task=reaped stack=0x0000000080000000 exit=7\n" ++
            "procs: id=1 name=USER.BIN state=running task=2 stack=0x000000001a400000 exit=-\n",
        env.mock.contents(),
    );
}

test "monitor: kill is registered and arms a running process by id and by name" {
    // Card 3c (claim 7786): `kill <pid|name>` resolves the process and
    // ARMS its executor task; the ring converts the next selection into
    // the existing exit path with the reserved status 137.
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expect(lookup("kill") != null);
    try std.testing.expectEqualStrings("terminate a running process (kernel-owned lifetime)", lookup("kill").?.help);
    _ = scheduler.init();
    _ = scheduler.register_worker(0);
    _ = scheduler.register_user(0, 0);
    // The boot payload's process (id 0) is RUNNING on task 2; the demo
    // spawn fills slot 3 so a second process can bind a real executor.
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"spawn"}));
    env.mock.reset();
    const p1 = process.create("USER.BIN", .{ .entry_va = 0x400000, .content_len = 0xea }, .{}, .{}).?;
    try std.testing.expectEqual(@as(usize, 1), p1);
    _ = process.bind(p1, 3);
    // By id (the `procs` id).
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "kill", "0" }));
    try std.testing.expectEqualStrings("kill: user-el0 armed\n", env.mock.contents());
    // By name (the FAT file name).
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "kill", "USER.BIN" }));
    try std.testing.expectEqualStrings("kill: USER.BIN armed\n", env.mock.contents());
    // The armed kill flows through the REAL lifecycle at the next ring
    // selection: user-el0 (task 2) exits with the reserved status 137.
    scheduler.start();
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user -> killed -> spawn-demo
    try std.testing.expectEqual(@as(?u64, scheduler.reserved_kill_status), scheduler.terminated_status(2));
}

test "monitor: kill refuses unknown, already-exited, and not-running targets exactly" {
    var env = TestEnv.init();
    var mon = env.monitor();
    _ = scheduler.init();
    _ = scheduler.register_worker(0);
    _ = scheduler.register_user(0, 0);
    // An EXITED process (the exited state's exact refusal).
    const exited_p = process.create("BOOTED", .{ .entry_va = 0x400000, .content_len = 1 }, .{}, .{}).?;
    _ = process.bind(exited_p, 4);
    _ = process.on_task_exit(4, 7);
    _ = process.take_exit_report();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "kill", "BOOTED" }));
    try std.testing.expectEqualStrings("error: BOOTED already exited\n", env.mock.contents());
    // A CREATED (loaded, not yet bound) process: no executor to terminate.
    env.mock.reset();
    _ = process.create("ROLLBACK.BIN", .{ .entry_va = 0x400000, .content_len = 1 }, .{}, .{});
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "kill", "ROLLBACK.BIN" }));
    try std.testing.expectEqualStrings("error: ROLLBACK.BIN not running\n", env.mock.contents());
    // Unknown name and unknown numeric id.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "kill", "NOPE.BIN" }));
    try std.testing.expectEqualStrings("error: no such process: NOPE.BIN\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "kill", "9" }));
    try std.testing.expectEqualStrings("error: no such process: 9\n", env.mock.contents());
}

test "monitor: spawn is registered and reports the demo spawn or the bound" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expect(lookup("spawn") != null);
    try std.testing.expectEqualStrings("spawn the lifecycle demo task", lookup("spawn").?.help);
    _ = scheduler.init();
    _ = scheduler.register_worker(0);
    _ = scheduler.register_user(0, 0);
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"spawn"}));
    try std.testing.expectEqualStrings("spawn: spawn-demo id=3\n", env.mock.contents());
    // One demo spawn per boot: the second reports the bound.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"spawn"}));
    try std.testing.expectEqualStrings("spawn: pool full or demo already running\n", env.mock.contents());
}

test "monitor: syscalls is registered and reports deterministic rows" {
    var env = TestEnv.init();
    var mon = env.monitor();
    syscall.init(test_syscall_writer);
    try std.testing.expect(lookup("syscalls") != null);
    try std.testing.expectEqualStrings("numbered syscall table and counters", lookup("syscalls").?.help);
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"syscalls"}));
    try std.testing.expectEqualStrings(
        "syscalls: slots=64 implemented=66\n" ++
            "  0 sys_ping calls=0\n" ++
            "  1 sys_write calls=0\n" ++
            "  2 sys_yield calls=0\n" ++
            "  3 sys_exit calls=0\n" ++
            "  4 sys_sleep calls=0\n" ++
            "  5 sys_ipc_send calls=0\n" ++
            "  6 sys_ipc_recv calls=0\n" ++
            "  7 sys_procs calls=0\n" ++
            "  8 sys_wait calls=0\n" ++
            "  9 sys_udp_listen calls=0\n" ++
            "  10 sys_udp_send calls=0\n" ++
            "  11 sys_udp_recv calls=0\n" ++
            "  12 sys_win_open calls=0\n" ++
            "  13 sys_win_fill calls=0\n" ++
            "  14 sys_win_present calls=0\n" ++
            "  15 sys_win_close calls=0\n" ++
            "  16 sys_win_move calls=0\n" ++
            "  17 sys_win_raise calls=0\n" ++
            "  18 sys_win_get calls=0\n" ++
            "  19 sys_win_query calls=0\n" ++
            "  20 sys_win_set_visible calls=0\n" ++
            "  21 sys_poll_event calls=0\n" ++
            "  22 sys_wait_event calls=0\n" ++
            "  23 sys_file_open calls=0\n" ++
            "  24 sys_file_read calls=0\n" ++
            "  25 sys_file_write calls=0\n" ++
            "  26 sys_file_close calls=0\n" ++
            "  27 sys_dir_list calls=0\n" ++
            "  28 sys_exec calls=0\n" ++
            "  29 sys_kill calls=0\n" ++
            "  30 sys_tcp_connect calls=0\n" ++
            "  31 sys_tcp_send calls=0\n" ++
            "  32 sys_tcp_recv calls=0\n" ++
            "  33 sys_tcp_close calls=0\n" ++
            "  34 sys_file_delete calls=0\n" ++
            "  35 sys_file_rename calls=0\n" ++
            "  36 sys_file_truncate calls=0\n" ++
            "  37 sys_file_free calls=0\n" ++
            "  38 sys_clipboard_set calls=0\n" ++
            "  39 sys_clipboard_get calls=0\n" ++
            "  40 sys_timer_set calls=0\n" ++
            "  41 sys_timer_cancel calls=0\n" ++
            "  42 sys_audio_info calls=0\n" ++
            "  43 sys_audio_play calls=0\n" ++
            "  44 sys_audio_volume calls=0\n" ++
            "  45 sys_audio_mute calls=0\n" ++
            "  46 sys_win_fill_batch calls=0\n" ++
            "  47 sys_win_resize calls=0\n" ++
            "  48 sys_drag_start calls=0\n" ++
            "  49 sys_win_raise_front calls=0\n" ++
            "  50 sys_win_lower_back calls=0\n" ++
            "  51 sys_notify calls=0\n" ++
            "  52 sys_win_move_to_workspace calls=0\n" ++
            "  53 sys_win_set_unsaved calls=0\n" ++
            "  54 sys_setrlimit calls=0\n" ++
            "  55 sys_drag_read calls=0\n" ++
            "  56 sys_pipe_read calls=0\n" ++
            "  57 sys_pipe_write calls=0\n" ++
            "  58 sys_font_size calls=0\n" ++
            "  59 sys_ping_send calls=0\n" ++
            "  60 sys_ping_poll calls=0\n" ++
            "  61 sys_win_set_title calls=0\n" ++
            "  62 sys_net_stats calls=0\n" ++
            "  63 sys_mmap calls=0\n" ++
            "  64 sys_munmap calls=0\n" ++
            "  65 sys_wmctl calls=0\n",
        env.mock.contents(),
    );
}

test "monitor: clip copies and pastes the shared clipboard (claim 0169)" {
    clipboard.init();
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expect(lookup("clip") != null);
    try std.testing.expectEqualStrings("copy/paste the shared kernel clipboard ('clip <text...>' sets it, 'clip' prints it)", lookup("clip").?.help);

    // Empty clipboard pastes the honest empty marker.
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"clip"}));
    try std.testing.expectEqualStrings("clip: empty\n", env.mock.contents());

    // Copy joins args space-separated and stores them.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "clip", "hello", "world" }));
    try std.testing.expectEqualStrings("clip: stored 11 bytes\n", env.mock.contents());

    // Paste reads the SAME bytes back.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"clip"}));
    try std.testing.expectEqualStrings("clip: hello world\n", env.mock.contents());

    // A new copy overwrites; an empty-arg copy clears.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "clip", "second" }));
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"clip"}));
    try std.testing.expectEqualStrings("clip: second\n", env.mock.contents());
}

test "monitor: uaccess command is honest on a host process (no vectors)" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expect(lookup("uaccess") != null);
    try std.testing.expectEqualStrings("user-memory copy diagnostics (valid, fault, recovery)", lookup("uaccess").?.help);
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"uaccess"}));
    // Host process: no regions configured and no exception vectors, so the
    // validated copy is rejected at range check and the raw probe returns
    // fault without dereferencing (recovered=0). On VZ the class-B gate
    // asserts the real recovery line instead.
    try std.testing.expectEqualStrings(
        "uaccess: valid=0 fault=1 recovered=0 copies=0 validation_faults=1\n",
        env.mock.contents(),
    );
}

test "monitor: output overflow is bounded and flagged, never fatal" {
    var small = console.MockConsole(16){};
    var machine = MockMachineControl{};
    const fixture = MapFixture.init();
    var mon = Monitor.init(
        small.console(),
        .{ .handoff = make_handoff(), .map = fixture.view, .console_name = "mock" },
        machine.control(),
    );
    const long = "x" ** 100;
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "echo", long }));
    try std.testing.expect(small.overflowed);
    try std.testing.expectEqual(@as(usize, 16), small.len);

    small.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "repeat", "64", "abcdefgh" }));
    try std.testing.expect(small.overflowed);
    try std.testing.expectEqual(@as(usize, 16), small.len);
}

test "monitor: boot message selection is deterministic" {
    const msgs = BootMessages.messages();
    try std.testing.expectEqualStrings(msgs[0], BootMessages.pick(0));
    try std.testing.expectEqualStrings(msgs[1], BootMessages.pick(1));
    try std.testing.expectEqualStrings(msgs[5], BootMessages.pick(5));
    try std.testing.expectEqualStrings(msgs[0], BootMessages.pick(6));
}

test "monitor: banner is deterministic and avoids invented claims" {
    var env = TestEnv.init();
    var mon = env.monitor();
    banner(&mon);
    const out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "DipshitOS - AArch64 firmware-assisted kernel monitor") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, BootMessages.messages()[2]) != null); // image_handle=2
    try std.testing.expect(std.mem.indexOf(u8, out, "Type 'help' before touching anything expensive.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "0.1") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "256 MiB") == null);
}

test "monitor: ls lists the ESP files deterministically" {
    esp.reset();
    try std.testing.expect(esp.add_esp_entry("KERNEL.BIN", 0x88b38, ""));
    try std.testing.expect(esp.add_dir_entry("EFI"));
    try std.testing.expect(esp.add_esp_entry("BOOTED.TXT", 0x29, "DIPSHITOS BOOTLOADER\nfirmware has agreed to cooperate\n"));
    try std.testing.expect(esp.add_esp_entry("HELLO.TXT", 11, "hello world"));

    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"ls"}));
    // Entries are listed in the window's order (the FAT root walk) —
    // deterministic per boot. The name column pads to the widest entry;
    // sizes are 0x + 16 hex digits.
    try std.testing.expectEqualStrings(
        "ls: esp=0x0000000000000004\n" ++
            "  KERNEL.BIN  0x0000000000088b38  [esp]\n" ++
            "  EFI         0x0000000000000000  [dir]\n" ++
            "  BOOTED.TXT  0x0000000000000029  [esp]\n" ++
            "  HELLO.TXT   0x000000000000000b  [esp]\n",
        env.mock.contents(),
    );
}

test "monitor: cat prints ESP content with honest errors" {
    esp.reset();
    try std.testing.expect(esp.add_esp_entry("BOOTED.TXT", 0x29, "DIPSHITOS BOOTLOADER\nfirmware has agreed to cooperate\n"));
    try std.testing.expect(esp.add_esp_entry("KERNEL.BIN", 0x88b38, ""));
    try std.testing.expect(esp.add_dir_entry("EFI"));
    try std.testing.expect(esp.add_esp_entry("hello.txt", 11, "hello world"));

    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "cat", "BOOTED.TXT" }));
    // The file already ends with a newline — cat prints it verbatim.
    try std.testing.expectEqualStrings("DIPSHITOS BOOTLOADER\nfirmware has agreed to cooperate\n", env.mock.contents());
    env.mock.reset();
    // Case-insensitive lookup.
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "cat", "HELLO.TXT" }));
    try std.testing.expectEqualStrings("hello world\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "cat", "KERNEL.BIN" }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "content not loaded") != null);
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "cat", "EFI" }));
    try std.testing.expectEqualStrings("error: EFI: is a directory\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "cat", "NOPE.TXT" }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "not found") != null);
}

test "monitor: ls/cat accept /-paths (honest no-volume errors in a test process)" {
    esp.reset();
    var env = TestEnv.init();
    var mon = env.monitor();
    // No FAT volume in a host test process: the path branches resolve
    // nothing and report it honestly (the success path is exercised live
    // by verify-live-fs.sh — `ls EFI/BOOT` + `cat EFI/BOOT/BOOTAA64.EFI`).
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "ls", "EFI/BOOT" }));
    try std.testing.expectEqualStrings("error: EFI/BOOT: not found (no such directory on the FAT volume)\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "cat", "EFI/BOOT/BOOTAA64.EFI" }));
    try std.testing.expectEqualStrings("error: EFI/BOOT/BOOTAA64.EFI: not found (no such file on the FAT volume)\n", env.mock.contents());
    env.mock.reset();
    // The no-arg ls still lists the (empty) window.
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"ls"}));
    try std.testing.expectEqualStrings("ls: esp=0x0000000000000000\nls: no files on the ESP (FAT volume unavailable or empty)\n", env.mock.contents());
}

test "monitor: mount is registered and reports honest transport errors in a test process" {
    esp.reset();
    var env = TestEnv.init();
    var mon = env.monitor();
    // No virtio-blk transport in a host test process (blk_ready=false): the
    // sector ops fail, so both volumes report the I/O result honestly (the
    // success path is the live gate).
    try std.testing.expectEqual(ExecError.machine_failed, exec(&mon, &.{ "mount", "data" }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "error: data: sector I/O failed") != null);
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "mount", "nvme0" }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "unknown volume") != null);
    env.mock.reset();
    // The registry documents the command.
    try std.testing.expectEqualStrings("switch the active FAT volume (esp or data)", lookup("mount").?.help);
}

test "monitor: write joins arguments and honestly reports no disk in a test process" {
    esp.reset();
    var env = TestEnv.init();
    var mon = env.monitor();
    // In a host test process there is no disk (no FAT volume mounted); the
    // write must be refused honestly, never faked.
    try std.testing.expectEqual(ExecError.not_implemented, exec(&mon, &.{ "write", "hello.txt", "hello", "world" }));
    try std.testing.expectEqualStrings(
        "error: hello.txt: not persisted - no disk (FAT volume unavailable)\n",
        env.mock.contents(),
    );
    // Bounds are validated before any persistence attempt.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "write", "bad/name.txt", "x" }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "invalid file name") != null);
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "write", "verylongname.txt", "x" }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "does not fit FAT 8.3") != null);
    env.mock.reset();
    // Empty content is allowed (a zero-length file); still refused honestly.
    try std.testing.expectEqual(ExecError.not_implemented, exec(&mon, &.{ "write", "n.txt" }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "content too long") == null);
}

test "monitor: exec is registered and refuses honestly without a disk" {
    esp.reset();
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expect(lookup("exec") != null);
    try std.testing.expectEqualStrings("load a user program from the ESP and enter it at EL0", lookup("exec").?.help);
    // No FAT volume in a host test process: refused honestly, never faked.
    // (The full load+spawn path is covered by exec.zig's own tests, which
    // mount the in-memory FAT fixture and retire the static user task.)
    try std.testing.expectEqual(ExecError.not_implemented, exec(&mon, &.{"exec"}));
    try std.testing.expectEqualStrings("error: no disk (ESP FAT volume unavailable)\n", env.mock.contents());
}

test "monitor: net dns command validation and execution" {
    var env = TestEnv.init();
    var mon = env.monitor();
    virtio_net.net_ready = false;
    virtio_net.arp.own_ip = .{ 0, 0, 0, 0 };

    // Missing arguments
    try std.testing.expectEqual(ExecError.usage, exec(&mon, &.{ "net", "dns" }));

    // No device
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "net", "dns", "example.com" }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "error: no virtio-net device\n") != null);

    // Invalid server IP
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "net", "dns", "example.com", "999.0.0.1" }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "error: invalid server address: 999.0.0.1\n") != null);
}

test "monitor: sound volume/mute drive the bounded stream state (claim 9297)" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expect(lookup("sound") != null);
    try std.testing.expectEqualStrings("sound [volume <0-100> | mute <on|off>]", lookup("sound").?.usage);

    // Defaults: full volume, unmuted.
    virtio_snd.stream_volume = 100;
    virtio_snd.stream_muted = false;

    // `sound volume <0-100>` sets the bounded gain and echoes it.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "sound", "volume", "30" }));
    try std.testing.expectEqualStrings("sound: volume=30\n", env.mock.contents());
    try std.testing.expectEqual(@as(u8, 30), virtio_snd.stream_volume);

    // Out-of-range is refused honestly (no silent clamping).
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "sound", "volume", "101" }));
    try std.testing.expectEqualStrings("sound: volume must be 0..100\n", env.mock.contents());
    try std.testing.expectEqual(@as(u8, 30), virtio_snd.stream_volume);

    // `sound mute on|off` sets the flag.
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "sound", "mute", "on" }));
    try std.testing.expectEqualStrings("sound: mute=on\n", env.mock.contents());
    try std.testing.expect(virtio_snd.stream_muted);
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "sound", "mute", "off" }));
    try std.testing.expectEqualStrings("sound: mute=off\n", env.mock.contents());
    try std.testing.expect(!virtio_snd.stream_muted);

    // A bad subcommand is a usage error.
    try std.testing.expectEqual(ExecError.usage, exec(&mon, &.{ "sound", "bogus", "1" }));

    // The `sound` report shows the stream state (works without a device).
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"sound"}));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "sound: vol=30 mute=0\n") != null);

    // Restore the honest default.
    virtio_snd.stream_volume = 100;
    virtio_snd.stream_muted = false;
}

test "monitor: which resolves builtin, monitor, app, and not-found names (D16)" {
    esp.reset();
    try std.testing.expect(esp.add_esp_entry("NOTEPAD.BIN", 123, ""));

    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "which", "type" }));
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "which", "stat" }));
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "which", "NOTEPAD.BIN" }));
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "which", "nope.bin" }));
    const out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "type: shell builtin") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "stat: monitor command") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "NOTEPAD.BIN: ESP application") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "nope.bin: not found") != null);
}

test "monitor: du reports recursive directory size (M25 F4)" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"du"}));
    const out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "du: /") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "bytes (dirs=") != null);
}

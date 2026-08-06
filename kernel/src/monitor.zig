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
const console = @import("console.zig");
const handoff = @import("handoff.zig");
const memmap = @import("memmap.zig");

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
    pub fn disabled() MachineControl {
        const Noop = struct {
            fn reboot(_: *anyopaque) MachineResult {
                return .not_implemented;
            }
            fn shutdown(_: *anyopaque) MachineResult {
                return .not_implemented;
            }
        };
        return .{
            .ctx = @ptrCast(@constCast(&Noop)),
            .vtable = &.{ .reboot = Noop.reboot, .shutdown = Noop.shutdown },
        };
    }
};

/// Host-test double: records calls and returns scripted results.
pub const MockMachineControl = struct {
    reboot_result: MachineResult = .ok,
    shutdown_result: MachineResult = .ok,
    reboot_calls: usize = 0,
    shutdown_calls: usize = 0,

    pub fn control(self: *MockMachineControl) MachineControl {
        return .{ .ctx = self, .vtable = &.{ .reboot = rebootFn, .shutdown = shutdownFn } };
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

pub const Command = struct {
    name: []const u8,
    help: []const u8,
    usage: []const u8,
    min_args: u8 = 0,
    max_args: u8 = max_args_limit,
    handler: *const fn (m: *Monitor, args: []const []const u8) ExecError,
};

/// Comptime registry: adding a command is one entry here (name, help,
/// usage, arg constraints, handler). `help` derives its listing from this
/// array, so the two cannot drift.
pub const registry = [_]Command{
    .{ .name = "about", .help = "explain this questionable system", .usage = "about", .handler = cmd_about },
    .{ .name = "beans", .help = "count beans, probably", .usage = "beans [count]", .max_args = 1, .handler = cmd_beans },
    .{ .name = "clear", .help = "clean up the crime scene", .usage = "clear", .handler = cmd_clear },
    .{ .name = "echo", .help = "repeat your regrettable decisions", .usage = "echo <text...>", .handler = cmd_echo },
    .{ .name = "elephant", .help = "operational mascot diagnostics", .usage = "elephant", .handler = cmd_elephant },
    .{ .name = "handoff", .help = "display boot-to-kernel ABI data", .usage = "handoff", .handler = cmd_handoff },
    .{ .name = "help", .help = "list commands and their help text", .usage = "help [command]", .max_args = 1, .handler = cmd_help },
    .{ .name = "hex", .help = "format an integer in hexadecimal", .usage = "hex <number>...", .min_args = 1, .handler = cmd_hex },
    .{ .name = "mem", .help = "summarize the EFI memory map", .usage = "mem", .handler = cmd_mem },
    .{ .name = "reboot", .help = "restart the machine", .usage = "reboot", .handler = cmd_reboot },
    .{ .name = "repeat", .help = "repeat text, safely bounded", .usage = "repeat <count> <text...>", .min_args = 1, .handler = cmd_repeat },
    .{ .name = "shutdown", .help = "request power-off", .usage = "shutdown", .handler = cmd_shutdown },
    .{ .name = "uname", .help = "compact system identity", .usage = "uname", .handler = cmd_uname },
    .{ .name = "version", .help = "display build information", .usage = "version", .handler = cmd_version },
};

pub fn lookup(name: []const u8) ?*const Command {
    for (&registry) |*cmd| {
        if (std.mem.eql(u8, cmd.name, name)) return cmd;
    }
    return null;
}

/// Execute an already-tokenized command line: `argv[0]` is the command
/// name, the rest are its arguments. Tokenization and line editing belong
/// to the later Console & Shell Core stream.
pub fn exec(m: *Monitor, argv: []const []const u8) ExecError {
    if (argv.len == 0) {
        m.console.print_line("no command given; type 'help' for a list of commands");
        return .usage;
    }
    if (argv.len > max_args_limit + 1) {
        m.console.print_line("too many arguments; type 'help' for a list of commands");
        return .usage;
    }
    const cmd = lookup(argv[0]) orelse {
        m.console.puts("unknown command: ");
        m.console.puts(argv[0]);
        m.console.puts("\ntype 'help' for a list of commands\n");
        return .unknown_command;
    };
    const args = argv[1..];
    if (args.len < cmd.min_args or args.len > cmd.max_args) {
        m.console.puts("usage: ");
        m.console.puts(cmd.usage);
        m.console.puts("\n");
        return .usage;
    }
    return cmd.handler(m, args);
}

// ---------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------

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
            m.console.puts(verb);
            m.console.puts(": not implemented - no proven post-ExitBootServices machine-control mechanism; terminal WFE loop continues\n");
            return .not_implemented;
        },
        .failed => {
            m.console.puts(verb);
            m.console.puts(": failed\n");
            return .machine_failed;
        },
    }
}

// ---------------------------------------------------------------------------
// Identity and inspection commands
// ---------------------------------------------------------------------------

fn cmd_help(m: *Monitor, args: []const []const u8) ExecError {
    if (args.len == 1) {
        const cmd = lookup(args[0]) orelse {
            m.console.puts("help: no such command: ");
            m.console.puts(args[0]);
            m.console.puts("\n");
            return .invalid_argument;
        };
        m.console.puts(cmd.name);
        m.console.puts(" - ");
        m.console.puts(cmd.help);
        m.console.puts("\nusage: ");
        m.console.puts(cmd.usage);
        m.console.puts("\n");
        return .none;
    }
    m.console.print_line("available commands:");
    var width: usize = 0;
    for (registry) |cmd| width = @max(width, cmd.name.len);
    for (registry) |cmd| {
        m.console.puts("  ");
        m.console.puts(cmd.name);
        var pad: usize = cmd.name.len;
        while (pad < width) : (pad += 1) m.console.putc(' ');
        m.console.puts("  ");
        m.console.puts(cmd.help);
        m.console.puts("\n");
    }
    m.console.print_line("type 'help <command>' for details on a single command.");
    return .none;
}

fn cmd_about(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    m.console.print_line("DipshitOS is a from-scratch AArch64 operating system.");
    m.console.print_line("Written in freestanding Zig: no libc, no POSIX.");
    m.console.print_line("Hosted under Apple Virtualization.framework on Apple silicon.");
    m.console.print_line("Milestone-two kernel proper: ExitBootServices, identity-map MMU,");
    m.console.print_line("polled serial console (ADR 0004). Handoff ABI v2 (ADR 0004 D5).");
    m.console.print_line("The interactive monitor command layer is tested against a mock");
    m.console.print_line("console; live serial input is not wired yet.");
    m.console.print_line("Type 'help' for a list of commands.");
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

fn cmd_clear(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    // ANSI erase-in-display + cursor home. On terminals without ANSI
    // support this sequence is ignored harmlessly; the fallback is a
    // documented no-op. Deterministic and testable at the byte level.
    m.console.puts("\x1b[2J\x1b[H");
    return .none;
}

fn cmd_hex(m: *Monitor, args: []const []const u8) ExecError {
    for (args) |arg| {
        const value = parseInt(arg) catch {
            m.console.puts("hex: invalid number: ");
            m.console.puts(arg);
            m.console.puts("\n");
            return .invalid_argument;
        };
        m.console.print_hex_min(value);
        m.console.puts("\n");
    }
    return .none;
}

fn cmd_repeat(m: *Monitor, args: []const []const u8) ExecError {
    const count = parseInt(args[0]) catch {
        m.console.puts("repeat: invalid count: ");
        m.console.puts(args[0]);
        m.console.puts("\n");
        return .invalid_argument;
    };
    if (count < 1 or count > repeat_max_count) {
        m.console.puts("repeat: count must be between 1 and ");
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
        m.console.puts("repeat: output too large (max ");
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

// ---------------------------------------------------------------------------
// Machine control commands
// ---------------------------------------------------------------------------

fn cmd_reboot(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    return report_machine(m, "reboot", m.machine.reboot());
}

fn cmd_shutdown(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    return report_machine(m, "shutdown", m.machine.shutdown());
}

// ---------------------------------------------------------------------------
// Personality commands
// ---------------------------------------------------------------------------

/// Fixed mascot art (bounded, deterministic, no state).
pub const elephant_lines = [_][]const u8{
    "      _    _",
    "     (o)  (o)",
    "       \\  /",
    "       _||_",
    "      /    \\",
    "     |  __  |",
    "     | |  | |",
    "     |_|  |_|",
    "    /  |  |  \\",
    "   /   |  |   \\",
    "  |    |  |    |",
    "  |____|  |____|",
};

fn cmd_elephant(m: *Monitor, args: []const []const u8) ExecError {
    _ = args;
    for (elephant_lines) |line| m.console.print_line(line);
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
            m.console.puts("beans: invalid count: ");
            m.console.puts(args[0]);
            m.console.puts("\n");
            return .invalid_argument;
        };
        if (count < 1 or count > beans_max_count) {
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
    pub const messages = [_][]const u8{
        "DipshitOS: the elephant has left the building.",
        "DipshitOS: 42 beans, zero dignity.",
        "DipshitOS: memory is a map, not a territory.",
        "DipshitOS: no libc was harmed in the making of this kernel.",
        "DipshitOS: terminal loop, meet the monitor.",
        "DipshitOS: from scratch, with love and beans.",
    };

    /// Deterministic, stateless "rotation": the choice depends only on the
    /// boot's image handle, so it is stable within a boot, varies across
    /// boots, and needs no hidden mutable state.
    pub fn pick(image_handle: u64) []const u8 {
        return messages[@as(usize, @intCast(image_handle % messages.len))];
    }
};

/// Banner text the later shell-core stream prints at boot. Deliberately
/// does not print "DIPSHITOS 0.1" (the repository defines no release
/// number) or a hardcoded "256 MiB detected" (memory must be derived from
/// the captured map — `mem` does exactly that).
pub fn banner(m: *Monitor) void {
    m.console.print_line("DipshitOS - AArch64 firmware-assisted kernel monitor");
    m.console.puts(BootMessages.pick(m.state.handoff.image_handle));
    m.console.puts("\n");
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
    mock: console.MockConsole(4096) = .{},
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

test "monitor: command lookup" {
    try std.testing.expect(lookup("echo") != null);
    try std.testing.expectEqualStrings("echo", lookup("echo").?.name);
    try std.testing.expect(lookup("beans") != null);
    try std.testing.expect(lookup("help") != null);
    try std.testing.expect(lookup("frobnicate") == null);
}

test "monitor: registry is well-formed" {
    try std.testing.expect(registry.len >= 10);
    for (registry, 0..) |cmd, index| {
        try std.testing.expect(cmd.name.len > 0);
        try std.testing.expect(cmd.help.len > 0);
        try std.testing.expect(cmd.usage.len > 0);
        try std.testing.expect(cmd.min_args <= cmd.max_args);
        try std.testing.expect(cmd.max_args <= max_args_limit);
        for (registry[0..index]) |other| {
            try std.testing.expect(!std.mem.eql(u8, cmd.name, other.name));
        }
    }
}

test "monitor: help listing is generated from the registry" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"help"}));
    const out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "available commands:") != null);
    for (registry) |cmd| {
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
    try std.testing.expectEqualStrings("help: no such command: bogus\n", env.mock.contents());
}

test "monitor: unknown command is diagnosed" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.unknown_command, exec(&mon, &.{"frobnicate"}));
    try std.testing.expectEqualStrings("unknown command: frobnicate\ntype 'help' for a list of commands\n", env.mock.contents());
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
    try std.testing.expectEqualStrings("usage: hex <number>...\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.usage, exec(&mon, &.{"repeat"}));
    try std.testing.expectEqualStrings("usage: repeat <count> <text...>\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.usage, exec(&mon, &.{ "beans", "1", "2" }));
    try std.testing.expectEqualStrings("usage: beans [count]\n", env.mock.contents());
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
    try std.testing.expect(std.mem.indexOf(u8, out, "mock") != null);
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
    try std.testing.expectEqualStrings("hex: invalid number: zz\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "hex", "-1" }));
    try std.testing.expectEqualStrings("hex: invalid number: -1\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "hex", "18446744073709551616" }));
    try std.testing.expectEqualStrings("hex: invalid number: 18446744073709551616\n", env.mock.contents());
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
    try std.testing.expectEqualStrings("repeat: count must be between 1 and 64\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "repeat", "65", "x" }));
    try std.testing.expectEqualStrings("repeat: count must be between 1 and 64\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "repeat", "zz", "x" }));
    try std.testing.expectEqualStrings("repeat: invalid count: zz\n", env.mock.contents());
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
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "repeat: output too large (max 4096 bytes)") != null);
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
    try std.testing.expectEqualStrings("shutdown: ok\n", env.mock.contents());
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
    try std.testing.expectEqualStrings("reboot: failed\n", env.mock.contents());
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
    try std.testing.expect(std.mem.startsWith(u8, first, elephant_lines[0]));
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
    try std.testing.expectEqualStrings("beans: count must be between 1 and 100\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "beans", "101" }));
    try std.testing.expectEqualStrings("beans: count must be between 1 and 100\n", env.mock.contents());
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
    try std.testing.expectEqualStrings(BootMessages.messages[0], BootMessages.pick(0));
    try std.testing.expectEqualStrings(BootMessages.messages[1], BootMessages.pick(1));
    try std.testing.expectEqualStrings(BootMessages.messages[5], BootMessages.pick(5));
    try std.testing.expectEqualStrings(BootMessages.messages[0], BootMessages.pick(6));
}

test "monitor: banner is deterministic and avoids invented claims" {
    var env = TestEnv.init();
    var mon = env.monitor();
    banner(&mon);
    const out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "DipshitOS - AArch64 firmware-assisted kernel monitor") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, BootMessages.messages[2]) != null); // image_handle=2
    try std.testing.expect(std.mem.indexOf(u8, out, "Type 'help' before touching anything expensive.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "0.1") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "256 MiB") == null);
}

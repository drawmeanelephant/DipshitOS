//! Decoupled unit tests for kernel monitor (M41 TS4, #955)

const std = @import("std");
const builtin = @import("builtin");
const monitor = @import("monitor");
const console = monitor.console;
const gic = monitor.gic;
const handoff = monitor.handoff;
const mailbox = monitor.mailbox;
const memmap = monitor.memmap;
const mmu = monitor.mmu;
const pci = monitor.pci;
const process = monitor.process;
const scheduler = monitor.scheduler;
const syscall = monitor.syscall;
const timer = monitor.timer;
const uaccess = monitor.uaccess;
const virtio_file = monitor.virtio_file;
const csprng = monitor.csprng;
const clipboard = monitor.clipboard;
const virtio_net = monitor.virtio_net;
const virtio_gpu = monitor.virtio_gpu;
const virtio_snd = monitor.virtio_snd;
const fbtext = monitor.fbtext;
const xhci = monitor.xhci;
const input = monitor.input;
const settings = monitor.settings;
const dns = monitor.dns;
const events = monitor.events;

// Monitor types and symbols
const Monitor = monitor.Monitor;
const Command = monitor.Command;
const Category = monitor.Category;
const ExecError = monitor.ExecError;
const MachineResult = monitor.MachineResult;
const MachineControl = monitor.MachineControl;
const MockMachineControl = monitor.MockMachineControl;
const BootMessages = monitor.BootMessages;
const lookup = monitor.lookup;
const exec = monitor.exec;
const complete = monitor.complete;
const ensure_registry = monitor.ensure_registry;
const category_order = monitor.category_order;
const category_name = monitor.category_name;
const max_args_limit = monitor.max_args_limit;
const repeat_max_count = monitor.repeat_max_count;
const repeat_max_bytes = monitor.repeat_max_bytes;
const beans_max_count = monitor.beans_max_count;
const random_max_bytes = monitor.random_max_bytes;
const elephant_lines = monitor.elephant_lines;
const sexiburger_lines = monitor.sexiburger_lines;
const net_dhcp_autonomous = monitor.net_dhcp_autonomous;
const banner = monitor.banner;

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
        "virelai-kernel\nmilestone-two kernel proper (ADR 0004)\nhandoff ABI v2\nbuild label: m1.5 commands & personality (mock console)\n",
        env.mock.contents(),
    );
    env.mock.reset();

    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"uname"}));
    try std.testing.expectEqualStrings("VirelaiOS aarch64\nfreestanding kernel; no POSIX compatibility\n", env.mock.contents());
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
    try std.testing.expect(std.mem.indexOf(u8, tour_out, "Welcome to VirelaiOS!") != null);
    try std.testing.expect(std.mem.indexOf(u8, tour_out, "1. Discovery: Type 'help'") != null);
    try std.testing.expect(std.mem.indexOf(u8, tour_out, "docs/") != null);
    env.mock.reset();

    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"tour"}));
    try std.testing.expectEqualStrings(tour_out, env.mock.contents());
    env.mock.reset();

    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"sysinfo"}));
    const sys_out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, sys_out, "sysinfo: VirelaiOS AArch64 support snapshot") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys_out, "kernel=virelai-kernel handoff=v2 status=valid") != null);
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
    try std.testing.expectEqualStrings("settings: hostname=virelai\n", env.mock.contents());
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

test "monitor: sexiburger is deterministic and reports diagnostics" {
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"sexiburger"}));
    const first = env.mock.contents();
    try std.testing.expect(std.mem.startsWith(u8, first, sexiburger_lines()[0]));
    const expected_tail = "SEXIBURGER ONLINE\n" ++
        "  mascot: Sexipus (hexapus clade)\n" ++
        "  tentacles: 6 (3 left, 3 right, lower pair curling inward)\n" ++
        "  layers: 6 (Crown, Lettuce, Tomato, Cheese, Patty, Heel)\n" ++
        "  covenant: the tentacle count is load-bearing\n" ++
        "  status: all 6 invariants intact\n";
    try std.testing.expect(std.mem.endsWith(u8, first, expected_tail));

    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"sexiburger"}));
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
    try std.testing.expect(std.mem.indexOf(u8, out, "/13\n") != null); // WM1: 4 fixed + 8 user + 1 spare
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
    try std.testing.expect(std.mem.indexOf(u8, out, "VirelaiOS - AArch64 firmware-assisted kernel monitor") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, BootMessages.messages()[2]) != null); // image_handle=2
    try std.testing.expect(std.mem.indexOf(u8, out, "Type 'help' before touching anything expensive.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "0.1") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "256 MiB") == null);
}

/// M34 HF6 (issue #740): monitor file-surface tests serve the in-memory
/// share override (the ESP window and FAT volume are gone). Same upsert
/// pattern as exec.zig's seam; `test_reset_share()` arms an EMPTY share
/// (honest not_found for every name), `set_test_share(null)` restores the
/// no-channel state.
var test_share_files: [8]virtio_file.TestFile = undefined;
var test_share_n: usize = 0;
fn test_seed_share(name: []const u8, content: []const u8) void {
    for (test_share_files[0..test_share_n]) |*f| {
        if (std.mem.eql(u8, f.name, name)) {
            f.* = .{ .name = name, .data = content };
            virtio_file.set_test_share(test_share_files[0..test_share_n]);
            return;
        }
    }
    if (test_share_n < test_share_files.len) {
        test_share_files[test_share_n] = .{ .name = name, .data = content };
        test_share_n += 1;
        virtio_file.set_test_share(test_share_files[0..test_share_n]);
    }
}
fn test_reset_share() void {
    test_share_n = 0;
    virtio_file.set_test_share(test_share_files[0..0]);
}

test "monitor: ls lists the host-share files deterministically" {
    test_reset_share();
    defer virtio_file.set_test_share(null);
    test_seed_share("KERNEL.BIN", "abcd");
    test_seed_share("BOOTED.TXT", "VIRELAIOS BOOTLOADER\nfirmware has agreed to cooperate\n");
    test_seed_share("HELLO.TXT", "hello world");

    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"ls"}));
    // Entries are listed in share order — deterministic per boot. The
    // name column pads to the widest entry; sizes are 0x + 16 hex digits.
    try std.testing.expectEqualStrings(
        "ls: host=0x0000000000000003\n" ++
            "  KERNEL.BIN  0x0000000000000004  [host]\n" ++
            "  BOOTED.TXT  0x0000000000000036  [host]\n" ++
            "  HELLO.TXT   0x000000000000000b  [host]\n",
        env.mock.contents(),
    );
}

test "monitor: cat prints share content with honest errors" {
    test_reset_share();
    defer virtio_file.set_test_share(null);
    test_seed_share("BOOTED.TXT", "VIRELAIOS BOOTLOADER\nfirmware has agreed to cooperate\n");
    test_seed_share("KERNEL.BIN", "");
    test_seed_share("hello.txt", "hello world");

    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "cat", "BOOTED.TXT" }));
    // The file already ends with a newline — cat prints it verbatim.
    try std.testing.expectEqualStrings("VIRELAIOS BOOTLOADER\nfirmware has agreed to cooperate\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "cat", "hello.txt" }));
    try std.testing.expectEqualStrings("hello world\n", env.mock.contents());
    env.mock.reset();
    // An empty file prints just the trailing newline (no error).
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "cat", "KERNEL.BIN" }));
    try std.testing.expectEqualStrings("\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "cat", "NOPE.TXT" }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "not found") != null);
}

test "monitor: ls/cat accept /-paths (honest not-found on the share)" {
    test_reset_share(); // armed, empty — every path is an honest not_found
    defer virtio_file.set_test_share(null);
    var env = TestEnv.init();
    var mon = env.monitor();
    // No host file channel in a host test process: the path branches
    // resolve nothing and report it honestly (the success path is the
    // live vf gate — `ls`/`cat` on a seeded share).
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "ls", "EFI/BOOT" }));
    try std.testing.expectEqualStrings("error: EFI/BOOT: not found (no such directory on the host share)\n", env.mock.contents());
    env.mock.reset();
    try std.testing.expectEqual(ExecError.invalid_argument, exec(&mon, &.{ "cat", "EFI/BOOT/BOOTAA64.EFI" }));
    try std.testing.expectEqualStrings("error: EFI/BOOT/BOOTAA64.EFI: not found (no such file on the host share)\n", env.mock.contents());
    env.mock.reset();
    // The no-arg ls lists the (empty) share.
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{"ls"}));
    try std.testing.expectEqualStrings("ls: host=0x0000000000000000\nls: no files on the host share\n", env.mock.contents());
}

test "monitor: mount reports the host-share state (HF6)" {
    virtio_file.set_test_share(null); // no channel
    defer virtio_file.set_test_share(null);
    var env = TestEnv.init();
    var mon = env.monitor();
    // No host file channel: mount reports it honestly (there are no FAT
    // volumes to switch anymore — HF6 deleted them).
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "mount", "data" }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "mount: no host file channel") != null);
    env.mock.reset();
    // The registry documents the command.
    try std.testing.expectEqualStrings("report the host-share file store (HF6: the FAT volumes are gone)", lookup("mount").?.help);
}

test "monitor: write joins arguments and honestly reports no channel in a test process" {
    virtio_file.set_test_share(null); // no channel
    defer virtio_file.set_test_share(null);
    var env = TestEnv.init();
    var mon = env.monitor();
    // In a host test process there is no file channel; the write must be
    // refused honestly, never faked (the live vf gate exercises the real
    // host-disk write).
    try std.testing.expectEqual(ExecError.not_implemented, exec(&mon, &.{ "write", "hello.txt", "hello", "world" }));
    try std.testing.expectEqualStrings(
        "error: hello.txt: not persisted - host file-channel error\n",
        env.mock.contents(),
    );
    env.mock.reset();
    // Empty content is still refused without a channel.
    try std.testing.expectEqual(ExecError.not_implemented, exec(&mon, &.{ "write", "n.txt" }));
    try std.testing.expect(std.mem.indexOf(u8, env.mock.contents(), "not persisted") != null);
}

test "monitor: exec is registered and refuses honestly without a channel" {
    virtio_file.set_test_share(null); // no channel
    defer virtio_file.set_test_share(null);
    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expect(lookup("exec") != null);
    try std.testing.expectEqualStrings("load a user program from the host share and enter it at EL0", lookup("exec").?.help);
    // No host file channel in a host test process: refused honestly, never
    // faked. (The full load+spawn path is covered by exec.zig's own tests,
    // which serve the in-memory share fixture.)
    try std.testing.expectEqual(ExecError.not_implemented, exec(&mon, &.{"exec"}));
    try std.testing.expectEqualStrings("error: no host file channel (boot the runner with --cvc-file <host-dir>)\n", env.mock.contents());
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
    test_reset_share();
    defer virtio_file.set_test_share(null);
    test_seed_share("NOTEPAD.BIN", "x");

    var env = TestEnv.init();
    var mon = env.monitor();
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "which", "type" }));
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "which", "stat" }));
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "which", "NOTEPAD.BIN" }));
    try std.testing.expectEqual(ExecError.none, exec(&mon, &.{ "which", "nope.bin" }));
    const out = env.mock.contents();
    try std.testing.expect(std.mem.indexOf(u8, out, "type: shell builtin") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "stat: monitor command") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "NOTEPAD.BIN: host-share application") != null);
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

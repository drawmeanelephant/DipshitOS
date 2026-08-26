//! DipshitOS ESP exec (milestone-three card 6, claim 6783; extended by the
//! milestone-four follow-on claim 0826 — concurrent processes).
//!
//! Loads a real user program from the ESP and enters it at EL0. The
//! claim-8215 static EL0 payload is boot-registered; this module loads
//! programs read through the claim-6420 FAT path (`fat.read_file` over
//! virtio-blk): the file is a flat AArch64 image in the same DSK1 format
//! as KERNEL.BIN (`tools/elf2bin.py`, 24-byte header, content at offset
//! 24), built by `zig build user` and embedded on the ESP by the image
//! builder.
//!
//! Exec is the monitor command `exec [<file>]` (default `USER.BIN`):
//!
//!   1. Read the file into a fixed 4 KiB BSS staging buffer (bounded).
//!   2. Validate the DSK1 header (magic, entry offset, image size).
//!   3. Gate on CAPACITY (claim 0826 — the old `user_root_in_use` gate is
//!      gone: a second program loads and runs while the first is alive):
//!      the pool's free slot (checked FIRST, so a full pool never leaks
//!      pages or tables), the page-table carve-out (`table_full`), the
//!      process registry (`process_full`), and the physical allocator
//!      (`out_of_memory`).
//!   4. Allocate the program's OWN pages — 1 text page + 2 user-stack
//!      pages + 2 EL1 exception-stack pages from the physical allocator
//!      (claims 3972/5162) — copy the stripped content into the text page,
//!      and build the process's OWN TTBR0 user root with
//!      `mmu.build_user_root` (claim 5804: identity-tree clone + EL1-only
//!      kernel overlay + the text page at `userspace.text_va` + the user
//!      stack at the randomized `stack_va`). Works POST-install because the
//!      kernel stays identity-mapped (the VZ TTBR1 fallback), so
//!      `@intFromPtr` is still physical; the fresh clone tables are
//!      D-cache-cleaned before the scheduler's next TTBR0 switch. The
//!      process owns every page (freed at reap/recycle), and the boot-time
//!      static payload keeps its linked `.usertext`/`.userbss` pages.
//!   5. Create + bind the process (`process.zig`, claim 3848) and spawn it
//!      as an EL0t task (`scheduler.register_exec_user`) under the fixed
//!      syscall ABI — with its own EL1 exception stack, because two live
//!      user tasks cannot share the static one (a second task's vector
//!      frame would clobber the first's saved context).
//!
//! Card 3e (claim 4636): `exec <file> [arg...]` packs a bounded argv block
//! (8 args × 32 B, NUL-terminated, per-arg 31-byte truncation) into the
//! process's OWN text page right after the loaded content — the text leaf
//! is already EL0 read-only (W^X), so the block is a READ-ONLY leaf with
//! zero extra pages (the per-program 5-page budget and every exact-count
//! page gate stay untouched). The text aperture extends over the block
//! (uaccess reads it, copy_out to it faults), and `_start` receives argc
//! in x0 + the block VA in x1 (an entry-contract extension, NOT a syscall;
//! ADR 0007 frozen). More than 8 args is an honest refusal; a no-args exec
//! is byte-identical to earlier cards.
//!
//! The syscall/uaccess apertures are per process (armed at SVC entry from
//! the task's TCB, claim 0826), so `sys_write` bounds follow whichever
//! program issued the call. No libc, no POSIX, no heap allocation.

const std = @import("std");
const console = @import("console.zig"); // card 3c (claim 7786): the shell-side report drain in host tests
const exceptions = @import("exceptions.zig"); // card 3e (claim 4636): the entry-contract frame slots (x0/x1) in host tests
const uaccess = @import("uaccess.zig"); // card 3e (claim 4636): the args range is read-only (copy_in ok, copy_out fault)
const mmu = @import("mmu.zig");
const esp = @import("esp.zig");
const fat = @import("fat.zig");
const scheduler = @import("scheduler.zig");
const userspace = @import("userspace.zig");
// Milestone four (claim 2665): the seeded CSPRNG supplies the randomized
// user stack VA (the seed's real ASLR consumer).
const csprng = @import("csprng.zig");
const syscall = @import("syscall.zig");
// Milestone four (claim 3848): the loaded program is a PROCESS — the
// image + address space + lifecycle live in the bounded process registry,
// not in this module's globals.
const process = @import("process.zig");
// Card 3f (claim 5965): the per-process IPC mailbox — each exec'd
// process's ring is reset the moment its process id is created.
const mailbox = @import("mailbox.zig");
// Milestone 9 (claim 7670): per-process event queue
const events = @import("events.zig");
const app_timers = @import("app_timers.zig"); // claim 7323: the per-process app timer reset on exec
// Milestone 10 (claim 9948): per-process file handle table
const file_table = @import("file_table.zig");
// Claim 0826: the per-process text/stack/kernel-stack pages come from the
// physical page allocator (claims 3972/5162).
const alloc = @import("alloc.zig");
const memmap = @import("memmap.zig"); // host-test fixture view (page_size + the arming view)
// M22 D1 (issue #324): the AArch64 ELF parse/validate module — exec_file
// sniffs the ELF magic and takes this path alongside DSK1/DSK3.
const elf_mod = @import("elf.zig");
// M22 D3 (issue #326): crash-report symbol names — populated from the
// loaded image's .symtab on every ELF exec, cleared on every other exec.
const symbol = @import("symbol.zig");

/// Fixed load buffer: 256 KiB (64 pages). A program larger than this is
/// rejected honestly (`too_large`). Milestone sixteen C1 (claim 3805) lifts
/// this from the original 16 KiB bound — the M15 JINGLE draft was 33 KB and
/// would not load (claim 7636) — so programs can grow. 256 KiB = 8× the old
/// bound and comfortably fits the first big program (`GLOBALS.BIN`).
pub const exec_program_max: usize = 256 * 1024;
/// Card 3e (claim 4636): the bounded argv block — at most 8 args, each in
/// a 32-byte slot (31 chars + NUL terminator), 256 bytes total. Packed into
/// the process's OWN text page right after the loaded content (the text
/// leaf is already EL0 read-only, W^X), so the block is a READ-ONLY leaf
/// with ZERO extra pages — the per-program 5-page budget and every
/// exact-count page gate stay untouched.
pub const max_exec_args: usize = 8;
pub const arg_slot_bytes: usize = 32;
pub const arg_block_bytes: usize = max_exec_args * arg_slot_bytes; // 256
/// Default file name for `exec` with no argument.
pub const default_name: []const u8 = "USER.BIN";
/// elf2bin.py's DSK1 header size (magic/flags/entry/image_size).
pub const dsk1_header_size: usize = 24;
const dsk1_magic: u32 = 0x314b5344; // "DSK1"
/// Milestone sixteen C1 (claim 3805): the segmented user-image header —
/// 48 bytes: magic/flags/entry/image_size + text_size/data_file_size/
/// data_mem_size, followed by [text+rodata][data] (the BSS tail is implicit
/// zero-fill). The loader maps text EL0-RO+PXN and data+bss EL0-RW+UXN+PXN.
pub const dsk3_header_size: usize = 48;
const dsk3_magic: u32 = 0x334b5344; // "DSK3" ("DSK2" 0x324b5344 is the handoff magic)
/// M22 D1 (issue #324): AArch64 ELF executables ("\x7fELF", little-endian).
const elf_magic: u32 = 0x464c457f;

pub const ExecResult = enum {
    ok,
    /// ESP FAT volume not mounted (host test process, or blk init failed).
    no_disk,
    /// The named file is absent from the volume (or is a directory).
    not_found,
    /// The image (or the file) exceeds the fixed 4 KiB load buffer.
    too_large,
    /// Not a DSK1 flat program image.
    bad_magic,
    /// entry_offset outside the loaded content.
    bad_entry,
    /// No free scheduler pool slot — the capacity gate (claim 0826).
    pool_full,
    /// The physical page allocator could not supply the program's own
    /// text/stack/exception-stack pages (claim 0826).
    out_of_memory,
    /// More than `max_exec_args` arguments were given (card 3e) — an
    /// honest refusal, never silent truncation of the arg list.
    too_many_args,
    /// The image leaves no room for the 256-byte argv block in its 4 KiB
    /// text page (content + block would overflow the page).
    no_args_room,
    /// The fixed page-table carve-out cannot hold another user-root clone.
    table_full,
    /// The process registry holds only live (created/running) processes —
    /// no free slot and no exited descriptor to recycle.
    process_full,
    // M22 D1 (issue #324): honest ELF refusals, one per failure class.
    /// Structurally invalid ELF (bad header, truncated table, entry outside
    /// the initialized text).
    bad_elf,
    /// Not an AArch64 little-endian image.
    unsupported_arch,
    /// The file declares no PT_LOAD program headers.
    no_pt_load,
    /// More than two PT_LOAD segments (the loader maps text + data only).
    too_many_segments,
    /// A segment escapes the load bound/buffer, overlaps the other, or
    /// breaks the W^X / placement contract.
    segment_too_large,
};

/// The loaded program image (BSS, page-aligned so the user root can map the
/// whole page at `userspace.text_va`).
var program: [exec_program_max]u8 align(4096) = undefined;

pub const LoadedInfo = struct {
    name: []const u8,
    /// Content bytes (image minus the 24-byte DSK1 header).
    content_len: usize,
    /// User VA the task enters at.
    entry_va: u64,
    /// The process's OWN randomized user stack VA (claim 0826 — per-process
    /// stacks, so the reply prints this program's placement, not a global).
    stack_va: u64,
    /// Claim 3805 (milestone sixteen C1): the mapped DATA+bss region's byte
    /// length and page count (0 for a flat DSK1 image, which has no
    /// writable segment). The `exec` reply prints these only when non-zero.
    data_len: u64 = 0,
    data_pages: u64 = 0,
};

/// Claim 6359 (ADR 0007 slot 28): the pid of the most recently exec'd
/// process, set at the loader's success point. `sys_exec` returns it so an
/// EL0 launcher can hand the new pid to `sys_wait`/a future `sys_kill`.
/// A later exec overwrites it (single-core, exec is synchronous — no
/// interleaving exec can race the read at return time); the EL1h monitor
/// ignores it.
var last_pid: ?usize = null;

/// Claim 6359: the pid the last successful `exec_file` spawned (null
/// before any exec succeeds).
pub fn last_exec_pid() ?usize {
    return last_pid;
}

/// What the current process's image is (claim 3848): the descriptor lives
/// in the process registry, so this reads the most recently created
/// process instead of a module-global copy — a later exec never leaves
/// stale "last program" state behind.
pub fn loaded() ?LoadedInfo {
    const id = process.current() orelse return null;
    const info = process.info(id) orelse return null;
    if (info.state == .free) return null;
    return .{
        .name = info.name,
        .content_len = info.content_len,
        .entry_va = info.entry_va,
        .stack_va = info.stack_va,
        .data_len = info.data_len,
        .data_pages = info.data_pages,
    };
}

/// The first 8 bytes of the LOADED CONTENT (the stripped image's first
/// instruction). Diagnostic: the `exec` reply prints them so a live run can
/// confirm the exact bytes that will execute at EL0.
pub fn head() [8]u8 {
    var out: [8]u8 = undefined;
    @memcpy(out[0..8], program[0..8]);
    return out;
}

/// Pack `args` into a fixed argv block (card 3e): every slot is 32 bytes,
/// NUL-terminated (the block is zeroed first); a string longer than 31
/// bytes is TRUNCATED to 31 + terminator (documented + host-tested). The
/// caller has already bounded `args.len` to `max_exec_args`. Returns the
/// packed arg count.
pub fn pack_args(args: []const []const u8, block: []u8) usize {
    @memset(block, 0);
    for (args, 0..) |arg, i| {
        const slot = block[i * arg_slot_bytes ..][0..arg_slot_bytes];
        const take = @min(arg.len, arg_slot_bytes - 1);
        @memcpy(slot[0..take], arg[0..take]);
    }
    return args.len;
}

/// The user VA of the argv block for a loaded program with `content_len`
/// content bytes (the block sits right after the content, 8-aligned, in
/// the program's OWN text page). 0 when the block does not fit.
pub fn argv_va_for(content_len: usize) u64 {
    const block_off = (content_len + 7) & ~@as(usize, 7);
    const page_limit = if (content_len == 0) alloc.page_size else ((content_len + alloc.page_size - 1) / alloc.page_size) * alloc.page_size;
    if (block_off + arg_block_bytes > page_limit or block_off + arg_block_bytes > exec_program_max) return 0;
    return userspace.text_va + block_off;
}

/// Load `name` from the ESP, rebuild the user root around it, and spawn it
/// as an EL0t task. `args` (bounded to `max_exec_args`) are packed into the
/// program's text page and passed at entry: `_start` receives argc in x0
/// and the argv block VA in x1 (card 3e — an entry-contract extension, NOT
/// a syscall; ADR 0007 frozen). See the module doc for the ordered steps.
pub fn exec_file(name: []const u8, args: []const []const u8) ExecResult {
    if (args.len > max_exec_args) return .too_many_args;
    if (name.len == 0 or name.len > esp.name_max) return .not_found;
    if (!esp.disk_ready()) return .no_disk;
    const e = esp.lookup(name) orelse return .not_found;
    if (e.kind != .esp_file) return .not_found;
    // Read the raw volume directly (the ESP window only content-loads
    // files ≤ esp_content_max; exec reads up to its own fixed buffer).
    const got = fat.read_file(name, &program) orelse return .not_found;
    if (got < dsk1_header_size) return .bad_magic;
    const magic = std.mem.readInt(u32, program[0..4], .little);
    // Milestone sixteen C1 (claim 3805): two load paths. DSK1 (the flat
    // single-segment shape, kept for the boot-payload-era images and the
    // argv consumers) maps one read-only W^X text page. DSK3 (the segmented
    // shape from `elf2bin.py --segments`) adds a writable data region with a
    // zero-filled BSS tail — the loader maps text EL0-RO+PXN and data+bss
    // EL0-RW+UXN+PXN, so EL0 globals are real writable memory.
    var header_size: usize = dsk1_header_size;
    var entry_off: u64 = 0;
    var image_size: u64 = 0;
    var text_size: usize = 0;
    var data_file_size: usize = 0;
    var data_mem_size: usize = 0;
    // M22 D1: the ELF branch stages the image into the contiguous
    // [text][data] layout itself, so the shared strip below is skipped.
    var pre_staged = false;
    switch (magic) {
        dsk1_magic => {
            entry_off = std.mem.readInt(u64, program[8..16], .little);
            image_size = std.mem.readInt(u64, program[16..24], .little);
            if (image_size > program.len) return .too_large;
            if (image_size > got) return .too_large; // truncated read — file bigger than the buffer
            if (entry_off < dsk1_header_size or entry_off >= image_size) return .bad_entry;
            text_size = @intCast(image_size - dsk1_header_size);
        },
        dsk3_magic => {
            header_size = dsk3_header_size;
            switch (parse_dsk3(&program, got)) {
                .err => |err| return err,
                .ok => |s| {
                    entry_off = s.entry_off;
                    text_size = s.text_size;
                    data_file_size = s.data_file_size;
                    data_mem_size = s.data_mem_size;
                },
            }
        },
        elf_magic => {
            const image = elf_mod.parse(program[0..got]) catch |err| return elf_exec_error(err);
            // M22 D3 (issue #326): crash-report symbol names follow the
            // program — every exec starts from an empty table, then this
            // image's .symtab repopulates it. Harvest BEFORE staging
            // rearranges the buffer (names point into it and the table
            // copies them out immediately).
            symbol.reset();
            var syms: [symbol.max_symbols]elf_mod.SymInfo = undefined;
            const sym_n = elf_mod.collect_symbols(program[0..got], &syms);
            for (syms[0..sym_n]) |si| {
                _ = symbol.add(si.name, si.addr, si.size);
            }
            const seg0 = image.segments[0];
            // The loader contract (elf.zig): segment 0 sits at
            // userspace.text_va, an optional writable segment 1 directly
            // after its memory image. Stage [text][data] contiguously —
            // exactly the stripped DSK3 shape downstream expects. The copy
            // is forward-safe because parse() rejects overlapping file
            // ranges and every destination offset is below its source.
            text_size = @intCast(seg0.mem_size);
            std.mem.copyForwards(u8, program[0..seg0.file_size], program[seg0.file_offset..][0..seg0.file_size]);
            if (image.segment_count == 2) {
                const seg1 = image.segments[1];
                data_file_size = seg1.file_size;
                data_mem_size = seg1.mem_size;
                std.mem.copyForwards(u8, program[text_size..][0..seg1.file_size], program[seg1.file_offset..][0..seg1.file_size]);
            }
            header_size = seg0.file_offset;
            entry_off = header_size + image.entry_rel;
            pre_staged = true;
        },
        else => return .bad_magic,
    }
    // Claim 0826: the exec gate is GONE — a second program loads and runs
    // while the first is alive (every process owns its own root + pages, so
    // nothing shared is rebuilt under a live task). The gates are capacity:
    // the pool slot FIRST (a full pool fails cheaply and never leaks pages
    // or tables), then the allocator, the table carve-out, the registry.
    if (!scheduler.has_free_slot()) return .pool_full;

    const content_len: usize = text_size;
    // Strip the header IN PLACE (staging): the user root maps whole pages
    // at `text_va` (the clone masks the phys to page granularity), so the
    // loadable content must start at a page boundary. The entry offset is
    // file-relative, so the entry VA is `text_va + (entry_offset - header)`.
    // The stripped buffer layout is [text+rodata][data] for both formats
    // (the data portion is empty for DSK1 — `data_file_size` is 0 there).
    // M22 D1: the ELF branch already staged its contiguous layout, so only
    // the DSK header paths strip here.
    if (!pre_staged) {
        std.mem.copyForwards(u8, program[0 .. text_size + data_file_size], program[header_size..][0 .. text_size + data_file_size]);
    }
    @memset(program[text_size + data_file_size ..], 0); // the rest of the staging page is padding
    // Card 3e (claim 4636): pack the argv block into the staging buffer
    // right after the content (it is copied into the process's OWN text
    // page below — the text leaf is already EL0 read-only, so the block is
    // a read-only leaf with no extra page). The text aperture extends over
    // the block, so uaccess reads it (copy_in ok) and writes to it fault
    // (copy_out → EFAULT). A no-args exec packs nothing and keeps the
    // byte-identical text aperture of earlier cards.
    const argc = args.len;
    var argv_va: u64 = 0;
    var text_len: usize = content_len;
    if (argc > 0) {
        // Claim 3805: the segmented path does not yet reserve argv room in
        // its page-aligned text region — an honest refusal (the flat DSK1
        // path keeps the claim-4636 behavior). No current DSK3 program
        // takes arguments; a later card packs argv into a reserved data
        // tail when a DSK3 consumer needs it. M22 D1: ELF images share the
        // refusal (their text region is fixed by the loader contract).
        if (magic != dsk1_magic) return .no_args_room;
        const block_off = (content_len + 7) & ~@as(usize, 7);
        const page_limit = if (content_len == 0) alloc.page_size else ((content_len + alloc.page_size - 1) / alloc.page_size) * alloc.page_size;
        if (block_off + arg_block_bytes > page_limit or block_off + arg_block_bytes > exec_program_max) return .no_args_room;
        _ = pack_args(args, program[block_off..][0..arg_block_bytes]);
        text_len = block_off + arg_block_bytes;
        argv_va = userspace.text_va + block_off;
    }
    // Claim 0826: per-process pages from the physical allocator — the
    // program's OWN text (1 page), user stack (8 KiB = 2 pages) and EL1
    // exception stack (8 KiB = 2 pages). The process owns them and frees
    // them at reap/recycle; the staging `program` buffer is only a read
    // buffer now, so a later exec of a DIFFERENT file can never overwrite
    // a live program's text. The boot-time static payload keeps its linked
    // `.usertext`/`.userbss` pages instead.
    const text_pages: u64 = (text_len + alloc.page_size - 1) / alloc.page_size;
    const text_phys = alloc.alloc_pages(text_pages) orelse return .out_of_memory;
    // Claim 3805: the segmented image's data+bss pages (0 for a flat DSK1
    // image, which has no writable segment).
    const data_pages: u64 = (data_mem_size + alloc.page_size - 1) / alloc.page_size;
    const data_phys: u64 = if (data_pages > 0) (alloc.alloc_pages(data_pages) orelse {
        _ = alloc.free_pages(text_phys, text_pages);
        return .out_of_memory;
    }) else 0;
    const stack_pages: u64 = (scheduler.task_stack_size + alloc.page_size - 1) / alloc.page_size;
    const stack_phys = alloc.alloc_pages(stack_pages) orelse {
        _ = alloc.free_pages(text_phys, text_pages);
        if (data_pages > 0) _ = alloc.free_pages(data_phys, data_pages);
        return .out_of_memory;
    };
    const kstack_pages: u64 = stack_pages;
    const kstack_phys = alloc.alloc_pages(kstack_pages) orelse {
        _ = alloc.free_pages(text_phys, text_pages);
        if (data_pages > 0) _ = alloc.free_pages(data_phys, data_pages);
        _ = alloc.free_pages(stack_phys, stack_pages);
        return .out_of_memory;
    };
    // Copy the stripped content (plus the argv block, card 3e) into the
    // process's OWN text page (the identity map keeps the physical address
    // a valid kernel pointer).
    const text_dst: [*]u8 = @ptrFromInt(text_phys);
    @memcpy(text_dst[0..text_len], program[0..text_len]);
    // Claim 3805: copy the initialized data, then zero-fill the BSS tail
    // (the data aperture maps `data_mem_size` bytes; the file only carried
    // `data_file_size` of them).
    if (data_pages > 0) {
        const data_dst: [*]u8 = @ptrFromInt(data_phys);
        if (data_file_size > 0) @memcpy(data_dst[0..data_file_size], program[text_size .. text_size + data_file_size]);
        @memset(data_dst[data_file_size..data_mem_size], 0);
    }
    const kstack: []u8 = @as(*[scheduler.task_stack_size]u8, @ptrFromInt(kstack_phys))[0..];
    // Milestone four (claim 2665): ASLR — the loaded program's EL0 stack
    // lands at a per-boot random VA from the seeded CSPRNG (page-aligned,
    // 64 KiB placement granularity, clear of text_va); the per-process
    // uaccess stack region follows via set_stack_va so the program may
    // write from its stack through sys_write. Unseeded (host test /
    // fallback) returns the fixed default, so nothing below ever sees an
    // out-of-band VA. rebuild_user_root runs the whole sequence (randomize
    // → map → clean → re-arm) — shared with the boot-time static payload
    // (claim 3693), which passes the static stack phys instead.
    // Claim 3805: the data aperture maps right after the (page-aligned)
    // text region, matching the linker's `.data` placement at base + text_size.
    const data_va = userspace.text_va + text_size;
    const rebuild = rebuild_user_root_full(text_phys, @intCast(text_len), data_va, data_phys, @intCast(data_mem_size), stack_phys, scheduler.task_stack_size) orelse {
        _ = alloc.free_pages(text_phys, text_pages);
        if (data_pages > 0) _ = alloc.free_pages(data_phys, data_pages);
        _ = alloc.free_pages(stack_phys, stack_pages);
        _ = alloc.free_pages(kstack_phys, kstack_pages);
        return .table_full;
    };

    const entry_va = userspace.text_va + (entry_off - header_size);
    // Milestone four (claim 3848): the loaded program is a PROCESS. The
    // descriptor owns the image + the rebuilt address space + the owned
    // pages; a later exec creates a NEW process (per-process identity)
    // instead of overwriting module globals. The process registry is
    // exhausted only when every slot holds a live process (no exited
    // descriptor to recycle) — an honest, distinct failure from the pool
    // being full.
    const proc_id = process.create(
        name,
        .{ .entry_va = entry_va, .content_len = content_len },
        .{
            .root_phys = rebuild.root_phys,
            .text_va = userspace.text_va,
            .text_len = @intCast(text_len),
            .text_phys = text_phys,
            .text_pages = text_pages,
            .data_va = data_va,
            .data_len = @intCast(data_mem_size),
            .data_phys = data_phys,
            .data_pages = data_pages,
            .stack_va = rebuild.stack_va,
            .stack_len = scheduler.task_stack_size,
            .stack_phys = stack_phys,
            .stack_pages = stack_pages,
        },
        .{ .phys = kstack_phys, .pages = kstack_pages },
    ) orelse {
        _ = alloc.free_pages(text_phys, text_pages);
        if (data_pages > 0) _ = alloc.free_pages(data_phys, data_pages);
        _ = alloc.free_pages(stack_phys, stack_pages);
        _ = alloc.free_pages(kstack_phys, kstack_pages);
        return .process_full;
    };
    // Card 3f (claim 5965): the new process's IPC ring starts clean — a
    // recycled process id must never inherit an earlier occupant's queued
    // messages (cross-process isolation at the mailbox level). Card E1: same
    // for event queue.
    mailbox.reset(proc_id);
    events.reset(proc_id);
    file_table.reset_process(proc_id);
    app_timers.reset(proc_id); // claim 7323: a recycled pid inherits no stale app timer
    if (scheduler.register_exec_user(entry_va, rebuild.root_phys, @intCast(text_len), rebuild.stack_va, scheduler.task_stack_size, kstack, @intCast(argc), argv_va)) |task_id| {
        _ = process.bind(proc_id, task_id);
    } else {
        // Defensive rollback (the upfront slot check makes this
        // unreachable): the process reap frees its owned pages.
        _ = process.reap(proc_id);
        return .pool_full;
    }
    // Claim 6359 (slot 28 `sys_exec`): record the spawned pid at the true
    // success point so the EL0 caller can read it back.
    last_pid = proc_id;
    return .ok;
}

/// M22 D1 (issue #324): map an `elf.parse` refusal onto the exec result —
/// one honest class per failure, matching the issue's message list.
fn elf_exec_error(err: elf_mod.Error) ExecResult {
    return switch (err) {
        error.not_elf,
        error.truncated,
        error.bad_phdr,
        => .bad_elf,
        error.unsupported_class,
        error.unsupported_endian,
        error.unsupported_machine,
        => .unsupported_arch,
        error.no_load_segments => .no_pt_load,
        error.too_many_segments => .too_many_segments,
        error.bad_entry => .bad_entry,
        error.segment_too_large,
        error.overlapping_segments,
        error.writable_text,
        error.readable_data,
        error.bad_text_base,
        error.bad_data_base,
        => .segment_too_large,
    };
}

/// Rebuild the EL0 user root around a fresh randomized stack placement
/// (milestone-four ASLR, claims 2665 + 3693): draw a per-boot stack VA
/// from the seeded CSPRNG, map `text_len` bytes of `text_phys` at
/// `userspace.text_va` plus the user stack at the new base (`stack_phys`,
/// `stack_len` bytes), clean the fresh clone tables + mapped text (the
/// walker and EL0 instruction fetch must see the real bytes), and re-arm
/// the syscall/uaccess regions so `sys_write` bounds follow the new base.
/// The single shared sequence for the exec path (the loaded program's own
/// pages, claim 0826) and the boot-time rebuild of the static EL0 payload
/// (claim 3693, which passes the static `.userbss` stack phys).
///
/// `stack_len` must cover the FULL `.userbss` section for the static boot
/// payload: the scheduler's timer-preemption witness sits just past the
/// 8 KiB stack, and its VA is base-relative to the stack, so the rebuilt
/// root must map it too. Exec passes the task stack size (no witness).
///
/// Claim 0826: the rebuilt root is the process's OWN root — `build_user_root`
/// returns its phys, and the caller records it in the process descriptor
/// (and hands it to `register_exec_user`), so a second exec never touches
/// the first process's live root. Returns null when the fixed table
/// carve-out cannot hold another user-root clone (the caller's root is
/// then unchanged).
pub const RootInfo = struct {
    /// Physical root of the freshly built per-process TTBR0 user root.
    root_phys: u64,
    /// The randomized user stack VA mapped in that root.
    stack_va: u64,
};

pub fn rebuild_user_root(text_phys: u64, text_len: u64, stack_phys: u64, stack_len: u64) ?RootInfo {
    return rebuild_user_root_full(text_phys, text_len, 0, 0, 0, stack_phys, stack_len);
}

/// The full rebuild (milestone sixteen C1, claim 3805): like
/// `rebuild_user_root` but with a writable DATA aperture (`data_phys`,
/// `data_len` at `data_va`) mapped between text and stack — the segmented
/// image's `.data` + zeroed `.bss`. `data_len == 0` omits the aperture.
pub fn rebuild_user_root_full(
    text_phys: u64,
    text_len: u64,
    data_va: u64,
    data_phys: u64,
    data_len: u64,
    stack_phys: u64,
    stack_len: u64,
) ?RootInfo {
    const stack_va = csprng.random_stack_va();
    userspace.set_stack_va(stack_va);
    const root_phys = mmu.build_user_root_full(
        userspace.text_va,
        text_phys,
        text_len,
        data_va,
        data_phys,
        data_len,
        stack_va,
        stack_phys,
        stack_len,
    ) orelse return null;
    // The fresh clone tables and the mapped text/data are dirty in the
    // D-cache; clean both before the scheduler's next TTBR0 switch (the
    // walker + EL0 instruction/data fetch must see the real bytes).
    mmu.clean_table_storage();
    mmu.clean_dcache_range(text_phys, text_len);
    if (data_len > 0) mmu.clean_dcache_range(data_phys, data_len);
    // The user stack aperture moved: re-arm the syscall/uaccess regions so
    // sys_write bounds follow the randomized base (per-task re-arming at
    // SVC entry keeps every process's bounds correct, claim 0826).
    syscall.set_user_regions(userspace.text_va_region(), userspace.stack_va_region());
    return .{ .root_phys = root_phys, .stack_va = stack_va };
}

// ---------------------------------------------------------------------------
// Tests (host-side: in-memory FAT fixture; the MMU clone builds an empty
// root on the host, so the tests pin the load/validate/gate/spawn logic)
// ---------------------------------------------------------------------------

const test_allocator = std.testing.allocator;

/// The segmented DSK3 header fields (claim 3805), parsed + validated.
pub const Segments = struct {
    entry_off: u64,
    text_size: usize,
    data_file_size: usize,
    data_mem_size: usize,
};

/// Parse + validate a DSK3 segmented header at the start of `buf` (the
/// first `got` bytes are valid). Pure — no globals — so host tests pin the
/// boundary checks without a FAT fixture (a valid DSK3 image is always
/// ≥ 4 KiB of page-aligned text, above the 2 KiB test write cap).
pub fn parse_dsk3(buf: []const u8, got: usize) union(enum) { ok: Segments, err: ExecResult } {
    const entry_off = std.mem.readInt(u64, buf[8..16], .little);
    const image_size = std.mem.readInt(u64, buf[16..24], .little);
    const text_size: usize = @intCast(std.mem.readInt(u64, buf[24..32], .little));
    const data_file_size: usize = @intCast(std.mem.readInt(u64, buf[32..40], .little));
    const data_mem_size: usize = @intCast(std.mem.readInt(u64, buf[40..48], .little));
    if (image_size > buf.len) return .{ .err = .too_large };
    if (image_size > got) return .{ .err = .too_large }; // truncated read
    if (image_size != dsk3_header_size + text_size + data_file_size) return .{ .err = .bad_magic };
    if (text_size == 0 or text_size > exec_program_max) return .{ .err = .too_large };
    if (data_mem_size < data_file_size or data_mem_size > exec_program_max) return .{ .err = .too_large };
    if (entry_off < dsk3_header_size or entry_off >= dsk3_header_size + text_size) return .{ .err = .bad_entry };
    return .{ .ok = .{
        .entry_off = entry_off,
        .text_size = text_size,
        .data_file_size = data_file_size,
        .data_mem_size = data_mem_size,
    } };
}

/// Build a minimal DSK1 flat image: header (entry at offset 24 = content
/// start) + `content`.
fn dsk1(content: []const u8, entry_off: u64, image_size: u64) [dsk1_header_size + 64]u8 {
    var img = [_]u8{0} ** (dsk1_header_size + 64);
    std.mem.writeInt(u32, img[0..4], dsk1_magic, .little);
    std.mem.writeInt(u32, img[4..8], 0, .little);
    std.mem.writeInt(u64, img[8..16], entry_off, .little);
    std.mem.writeInt(u64, img[16..24], image_size, .little);
    @memcpy(img[dsk1_header_size..][0..content.len], content);
    return img;
}

var saved_image: []u8 = undefined;

fn fake_read(lba: u64, out: *[fat.sector_size]u8) bool {
    const off = lba * fat.sector_size;
    if (off + fat.sector_size > saved_image.len) return false;
    @memcpy(out, saved_image[off .. off + fat.sector_size]);
    return true;
}

fn fake_write(lba: u64, data: *const [fat.sector_size]u8) bool {
    const off = lba * fat.sector_size;
    if (off + fat.sector_size > saved_image.len) return false;
    @memcpy(saved_image[off .. off + fat.sector_size], data);
    return true;
}

/// Arm the module physical allocator with a small fixture map, the way the
/// kernel arms it post-boot (claim 0826: exec allocates the program's own
/// pages, so the successful-path tests need a real pool). The pool backs a
/// HOST buffer: exec dereferences the program's text page to load its
/// bytes (`@ptrFromInt(text_phys)` is valid on the identity-mapped kernel,
/// but a fake 0x100000 base would segfault the host tests).
// Milestone sixteen C3 (claim 0339): the pool grew to EIGHT live user
// programs, and each exec'd program owns 9 pages (text 1 + user stack 4 +
// EL1 exception stack 4), so the fixture pool must back 8 × 9 = 72 pages
// plus headroom.
var fixture_pool: [256 * 4096]u8 align(4096) = undefined;

fn arm_allocator() void {
    const descriptors = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = @intFromPtr(&fixture_pool), .virtual_start = 0, .number_of_pages = 256, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&descriptors), @sizeOf(memmap.MemoryDescriptor), descriptors.len);
    _ = alloc.init(view, &.{});
}

test "exec: DSK1 header parse rejects bad magic, entry, and oversize images" {
    try build_image(test_allocator);
    defer test_allocator.free(saved_image);
    esp.reset();
    try std.testing.expectEqual(fat.MountResult.ok, esp.set_disk(.{ .read = &fake_read, .write = &fake_write }));
    try std.testing.expectEqual(ExecResult.not_found, exec_file("NOPE.BIN", &.{}));

    // Bad magic.
    try std.testing.expectEqual(esp.WriteResult.ok, esp.write_file("USER.BIN", "NOT A DSK1 IMAGE!"));
    try std.testing.expectEqual(ExecResult.bad_magic, exec_file("USER.BIN", &.{}));

    // entry_offset below the 24-byte header (and past the content).
    const bad_entry = dsk1("xx", 4, 24 + 2);
    try std.testing.expectEqual(esp.WriteResult.ok, esp.write_file("USER.BIN", bad_entry[0 .. 24 + 2]));
    try std.testing.expectEqual(ExecResult.bad_entry, exec_file("USER.BIN", &.{}));
    const bad_entry2 = dsk1("xx", 30, 24 + 2);
    try std.testing.expectEqual(esp.WriteResult.ok, esp.write_file("USER.BIN", bad_entry2[0 .. 24 + 2]));
    try std.testing.expectEqual(ExecResult.bad_entry, exec_file("USER.BIN", &.{}));

    // image_size beyond the fixed buffer.
    const oversize = dsk1("xx", 24, exec_program_max + 1);
    try std.testing.expectEqual(esp.WriteResult.ok, esp.write_file("USER.BIN", oversize[0 .. 24 + 2]));
    try std.testing.expectEqual(ExecResult.too_large, exec_file("USER.BIN", &.{}));
}

test "exec: no disk is reported honestly" {
    esp.reset();
    try std.testing.expectEqual(ExecResult.no_disk, exec_file("USER.BIN", &.{}));
}

test "exec: DSK3 header validation pins the segment bounds (claim 3805)" {
    var buf: [dsk3_header_size + 4096 + 16]u8 = [_]u8{0} ** (dsk3_header_size + 4096 + 16);
    // A valid segmented header: page-aligned 4 KiB text + 8 data + 8 BSS.
    std.mem.writeInt(u32, buf[0..4], dsk3_magic, .little);
    std.mem.writeInt(u64, buf[8..16], dsk3_header_size, .little); // entry at content start
    std.mem.writeInt(u64, buf[16..24], dsk3_header_size + 4096 + 8, .little);
    std.mem.writeInt(u64, buf[24..32], 4096, .little);
    std.mem.writeInt(u64, buf[32..40], 8, .little);
    std.mem.writeInt(u64, buf[40..48], 16, .little);
    const got = buf.len;
    const ok = parse_dsk3(&buf, got).ok;
    try std.testing.expectEqual(@as(u64, dsk3_header_size), ok.entry_off);
    try std.testing.expectEqual(@as(usize, 4096), ok.text_size);
    try std.testing.expectEqual(@as(usize, 8), ok.data_file_size);
    try std.testing.expectEqual(@as(usize, 16), ok.data_mem_size);

    // image_size must equal header + text + data_file (no phantom bytes).
    var bad_image = buf;
    std.mem.writeInt(u64, bad_image[16..24], dsk3_header_size + 4096 + 7, .little);
    try std.testing.expectEqual(ExecResult.bad_magic, parse_dsk3(&bad_image, got).err);

    // A zero text region is not a loadable program.
    var zero_text = buf;
    std.mem.writeInt(u64, zero_text[24..32], 0, .little);
    std.mem.writeInt(u64, zero_text[16..24], dsk3_header_size + 0 + 8, .little);
    try std.testing.expectEqual(ExecResult.too_large, parse_dsk3(&zero_text, got).err);

    // BSS must not be smaller than the initialized data.
    var bad_bss = buf;
    std.mem.writeInt(u64, bad_bss[40..48], 4, .little);
    try std.testing.expectEqual(ExecResult.too_large, parse_dsk3(&bad_bss, got).err);

    // The entry must land inside the RX region.
    var bad_entry = buf;
    std.mem.writeInt(u64, bad_entry[8..16], dsk3_header_size + 4096, .little); // == text end
    try std.testing.expectEqual(ExecResult.bad_entry, parse_dsk3(&bad_entry, got).err);

    // A truncated read (got < image_size) is an honest too_large.
    try std.testing.expectEqual(ExecResult.too_large, parse_dsk3(&buf, dsk3_header_size + 4096 + 4).err);
}

test "exec: ok path loads, validates, builds the root, and spawns the task" {
    try build_image(test_allocator);
    defer test_allocator.free(saved_image);
    esp.reset();
    try std.testing.expectEqual(fat.MountResult.ok, esp.set_disk(.{ .read = &fake_read, .write = &fake_write }));
    arm_allocator();
    // Give the boot user root a real (non-zero) value so the payload's
    // task carries it: the EL1h tasks keep the kernel root (0).
    _ = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192) orelse return error.TestUnexpectedResult;
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    // Retire the static user task (a normal boot's payload exits early),
    // freeing its pool slot for the exec'd program.
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expect(scheduler.exit_current(7)); // user -> idle
    try std.testing.expect(scheduler.reap(2));

    const img = dsk1("user: hello from the ESP\n", 24, 24 + 25);
    try std.testing.expectEqual(esp.WriteResult.ok, esp.write_file("USER.BIN", img[0 .. 24 + 25]));
    try std.testing.expectEqual(ExecResult.ok, exec_file("USER.BIN", &.{}));
    const info = loaded().?;
    try std.testing.expectEqualStrings("USER.BIN", info.name);
    try std.testing.expectEqual(@as(usize, 25), info.content_len);
    try std.testing.expectEqual(userspace.text_va, info.entry_va); // entry at content start
    try std.testing.expect(info.stack_va != 0);
    // The 24-byte DSK1 header is stripped in the staging buffer: the
    // loaded content starts with the program bytes, not "DSK1".
    try std.testing.expectEqualStrings("user: hello from the ESP\n", program[0..25]);
    const h = head();
    try std.testing.expectEqualStrings("user: he", h[0..8]);
    const t = scheduler.task_info(2).?;
    try std.testing.expectEqualStrings("user-exec", t.name);
    try std.testing.expectEqual(@as(u64, 0), t.saves);
    try std.testing.expectEqual(@as(u64, 0), t.resumes);
    // Claim 3848: the exec'd program is a PROCESS — the boot payload's
    // process (exited, status 7) and the new USER.BIN process (bound to
    // the spawned task, carrying the rebuilt address space) both exist.
    try std.testing.expectEqual(@as(usize, 2), process.count());
    // Claim 6359 (slot 28 `sys_exec`): the loader records the spawned pid
    // so an EL0 caller can read it back.
    try std.testing.expectEqual(@as(?usize, 1), last_exec_pid());
    const boot_proc = process.info(0).?;
    try std.testing.expectEqualStrings("user-el0", boot_proc.name);
    try std.testing.expectEqual(process.State.exited, boot_proc.state);
    try std.testing.expectEqual(@as(u64, 7), boot_proc.exit_status);
    const exec_proc = process.info(1).?;
    try std.testing.expectEqualStrings("USER.BIN", exec_proc.name);
    try std.testing.expectEqual(process.State.running, exec_proc.state);
    try std.testing.expectEqual(@as(?usize, 2), exec_proc.task_id);
    try std.testing.expectEqual(@as(u64, 25), exec_proc.content_len);
    try std.testing.expectEqual(userspace.text_va, exec_proc.entry_va);
    try std.testing.expectEqual(mmu.user_root_phys(), exec_proc.root_phys);
    try std.testing.expectEqual(@as(u64, 32768), exec_proc.stack_len);
    // Claim 0826: the process owns its own text/stack/kernel-stack pages
    // from the physical allocator (the boot payload owns none of these).
    try std.testing.expect(exec_proc.text_phys != 0);
    try std.testing.expectEqual(@as(u64, 1), exec_proc.text_pages);
    try std.testing.expect(exec_proc.stack_phys != 0);
    try std.testing.expectEqual(@as(u64, 8), exec_proc.stack_pages);
    try std.testing.expect(exec_proc.kernel_stack_phys != 0);
    try std.testing.expectEqual(@as(u64, 8), exec_proc.kernel_stack_pages);
    // The loaded bytes landed in the process's OWN text page.
    const text_dst: [*]const u8 = @ptrFromInt(exec_proc.text_phys);
    try std.testing.expectEqualStrings("user: hello from the ESP\n", text_dst[0..25]);
}

test "exec: a second program loads and runs while the first is alive" {
    try build_image(test_allocator);
    defer test_allocator.free(saved_image);
    esp.reset();
    try std.testing.expectEqual(fat.MountResult.ok, esp.set_disk(.{ .read = &fake_read, .write = &fake_write }));
    arm_allocator();
    _ = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192) orelse return error.TestUnexpectedResult;
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    // Retire the boot payload (exit + reap) so BOTH exec'd programs fit
    // the fixed pool (shell + worker + exec A + exec B + idle).
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expect(scheduler.exit_current(7));
    try std.testing.expect(scheduler.reap(2));
    const img = dsk1("user: hello from the ESP\n", 24, 24 + 25);
    try std.testing.expectEqual(esp.WriteResult.ok, esp.write_file("USER.BIN", img[0 .. 24 + 25]));
    // Claim 0826: the exec gate is gone — the FIRST exec succeeds with the
    // pool slot free, and the SECOND through EIGHTH succeed WITHOUT waiting
    // for the earlier programs to exit (the old `user_busy` refusal is
    // gone). Milestone sixteen C3 (claim 0339): the 11-slot budget holds
    // EIGHT live user programs.
    var n: usize = 0;
    while (n < 8) : (n += 1) {
        try std.testing.expectEqual(ExecResult.ok, exec_file("USER.BIN", &.{}));
    }
    // All eight programs are live: RUNNING USER.BIN processes with their
    // OWN roots, stacks, and executor tasks (the procs-table shape the
    // live gate asserts — EIGHT live programs is the C3 headline at the
    // host level).
    try std.testing.expectEqual(@as(usize, 9), process.count()); // boot exited + A..H
    const proc_a = process.info(1).?;
    const proc_b = process.info(2).?;
    const proc_c = process.info(3).?;
    const proc_d = process.info(4).?;
    const proc_e = process.info(5).?;
    const proc_f = process.info(6).?;
    const proc_g = process.info(7).?;
    const proc_h = process.info(8).?;
    try std.testing.expectEqualStrings("USER.BIN", proc_a.name);
    try std.testing.expectEqualStrings("USER.BIN", proc_b.name);
    try std.testing.expectEqualStrings("USER.BIN", proc_h.name);
    try std.testing.expectEqual(process.State.running, proc_a.state);
    try std.testing.expectEqual(process.State.running, proc_b.state);
    try std.testing.expectEqual(process.State.running, proc_c.state);
    try std.testing.expectEqual(process.State.running, proc_d.state);
    try std.testing.expectEqual(process.State.running, proc_e.state);
    try std.testing.expectEqual(process.State.running, proc_f.state);
    try std.testing.expectEqual(process.State.running, proc_g.state);
    try std.testing.expectEqual(process.State.running, proc_h.state);
    // Distinct executors, roots, and pages across all eight processes.
    const tasks_set = [_]usize{ proc_a.task_id.?, proc_b.task_id.?, proc_c.task_id.?, proc_d.task_id.?, proc_e.task_id.?, proc_f.task_id.?, proc_g.task_id.?, proc_h.task_id.? };
    for (tasks_set, 0..) |t1, i| for (tasks_set[i + 1 ..]) |t2| try std.testing.expect(t1 != t2);
    const roots_set = [_]u64{ proc_a.root_phys, proc_b.root_phys, proc_c.root_phys, proc_d.root_phys, proc_e.root_phys, proc_f.root_phys, proc_g.root_phys, proc_h.root_phys };
    for (roots_set, 0..) |r1, i| for (roots_set[i + 1 ..]) |r2| try std.testing.expect(r1 != r2);
    // Per-process ASLR (claim 0826): each process owns its stack PLACEMENT
    // (distinct when the CSPRNG is seeded, identical fixed VA when not) —
    // the ownership claim is the PHYSICAL pages + roots, which must differ.
    try std.testing.expect(proc_a.text_phys != proc_b.text_phys);
    try std.testing.expect(proc_a.stack_phys != proc_b.stack_phys);
    try std.testing.expectEqualStrings("user-exec", scheduler.task_info(proc_a.task_id.?).?.name);
    try std.testing.expectEqualStrings("user-exec", scheduler.task_info(proc_h.task_id.?).?.name);
    // The pool is the capacity gate: a NINTH program cannot load.
    try std.testing.expect(!scheduler.has_free_slot());
    try std.testing.expectEqual(ExecResult.pool_full, exec_file("USER.BIN", &.{}));
    try std.testing.expectEqual(@as(usize, 9), process.count()); // pool_full allocates nothing

}

test "exec: a live user task does not block a second exec (gate is gone)" {
    try build_image(test_allocator);
    defer test_allocator.free(saved_image);
    esp.reset();
    try std.testing.expectEqual(fat.MountResult.ok, esp.set_disk(.{ .read = &fake_read, .write = &fake_write }));
    arm_allocator();
    _ = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192) orelse return error.TestUnexpectedResult;
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    const img = dsk1("user: hello from the ESP\n", 24, 24 + 25);
    try std.testing.expectEqual(esp.WriteResult.ok, esp.write_file("USER.BIN", img[0 .. 24 + 25]));
    // The boot payload's user task (slot 2) is STILL ALIVE — the old
    // `user_busy` gate is gone. The exec'd program gets its OWN root,
    // stack, and task, so it loads and runs alongside the payload.
    try std.testing.expectEqual(ExecResult.ok, exec_file("USER.BIN", &.{}));
    // Slot 2 stays the boot payload's; the exec'd program takes the spare
    // slot 3 and runs alongside it.
    try std.testing.expectEqualStrings("user-el0", scheduler.task_info(2).?.name);
    try std.testing.expectEqualStrings("user-exec", scheduler.task_info(3).?.name);
    // Both live processes now exist: boot payload + exec'd program.
    try std.testing.expectEqual(@as(usize, 2), process.count());
    try std.testing.expectEqual(process.State.running, process.info(1).?.state);
    try std.testing.expect(process.info(1).?.root_phys != process.info(0).?.root_phys);
}

test "exec: COUNTER.BIN loads by name with its own marker and process" {
    try build_image(test_allocator);
    defer test_allocator.free(saved_image);
    esp.reset();
    try std.testing.expectEqual(fat.MountResult.ok, esp.set_disk(.{ .read = &fake_read, .write = &fake_write }));
    arm_allocator();
    _ = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192) orelse return error.TestUnexpectedResult;
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    // Retire the boot payload so its slot is free for the counter.
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expect(scheduler.exit_current(7));
    try std.testing.expect(scheduler.reap(2));

    // The counter's DSK1 image carries its DISTINCT marker (claim 4613 —
    // the `counter: alive` line the live gate greps for; deliberately
    // different from every USER.BIN marker so the serial log can tell the
    // two programs apart).
    const img = dsk1("counter: alive\n", 24, 24 + 15);
    try std.testing.expectEqual(esp.WriteResult.ok, esp.write_file("COUNTER.BIN", img[0 .. 24 + 15]));
    try std.testing.expectEqual(ExecResult.ok, exec_file("COUNTER.BIN", &.{}));
    const info = loaded().?;
    try std.testing.expectEqualStrings("COUNTER.BIN", info.name);
    try std.testing.expectEqual(@as(usize, 15), info.content_len);
    // The marker landed in the process's OWN text page (this program's
    // content, not USER.BIN's).
    const proc = process.info(1).?;
    try std.testing.expectEqualStrings("COUNTER.BIN", proc.name);
    try std.testing.expectEqual(process.State.running, proc.state);
    try std.testing.expect(proc.text_phys != 0);
    const text_dst: [*]const u8 = @ptrFromInt(proc.text_phys);
    try std.testing.expectEqualStrings("counter: alive\n", text_dst[0..15]);
    // USER.BIN is a DIFFERENT program: exec it too — the two live
    // processes are DISTINCT programs now (the claim-0826 gate ran two
    // copies of the same image).
    const img2 = dsk1("user: hello from the ESP\n", 24, 24 + 25);
    try std.testing.expectEqual(esp.WriteResult.ok, esp.write_file("USER.BIN", img2[0 .. 24 + 25]));
    try std.testing.expectEqual(ExecResult.ok, exec_file("USER.BIN", &.{}));
    try std.testing.expectEqualStrings("USER.BIN", loaded().?.name);
    try std.testing.expectEqual(@as(usize, 3), process.count()); // boot exited + COUNTER + USER
    try std.testing.expectEqual(process.State.running, process.info(1).?.state);
    try std.testing.expectEqual(process.State.running, process.info(2).?.state);
    try std.testing.expect(process.info(1).?.text_phys != process.info(2).?.text_phys);
}

/// M22 D1 (issue #324): build a minimal but fully valid AArch64 ELF32
/// executable — ELF header (52 B) + one PT_LOAD phdr (32 B) + code. The
/// single segment is R+X at `elf_mod.text_base` with entry at its start.
fn elf32_hello() [128]u8 {
    var img = [_]u8{0} ** 128;
    @memcpy(img[0..4], &elf_mod.magic);
    img[4] = 1; // ELF32
    img[5] = 1; // little-endian
    img[6] = 1; // EV_CURRENT
    std.mem.writeInt(u16, img[16..18], 2, .little); // e_type = EXEC
    std.mem.writeInt(u16, img[18..20], elf_mod.em_aarch64, .little);
    std.mem.writeInt(u32, img[20..24], 1, .little); // e_version
    std.mem.writeInt(u32, img[24..28], @intCast(elf_mod.text_base), .little); // e_entry
    std.mem.writeInt(u32, img[28..32], 52, .little); // e_phoff
    std.mem.writeInt(u16, img[40..42], 52, .little); // e_ehsize
    std.mem.writeInt(u16, img[42..44], 32, .little); // e_phentsize
    std.mem.writeInt(u16, img[44..46], 1, .little); // e_phnum
    std.mem.writeInt(u32, img[52..56], 1, .little); // PT_LOAD
    std.mem.writeInt(u32, img[56..60], 84, .little); // p_offset (after headers)
    std.mem.writeInt(u32, img[60..64], @intCast(elf_mod.text_base), .little); // p_vaddr
    std.mem.writeInt(u32, img[68..72], 44, .little); // p_filesz (128 - 84)
    std.mem.writeInt(u32, img[72..76], 44, .little); // p_memsz
    std.mem.writeInt(u32, img[76..80], 5, .little); // R+X
    const marker = "elf: loaded from the ESP\n";
    @memcpy(img[84..][0..marker.len], marker);
    return img;
}

test "exec: a valid AArch64 ELF32 loads through the magic-sniff path" {
    try build_image(test_allocator);
    defer test_allocator.free(saved_image);
    esp.reset();
    try std.testing.expectEqual(fat.MountResult.ok, esp.set_disk(.{ .read = &fake_read, .write = &fake_write }));
    arm_allocator();
    _ = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192) orelse return error.TestUnexpectedResult;
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expect(scheduler.exit_current(7));
    try std.testing.expect(scheduler.reap(2));

    const hello = elf32_hello();
    try std.testing.expectEqual(esp.WriteResult.ok, esp.write_file("HELLO.ELF", hello[0..]));
    try std.testing.expectEqual(ExecResult.ok, exec_file("HELLO.ELF", &.{}));
    const info = loaded().?;
    try std.testing.expectEqualStrings("HELLO.ELF", info.name);
    // content_len is the segment's memory size; the entry lands at the
    // aperture base (entry_rel == 0 for this fixture).
    try std.testing.expectEqual(@as(usize, 44), info.content_len);
    try std.testing.expectEqual(userspace.text_va, info.entry_va);
    // The staged text page carries the segment bytes, not the ELF header.
    const proc = process.info(1).?;
    try std.testing.expectEqualStrings("HELLO.ELF", proc.name);
    const text_dst: [*]const u8 = @ptrFromInt(proc.text_phys);
    try std.testing.expectEqualStrings("elf: loaded from the ESP\n", text_dst[0..25]);

    // Honest refusals: an x86_64-marked image and a truncated header.
    var x86 = elf32_hello();
    std.mem.writeInt(u16, x86[18..20], 0x3e, .little); // EM_X86_64
    try std.testing.expectEqual(esp.WriteResult.ok, esp.write_file("BAD.ELF", x86[0..]));
    try std.testing.expectEqual(ExecResult.unsupported_arch, exec_file("BAD.ELF", &.{}));
    // Truncated ELF (magic intact, header cut short) → honest refusal.
    try std.testing.expectEqual(esp.WriteResult.ok, esp.write_file("SHORT.ELF", hello[0..40]));
    try std.testing.expectEqual(ExecResult.bad_elf, exec_file("SHORT.ELF", &.{}));
}

test "exec: PEER.BIN loads by name — counter + peer fill the 11-slot pool" {
    // Card 3f (claim 5965): the THIRD ESP program loads by name exactly
    // like USER.BIN/COUNTER.BIN (same DSK1 pipeline). Milestone sixteen
    // C3 (claim 0339): the 11-slot budget holds EIGHT user programs —
    // counter + peer + six USER.BINs = 11/11 (shell + worker + 8 users +
    // idle), so a NINTH exec is pool_full (the 3b capacity proof
    // re-derived at the grown budget).
    try build_image(test_allocator);
    defer test_allocator.free(saved_image);
    esp.reset();
    try std.testing.expectEqual(fat.MountResult.ok, esp.set_disk(.{ .read = &fake_read, .write = &fake_write }));
    arm_allocator();
    _ = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192) orelse return error.TestUnexpectedResult;
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    // Retire the boot payload so BOTH exec'd programs fit the pool.
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expect(scheduler.exit_current(7));
    try std.testing.expect(scheduler.reap(2));

    const counter_img = dsk1("counter: alive\n", 24, 24 + 15);
    try std.testing.expectEqual(esp.WriteResult.ok, esp.write_file("COUNTER.BIN", counter_img[0 .. 24 + 15]));
    const peer_img = dsk1("peer: got \n", 24, 24 + 11);
    try std.testing.expectEqual(esp.WriteResult.ok, esp.write_file("PEER.BIN", peer_img[0 .. 24 + 11]));
    // Both load by name, each with its OWN process and executor slot.
    try std.testing.expectEqual(ExecResult.ok, exec_file("COUNTER.BIN", &.{})); // pid 1, slot 2
    try std.testing.expectEqual(ExecResult.ok, exec_file("PEER.BIN", &.{})); // pid 2, slot 3
    const counter = process.info(1).?;
    const peer = process.info(2).?;
    try std.testing.expectEqualStrings("COUNTER.BIN", counter.name);
    try std.testing.expectEqualStrings("PEER.BIN", peer.name);
    try std.testing.expectEqual(process.State.running, counter.state);
    try std.testing.expectEqual(process.State.running, peer.state);
    try std.testing.expect(counter.task_id != peer.task_id);
    try std.testing.expect(counter.text_phys != peer.text_phys);
    try std.testing.expect(counter.stack_phys != peer.stack_phys);
    // The peer's payload is in ITS OWN text page (its marker, not the
    // counter's — the serial log can tell the two programs apart).
    const peer_text: [*]const u8 = @ptrFromInt(peer.text_phys);
    try std.testing.expectEqualStrings("peer: got \n", peer_text[0..11]);
    // C3 (claim 0339): six more USER.BINs load (counter + peer + six users
    // = EIGHT user slots — the grown budget's headline), then the pool is
    // 11/11: a NINTH exec is pool_full, checked BEFORE any allocation
    // (nothing leaks).
    const user_img = dsk1("user: hello from the ESP\n", 24, 24 + 25);
    try std.testing.expectEqual(esp.WriteResult.ok, esp.write_file("USER.BIN", user_img[0 .. 24 + 25]));
    var n: usize = 0;
    while (n < 6) : (n += 1) {
        try std.testing.expectEqual(ExecResult.ok, exec_file("USER.BIN", &.{})); // pids 3..8, slots 4..9
    }
    try std.testing.expect(!scheduler.has_free_slot());
    try std.testing.expectEqual(ExecResult.pool_full, exec_file("USER.BIN", &.{}));
    try std.testing.expectEqual(@as(usize, 9), process.count()); // boot exited + counter + peer + 6 users
}

test "exec: permanent occupant + recycle — one spare slot, pool_full, then the re-exec lands" {
    try build_image(test_allocator);
    defer test_allocator.free(saved_image);
    esp.reset();
    try std.testing.expectEqual(fat.MountResult.ok, esp.set_disk(.{ .read = &fake_read, .write = &fake_write }));
    arm_allocator();
    _ = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192) orelse return error.TestUnexpectedResult;
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    // Retire the boot payload: shell + idle + worker leave EIGHT free slots.
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expect(scheduler.exit_current(7));
    try std.testing.expect(scheduler.reap(2));

    const counter_img = dsk1("counter: alive\n", 24, 24 + 15);
    try std.testing.expectEqual(esp.WriteResult.ok, esp.write_file("COUNTER.BIN", counter_img[0 .. 24 + 15]));
    const user_img = dsk1("user: hello from the ESP\n", 24, 24 + 25);
    try std.testing.expectEqual(esp.WriteResult.ok, esp.write_file("USER.BIN", user_img[0 .. 24 + 25]));

    // The counter is the permanent occupant: it takes one slot and never
    // exits (this test never drives it to exit). Milestone sixteen C3
    // (claim 0339): SEVEN short programs fill the remaining user slots
    // (shell + idle + worker + counter + 7 users = the full 11-slot pool).
    try std.testing.expectEqual(ExecResult.ok, exec_file("COUNTER.BIN", &.{})); // slot 2
    const free_after_counter = alloc.stats().free_pages;
    var n: usize = 0;
    while (n < 7) : (n += 1) {
        try std.testing.expectEqual(ExecResult.ok, exec_file("USER.BIN", &.{})); // slots 3..9
    }
    try std.testing.expect(!scheduler.has_free_slot());
    // The capacity gate: a ninth exec while all eight programs are live is
    // pool_full, checked BEFORE any allocation — nothing leaks.
    try std.testing.expectEqual(ExecResult.pool_full, exec_file("USER.BIN", &.{}));
    try std.testing.expectEqual(free_after_counter - 119, alloc.stats().free_pages);

    // Drive the FIRST short program's exit + reap (the idle task's
    // lifecycle reap): its 17 pages (text 1 + stack 8 + kstack 8) return
    // to the allocator and its
    // executor slot becomes spawnable again — while the counter stays
    // running.
    try std.testing.expect(scheduler.yield_current()); // idle -> shell
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> counter
    try std.testing.expect(scheduler.yield_current()); // counter -> user (slot 3)
    try std.testing.expectEqual(@as(usize, 3), scheduler.current_id());
    try std.testing.expect(scheduler.exit_current(43)); // user -> idle
    try std.testing.expectEqual(process.State.exited, process.info(2).?.state);
    // The exited process holds its pages until the reap...
    try std.testing.expectEqual(free_after_counter - 119, alloc.stats().free_pages);
    // ...the scheduler reap returns them (claim 4613) while the exited
    // descriptor stays in the procs table with its status.
    try std.testing.expect(scheduler.reap(3));
    try std.testing.expectEqual(free_after_counter - 102, alloc.stats().free_pages);
    try std.testing.expectEqual(process.State.exited, process.info(2).?.state);
    try std.testing.expectEqual(@as(u64, 43), process.info(2).?.exit_status);
    try std.testing.expectEqual(@as(u64, 0), process.info(2).?.text_pages);
    try std.testing.expect(scheduler.has_free_slot());
    try std.testing.expectEqual(process.State.running, process.info(1).?.state); // counter still live

    // The next exec lands in the freed slot (recycle under a permanent
    // occupant — the claim-0826 gate could never show this, because both
    // its programs exited)...
    try std.testing.expectEqual(ExecResult.ok, exec_file("USER.BIN", &.{}));
    try std.testing.expectEqual(process.State.running, process.info(3).?.state);
    // ...and with the counter + seven live programs the pool is full
    // again: a subsequent exec is pool_full, still leak-free.
    try std.testing.expect(!scheduler.has_free_slot());
    try std.testing.expectEqual(ExecResult.pool_full, exec_file("USER.BIN", &.{}));
    try std.testing.expectEqual(free_after_counter - 119, alloc.stats().free_pages);
    try std.testing.expectEqual(process.State.running, process.info(1).?.state);
}

test "exec: kill reaps a permanent occupant — pages return, the slot is re-exec'd" {
    // Card 3c (claim 7786): the OS, not the program, owns process
    // lifetime. The never-exiting COUNTER.BIN is force-terminated through
    // the EXISTING exit → zombie → idle-reap path with the reserved
    // status 137; its 9 allocator pages return at the reap (exact +9
    // free-count recovery), the slot frees, and a subsequent exec lands
    // in it.
    try build_image(test_allocator);
    defer test_allocator.free(saved_image);
    esp.reset();
    try std.testing.expectEqual(fat.MountResult.ok, esp.set_disk(.{ .read = &fake_read, .write = &fake_write }));
    arm_allocator();
    _ = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192) orelse return error.TestUnexpectedResult;
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    // Retire the boot payload: shell + idle + worker leave two free slots.
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expect(scheduler.exit_current(7));
    try std.testing.expect(scheduler.reap(2));
    // Drain the boot payload's exit/reap reports into a throwaway so the
    // kill's report below is the ONLY pending one (single-slot flags).
    var drain_mock = console.MockConsole(256){};
    var drain_con = drain_mock.console();
    scheduler.maybe_report(&drain_con);

    const counter_img = dsk1("counter: alive\n", 24, 24 + 15);
    try std.testing.expectEqual(esp.WriteResult.ok, esp.write_file("COUNTER.BIN", counter_img[0 .. 24 + 15]));
    const user_img = dsk1("user: hello from the ESP\n", 24, 24 + 25);
    try std.testing.expectEqual(esp.WriteResult.ok, esp.write_file("USER.BIN", user_img[0 .. 24 + 25]));

    // The permanent occupant takes a slot and 9 pages (1 text + 4 stack +
    // 4 EL1 exception stack).
    try std.testing.expectEqual(ExecResult.ok, exec_file("COUNTER.BIN", &.{})); // slot 2
    const free_after_counter = alloc.stats().free_pages;
    const counter_proc = process.info(1).?;
    try std.testing.expectEqualStrings("COUNTER.BIN", counter_proc.name);
    try std.testing.expectEqual(process.State.running, counter_proc.state);
    // Kill by id (the `procs` id): the kernel arms the counter's executor.
    try std.testing.expectEqual(scheduler.KillResult.ok, scheduler.request_kill(counter_proc.task_id.?));
    // The ring's next selection of the counter converts it to the exit
    // path with the RESERVED status 137 (not a cooperative sys_exit).
    try std.testing.expect(scheduler.yield_current()); // idle -> shell
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> counter -> killed -> idle
    try std.testing.expectEqual(@as(usize, scheduler.idle_id), scheduler.current_id());
    try std.testing.expect(scheduler.is_terminated(2));
    try std.testing.expectEqual(@as(?u64, scheduler.reserved_kill_status), scheduler.terminated_status(2));
    // The process exit report carries 137 (the killed-status report).
    var mock = console.MockConsole(128){};
    var con = mock.console();
    scheduler.maybe_report(&con);
    try std.testing.expectEqualStrings("tasks user-exec exited status=137\nprocs COUNTER.BIN exited status=137\n", mock.contents());
    const killed = process.info(1).?;
    try std.testing.expectEqual(process.State.exited, killed.state);
    try std.testing.expectEqual(@as(u64, 137), killed.exit_status);
    // The exited process holds its 9 pages until the reap (the free
    // count is unchanged from right after the exec — 17 still out)...
    try std.testing.expectEqual(free_after_counter, alloc.stats().free_pages);
    // ...then the scheduler reap returns them (exact +17 recovery).
    try std.testing.expect(scheduler.reap(2));
    try std.testing.expectEqual(free_after_counter + 17, alloc.stats().free_pages);
    try std.testing.expect(scheduler.has_free_slot());
    // A subsequent exec lands in the freed slot.
    try std.testing.expectEqual(ExecResult.ok, exec_file("USER.BIN", &.{}));
    try std.testing.expectEqual(process.State.running, process.info(2).?.state);
    try std.testing.expectEqual(@as(?usize, 2), process.info(2).?.task_id); // slot 2 reused
    // The counter's exited descriptor stays in the procs table.
    try std.testing.expectEqual(process.State.exited, process.info(1).?.state);
    try std.testing.expectEqual(@as(u64, 137), process.info(1).?.exit_status);
}

test "exec: argv packing shape, per-arg truncation, and block VA" {
    // Card 3e (claim 4636): the block is 8 slots × 32 bytes, zeroed,
    // NUL-terminated, packed right after the content in the process's own
    // text page. pack_args is pure — the shape is pinned without a disk.
    var block: [arg_block_bytes]u8 = undefined;
    const n = pack_args(&.{ "alpha", "beta", "gamma" }, &block);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("alpha", block[0..32][0..5]);
    try std.testing.expectEqual(@as(u8, 0), block[5]);
    try std.testing.expectEqualStrings("beta", block[32..64][0..4]);
    try std.testing.expectEqualStrings("gamma", block[64..96][0..5]);
    for (block[96..]) |b| try std.testing.expectEqual(@as(u8, 0), b);

    // A 40-byte arg is truncated to 31 chars + NUL (documented, honest).
    const long = "x" ** 40;
    const n2 = pack_args(&.{long}, &block);
    try std.testing.expectEqual(@as(usize, 1), n2);
    for (block[0..31]) |b| try std.testing.expectEqual(@as(u8, 'x'), b);
    try std.testing.expectEqual(@as(u8, 0), block[31]);

    // The block VA sits right after the content, 8-aligned, inside the
    // text page; an image that nearly fills the page leaves no room.
    try std.testing.expectEqual(userspace.text_va + 24, argv_va_for(24));
    try std.testing.expectEqual(userspace.text_va + 240, argv_va_for(234));
    try std.testing.expectEqual(@as(u64, 0), argv_va_for(4096 - 100));
}

test "exec: more than 8 args is refused honestly (too_many_args)" {
    // Card 3e: the bounded block holds 8 args; a 9th is an honest refusal,
    // never silent truncation. Checked BEFORE any disk/file work (fails
    // even with no disk mounted).
    esp.reset();
    const args = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i" };
    try std.testing.expectEqual(ExecResult.too_many_args, exec_file("USER.BIN", &args));
}

test "exec: the argv-block room guard is exact at the 4 KiB page boundary" {
    // Card 3e: the block needs 256 bytes after the content in the same
    // 4 KiB page. The guard is defensive — the ESP/FAT write path caps
    // files at 2048 bytes, so content + block always fits through the real
    // write path — but the boundary is pinned exactly: content 3840 leaves
    // the block at the page end (fits), content 3841 does not.
    try std.testing.expect(userspace.text_va + 3840 == argv_va_for(3840));
    try std.testing.expectEqual(@as(u64, 0), argv_va_for(3841));
    try std.testing.expectEqual(@as(u64, 0), argv_va_for(4095));
}

test "exec: argv block is a read-only leaf — uaccess reads it, writes fault, per-exec distinct" {
    // Card 3e: `exec USER.BIN alpha` + `exec USER.BIN beta` — the SAME
    // image, distinguished by its argv. Each exec packs its own block into
    // its OWN text page; the block sits inside the (read-only) text
    // aperture, so uaccess copy_in reads it and copy_out is a permission
    // fault — the args range is never in the EL0 write aperture.
    try build_image(test_allocator);
    defer test_allocator.free(saved_image);
    esp.reset();
    try std.testing.expectEqual(fat.MountResult.ok, esp.set_disk(.{ .read = &fake_read, .write = &fake_write }));
    arm_allocator();
    _ = mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192) orelse return error.TestUnexpectedResult;
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    // Retire the boot payload so BOTH exec'd programs fit the pool.
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expect(scheduler.exit_current(7));
    try std.testing.expect(scheduler.reap(2));

    const img = dsk1("user: hello from the ESP\n", 24, 24 + 25);
    try std.testing.expectEqual(esp.WriteResult.ok, esp.write_file("USER.BIN", img[0 .. 24 + 25]));
    try std.testing.expectEqual(ExecResult.ok, exec_file("USER.BIN", &.{"alpha"}));
    try std.testing.expectEqual(ExecResult.ok, exec_file("USER.BIN", &.{"beta"}));
    // Both processes live, each with its OWN text page and its own block.
    try std.testing.expectEqual(@as(usize, 3), process.count());
    const proc_a = process.info(1).?;
    const proc_b = process.info(2).?;
    try std.testing.expectEqual(process.State.running, proc_a.state);
    try std.testing.expectEqual(process.State.running, proc_b.state);
    try std.testing.expect(proc_a.text_phys != proc_b.text_phys);
    const block_off: usize = (25 + 7) & ~@as(usize, 7); // 32 for content 25
    const text_a: [*]const u8 = @ptrFromInt(proc_a.text_phys);
    const text_b: [*]const u8 = @ptrFromInt(proc_b.text_phys);
    try std.testing.expectEqualStrings("alpha", text_a[block_off..][0..5]);
    try std.testing.expectEqualStrings("beta", text_b[block_off..][0..4]);
    try std.testing.expect(std.mem.indexOf(u8, text_a[0..256], "beta") == null);
    // The text aperture extends over the block (the region uaccess reads
    // from covers content + block) and the block VA is the one USER.BIN is
    // told about (x1 at entry).
    const text_region_len = block_off + arg_block_bytes; // 288 = 25 content + 256 block, 8-aligned
    try std.testing.expectEqual(userspace.text_va + block_off, argv_va_for(25));
    // uaccess both directions: copy_in from the args range reads the
    // packed bytes; copy_out to it is a permission fault.
    syscall.set_user_regions(
        .{ .base = proc_a.text_phys, .len = text_region_len },
        .{ .base = 0, .len = 0 },
    );
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(uaccess.Outcome.ok, uaccess.copy_in(&buf, proc_a.text_phys + block_off, 5));
    try std.testing.expectEqualStrings("alpha", buf[0..5]);
    try std.testing.expectEqual(uaccess.Outcome.fault, uaccess.copy_out(proc_a.text_phys + block_off, "12345678", 8));
    // The args range is absent from the EL0 write aperture: the real
    // per-task write aperture is the user STACK (a different page), so the
    // args range on the text page is never writable — while the stack
    // itself IS the EL0 write aperture.
    syscall.set_user_regions(
        .{ .base = 0, .len = 0 },
        .{ .base = proc_a.stack_phys, .len = proc_a.stack_len },
    );
    try std.testing.expectEqual(uaccess.Outcome.fault, uaccess.copy_out(proc_a.text_phys + block_off, "12345678", 8));
    try std.testing.expectEqual(uaccess.Outcome.ok, uaccess.copy_out(proc_a.stack_phys, "12345678", 8));
}

fn build_image(alloc_arg: std.mem.Allocator) !void {
    // Reuse the esp.zig fixture builder by importing its module-scope test
    // image? No — esp.zig's fixture is private. Build a minimal GPT+FAT32
    // image here with mkfat32's layout: 64 MiB, ESP at LBA 2048, root
    // cluster 2 with BOOTED.TXT only.
    const total_sectors: u64 = 64 * 1024 * 1024 / 512;
    const esp_offset: u64 = 2048;
    const last_usable: u64 = total_sectors - 34;
    const volume_sectors: u32 = @intCast(last_usable - esp_offset + 1);
    var fat_sectors: u32 = 1;
    while (true) {
        const clusters = volume_sectors - 32 - 2 * fat_sectors;
        const need: u32 = @intCast((clusters * 4 + 511) / 512);
        if (need == fat_sectors) break;
        fat_sectors = need;
    }
    const data_start: u32 = 32 + 2 * fat_sectors;

    saved_image = try alloc_arg.alloc(u8, @intCast(total_sectors * 512));
    @memset(saved_image, 0);
    saved_image[510] = 0x55;
    saved_image[511] = 0xaa;
    const hdr_off: usize = 1 * 512;
    @memcpy(saved_image[hdr_off .. hdr_off + 8], "EFI PART");
    std.mem.writeInt(u32, saved_image[hdr_off + 12 ..][0..4], 92, .little);
    std.mem.writeInt(u64, saved_image[hdr_off + 24 ..][0..8], 1, .little);
    std.mem.writeInt(u64, saved_image[hdr_off + 32 ..][0..8], total_sectors - 1, .little);
    std.mem.writeInt(u64, saved_image[hdr_off + 72 ..][0..8], 2, .little);
    std.mem.writeInt(u32, saved_image[hdr_off + 80 ..][0..4], 128, .little);
    std.mem.writeInt(u32, saved_image[hdr_off + 84 ..][0..4], 128, .little);
    const ent_off: usize = 2 * 512;
    const esp_guid = [16]u8{ 0x28, 0x73, 0x2a, 0xc1, 0x1f, 0xf8, 0xd2, 0x11, 0xba, 0x4b, 0x00, 0xa0, 0xc9, 0x3e, 0xc9, 0x3b };
    @memcpy(saved_image[ent_off .. ent_off + 16], &esp_guid);
    std.mem.writeInt(u64, saved_image[ent_off + 32 ..][0..8], esp_offset, .little);
    std.mem.writeInt(u64, saved_image[ent_off + 40 ..][0..8], last_usable, .little);

    const base: usize = @intCast(esp_offset * 512);
    const bs = saved_image[base .. base + 512];
    const jmp_boot = [_]u8{ 0xeb, 0x58, 0x90 };
    @memcpy(bs[0..3], &jmp_boot);
    std.mem.writeInt(u16, bs[11..13], 512, .little);
    bs[13] = 1;
    std.mem.writeInt(u16, bs[14..16], 32, .little);
    bs[16] = 2;
    bs[21] = 0xf8;
    std.mem.writeInt(u32, bs[28..32], @intCast(esp_offset), .little);
    std.mem.writeInt(u32, bs[32..36], volume_sectors, .little);
    std.mem.writeInt(u32, bs[36..40], fat_sectors, .little);
    std.mem.writeInt(u32, bs[44..48], 2, .little);
    bs[510] = 0x55;
    bs[511] = 0xaa;

    const fat_off: usize = @intCast((esp_offset + 32) * 512);
    const fat_bytes = fat_sectors * 512;
    const fat_buf = try alloc_arg.alloc(u8, fat_bytes);
    @memset(fat_buf, 0);
    std.mem.writeInt(u32, fat_buf[0..4], 0x0ffffff8, .little);
    std.mem.writeInt(u32, fat_buf[4..8], 0x0fffffff, .little);
    for ([_]u32{ 2, 3, 4, 5 }) |c| std.mem.writeInt(u32, fat_buf[@as(usize, c) * 4 ..][0..4], 0x0fffffff, .little);
    for (0..2) |f| @memcpy(saved_image[fat_off + f * fat_bytes ..][0..fat_bytes], fat_buf);
    alloc_arg.free(fat_buf);

    const root_off: usize = @intCast((esp_offset + data_start) * 512);
    var root = [_]u8{0} ** 512;
    write_entry(&root, 0, "DIPSHITOS  ", 0x08, 0, 0);
    write_entry(&root, 1, "BOOTED  TXT", 0x20, 5, 3);
    @memcpy(saved_image[root_off .. root_off + 512], &root);
    const b_off: usize = @intCast((esp_offset + data_start + 3) * 512);
    @memcpy(saved_image[b_off .. b_off + 3], "ok\n");
}

fn write_entry(cluster: *[512]u8, slot: usize, name11: *const [11]u8, attr: u8, cluster_no: u32, size: u32) void {
    const off = slot * 32;
    @memcpy(cluster[off .. off + 11], name11[0..11]);
    cluster[off + 11] = attr;
    std.mem.writeInt(u16, cluster[off + 20 ..][0..2], @truncate(cluster_no >> 16), .little);
    std.mem.writeInt(u16, cluster[off + 26 ..][0..2], @truncate(cluster_no), .little);
    std.mem.writeInt(u32, cluster[off + 28 ..][0..4], size, .little);
}

//! DipshitOS ESP exec (milestone-three card 6, claim 6783).
//!
//! Loads a real user program from the ESP and enters it at EL0 — the last
//! big milestone-three userspace card. The claim-8215 static EL0 payload is
//! boot-registered; this module REPLACES it at runtime with a program read
//! through the claim-6420 FAT path (`fat.read_file` over virtio-blk): the
//! file is a flat AArch64 image in the same DSK1 format as KERNEL.BIN
//! (`tools/elf2bin.py`, 24-byte header, content at offset 24), built by
//! `zig build user` and embedded on the ESP by the image builder.
//!
//! Exec is the monitor command `exec [<file>]` (default `USER.BIN`):
//!
//!   1. Read the file into a fixed 4 KiB BSS buffer (bounded — the claim-\n
//!      8215 text aperture is one page).
//!   2. Validate the DSK1 header (magic, entry offset, image size).
//!   3. Gate on `scheduler.user_root_in_use()` — one user program at a
//!      time. Rebuilding the user root while a live task runs under it
//!      would strand that task, so exec refuses until the previous user
//!      task exited (to a zombie) and was reaped by the claim-6729 idle
//!      task.
//!   4. Rebuild the EL0 task's TTBR0 user root around the loaded page with
//!      `mmu.build_user_root` (claim 5804: identity-tree clone + EL1-only
//!      kernel overlay + the loaded text page at `userspace.text_va` + the
//!      static user stack at `userspace.stack_va`). This works POST-install
//!      because the kernel stays identity-mapped (the VZ TTBR1 fallback),
//!      so `@intFromPtr` is still physical; the fresh clone tables are
//!      D-cache-cleaned before the scheduler's next TTBR0 switch.
//!   5. Spawn the program as an EL0t task (`scheduler.register_exec_user`)
//!      and let it run under the fixed syscall ABI.
//!
//! The syscall/uaccess apertures stay the claim-8215 static regions: the
//! loaded program maps within them (≤ 1 page at `text_va`, the 8 KiB user
//! stack), so `sys_write` bounds hold unchanged. No libc, no POSIX, no
//! allocation, no process abstraction.

const std = @import("std");
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

/// Fixed load buffer: one page, the claim-8215 text aperture's size. A
/// program larger than this is rejected honestly (`too_large`).
pub const exec_program_max: usize = 4096;
/// Default file name for `exec` with no argument.
pub const default_name: []const u8 = "USER.BIN";
/// elf2bin.py's DSK1 header size (magic/flags/entry/image_size).
pub const dsk1_header_size: usize = 24;
const dsk1_magic: u32 = 0x314b5344; // "DSK1"

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
    /// A live (ready/running) task still runs under the user root — the
    /// previous user program has not exited and been reaped yet.
    user_busy,
    /// No free scheduler pool slot.
    pool_full,
    /// The fixed page-table carve-out cannot hold another user-root clone.
    table_full,
    /// The process registry holds only live (created/running) processes —
    /// no free slot and no exited descriptor to recycle.
    process_full,
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
};

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

/// Load `name` from the ESP, rebuild the user root around it, and spawn it
/// as an EL0t task. See the module doc for the ordered steps.
pub fn exec_file(name: []const u8) ExecResult {
    if (name.len == 0 or name.len > esp.name_max) return .not_found;
    if (!esp.disk_ready()) return .no_disk;
    const e = esp.lookup(name) orelse return .not_found;
    if (e.kind != .esp_file) return .not_found;
    // Read the raw volume directly (the ESP window only content-loads
    // files ≤ esp_content_max; exec reads up to its own fixed buffer).
    const got = fat.read_file(name, &program) orelse return .not_found;
    if (got < dsk1_header_size) return .bad_magic;
    if (std.mem.readInt(u32, program[0..4], .little) != dsk1_magic) return .bad_magic;
    const entry_off = std.mem.readInt(u64, program[8..16], .little);
    const image_size = std.mem.readInt(u64, program[16..24], .little);
    if (image_size > program.len) return .too_large;
    if (image_size > got) return .too_large; // truncated read — file bigger than the buffer
    if (entry_off < dsk1_header_size or entry_off >= image_size) return .bad_entry;
    if (scheduler.user_root_in_use()) return .user_busy;

    const content_len: usize = @intCast(image_size - dsk1_header_size);
    // Strip the 24-byte DSK1 header IN PLACE: the user root maps whole
    // pages at `text_va` (the clone masks the phys to page granularity),
    // so the loadable content must start at a page boundary. The entry
    // offset is file-relative, so the entry VA is unchanged:
    // `text_va + (entry_offset - header)`.
    std.mem.copyForwards(u8, program[0..content_len], program[dsk1_header_size..][0..content_len]);
    @memset(program[content_len..], 0); // the rest of the page is BSS padding
    const text_phys = mmu.to_phys(@intFromPtr(&program));
    // Milestone four (claim 2665): ASLR — the loaded program's EL0 stack
    // lands at a per-boot random VA from the seeded CSPRNG (page-aligned,
    // 64 KiB placement granularity, clear of text_va). The uaccess stack
    // region follows via set_stack_va so a later program may write from
    // the stack through sys_write. Unseeded (host test / fallback) returns
    // the fixed default, so nothing below ever sees an out-of-band VA.
    // rebuild_user_root runs the whole sequence (randomize → map → clean →
    // re-arm) — shared with the boot-time static payload (claim 3693).
    const stack_va = rebuild_user_root(text_phys, content_len, scheduler.task_stack_size) orelse return .table_full;

    const entry_va = userspace.text_va + (entry_off - dsk1_header_size);
    // Milestone four (claim 3848): the loaded program is a PROCESS. The
    // descriptor owns the image + the rebuilt address space; a later exec
    // creates a NEW process (per-process identity) instead of overwriting
    // module globals. The process registry is exhausted only when every
    // slot holds a live process (no exited descriptor to recycle) — an
    // honest, distinct failure from the pool being full.
    const proc_id = process.create(
        name,
        .{ .entry_va = entry_va, .content_len = content_len },
        .{
            .root_phys = mmu.user_root_phys(),
            .text_va = userspace.text_va,
            .text_len = content_len,
            .stack_va = stack_va,
            .stack_len = scheduler.task_stack_size,
        },
    ) orelse return .process_full;
    if (scheduler.register_exec_user(entry_va, stack_va)) |task_id| {
        _ = process.bind(proc_id, task_id);
    } else {
        // Spawn failed (pool full): roll the created process back.
        _ = process.reap(proc_id);
        return .pool_full;
    }
    return .ok;
}

/// Rebuild the EL0 user root around a fresh randomized stack placement
/// (milestone-four ASLR, claims 2665 + 3693): draw a per-boot stack VA
/// from the seeded CSPRNG, map `text_len` bytes of `text_phys` at
/// `userspace.text_va` plus the static user stack at the new base
/// (`scheduler.user_stack_phys()`, `stack_len` bytes), clean the fresh
/// clone tables + mapped text (the walker and EL0 instruction fetch must
/// see the real bytes), and re-arm the syscall/uaccess regions so
/// `sys_write` bounds follow the new base. The single shared sequence for
/// the exec path (the loaded program's page, claim 2665) and the
/// boot-time rebuild of the static EL0 payload (claim 3693).
///
/// `stack_len` must cover the FULL `.userbss` section for the static boot
/// payload: the scheduler's timer-preemption witness sits just past the
/// 8 KiB stack, and its VA is base-relative to the stack, so the rebuilt
/// root must map it too. Exec passes the task stack size (no witness).
///
/// Returns the new stack VA on success, or null when the fixed table
/// carve-out cannot hold another user-root clone (the caller's root is
/// then unchanged).
pub fn rebuild_user_root(text_phys: u64, text_len: u64, stack_len: u64) ?u64 {
    const stack_va = csprng.random_stack_va();
    userspace.set_stack_va(stack_va);
    if (!mmu.build_user_root(
        userspace.text_va,
        text_phys,
        text_len,
        stack_va,
        scheduler.user_stack_phys(),
        stack_len,
    )) return null;
    // The fresh clone tables and the mapped text are dirty in the D-cache;
    // clean both before the scheduler's next TTBR0 switch (the walker +
    // EL0 instruction fetch must see the real bytes).
    mmu.clean_table_storage();
    mmu.clean_dcache_range(text_phys, text_len);
    // The user stack aperture moved: re-arm the syscall/uaccess regions so
    // sys_write bounds follow the randomized base.
    syscall.set_user_regions(userspace.text_va_region(), userspace.stack_va_region());
    return stack_va;
}

// ---------------------------------------------------------------------------
// Tests (host-side: in-memory FAT fixture; the MMU clone builds an empty
// root on the host, so the tests pin the load/validate/gate/spawn logic)
// ---------------------------------------------------------------------------

const test_allocator = std.testing.allocator;

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

test "exec: DSK1 header parse rejects bad magic, entry, and oversize images" {
    try build_image(test_allocator);
    defer test_allocator.free(saved_image);
    esp.reset();
    try std.testing.expectEqual(fat.MountResult.ok, esp.set_disk(.{ .read = &fake_read, .write = &fake_write }));
    try std.testing.expectEqual(ExecResult.not_found, exec_file("NOPE.BIN"));

    // Bad magic.
    try std.testing.expectEqual(esp.WriteResult.ok, esp.write_file("USER.BIN", "NOT A DSK1 IMAGE!"));
    try std.testing.expectEqual(ExecResult.bad_magic, exec_file("USER.BIN"));

    // entry_offset below the 24-byte header (and past the content).
    const bad_entry = dsk1("xx", 4, 24 + 2);
    try std.testing.expectEqual(esp.WriteResult.ok, esp.write_file("USER.BIN", bad_entry[0 .. 24 + 2]));
    try std.testing.expectEqual(ExecResult.bad_entry, exec_file("USER.BIN"));
    const bad_entry2 = dsk1("xx", 30, 24 + 2);
    try std.testing.expectEqual(esp.WriteResult.ok, esp.write_file("USER.BIN", bad_entry2[0 .. 24 + 2]));
    try std.testing.expectEqual(ExecResult.bad_entry, exec_file("USER.BIN"));

    // image_size beyond the fixed buffer.
    const oversize = dsk1("xx", 24, exec_program_max + 1);
    try std.testing.expectEqual(esp.WriteResult.ok, esp.write_file("USER.BIN", oversize[0 .. 24 + 2]));
    try std.testing.expectEqual(ExecResult.too_large, exec_file("USER.BIN"));
}

test "exec: no disk is reported honestly" {
    esp.reset();
    try std.testing.expectEqual(ExecResult.no_disk, exec_file("USER.BIN"));
}

test "exec: ok path loads, validates, rebuilds the root, and spawns the task" {
    try build_image(test_allocator);
    defer test_allocator.free(saved_image);
    esp.reset();
    try std.testing.expectEqual(fat.MountResult.ok, esp.set_disk(.{ .read = &fake_read, .write = &fake_write }));
    // Give the user root a real (non-zero) value so the live-user gate is
    // unambiguous on the host: the EL1h tasks carry the kernel root (0).
    try std.testing.expect(mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192));
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    // Retire the static user task first (exec requires the user root free).
    try std.testing.expect(scheduler.yield_current()); // shell -> worker
    try std.testing.expect(scheduler.yield_current()); // worker -> user
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expect(scheduler.exit_current(7)); // user -> idle
    try std.testing.expect(scheduler.reap(2));

    const img = dsk1("user: hello from the ESP\n", 24, 24 + 25);
    try std.testing.expectEqual(esp.WriteResult.ok, esp.write_file("USER.BIN", img[0 .. 24 + 25]));
    try std.testing.expectEqual(ExecResult.ok, exec_file("USER.BIN"));
    const info = loaded().?;
    try std.testing.expectEqualStrings("USER.BIN", info.name);
    try std.testing.expectEqual(@as(usize, 25), info.content_len);
    try std.testing.expectEqual(userspace.text_va, info.entry_va); // entry at content start
    // The 24-byte DSK1 header is stripped in place: the loaded page starts
    // with the content, not "DSK1".
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
    try std.testing.expectEqual(@as(u64, 8192), exec_proc.stack_len);
}

test "exec: a live user task blocks exec (one user program at a time)" {
    try build_image(test_allocator);
    defer test_allocator.free(saved_image);
    esp.reset();
    try std.testing.expectEqual(fat.MountResult.ok, esp.set_disk(.{ .read = &fake_read, .write = &fake_write }));
    // Give the user root a real value FIRST so register_user's task carries
    // it (see the ok-path test); the EL1h tasks keep the kernel root (0).
    try std.testing.expect(mmu.build_user_root(userspace.text_va, 0x1000, 64, userspace.stack_va, 0x2000, 8192));
    _ = scheduler.init();
    _ = scheduler.register_worker(0x2000);
    _ = scheduler.register_user(0x3000, 0);
    scheduler.start();
    const img = dsk1("x", 24, 25);
    try std.testing.expectEqual(esp.WriteResult.ok, esp.write_file("USER.BIN", img[0..25]));
    // The static user task is alive under the user root -> busy.
    try std.testing.expectEqual(ExecResult.user_busy, exec_file("USER.BIN"));
    // Once it exits to a zombie and is reaped, exec proceeds (the zombie is
    // not live; the freed slot becomes the exec'd task's).
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expect(scheduler.yield_current());
    try std.testing.expectEqual(@as(usize, 2), scheduler.current_id());
    try std.testing.expect(scheduler.exit_current(7));
    try std.testing.expect(scheduler.reap(2));
    try std.testing.expectEqual(ExecResult.ok, exec_file("USER.BIN"));
    try std.testing.expectEqualStrings("user-exec", scheduler.task_info(2).?.name);
}

fn build_image(alloc: std.mem.Allocator) !void {
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

    saved_image = try alloc.alloc(u8, @intCast(total_sectors * 512));
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
    const fat_buf = try alloc.alloc(u8, fat_bytes);
    @memset(fat_buf, 0);
    std.mem.writeInt(u32, fat_buf[0..4], 0x0ffffff8, .little);
    std.mem.writeInt(u32, fat_buf[4..8], 0x0fffffff, .little);
    for ([_]u32{ 2, 3, 4, 5 }) |c| std.mem.writeInt(u32, fat_buf[@as(usize, c) * 4 ..][0..4], 0x0fffffff, .little);
    for (0..2) |f| @memcpy(saved_image[fat_off + f * fat_bytes ..][0..fat_bytes], fat_buf);
    alloc.free(fat_buf);

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

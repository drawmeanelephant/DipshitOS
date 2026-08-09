//! DipshitOS physical page allocator over the captured EFI map.
//!
//! Next-card milestone (canonical ordering: `docs/status.md`): a first-fit
//! **bitmap** allocator whose pool is the ConventionalMemory regions of the
//! map the kernel captured pre-exit. ADR 0004 D2: the captured map is the
//! sole authority on memory layout — there is no `GetMemoryMap` after
//! exit, so the pool is built once, post-exit, from `MapView` bytes.
//!
//! ConventionalMemory-only is deliberate and safe with zero exclusions:
//! the kernel image (loader_code), the map buffer (loader_data), the
//! stack, the identity-map tables (BSS), and the virtio BAR (MMIO) all
//! live outside conventional memory, so the pool can never hand back the
//! kernel itself. Loader/boot-services regions are explicitly deferred
//! (they would need kernel-image + map-buffer exclusion ranges).
//!
//! The bitmap covers the same 4 GiB span the identity map blankets
//! (`mmu.zig`): one bit per 4 KiB page, 1 = allocated, 0 = free. During
//! init every bit in the span is set and then the pooled regions' bits are
//! cleared, so gaps between conventional regions (reserved/MMIO windows)
//! are never allocatable. The bitmap is fixed BSS (128 KiB) — no
//! allocation during construction, no libc, no POSIX, no MMIO, no
//! interrupts. Conventional regions whose whole pages fall outside the
//! 4 GiB span are honestly untracked.
//!
//! The `State` struct owns its bitmap inline, so host tests build fixture
//! states directly; the module also carries one `state` + thin wrappers
//! (the `machine.zig` pattern) for the kernel and the `pages` monitor
//! command.

const std = @import("std");
const memmap = @import("memmap.zig");

pub const page_size: u64 = memmap.page_size; // 4096

/// The bitmap's physical span: 4 GiB — the same blanket the identity map
/// covers (mmu.zig). Conventional pages outside it are not tracked.
pub const span_bytes: u64 = 0x1_0000_0000;
pub const max_span_pages: u64 = span_bytes / page_size; // 1 Mi pages
pub const bitmap_bytes: usize = @intCast(max_span_pages / 8); // 128 KiB

/// Maximum pooled conventional regions recorded for reporting. Maps with
/// more regions pool the first `max_regions` (in map order) and leave the
/// rest untracked (honestly visible via `region_count`).
pub const max_regions: usize = 64;

/// One pooled conventional region (whole pages only).
pub const Region = struct {
    base: u64,
    pages: u64,
};

pub const Stats = struct {
    armed: bool,
    total_pages: u64,
    free_pages: u64,
    region_count: usize,
    span_pages: u64,
};

pub const State = struct {
    /// 1 = allocated, 0 = free. Bit `i` is page
    /// `bitmap_base + i * page_size`. All bits start SET (allocated); init
    /// clears exactly the pooled conventional pages, so any page the map
    /// does not declare conventional is unallocatable.
    bitmap: [bitmap_bytes]u8 = [_]u8{0} ** bitmap_bytes,
    regions: [max_regions]Region = undefined,
    region_count: usize = 0,
    bitmap_base: u64 = 0,
    span_pages: u64 = 0,
    total_pages: u64 = 0,
    free_count: u64 = 0,
    armed: bool = false,

    /// Build the pool from a captured map view. Resets any prior state.
    /// Returns true iff at least one conventional page is pooled.
    pub fn init(self: *State, view: memmap.MapView) bool {
        self.bitmap = [_]u8{0} ** bitmap_bytes;
        self.region_count = 0;
        self.bitmap_base = 0;
        self.span_pages = 0;
        self.total_pages = 0;
        self.free_count = 0;
        self.armed = false;
        self.regions = undefined;

        // Pass 1: the aligned conventional span (min aligned base, max end).
        var min_base: u64 = std.math.maxInt(u64);
        var max_end: u64 = 0;
        var index: usize = 0;
        while (index < view.count) : (index += 1) {
            const d = view.get(index) orelse continue;
            if (d.type != .conventional_memory) continue;
            const start = ceil_page(d.physical_start);
            const end_addr = std.math.add(u64, d.physical_start, std.math.mul(u64, d.number_of_pages, page_size) catch continue) catch continue;
            const end = floor_page(end_addr);
            if (start >= end) continue;
            min_base = @min(min_base, start);
            max_end = @max(max_end, end);
        }
        if (min_base == std.math.maxInt(u64)) return false;

        // Cap the span to the bitmap; anything past the cap is untracked.
        self.bitmap_base = min_base;
        const cap_end = std.math.add(u64, min_base, span_bytes) catch span_bytes;
        const span_end = @min(max_end, cap_end);
        self.span_pages = (span_end - min_base) / page_size;
        if (self.span_pages == 0) return false;
        if (self.span_pages > max_span_pages) self.span_pages = max_span_pages;

        // Mark the whole span allocated, then clear exactly the pooled
        // conventional pages — gaps stay unallocatable.
        const span_bytes_full = @as(usize, @intCast((self.span_pages + 7) / 8));
        @memset(self.bitmap[0..span_bytes_full], 0xff);
        if (span_bytes_full * 8 > self.span_pages) {
            // Tail bits beyond span_pages are never addressed; keep them set.
        }

        // Pass 2: pool each whole-page conventional region inside the span.
        var total: u64 = 0;
        index = 0;
        while (index < view.count and self.region_count < max_regions) : (index += 1) {
            const d = view.get(index) orelse continue;
            if (d.type != .conventional_memory) continue;
            const start = ceil_page(d.physical_start);
            const end_addr = std.math.add(u64, d.physical_start, std.math.mul(u64, d.number_of_pages, page_size) catch continue) catch continue;
            const end = floor_page(end_addr);
            if (start >= end) continue;
            if (start < min_base or end > span_end) continue; // outside the capped span
            const pages = (end - start) / page_size;
            const base_index = (start - min_base) / page_size;
            var i: u64 = 0;
            while (i < pages) : (i += 1) self.bit_clear(base_index + i);
            self.regions[self.region_count] = .{ .base = start, .pages = pages };
            self.region_count += 1;
            total = std.math.add(u64, total, pages) catch std.math.maxInt(u64);
        }
        self.total_pages = total;
        self.free_count = total;
        self.armed = total > 0;
        return self.armed;
    }

    /// Allocate `n` contiguous pages (first-fit). Returns the physical
    /// address of the first page, or null when unavailable. Never touches
    /// the page contents.
    pub fn alloc_pages(self: *State, n: u64) ?u64 {
        if (!self.armed or n == 0 or n > self.free_count or n > self.span_pages) return null;
        var start: u64 = 0;
        while (start + n <= self.span_pages) {
            if (!self.bit_get(start)) {
                var run: u64 = 1;
                while (run < n and !self.bit_get(start + run)) run += 1;
                if (run == n) {
                    var i: u64 = 0;
                    while (i < n) : (i += 1) self.bit_set(start + i);
                    self.free_count -= n;
                    return self.bitmap_base + start * page_size;
                }
                start += run; // the bit at start+run is allocated; skip past it
            }
            start += 1;
        }
        return null;
    }

    /// Free `n` pages at `base`. Bounds-checked; clears only bits that were
    /// set, so freeing already-free pages frees nothing and reports false
    /// (a double free cannot inflate the free count).
    pub fn free_pages(self: *State, base: u64, n: u64) bool {
        if (!self.armed or n == 0) return false;
        const idx = self.index_of(base) orelse return false;
        if (n > self.span_pages or idx > self.span_pages - n) return false;
        var freed: u64 = 0;
        var i: u64 = 0;
        while (i < n) : (i += 1) {
            if (self.bit_get(idx + i)) {
                self.bit_clear(idx + i);
                freed += 1;
            }
        }
        self.free_count += freed;
        return freed > 0;
    }

    /// Size of the largest contiguous free run (in pages). Useful for
    /// callers deciding whether a chunk fits; a bounded single scan of the
    /// bitmap (≤ 1 Mi bits).
    pub fn largest_free_run(self: *const State) u64 {
        if (!self.armed) return 0;
        var best: u64 = 0;
        var run: u64 = 0;
        var i: u64 = 0;
        while (i < self.span_pages) : (i += 1) {
            if (!self.bit_get(i)) {
                run += 1;
                best = @max(best, run);
            } else {
                run = 0;
            }
        }
        return best;
    }

    /// Atomically mark `n` pages at `base` allocated without returning
    /// them (future exclusions / pinning). Returns false if any of the
    /// pages is already allocated or out of bounds; on false nothing
    /// changes.
    pub fn reserve(self: *State, base: u64, n: u64) bool {
        if (!self.armed or n == 0) return false;
        const idx = self.index_of(base) orelse return false;
        if (n > self.span_pages or idx > self.span_pages - n) return false;
        var i: u64 = 0;
        while (i < n) : (i += 1) {
            if (self.bit_get(idx + i)) return false;
        }
        i = 0;
        while (i < n) : (i += 1) self.bit_set(idx + i);
        self.free_count -= n;
        return true;
    }

    pub fn stats(self: *const State) Stats {
        return .{
            .armed = self.armed,
            .total_pages = self.total_pages,
            .free_pages = self.free_count,
            .region_count = self.region_count,
            .span_pages = self.span_pages,
        };
    }

    // -- bitmap helpers ----------------------------------------------------

    fn index_of(self: *const State, base: u64) ?u64 {
        if (base % page_size != 0) return null;
        if (base < self.bitmap_base) return null;
        const idx = (base - self.bitmap_base) / page_size;
        if (idx >= self.span_pages) return null;
        return idx;
    }

    fn bit_get(self: *const State, index: u64) bool {
        const byte = self.bitmap[@as(usize, @intCast(index / 8))];
        return (byte >> @as(u3, @intCast(index % 8))) & 1 == 1;
    }

    fn bit_set(self: *State, index: u64) void {
        const i: usize = @intCast(index / 8);
        self.bitmap[i] |= @as(u8, 1) << @as(u3, @intCast(index % 8));
    }

    fn bit_clear(self: *State, index: u64) void {
        const i: usize = @intCast(index / 8);
        self.bitmap[i] &= ~(@as(u8, 1) << @as(u3, @intCast(index % 8)));
    }
};

fn ceil_page(addr: u64) u64 {
    const rem = addr % page_size;
    return if (rem == 0) addr else std.math.add(u64, addr, page_size - rem) catch std.math.maxInt(u64);
}

fn floor_page(addr: u64) u64 {
    return addr - (addr % page_size);
}

// ---------------------------------------------------------------------------
// Module state (kernel + `pages` monitor command surface; machine.zig style)
// ---------------------------------------------------------------------------

var state: State = .{};

pub fn init(view: memmap.MapView) bool {
    return state.init(view);
}

pub fn alloc_pages(n: u64) ?u64 {
    return state.alloc_pages(n);
}

pub fn free_pages(base: u64, n: u64) bool {
    return state.free_pages(base, n);
}

pub fn reserve(base: u64, n: u64) bool {
    return state.reserve(base, n);
}

pub fn stats() Stats {
    return state.stats();
}

pub fn largest_free_run() u64 {
    return state.largest_free_run();
}

// ---------------------------------------------------------------------------
// Tests (host-side; fixture maps, no hardware)
// ---------------------------------------------------------------------------

const test_descriptors = [_]memmap.MemoryDescriptor{
    .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 960, .attribute = 0 },
    .{ .type = .loader_code, .physical_start = 0x7000000, .virtual_start = 0, .number_of_pages = 64, .attribute = 0 },
    .{ .type = .boot_services_data, .physical_start = 0x8000000, .virtual_start = 0, .number_of_pages = 128, .attribute = 0 },
    .{ .type = .runtime_services_data, .physical_start = 0x9000000, .virtual_start = 0, .number_of_pages = 8, .attribute = 0 },
    .{ .type = .memory_mapped_io, .physical_start = 0x1000000, .virtual_start = 0, .number_of_pages = 16, .attribute = 0 },
    .{ .type = .reserved_memory_type, .physical_start = 0x1ff00000, .virtual_start = 0, .number_of_pages = 1, .attribute = 0 },
};

fn make_view() memmap.MapView {
    return memmap.MapView.init(std.mem.asBytes(&test_descriptors), @sizeOf(memmap.MemoryDescriptor), test_descriptors.len);
}

test "alloc: init arms a pool from conventional memory only" {
    var st = State{};
    try std.testing.expect(st.init(make_view()));
    const s = st.stats();
    try std.testing.expect(s.armed);
    try std.testing.expectEqual(@as(u64, 960), s.total_pages);
    try std.testing.expectEqual(@as(u64, 960), s.free_pages);
    try std.testing.expectEqual(@as(usize, 1), s.region_count);
    // Only conventional pages are free; everything else in the span is set.
    try std.testing.expectEqual(@as(u64, 960), s.span_pages);
    try std.testing.expectEqual(@as(u64, 0x100000), st.bitmap_base);
}

test "alloc: no conventional memory leaves the allocator unarmed" {
    var st = State{};
    const no_conv = [_]memmap.MemoryDescriptor{
        .{ .type = .loader_code, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 64, .attribute = 0 },
        .{ .type = .memory_mapped_io, .physical_start = 0x2000000, .virtual_start = 0, .number_of_pages = 16, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&no_conv), @sizeOf(memmap.MemoryDescriptor), no_conv.len);
    try std.testing.expect(!st.init(view));
    try std.testing.expect(!st.stats().armed);
    try std.testing.expect(st.alloc_pages(1) == null);
    try std.testing.expect(!st.free_pages(0x100000, 1));
}

test "alloc: first-fit alloc returns contiguous page-aligned runs" {
    var st = State{};
    _ = st.init(make_view());
    const a1 = st.alloc_pages(1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x100000), a1);
    const a8 = st.alloc_pages(8) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x101000), a8); // contiguous right after a1
    try std.testing.expectEqual(@as(u64, a1 + 0x1000), a8);
    try std.testing.expectEqual(@as(u64, 960 - 1 - 8), st.free_count);
    try std.testing.expect(st.free_pages(a1, 1));
    // Bit 0 is now a lone free bit (a8 still occupies bits 1..8), so the
    // first 3-page run starts at bit 9.
    const a3 = st.alloc_pages(3) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x109000), a3);
    const a5 = st.alloc_pages(5) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x10c000), a5); // contiguous right after a3
    try std.testing.expectEqual(@as(u64, a3 + 3 * page_size), a5);
    try std.testing.expect(st.free_pages(a3, 3));
    try std.testing.expect(st.free_pages(a5, 5));
    try std.testing.expect(st.free_pages(a8, 8));
    try std.testing.expectEqual(@as(u64, 960), st.free_count);
}

test "alloc: exhaustion returns null and leaves the pool unchanged" {
    var st = State{};
    _ = st.init(make_view());
    const all = st.alloc_pages(960) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x100000), all);
    try std.testing.expectEqual(@as(u64, 0), st.free_count);
    try std.testing.expect(st.alloc_pages(1) == null);
    try std.testing.expect(st.alloc_pages(0) == null);
    try std.testing.expectEqual(@as(u64, 0), st.free_count); // failed alloc changed nothing
    try std.testing.expect(st.free_pages(all, 960));
    try std.testing.expectEqual(@as(u64, 960), st.free_count);
}

test "alloc: gaps between regions are never allocatable" {
    // Two conventional regions with a reserved gap between them: the gap
    // must stay unallocatable (its bitmap bits are set during init).
    const two_regions = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 4, .attribute = 0 },
        .{ .type = .reserved_memory_type, .physical_start = 0x104000, .virtual_start = 0, .number_of_pages = 4, .attribute = 0 },
        .{ .type = .conventional_memory, .physical_start = 0x105000, .virtual_start = 0, .number_of_pages = 4, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&two_regions), @sizeOf(memmap.MemoryDescriptor), two_regions.len);
    var st = State{};
    _ = st.init(view);
    try std.testing.expectEqual(@as(u64, 8), st.total_pages);
    const first = st.alloc_pages(4) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x100000), first);
    // The gap (0x104000..0x104fff) must NOT be handed out: the next run is
    // the second region (0x105000 = bit 20).
    const second = st.alloc_pages(4) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x105000), second);
    try std.testing.expect(st.alloc_pages(1) == null);
    try std.testing.expect(st.free_pages(first, 4));
    try std.testing.expect(st.free_pages(second, 4));
    try std.testing.expectEqual(@as(u64, 8), st.free_count);
}

test "alloc: unaligned conventional bases are rounded to whole pages" {
    const unaligned = [_]memmap.MemoryDescriptor{
        // base 0x100001: whole pages start at 0x101000 (2 pages declared,
        // 1 whole page remains after ceil/floor rounding).
        .{ .type = .conventional_memory, .physical_start = 0x100001, .virtual_start = 0, .number_of_pages = 2, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&unaligned), @sizeOf(memmap.MemoryDescriptor), unaligned.len);
    var st = State{};
    _ = st.init(view);
    try std.testing.expectEqual(@as(u64, 1), st.total_pages);
    const a = st.alloc_pages(1) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x101000), a);
}

test "alloc: free_pages bounds-checks alignment and span" {
    var st = State{};
    _ = st.init(make_view());
    try std.testing.expect(!st.free_pages(0x100001, 1)); // unaligned
    try std.testing.expect(!st.free_pages(0x100000 - 0x1000, 1)); // below base
    try std.testing.expect(!st.free_pages(0x100000, 961)); // past the end
    try std.testing.expect(!st.free_pages(0x100000, 0)); // zero pages
    // Freeing pages that were never allocated frees nothing.
    try std.testing.expect(!st.free_pages(0x100000, 1));
    try std.testing.expectEqual(@as(u64, 960), st.free_count);
}

test "alloc: double free cannot inflate the free count" {
    var st = State{};
    _ = st.init(make_view());
    const a = st.alloc_pages(4) orelse return error.TestUnexpectedResult;
    try std.testing.expect(st.free_pages(a, 4));
    try std.testing.expectEqual(@as(u64, 960), st.free_count);
    // Second free of the same pages frees nothing and reports false.
    try std.testing.expect(!st.free_pages(a, 4));
    try std.testing.expectEqual(@as(u64, 960), st.free_count);
}

test "alloc: reserve atomically removes pages from the pool" {
    var st = State{};
    _ = st.init(make_view());
    try std.testing.expect(st.reserve(0x100000, 4));
    try std.testing.expectEqual(@as(u64, 956), st.free_count);
    try std.testing.expect(!st.reserve(0x100000, 4)); // already reserved
    try std.testing.expectEqual(@as(u64, 956), st.free_count); // atomic: unchanged
    // The reserved run is not allocatable; the next run is after it.
    const a = st.alloc_pages(4) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x104000), a);
    try std.testing.expect(st.free_pages(0x100000, 4));
    try std.testing.expectEqual(@as(u64, 956 + 4 - 4), st.free_count);
}

test "alloc: largest_free_run reports the biggest contiguous run" {
    var st = State{};
    _ = st.init(make_view());
    try std.testing.expectEqual(@as(u64, 960), st.largest_free_run());
    const a = st.alloc_pages(300) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 660), st.largest_free_run());
    try std.testing.expect(st.free_pages(a, 300));
    try std.testing.expectEqual(@as(u64, 960), st.largest_free_run());
}

test "alloc: init is resettable (a second map rebuilds the pool)" {
    var st = State{};
    _ = st.init(make_view());
    const a = st.alloc_pages(1) orelse return error.TestUnexpectedResult;
    _ = a;
    try std.testing.expectEqual(@as(u64, 959), st.free_count);
    // Re-init with the same map resets the bitmap: all 960 pages free again.
    try std.testing.expect(st.init(make_view()));
    try std.testing.expectEqual(@as(u64, 960), st.free_count);
    try std.testing.expect(st.alloc_pages(1) != null);
}

test "alloc: regions beyond the 4 GiB bitmap span are untracked" {
    const far = [_]memmap.MemoryDescriptor{
        .{ .type = .conventional_memory, .physical_start = 0x100000, .virtual_start = 0, .number_of_pages = 4, .attribute = 0 },
        // Starts at exactly bitmap_base + 4 GiB — past the span cap.
        .{ .type = .conventional_memory, .physical_start = 0x1_0010_0000, .virtual_start = 0, .number_of_pages = 4, .attribute = 0 },
    };
    const view = memmap.MapView.init(std.mem.asBytes(&far), @sizeOf(memmap.MemoryDescriptor), far.len);
    var st = State{};
    _ = st.init(view);
    try std.testing.expectEqual(@as(u64, 4), st.total_pages);
    const a = st.alloc_pages(4) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0x100000), a);
    try std.testing.expect(st.alloc_pages(1) == null); // the far region is untracked
}

test "alloc: more than max_regions pools the first max_regions in map order" {
    var many: [max_regions + 4]memmap.MemoryDescriptor = undefined;
    for (0..many.len) |i| {
        many[i] = .{
            .type = .conventional_memory,
            .physical_start = 0x100000 + @as(u64, i) * 0x2000, // 2 pages each, 8 KiB apart
            .virtual_start = 0,
            .number_of_pages = 2,
            .attribute = 0,
        };
    }
    const view = memmap.MapView.init(std.mem.asBytes(&many), @sizeOf(memmap.MemoryDescriptor), many.len);
    var st = State{};
    _ = st.init(view);
    try std.testing.expectEqual(@as(usize, max_regions), st.region_count);
    try std.testing.expectEqual(@as(u64, max_regions * 2), st.total_pages);
    try std.testing.expectEqual(@as(u64, max_regions * 2), st.free_count);
}

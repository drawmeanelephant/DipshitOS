//! DipshitOS ESP file window (M1.5 close-out, claim 3475).
//!
//! The M1.5 definition of done lists `ls`/`cat`/`write`; hard gate 5
//! ("ls, cat, and write persist through reboot") was deferred at march step
//! 15 (2026-08-06) to a storage-driver milestone, with the milestone's own
//! sanctioned alternative being a **pre-exit file window** ("the kernel
//! reads/writes evidence files before exit and the monitor reports them").
//! This module implements that alternative:
//!
//! 1. **Pre-exit ESP snapshot.** `snapshot_esp(st, image_handle)` walks the
//!    ESP root via the EFI Simple File System protocol (the loader's proven
//!    pattern, boot/src/main.zig — the image handle comes from the handoff
//!    v2 record) BEFORE `ExitBootServices`, recording every entry's name,
//!    size, and — for files ≤ `esp_content_max` — its content, into a
//!    fixed BSS window. Post-exit the monitor serves `ls`/`cat` from the
//!    snapshot; no firmware service is used after the exit boundary.
//!
//! 2. **NVRAM-backed `write`.** Post-exit there is no writable filesystem
//!    (no ESP root / Simple File System; ADR 0004 D5), but EFI runtime
//!    `SetVariable` is proven alive on VZ (claims 0009/0015 — values
//!    ≤ ~512 B persist post-exit) and the runner's `VZEFIVariableStore`
//!    file (`artifacts/efi-vars.bin`) survives across boots, so a file
//!    written in one boot is present in the next. `write_file` stores the
//!    content as the non-volatile variable `DipshitF:<name>`; `scan_nvram`
//!    (run at every boot) reads those variables back via
//!    `GetNextVariableName`/`GetVariable` so `ls`/`cat` see them —
//!    persistence through reboot, honestly labeled `[nvram]`.
//!
//! Honesty rules: a failed/absent runtime call never changes control flow
//! (`write` reports the exact failure); NVRAM files are explicitly the
//! persistence medium, not a FAT write (the ESP stays read-only; a full
//! storage driver remains deferred); all limits are fixed and explicit; no
//! allocation beyond the fixed BSS window; case-insensitive name lookup
//! (FAT semantics) with the most recently written copy winning.
//!
//! No libc, no POSIX, no allocation, no interrupts.

const std = @import("std");
const uefi = std.os.uefi;
const SystemTable = uefi.tables.SystemTable;
const RuntimeServices = uefi.tables.RuntimeServices;
const Guid = uefi.Guid;
const Status = uefi.Status;

// ---------------------------------------------------------------------------
// Limits (fixed-size, explicit bounds)
// ---------------------------------------------------------------------------

/// Maximum file-name length (bytes, ASCII) listed or written.
pub const name_max: usize = 32;
/// Maximum ESP snapshot entries (files + directories, root only).
pub const esp_entries_max: usize = 48;
/// Maximum NVRAM-backed files (the runtime-variable window).
pub const nvram_entries_max: usize = 8;
/// Per-file content snapshot cap for ESP files (larger files are listed
/// with their size but not content-loaded; `cat` reports that honestly).
pub const esp_content_max: usize = 2048;
/// Per-file persistence cap for NVRAM-backed files. 384 B keeps the whole
/// variable value well under the ~512 B post-exit SetVariable budget proven
/// on VZ (claims 0013/0015).
pub const nvram_content_max: usize = 384;
/// Total content pool (BSS) shared by all loaded entries.
pub const content_pool_max: usize = 8192;
/// Total entry slots (ESP + NVRAM).
pub const entries_max: usize = esp_entries_max + nvram_entries_max;
/// Scan iteration bound: never walk the variable store unbounded.
const scan_iter_max: usize = 512;

/// Runtime-variable name prefix for NVRAM-backed files. Distinct from the
/// marker (`DipshitM2`), probe (`DipshitP*`), chunk (`DipshitC*`), and
/// diagnostic (`DipshitX`, `DipshitMmu`) namespaces.
const variable_prefix = "DipshitF:";

/// Same vendor GUID as the marker ladder / machine controls / NVRAM
/// console (`M2M2_DIPSHITOS-M`) so one store namespace holds all kernel
/// variables.
const vendor_guid = Guid{
    .time_low = 0x4d324d32, // "M2M2"
    .time_mid = 0x5f44, // "_D"
    .time_high_and_version = 0x4950, // "IP"
    .clock_seq_high_and_reserved = 0x53, // "S"
    .clock_seq_low = 0x48, // "H"
    .node = .{ 0x49, 0x54, 0x4f, 0x53, 0x2d, 0x4d }, // "ITOS-M"
};

const variable_attributes = RuntimeServices.VariableAttributes{
    .non_volatile = true,
    .bootservice_access = true,
    .runtime_access = true,
};

const SetVariableFn = *const fn (
    var_name: [*:0]const u16,
    vendor_guid: *const Guid,
    attributes: RuntimeServices.VariableAttributes,
    data_size: usize,
    data: [*]const u8,
) callconv(uefi.cc) Status;
const GetVariableFn = *const fn (
    var_name: [*:0]const u16,
    vendor_guid: *const Guid,
    attributes: ?*RuntimeServices.VariableAttributes,
    data_size: *usize,
    data: ?*anyopaque,
) callconv(uefi.cc) Status;
const GetNextVariableNameFn = *const fn (
    var_name_size: *usize,
    var_name: ?[*:0]const u16,
    vendor_guid: *Guid,
) callconv(uefi.cc) Status;
const QueryVariableInfoFn = *const fn (
    attributes: RuntimeServices.VariableAttributes,
    maximum_variable_storage_size: *u64,
    remaining_variable_storage_size: *u64,
    maximum_variable_size: *u64,
) callconv(uefi.cc) Status;

// ---------------------------------------------------------------------------
// Window state (fixed BSS)
// ---------------------------------------------------------------------------

pub const Kind = enum { esp_file, esp_dir, nvram_file };

pub const Entry = struct {
    name: [name_max]u8 = undefined,
    name_len: u8 = 0,
    /// ESP files: on-disk size. NVRAM files / dirs: content length / 0.
    size: u64 = 0,
    /// Offset into the content pool (meaningful when `len` > 0).
    offset: u16 = 0,
    /// Loaded content length (0 = listed but not content-loaded).
    len: u16 = 0,
    kind: Kind = .esp_file,
};

const State = struct {
    entries: [entries_max]Entry = undefined,
    content: [content_pool_max]u8 = undefined,
    entry_count: usize = 0,
    pool_used: usize = 0,
    /// Captured EFI Runtime Services (pre-exit). Null = honest no-op.
    runtime: ?*RuntimeServices = null,
    /// Remaining non-volatile variable-store budget from the last
    /// `QueryVariableInfo` (0 = not yet queried / unavailable).
    remaining: u64 = 0,
    /// True once the variable store has been scanned this boot.
    scanned: bool = false,

    fn clear(self: *State) void {
        self.entry_count = 0;
        self.pool_used = 0;
        self.scanned = false;
    }

    /// Append an entry, loading `content` when it fits the window. Returns
    /// false (and records nothing) when the name is invalid or the window
    /// is full; content that exceeds the per-file cap or the pool is
    /// listed without being loaded.
    fn add(self: *State, name: []const u8, size: u64, content: []const u8, kind: Kind) bool {
        if (name.len == 0 or name.len > name_max) return false;
        if (self.entry_count >= entries_max) return false;
        const e = &self.entries[self.entry_count];
        @memcpy(e.name[0..name.len], name);
        e.name_len = @intCast(name.len);
        e.size = size;
        e.kind = kind;
        e.offset = 0;
        e.len = 0;
        if (content.len > 0 and content.len <= esp_content_max and self.pool_used + content.len <= content_pool_max) {
            @memcpy(self.content[self.pool_used..][0..content.len], content);
            e.offset = @intCast(self.pool_used);
            e.len = @intCast(content.len);
            self.pool_used += content.len;
        }
        self.entry_count += 1;
        return true;
    }

    fn esp_count(self: *const State) usize {
        var n: usize = 0;
        for (self.entries[0..self.entry_count]) |e| {
            if (e.kind != .nvram_file) n += 1;
        }
        return n;
    }

    fn nvram_count(self: *const State) usize {
        var n: usize = 0;
        for (self.entries[0..self.entry_count]) |e| {
            if (e.kind == .nvram_file) n += 1;
        }
        return n;
    }

    /// Index of an existing NVRAM entry with the same (case-insensitive)
    /// name, or null. The most recently written copy wins.
    fn nvram_index(self: *const State, name: []const u8) ?usize {
        var i = self.entry_count;
        while (i > 0) {
            i -= 1;
            const e = &self.entries[i];
            if (e.kind == .nvram_file and name_eql(e.name[0..e.name_len], name)) return i;
        }
        return null;
    }
};

var state: State = .{};

// ---------------------------------------------------------------------------
// Public data-layer API (host-testable; no EFI calls)
// ---------------------------------------------------------------------------

/// Clear the window (boot-time init and tests).
pub fn reset() void {
    state.clear();
}

/// Capture the EFI Runtime Services table (kernel_main, pre-exit) so
/// `write_file`/`scan_nvram` can persist after ExitBootServices. Runtime
/// services, unlike boot services, survive it (the claim-0009 marker
/// channel proves SetVariable works post-exit on VZ). Without it writes
/// are honest no-ops.
pub fn set_runtime(rt: ?*RuntimeServices) void {
    state.runtime = rt;
    state.remaining = query_remaining();
}

/// Remaining non-volatile variable-store budget (bytes), or 0 when the
/// firmware does not implement `QueryVariableInfo`. The store is shared
/// with the marker/probe/chunk channels and is append-per-write on VZ
/// (claims 0009/0013), so this is the honest budget `write` has left.
pub fn remaining_bytes() u64 {
    return state.remaining;
}

fn query_remaining() u64 {
    const rt = state.runtime orelse return 0;
    const query: QueryVariableInfoFn = @ptrCast(rt._queryVariableInfo);
    var maximum: u64 = 0;
    var remaining: u64 = 0;
    var max_var: u64 = 0;
    if (query(variable_attributes, &maximum, &remaining, &max_var) != .success) return 0;
    return remaining;
}

pub fn entry_count() usize {
    return state.entry_count;
}

pub fn entries() []const Entry {
    return state.entries[0..state.entry_count];
}

pub fn entry(i: usize) *const Entry {
    return &state.entries[i];
}

pub fn esp_count() usize {
    return state.esp_count();
}

pub fn nvram_count() usize {
    return state.nvram_count();
}

/// Content bytes of an entry (empty when it was listed but not loaded).
pub fn content_of(e: *const Entry) []const u8 {
    return state.content[e.offset..][0..e.len];
}

/// Case-insensitive lookup (FAT semantics). NVRAM entries are scanned
/// first (most recently written wins), then the ESP snapshot.
pub fn lookup(name: []const u8) ?*const Entry {
    var i = state.entry_count;
    while (i > 0) {
        i -= 1;
        const e = &state.entries[i];
        if (name_eql(e.name[0..e.name_len], name)) return e;
    }
    return null;
}

/// Append an ESP file entry (used by the pre-exit EFI walk and by tests).
pub fn add_esp_entry(name: []const u8, size: u64, content: []const u8) bool {
    return state.add(name, size, content, .esp_file);
}

/// Append an ESP directory entry.
pub fn add_dir_entry(name: []const u8) bool {
    return state.add(name, 0, "", .esp_dir);
}

/// Add or replace an NVRAM-backed file entry in the window. Replaces an
/// existing same-name NVRAM entry in place (the pool is append-only, so a
/// replacement consumes at most `content.len` more bytes).
pub fn add_nvram_entry(name: []const u8, content: []const u8) bool {
    if (name.len == 0 or name.len > name_max) return false;
    if (content.len > nvram_content_max) return false;
    if (state.nvram_index(name)) |index| {
        const e = &state.entries[index];
        if (state.pool_used + content.len > content_pool_max) return false;
        @memcpy(state.content[state.pool_used..][0..content.len], content);
        e.offset = @intCast(state.pool_used);
        e.len = @intCast(content.len);
        e.size = content.len;
        state.pool_used += content.len;
        return true;
    }
    if (state.nvram_count() >= nvram_entries_max) return false;
    return state.add(name, content.len, content, .nvram_file);
}

// ---------------------------------------------------------------------------
// Persistence (`write`) and variable-store scan
// ---------------------------------------------------------------------------

pub const WriteResult = enum {
    ok,
    /// No runtime services captured (host test process, or init not run).
    no_runtime,
    name_invalid,
    content_too_long,
    /// NVRAM file slot limit (or content pool) reached.
    window_full,
    /// SetVariable returned an error — the file was NOT persisted.
    persist_failed,
};

/// Status code of the last failed SetVariable (diagnostics; 0 when the
/// last write succeeded or never reached the firmware).
pub var last_setvar_status: Status = .success;
/// Remaining store budget + max single-variable size queried at the moment
/// of the last failed write (diagnostics).
pub var last_query_remaining: u64 = 0;
pub var last_query_max_var: u64 = 0;

/// Persist a file as the non-volatile runtime variable `DipshitF:<name>`
/// and add it to the window. Capacity is checked BEFORE the write so a
/// persisted file is never invisible; the write itself is best effort
/// (a failed SetVariable is reported, never fatal). Bounded: name ≤ 32
/// chars, content ≤ 384 bytes, ≤ 8 files.
pub fn write_file(name: []const u8, content: []const u8) WriteResult {
    if (!valid_name(name)) return .name_invalid;
    if (content.len > nvram_content_max) return .content_too_long;
    const rt = state.runtime orelse return .no_runtime;
    if (state.nvram_index(name) == null) {
        if (state.nvram_count() >= nvram_entries_max) return .window_full;
        if (state.pool_used + content.len > content_pool_max) return .window_full;
    }
    const set_var: SetVariableFn = @ptrCast(rt._setVariable);
    var name16: [variable_prefix.len + name_max + 1:0]u16 = undefined;
    const n16 = variable_name_utf16(&name16, name);
    const st = set_var(n16, &vendor_guid, variable_attributes, content.len, content.ptr);
    if (st != .success) {
        last_setvar_status = st;
        const query: QueryVariableInfoFn = @ptrCast(rt._queryVariableInfo);
        var maximum: u64 = 0;
        var remaining: u64 = 0;
        var max_var: u64 = 0;
        if (query(variable_attributes, &maximum, &remaining, &max_var) == .success) {
            last_query_remaining = remaining;
            last_query_max_var = max_var;
        }
        return .persist_failed;
    }
    last_setvar_status = .success;
    if (!add_nvram_entry(name, content)) return .window_full;
    return .ok;
}

/// Scan the runtime-variable store for `DipshitF:` variables written by a
/// previous boot and add them to the window — this is what makes `ls`/`cat`
/// see files after a reboot. Best effort and bounded; a failed or absent
/// runtime call leaves whatever was already in the window.
pub fn scan_nvram() void {
    const rt = state.runtime orelse return;
    if (state.scanned) return;
    state.scanned = true;
    const get_next: GetNextVariableNameFn = @ptrCast(rt._getNextVariableName);
    const get_var: GetVariableFn = @ptrCast(rt._getVariable);
    var name_buf: [variable_prefix.len + name_max + 1:0]u16 = undefined;
    var guid: Guid = undefined;
    var iter: usize = 0;
    @memset(&name_buf, 0); // first call: empty name = start of the namespace
    var name_size: usize = @sizeOf(@TypeOf(name_buf));
    while (iter < scan_iter_max) : (iter += 1) {
        // The buffer carries the PREVIOUS name into the next call (EFI
        // spec); only the size is reset to the buffer capacity.
        if (get_next(&name_size, @ptrCast(&name_buf), &guid) != .success) break; // .not_found = end of namespace
        const nlen = std.mem.indexOfSentinel(u16, 0, &name_buf);
        name_size = @sizeOf(@TypeOf(name_buf));
        if (nlen <= variable_prefix.len) continue;
        if (!utf16_starts_with(name_buf[0..nlen], variable_prefix)) continue;
        // Probe the size, then read the value. GetVariable with our vendor
        // GUID skips variables from other namespaces (returns not_found).
        var attrs: RuntimeServices.VariableAttributes = undefined;
        var size: usize = 0;
        if (get_var(@ptrCast(&name_buf), &vendor_guid, &attrs, &size, null) != .buffer_too_small) continue;
        if (size == 0 or size > nvram_content_max) continue;
        var content: [nvram_content_max]u8 = undefined;
        if (get_var(@ptrCast(&name_buf), &vendor_guid, &attrs, &size, @ptrCast(&content)) != .success) continue;
        var fname: [name_max]u8 = undefined;
        var flen: usize = 0;
        var ok = true;
        for (name_buf[variable_prefix.len..nlen]) |ch| {
            if (ch > 0x7f or ch == 0) {
                ok = false;
                break;
            }
            if (flen >= name_max) {
                ok = false;
                break;
            }
            fname[flen] = @intCast(ch);
            flen += 1;
        }
        if (!ok or flen == 0) continue;
        _ = add_nvram_entry(fname[0..flen], content[0..size]);
    }
}

// ---------------------------------------------------------------------------
// Pre-exit ESP snapshot (EFI Boot Services; kernel path only)
// ---------------------------------------------------------------------------

/// Walk the ESP root via the EFI Simple File System protocol and fill the
/// window. Called PRE-EXIT (Boot Services must still be alive; post-exit
/// the protocols are gone — ADR 0004 D5). Best effort: any failure leaves
/// whatever was captured. The image handle comes from the handoff v2
/// record (the loader's own image handle — the kernel's std.start is not
/// the UEFI one).
pub fn snapshot_esp(st: *const SystemTable, image_handle: u64) void {
    const bs = st.boot_services orelse return;
    state.clear();
    const handle: uefi.Handle = @ptrFromInt(image_handle);
    const loaded_image = (bs.handleProtocol(uefi.protocol.LoadedImage, handle) catch null) orelse return;
    const device_handle = loaded_image.device_handle orelse return;
    const fs = (bs.handleProtocol(uefi.protocol.SimpleFileSystem, device_handle) catch null) orelse return;
    const root = fs.openVolume() catch return;
    defer root.close() catch {};

    var buf: [256]u8 align(8) = undefined;
    while (true) {
        // One directory entry per read; 0 bytes = end of directory.
        const n = root.read(&buf) catch return;
        if (n == 0) break;
        if (n < @sizeOf(uefi.protocol.File.Info.File)) continue;
        const info: *const uefi.protocol.File.Info.File = @ptrCast(@alignCast(&buf));
        const name16 = info.getFileName();
        var name: [name_max]u8 = undefined;
        var name_len: usize = 0;
        var ok = true;
        for (name16[0..std.mem.len(name16)]) |ch| {
            if (ch > 0x7f) {
                ok = false;
                break;
            }
            if (name_len >= name_max) {
                ok = false;
                break;
            }
            name[name_len] = @intCast(ch);
            name_len += 1;
        }
        if (!ok or name_len == 0) continue;
        const nm = name[0..name_len];
        if (std.mem.eql(u8, nm, ".") or std.mem.eql(u8, nm, "..")) continue;
        if (info.attribute.directory) {
            _ = add_dir_entry(nm);
            continue;
        }
        // Regular file: load content only when it fits the per-file cap
        // (larger files — e.g. KERNEL.BIN — are listed with their size).
        var content: [esp_content_max]u8 = undefined;
        var clen: usize = 0;
        if (info.file_size > 0 and info.file_size <= esp_content_max) {
            if (root.open(name16, .read, .{}) catch null) |f| {
                defer f.close() catch {};
                clen = f.read(&content) catch 0;
            }
        }
        _ = add_esp_entry(nm, info.file_size, content[0..clen]);
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn ascii_lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn name_eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (ascii_lower(x) != ascii_lower(y)) return false;
    }
    return true;
}

/// Printable ASCII, no path separators / control bytes.
fn valid_name(name: []const u8) bool {
    if (name.len == 0 or name.len > name_max) return false;
    for (name) |c| {
        if (c < 0x20 or c > 0x7e or c == '\\' or c == '/') return false;
    }
    return true;
}

fn utf16_starts_with(name: []const u16, prefix: []const u8) bool {
    if (name.len < prefix.len) return false;
    for (prefix, 0..) |c, i| if (name[i] != c) return false;
    return true;
}

/// Fill `buf` with "DipshitF:" + ASCII `name` (null-terminated u16) and
/// return the sentinel slice.
fn variable_name_utf16(buf: *[variable_prefix.len + name_max + 1:0]u16, name: []const u8) [*:0]const u16 {
    var i: usize = 0;
    for (variable_prefix) |c| {
        buf[i] = c;
        i += 1;
    }
    for (name) |c| {
        buf[i] = c;
        i += 1;
    }
    buf[i] = 0;
    return @ptrCast(buf);
}

// ---------------------------------------------------------------------------
// Tests (host-side; injected fakes, no hardware)
// ---------------------------------------------------------------------------

const spy_max_calls: usize = 64;
const spy_name_max: usize = variable_prefix.len + name_max + 1;
var spy_count: usize = 0;
var spy_names: [spy_max_calls][spy_name_max]u8 = undefined;
var spy_values: [spy_max_calls][nvram_content_max]u8 = undefined;
var spy_lens: [spy_max_calls]usize = undefined;
var spy_status: [spy_max_calls]Status = undefined;
/// Emulate a store: name (ascii) -> value. Filled by spySetVar, read by
/// spyGetVar / spyGetNextVariableName, so write_file + scan_nvram round-trip
/// like the real runner store.
var fake_store_count: usize = 0;
var fake_store_names: [spy_max_calls][spy_name_max]u8 = undefined;
var fake_store_values: [spy_max_calls][nvram_content_max]u8 = undefined;
var fake_store_lens: [spy_max_calls]usize = undefined;

fn spySetVar(
    var_name: [*:0]const u16,
    _: *const Guid,
    _: RuntimeServices.VariableAttributes,
    data_size: usize,
    data: [*]const u8,
) callconv(uefi.cc) Status {
    const name_len = std.mem.len(var_name);
    if (spy_count < spy_max_calls and name_len <= spy_name_max) {
        for (var_name[0..name_len], 0..) |ch, i| spy_names[spy_count][i] = @intCast(ch);
        spy_names[spy_count][name_len] = 0;
        const n = @min(data_size, nvram_content_max);
        @memcpy(spy_values[spy_count][0..n], data[0..n]);
        spy_lens[spy_count] = n;
        spy_status[spy_count] = .success;
        spy_count += 1;
    }
    // Mirror into the fake store so scan_nvram can read it back.
    if (fake_store_count < spy_max_calls and name_len <= spy_name_max) {
        for (var_name[0..name_len], 0..) |ch, i| fake_store_names[fake_store_count][i] = @intCast(ch);
        fake_store_names[fake_store_count][name_len] = 0;
        const n = @min(data_size, nvram_content_max);
        @memcpy(fake_store_values[fake_store_count][0..n], data[0..n]);
        fake_store_lens[fake_store_count] = n;
        fake_store_count += 1;
    }
    return .success;
}

fn spySetVarFail(
    _: [*:0]const u16,
    _: *const Guid,
    _: RuntimeServices.VariableAttributes,
    _: usize,
    _: [*]const u8,
) callconv(uefi.cc) Status {
    return .device_error;
}

fn spyQueryVariableInfo(
    _: RuntimeServices.VariableAttributes,
    maximum: *u64,
    remaining: *u64,
    max_var: *u64,
) callconv(uefi.cc) Status {
    maximum.* = 0x20000;
    remaining.* = 0x10000;
    max_var.* = 0x200;
    return .success;
}

fn spyGetNextVariableName(var_name_size: *usize, var_name: ?[*:0]const u16, _: *Guid) callconv(uefi.cc) Status {
    var pos: usize = 0;
    if (var_name) |prev| {
        // An empty name starts the namespace (the kernel zeroes the buffer
        // before its first call); otherwise find the previous name's
        // position in the store and continue after it.
        const prev_slice = std.mem.sliceTo(prev, 0);
        if (prev_slice.len > 0) {
            var prev_ascii: [spy_name_max]u8 = undefined;
            const plen = @min(prev_slice.len, spy_name_max);
            for (prev_slice[0..plen], 0..) |ch, i| prev_ascii[i] = @intCast(ch);
            while (pos < fake_store_count) {
                if (name_eql(std.mem.sliceTo(&fake_store_names[pos], 0), prev_ascii[0..plen])) {
                    pos += 1;
                    break;
                }
                pos += 1;
            }
        }
    }
    if (pos >= fake_store_count) return .not_found;
    if (var_name_size.* < fake_store_lens[pos] + 1) return .buffer_too_small;
    const dst: [*]u16 = @ptrCast(@alignCast(@constCast(var_name.?)));
    const name_len = std.mem.sliceTo(&fake_store_names[pos], 0).len;
    for (fake_store_names[pos][0..name_len], 0..) |ch, i| dst[i] = ch;
    dst[name_len] = 0;
    var_name_size.* = (name_len + 1) * 2;
    return .success;
}

fn spyGetVar(
    var_name: [*:0]const u16,
    _: *const Guid,
    _: ?*RuntimeServices.VariableAttributes,
    data_size: *usize,
    data: ?*anyopaque,
) callconv(uefi.cc) Status {
    const want = std.mem.sliceTo(var_name, 0);
    var want_ascii: [spy_name_max]u8 = undefined;
    const wlen = @min(want.len, spy_name_max);
    for (want[0..wlen], 0..) |ch, i| want_ascii[i] = @intCast(ch);
    var i: usize = fake_store_count;
    while (i > 0) {
        i -= 1;
        if (name_eql(std.mem.sliceTo(&fake_store_names[i], 0), want_ascii[0..wlen])) {
            if (data == null) {
                data_size.* = fake_store_lens[i];
                return .buffer_too_small;
            }
            if (data_size.* < fake_store_lens[i]) return .buffer_too_small;
            const n = fake_store_lens[i];
            @memcpy(@as([*]u8, @ptrCast(@alignCast(data.?)))[0..n], fake_store_values[i][0..n]);
            data_size.* = n;
            return .success;
        }
    }
    return .not_found;
}

/// Reset module state, capture the fake runtime services, and clear the
/// spies / fake store so tests are independent.
fn make_state() *State {
    spy_count = 0;
    fake_store_count = 0;
    state = .{};
    state.runtime = @ptrCast(&fake_runtime);
    return &state;
}

/// Minimal fake RuntimeServices exposing only the three function pointers
/// the module uses. The other fields are left undefined (never touched).
var fake_runtime: RuntimeServices = undefined;

fn init_fake_runtime() void {
    fake_runtime = undefined;
    fake_runtime._setVariable = @ptrCast(&spySetVar);
    fake_runtime._getVariable = @ptrCast(&spyGetVar);
    fake_runtime._getNextVariableName = @ptrCast(&spyGetNextVariableName);
    fake_runtime._queryVariableInfo = @ptrCast(&spyQueryVariableInfo);
}

fn spy_name(index: usize) []const u8 {
    return std.mem.sliceTo(&spy_names[index], 0);
}

test "esp: snapshot entries are listed in order with sizes and content" {
    _ = make_state();
    try std.testing.expect(add_esp_entry("KERNEL.BIN", 0x88b38, ""));
    try std.testing.expect(add_dir_entry("EFI"));
    try std.testing.expect(add_esp_entry("BOOTED.TXT", 0x29, "DIPSHITOS BOOTLOADER\nfirmware has agreed to cooperate\n"));
    try std.testing.expectEqual(@as(usize, 3), entry_count());
    try std.testing.expectEqual(@as(usize, 3), esp_count());
    try std.testing.expectEqual(@as(usize, 0), nvram_count());
    // KERNEL.BIN is listed with its size but no content loaded.
    const big = lookup("KERNEL.BIN").?;
    try std.testing.expectEqual(@as(u64, 0x88b38), big.size);
    try std.testing.expectEqual(@as(usize, 0), content_of(big).len);
    const booted = lookup("booted.txt").?; // case-insensitive
    try std.testing.expectEqualStrings("BOOTED.TXT", booted.name[0..booted.name_len]);
    try std.testing.expectEqualStrings("DIPSHITOS BOOTLOADER\nfirmware has agreed to cooperate\n", content_of(booted));
    try std.testing.expect(lookup("NOPE.TXT") == null);
}

test "esp: write_file persists via SetVariable and is immediately visible" {
    _ = make_state();
    init_fake_runtime();
    const r = write_file("hello.txt", "hello world");
    try std.testing.expectEqual(WriteResult.ok, r);
    try std.testing.expectEqual(@as(usize, 1), spy_count);
    try std.testing.expectEqualStrings("DipshitF:hello.txt", spy_name(0));
    try std.testing.expectEqual(@as(usize, 11), spy_lens[0]);
    try std.testing.expectEqualStrings("hello world", spy_values[0][0..spy_lens[0]]);
    const e = lookup("HELLO.TXT").?;
    try std.testing.expectEqual(Kind.nvram_file, e.kind);
    try std.testing.expectEqualStrings("hello world", content_of(e));
}

test "esp: scan_nvram reads back files persisted by a previous boot" {
    _ = make_state();
    init_fake_runtime();
    // Simulate a previous boot: write, then re-create the module state
    // (fresh window, same store) and scan.
    _ = write_file("hello.txt", "hello world");
    state = .{};
    state.runtime = @ptrCast(&fake_runtime);
    scan_nvram();
    try std.testing.expectEqual(@as(usize, 1), nvram_count());
    const e = lookup("hello.txt").?;
    try std.testing.expectEqual(Kind.nvram_file, e.kind);
    try std.testing.expectEqualStrings("hello world", content_of(e));
}

test "esp: scan_nvram runs at most once per boot" {
    _ = make_state();
    init_fake_runtime();
    _ = write_file("a.txt", "aaa");
    state = .{};
    state.runtime = @ptrCast(&fake_runtime);
    scan_nvram();
    scan_nvram();
    try std.testing.expectEqual(@as(usize, 1), nvram_count());
}

test "esp: write_file failure is reported honestly, never persisted" {
    _ = make_state();
    fake_runtime = undefined;
    fake_runtime._setVariable = @ptrCast(&spySetVarFail);
    fake_runtime._getVariable = @ptrCast(&spyGetVar);
    fake_runtime._getNextVariableName = @ptrCast(&spyGetNextVariableName);
    fake_runtime._queryVariableInfo = @ptrCast(&spyQueryVariableInfo);
    state.runtime = @ptrCast(&fake_runtime);
    try std.testing.expectEqual(WriteResult.persist_failed, write_file("x.txt", "x"));
    try std.testing.expectEqual(@as(usize, 0), nvram_count());
}

test "esp: write_file bounds — invalid names, over-long content, slot cap" {
    _ = make_state();
    init_fake_runtime();
    try std.testing.expectEqual(WriteResult.name_invalid, write_file("", "x"));
    try std.testing.expectEqual(WriteResult.name_invalid, write_file("a/b.txt", "x"));
    try std.testing.expectEqual(WriteResult.name_invalid, write_file("a\\b.txt", "x"));
    try std.testing.expectEqual(WriteResult.name_invalid, write_file("a\x01b", "x"));
    try std.testing.expectEqual(WriteResult.content_too_long, write_file("big.txt", &([_]u8{'x'} ** (nvram_content_max + 1))));
    // Fill the slot cap: the 8th distinct file is refused before any write.
    var i: usize = 0;
    while (i < nvram_entries_max) : (i += 1) {
        var nm: [16]u8 = undefined;
        const s = try std.fmt.bufPrint(&nm, "f{d}.txt", .{i});
        try std.testing.expectEqual(WriteResult.ok, write_file(s, "x"));
    }
    try std.testing.expectEqual(WriteResult.window_full, write_file("overflow.txt", "x"));
    // Replacing an existing file still works at the cap.
    try std.testing.expectEqual(WriteResult.ok, write_file("f0.txt", "replacement"));
}

test "esp: no runtime services makes write an honest no-op" {
    _ = make_state();
    state.runtime = null;
    try std.testing.expectEqual(WriteResult.no_runtime, write_file("x.txt", "x"));
    try std.testing.expectEqual(@as(usize, 0), nvram_count());
}

test "esp: name lookup is case-insensitive with the nvram copy winning" {
    _ = make_state();
    init_fake_runtime();
    try std.testing.expect(add_esp_entry("HELLO.TXT", 5, "esp!"));
    _ = write_file("hello.txt", "nvram!");
    const e = lookup("HeLlO.TxT").?;
    try std.testing.expectEqual(Kind.nvram_file, e.kind);
    try std.testing.expectEqualStrings("nvram!", content_of(e));
}

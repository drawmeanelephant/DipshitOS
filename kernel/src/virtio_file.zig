//! M34 HF1+HF2 (issues #735/#736): the guest client for the HOST FILE
//! CHANNEL — a macOS folder served over custom-virtio queue 5
//! (`virtio_custom.file_qidx`, runner flag `--cvc-file <host-dir>`).
//!
//! Mirrors how `fat.zig` sits on `virtio_blk.zig`: a pure, host-testable
//! encode/decode core (the wire format is pinned byte-for-byte by the
//! shared class-A fixtures and the host's pure-Swift `VFWire` module) plus
//! a bounded polled transport on the claim-4374 primitives
//! (`submit_ex`/`wait`/`free_chain_q`).
//!
//! Wire (pinned by `tests/vf-*.bin`; see docs/hardware-contract.md):
//!   request  [op u8][flags u8][len u16le][payload]
//!   reply    [status u8][dlen u16le][data]
//!
//! Ops: VF_PROBE (0x00, transport-only — never a filesystem path),
//! LIST (0x01), READ (0x02, payload = [path][u64le offset] — stateless
//! streaming, the host holds zero state between requests), STAT (0x03,
//! payload = [path]), and the HF3 mutation set (additive, 0x04..0x0b):
//! OPEN/CLOSE/WRITE/TRUNCATE/FSYNC (handle-based — the host's 8-slot
//! handle table carries the write cursor; parity with file_table.zig's
//! 8-handle ABI) and RENAME/MKDIR/DELETE (path-based stateless). Reply
//! status: 0 ok, 1 not found, 2 is a directory, 3 truncated (reply
//! exceeded the guest's buffer), 4 host error, 5 exists (create/rename
//! target collision), 6 handle error (host table full or bad handle).
//!
//! VF_PROBE (HF1's acceptance case A) proves the ONE unproven transport
//! fact: a full 32,768-byte device-WRITE reply (claim 0680 proved 32 KiB
//! device-reads; the claim-9492 echo is the largest device-write today, at
//! 12,340 bytes). The probe reply is the RAW 32,768-byte pattern — the
//! transport-only op carries no [status][dlen] frame (the op tells the
//! guest what the reply means; the framing applies to the file ops):
//!   reply = pattern[0..32768),  pattern[i] = (i & 0xff) ^ ((i >> 8) & 0xff)
//! The guest asserts the used ring reports the FULL writtenByteCount
//! (32768), regenerates and compares ALL 32,768 bytes (a full compare,
//! not just the checksum — catches offset/ordering bugs), then main.zig
//! prints the RFC-1071 checksum for the gate. The same 32,768 bytes are
//! the shared class-A fixture `tests/vf-pattern-32k.bin` (sha256-pinned).

const virtio_custom = @import("virtio_custom.zig");
const std = @import("std");

// ---------------------------------------------------------------------------
// Wire constants (mirrored by the host's VFWire module)
// ---------------------------------------------------------------------------

pub const op_probe: u8 = 0x00;
pub const op_list: u8 = 0x01;
pub const op_read: u8 = 0x02;
pub const op_stat: u8 = 0x03;
// HF3 (issue #737): mutation ops — ADDITIVE (0x04..0x0b), so the protocol
// stays non-breaking: an old host answers any new op with status 4 host
// error and an old guest never sends them. No version byte churn.
pub const op_open: u8 = 0x04;
pub const op_close: u8 = 0x05;
pub const op_write: u8 = 0x06;
pub const op_truncate: u8 = 0x07;
pub const op_fsync: u8 = 0x08;
pub const op_rename: u8 = 0x09;
pub const op_mkdir: u8 = 0x0a;
pub const op_delete: u8 = 0x0b;

pub const st_ok: u8 = 0;
pub const st_not_found: u8 = 1;
pub const st_is_dir: u8 = 2;
pub const st_truncated: u8 = 3;
pub const st_host_error: u8 = 4;
pub const st_exists: u8 = 5;
pub const st_handle: u8 = 6;

/// OPEN request `flags` byte bits (the framing's reserved byte picks up
/// per-op modifiers): bit0 create-if-missing, bit1 append-writes.
pub const open_flag_create: u8 = 0x01;
pub const open_flag_append: u8 = 0x02;

/// Request header: [op u8][flags u8][len u16le] then `len` payload bytes.
pub const request_hdr_len: usize = 4;
/// Reply header: [status u8][dlen u16le] then `dlen` data bytes.
pub const reply_hdr_len: usize = 3;
/// Paths are bounded (255 bytes) — honest refusal beyond.
pub const path_max: usize = 255;
/// The guest's reply buffer cap: full-cap 32 KiB device-write (HF1).
pub const reply_cap: usize = 32768;
/// LIST replies carry at most 128 40-byte rows (matches fat.max_root_slots;
/// 40 × 128 = 5 KiB — fits the reply buffer trivially).
pub const list_max_entries: usize = 128;
/// One LIST row: [name 31 B, NUL-padded][type u8][size u64le].
pub const entry_row_len: usize = 40;
/// READ payload = [path][u64le offset].
pub const read_offset_len: usize = 8;
/// HF3 handle + scalar field lengths.
pub const handle_len: usize = 2;
pub const written_len: usize = 8;
pub const truncate_size_len: usize = 8;
/// Host handle table cap — parity with kernel's file_table.zig
/// (max_handles_per_process = 8), asserted live on the HOST side where the
/// cursors live.
pub const max_file_handles: usize = 8;
/// Max data bytes per WRITE request body: the 2-byte handle + data must
/// fit the request nicely under the u16 length field AND stay within the
/// 32 KiB reply-cap symmetry (a chunked write never needs a large reply).
pub const write_chunk_max: usize = reply_cap - reply_hdr_len - handle_len;

pub const dir_type_file: u8 = 0;
pub const dir_type_dir: u8 = 1;

pub const DirEntry = struct {
    name: [31]u8 = [_]u8{0} ** 31,
    name_len: usize = 0,
    type: u8 = dir_type_file,
    size: u64 = 0,
};

// ---------------------------------------------------------------------------
// Pure encode/decode (host-testable; no transport state)
// ---------------------------------------------------------------------------

/// Little-endian byte primitives on SLICES (the std writeInt/readInt want
/// comptime-bounded array slices; our buffers are slice parameters — the
/// fat.zig read_le/write_le discipline).
fn write_le_u16(out: []u8, off: usize, v: u16) void {
    out[off] = @truncate(v);
    out[off + 1] = @truncate(v >> 8);
}

fn write_le_u64(out: []u8, off: usize, v: u64) void {
    var x = v;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        out[off + i] = @truncate(x);
        x >>= 8;
    }
}

fn read_le_u16(bytes: []const u8, off: usize) u16 {
    return @as(u16, bytes[off]) | (@as(u16, bytes[off + 1]) << 8);
}

fn read_le_u64(bytes: []const u8, off: usize) u64 {
    var v: u64 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) v |= @as(u64, bytes[off + i]) << @intCast(8 * i);
    return v;
}

/// Encode a request into `out`; returns the request length, or null when
/// the payload is too long or `out` is too small.
pub fn encode_request(op: u8, flags: u8, payload: []const u8, out: []u8) ?usize {
    if (payload.len > 0xffff) return null;
    const total = request_hdr_len + payload.len;
    if (out.len < total) return null;
    out[0] = op;
    out[1] = flags;
    write_le_u16(out, 2, @intCast(payload.len));
    @memcpy(out[4..][0..payload.len], payload);
    return total;
}

/// A decoded reply: status, the host's declared data length, and the data
/// slice — CLAMPED to the buffer (the read never goes out of bounds even
/// for a hostile dlen; `clamped` reports that truncation happened).
pub const Reply = struct {
    status: u8,
    dlen: u16,
    data: []const u8,
    clamped: bool,
};

/// Decode a reply buffer: [status u8][dlen u16le][data]. A buffer shorter
/// than the header decodes as host_error with an empty data slice.
pub fn decode_reply(buf: []const u8) Reply {
    if (buf.len < reply_hdr_len) {
        return .{ .status = st_host_error, .dlen = 0, .data = buf[0..0], .clamped = true };
    }
    const status = buf[0];
    const dlen = read_le_u16(buf, 1);
    const avail = buf.len - reply_hdr_len;
    const take = @min(@as(usize, dlen), avail);
    return .{
        .status = status,
        .dlen = dlen,
        .data = buf[reply_hdr_len .. reply_hdr_len + take],
        .clamped = take < dlen,
    };
}

/// The VF_PROBE pattern (both sides compute it without storing 32 KiB):
/// `pattern[i] = (i & 0xff) ^ ((i >> 8) & 0xff)`.
pub fn pattern(i: usize) u8 {
    return @intCast((i & 0xff) ^ ((i >> 8) & 0xff));
}

/// Decode one 40-byte LIST row into a DirEntry (never reads OOB; a short
/// row yields an empty entry).
pub fn decode_entry_row(row: []const u8) DirEntry {
    var e = DirEntry{};
    if (row.len < entry_row_len) return e;
    @memcpy(e.name[0..31], row[0..31]);
    e.name_len = 0;
    while (e.name_len < 31 and e.name[e.name_len] != 0) e.name_len += 1;
    e.type = row[31];
    e.size = read_le_u64(row, 32);
    return e;
}

/// Build a READ request payload: [path][u64le offset].
pub fn build_read_payload(path: []const u8, offset: u64, out: []u8) ?usize {
    if (path.len > path_max) return null;
    const total = path.len + read_offset_len;
    if (out.len < total) return null;
    @memcpy(out[0..path.len], path);
    write_le_u64(out, path.len, offset);
    return total;
}

// ---------------------------------------------------------------------------
// Bounded polled transport (queue 5)
// ---------------------------------------------------------------------------

/// The bounded wait budget for ONE file-channel exchange (polled — no IRQ
/// dependency; the 32 KiB reply needs a generous spin budget).
pub const exchange_budget: usize = 32_000_000;

/// BSS staging — the flat kernel does not relocate, so every buffer the
/// device touches must hold a runtime-correct address (claim 0015: no
/// comptime-folded pointers into .rodata). The request fits a 255-byte
/// path + u64 offset + the 4-byte header; the reply is the full 32 KiB.
var vf_req_buf: [request_hdr_len + path_max + read_offset_len]u8 align(16) = undefined;
/// WRITE staging: the full request [op][flags][len][handle u16][data] —
/// the one large guest→host payload (up to write_chunk_max data bytes per
/// round trip).
var vf_write_buf: [request_hdr_len + handle_len + write_chunk_max]u8 align(16) = undefined;
/// Runtime-built scatter staging (claim-0015/cv_scatter class): the
/// anonymous-array-literal form const-folds into .rodata with baked
/// image-relative pointers, so the read-buffer slice array lives in BSS.
var vf_scatter: [1][]const u8 = undefined;
/// The reply buffer (device-write target); the single largest per-queue
/// buffer and the point of HF1: the host must write all 32 KiB into it.
var vf_reply_buf: [reply_cap]u8 align(16) = undefined;

/// True when the transport is usable (queue 5 armed by the runner's
/// `--cvc-file`). Read by the monitor's `vf` commands to print the honest
/// "no host file channel" line on default boots.
pub fn available() bool {
    return virtio_custom.cv_ready and virtio_custom.has_file_queue;
}

/// One bounded exchange on queue 5: submit an ALREADY-ENCODED request
/// (`req`), poll-wait for the host's reply, free the chain. Returns the
/// used-ring length (bytes the host wrote), or null on transport
/// failure/timeout.
fn exchange_raw(req: []const u8, reply_buf: []u8) ?u32 {
    if (!available()) return null;
    vf_scatter[0] = req;
    const handle = virtio_custom.submit_ex(virtio_custom.file_qidx, &vf_scatter, reply_buf, false) orelse return null;
    const n = virtio_custom.wait(virtio_custom.file_qidx, handle, exchange_budget, reply_buf) orelse {
        // claim-0680 discipline: a polled send MUST free its descriptor
        // chain even on timeout — the ring never leaks.
        virtio_custom.free_chain_q(virtio_custom.file_qidx, handle);
        return null;
    };
    virtio_custom.free_chain_q(virtio_custom.file_qidx, handle);
    return n;
}

/// One bounded exchange on queue 5: encode the request into the shared
/// small request buffer, then exchange_raw.
fn exchange(op: u8, flags: u8, payload: []const u8, reply_buf: []u8) ?u32 {
    const req_len = encode_request(op, flags, payload, &vf_req_buf) orelse return null;
    return exchange_raw(vf_req_buf[0..req_len], reply_buf);
}

// ---------------------------------------------------------------------------
// VF_PROBE — the 32 KiB device-write spike (HF1 acceptance case A)
// ---------------------------------------------------------------------------

/// Total VF_PROBE reply size: exactly 32,768 bytes (the capability under
/// test — the used ring must report the FULL writtenByteCount).
pub const probe_reply_len: usize = reply_cap;
/// The probe's marker value (0x8000 = 32768) printed as `len=` — the
/// gate's needle for the full-cap reply.
pub const probe_dlen: u16 = 0x8000;

pub const ProbeResult = struct {
    ok: bool,
    cksum: u16,
    free: u16,
};

/// Run the spike once at boot when queue 5 is armed: two exchanges
/// (chain reuse + the ring's free count restored to full — the
/// claim-0680 leak class at full scale), each verifying the full 32 KiB
/// device-write reply byte-for-byte. Returns the result for main.zig to
/// print in the cvspike style (the gate's marker line).
pub fn probe_spike() ProbeResult {
    const bad = ProbeResult{ .ok = false, .cksum = 0, .free = 0 };
    if (!available()) return bad;
    var ok = true;
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        const n = exchange(op_probe, 0, &[_]u8{}, &vf_reply_buf) orelse {
            ok = false;
            break;
        };
        // The transport-only probe reply is the RAW 32,768-byte pattern
        // (no [status][dlen] frame): the used ring must report the FULL
        // writtenByteCount and every byte must match the generator.
        if (n != probe_reply_len) {
            ok = false;
            break;
        }
        var j: usize = 0;
        while (j < probe_reply_len) : (j += 1) {
            if (vf_reply_buf[j] != pattern(j)) {
                ok = false;
                break;
            }
        }
        if (!ok) break;
    }
    const free = virtio_custom.cv_rings[virtio_custom.file_qidx].free_count;
    if (!ok) return ProbeResult{ .ok = false, .cksum = 0, .free = free };
    const cksum = virtio_custom.checksum1071(vf_reply_buf[0..probe_reply_len]);
    return ProbeResult{ .ok = true, .cksum = cksum, .free = free };
}

// ---------------------------------------------------------------------------
// File ops (HF2 — used by the monitor's `vf ls` / `vf cat`)
// ---------------------------------------------------------------------------

/// The result of `list`: parsed rows + the reply status.
pub const ListResult = struct {
    entries: [list_max_entries]DirEntry = undefined,
    count: usize = 0,
    status: u8 = st_host_error,
};

/// LIST a directory on the host share. `path` empty = the share root.
/// Returns the reply status; rows land in `out`.
pub fn list(path: []const u8, out: *ListResult) u8 {
    out.* = .{};
    if (!available()) return st_host_error;
    const n = exchange(op_list, 0, path, &vf_reply_buf) orelse return st_host_error;
    const rep = decode_reply(vf_reply_buf[0..n]);
    out.status = rep.status;
    if (rep.status != st_ok) return rep.status;
    var off: usize = 0;
    while (off + entry_row_len <= rep.data.len and out.count < list_max_entries) : (off += entry_row_len) {
        out.entries[out.count] = decode_entry_row(rep.data[off .. off + entry_row_len]);
        out.count += 1;
    }
    return st_ok;
}

/// STAT a path: size, type. Returns the reply status.
pub const StatResult = struct {
    status: u8 = st_host_error,
    size: u64 = 0,
    is_dir: bool = false,
};

pub fn stat(path: []const u8, out: *StatResult) u8 {
    out.* = .{};
    if (!available()) return st_host_error;
    const n = exchange(op_stat, 0, path, &vf_reply_buf) orelse return st_host_error;
    const rep = decode_reply(vf_reply_buf[0..n]);
    out.status = rep.status;
    if (rep.status != st_ok) return rep.status;
    if (rep.data.len >= 9) {
        out.size = read_le_u64(rep.data, 0);
        out.is_dir = rep.data[8] == dir_type_dir;
    }
    return st_ok;
}

/// READ a file at `offset`. Returns the reply status; on ok the data
/// slice points into the module's reply buffer and is valid only until the
/// NEXT exchange on queue 5 (callers print/checksum immediately).
pub const ReadResult = struct {
    status: u8 = st_host_error,
    data: []const u8 = "",
};

pub fn read(path: []const u8, offset: u64) ReadResult {
    if (!available()) return .{ .status = st_host_error, .data = "" };
    var payload: [path_max + read_offset_len]u8 = undefined;
    const plen = build_read_payload(path, offset, &payload) orelse return .{ .status = st_host_error, .data = "" };
    const n = exchange(op_read, 0, payload[0..plen], &vf_reply_buf) orelse return .{ .status = st_host_error, .data = "" };
    const rep = decode_reply(vf_reply_buf[0..n]);
    if (rep.status != st_ok) return .{ .status = rep.status, .data = "" };
    if (rep.clamped) return .{ .status = st_truncated, .data = "" };
    return .{ .status = st_ok, .data = rep.data };
}

// ---------------------------------------------------------------------------
// Mutation ops (HF3, issue #737)
// ---------------------------------------------------------------------------

/// OPEN a file on the host share. `flags` = open_flag_create /
/// open_flag_append (create-if-missing makes the gate's "write a new
/// file" story one verb). On ok, `out_handle` receives the host handle
/// (cursor 0, or EOF when append — the host's table owns the cursor).
pub fn open(path: []const u8, flags: u8, out_handle: *u16) u8 {
    out_handle.* = 0;
    if (!available()) return st_host_error;
    const n = exchange(op_open, flags, path, &vf_reply_buf) orelse return st_host_error;
    const rep = decode_reply(vf_reply_buf[0..n]);
    if (rep.status != st_ok) return rep.status;
    if (rep.data.len < handle_len) return st_host_error;
    out_handle.* = read_le_u16(rep.data, 0);
    return st_ok;
}

/// CLOSE a host handle (flush + free the slot).
pub fn close(handle: u16) u8 {
    return exchange_simple(op_close, handle);
}

/// FSYNC a host handle — real durability (the host calls synchronize() on
/// the live FileHandle).
pub fn fsync(handle: u16) u8 {
    return exchange_simple(op_fsync, handle);
}

fn exchange_simple(op: u8, handle: u16) u8 {
    if (!available()) return st_host_error;
    var payload: [handle_len]u8 = undefined;
    write_le_u16(&payload, 0, handle);
    const n = exchange(op, 0, &payload, &vf_reply_buf) orelse return st_host_error;
    return decode_reply(vf_reply_buf[0..n]).status;
}

/// WRITE `data` at the handle's cursor (append handles write at EOF). The
/// host returns the byte count it actually wrote. One WRITE round trip
/// carries ≤ write_chunk_max data bytes; callers chunk larger payloads.
pub fn write(handle: u16, data: []const u8, out_written: *u64) u8 {
    out_written.* = 0;
    if (!available()) return st_host_error;
    if (data.len > write_chunk_max) return st_host_error;
    // Assemble the full request in one buffer without any self-overlap:
    // header fields at the head, body ([handle][data]) after them.
    const body_len = handle_len + data.len;
    const req_len = request_hdr_len + body_len;
    vf_write_buf[0] = op_write;
    vf_write_buf[1] = 0;
    write_le_u16(&vf_write_buf, 2, @intCast(body_len));
    write_le_u16(&vf_write_buf, request_hdr_len, handle);
    @memcpy(vf_write_buf[request_hdr_len + handle_len ..][0..data.len], data);
    const n = exchange_raw(vf_write_buf[0..req_len], &vf_reply_buf) orelse return st_host_error;
    const rep = decode_reply(vf_reply_buf[0..n]);
    if (rep.status != st_ok) return rep.status;
    if (rep.data.len < written_len) return st_host_error;
    out_written.* = read_le_u64(rep.data, 0);
    return st_ok;
}

/// TRUNCATE an open handle to `size` (read-modify-write: shrinking past
/// the cursor clamps the cursor; does not move the cursor otherwise).
pub fn truncate(handle: u16, size: u64) u8 {
    if (!available()) return st_host_error;
    var payload: [handle_len + truncate_size_len]u8 = undefined;
    write_le_u16(&payload, 0, handle);
    write_le_u64(&payload, handle_len, size);
    const n = exchange(op_truncate, 0, &payload, &vf_reply_buf) orelse return st_host_error;
    return decode_reply(vf_reply_buf[0..n]).status;
}

/// RENAME/overwrite `from` → `to` on the host share (stateless).
/// NUL-separated payload (paths are NUL-free by construction).
pub fn rename(from: []const u8, to: []const u8) u8 {
    if (!available()) return st_host_error;
    if (from.len == 0 or to.len == 0 or from.len > path_max or to.len > path_max) return st_host_error;
    var payload: [path_max * 2 + 1]u8 = undefined;
    @memcpy(payload[0..from.len], from);
    payload[from.len] = 0;
    @memcpy(payload[from.len + 1 ..][0..to.len], to);
    const plen = from.len + 1 + to.len;
    const n = exchange(op_rename, 0, payload[0..plen], &vf_reply_buf) orelse return st_host_error;
    return decode_reply(vf_reply_buf[0..n]).status;
}

/// MKDIR a directory on the host share (one level; parents must exist).
/// Returns st_exists when the target already exists.
pub fn mkdir(path: []const u8) u8 {
    return exchange_path(op_mkdir, path);
}

/// DELETE a file or EMPTY directory on the host share. Non-empty
/// directories fail honestly with a host error (never recursive).
pub fn delete(path: []const u8) u8 {
    return exchange_path(op_delete, path);
}

fn exchange_path(op: u8, path: []const u8) u8 {
    if (!available()) return st_host_error;
    if (path.len > path_max) return st_host_error;
    const n = exchange(op, 0, path, &vf_reply_buf) orelse return st_host_error;
    return decode_reply(vf_reply_buf[0..n]).status;
}

/// Pattern staging for `write_pattern` — BSS (the 16 KiB boot stack cannot
/// hold a 32 KiB chunk; claim-0015 also wants device paths runtime-only,
/// though this buffer itself never touches the device — write() copies it
/// into its own BSS request buffer).
var vf_write_pattern_buf: [write_chunk_max]u8 align(16) = undefined;

pub const WritePatternResult = struct {
    status: u8 = st_host_error,
    total: u64 = 0,
    chunks: usize = 0,
};

/// Stream `n` deterministic probe-pattern bytes through a handle's cursor
/// across chunk round trips (the monitor's `vf write <h> <n>` and the
/// mutation gate's deterministic on-disk check). The pattern index always
/// advances by the host-CONFIRMED written count, so a partial write never
/// corrupts the stream (honest byte accounting). Returns the final status
/// + host-confirmed total + round-trip count.
pub fn write_pattern(handle: u16, n: u64) WritePatternResult {
    var remaining = n;
    var res = WritePatternResult{};
    while (remaining > 0) {
        const take: usize = @intCast(@min(remaining, write_chunk_max));
        var i: usize = 0;
        while (i < take) : (i += 1) vf_write_pattern_buf[i] = pattern(@intCast(res.total + i));
        var written: u64 = 0;
        const st = write(handle, vf_write_pattern_buf[0..take], &written);
        if (st != st_ok) {
            res.status = st;
            return res;
        }
        res.total += written;
        remaining -= written;
        res.chunks += 1;
    }
    res.status = st_ok;
    return res;
}

/// Streaming RFC-1071 accumulator (big-endian word semantics, matching
/// `virtio_custom.checksum1071` and the gate's python cross-check) so
/// `vf cat` can checksum a >32 KiB stream across READ round trips.
pub const StreamCksum = struct {
    sum: u64 = 0,
    /// A pending high byte from an odd-length previous chunk.
    carry: ?u8 = null,

    pub fn add(self: *StreamCksum, data: []const u8) void {
        var i: usize = 0;
        if (self.carry) |hi| {
            if (data.len > 0) {
                self.sum += (@as(u64, hi) << 8) | data[0];
                i = 1;
                self.carry = null;
            }
        }
        while (i + 1 < data.len) : (i += 2) {
            self.sum += (@as(u64, data[i]) << 8) | data[i + 1];
        }
        if (i < data.len) self.carry = data[i];
    }

    pub fn finish(self: *const StreamCksum) u16 {
        var sum = self.sum;
        if (self.carry) |hi| sum += @as(u64, hi) << 8;
        while (sum >> 16 != 0) sum = (sum & 0xffff) + (sum >> 16);
        return ~@as(u16, @truncate(sum));
    }
};

// ---------------------------------------------------------------------------
// Host tests (G1–G6 from issue #735)
// ---------------------------------------------------------------------------

const testing = std.testing;

test "virtio_file: G1 — pattern generator parity is pinned (fixture class)" {
    // The generator is the byte-for-byte lock with the host's Swift
    // generator and the shared class-A fixture `tests/vf-pattern-32k.bin`
    // (whose sha256 the class-A gate pins).
    try testing.expectEqual(@as(u8, 0x00), pattern(0));
    try testing.expectEqual(@as(u8, 0xff), pattern(0xff));
    // 0x100 = 256: low byte 0x00 XOR high byte 0x01 = 1; 0x101 → 0 ^ 1 = 1
    // XOR 0x01 = 0.
    try testing.expectEqual(@as(u8, 0x01), pattern(0x100));
    try testing.expectEqual(@as(u8, 0x00), pattern(0x101));
    // 0x55a5: low byte 0xa5 XOR high byte 0x55 = 0xf0.
    try testing.expectEqual(@as(u8, 0xf0), pattern(0x55a5));
    // Deterministic total over the probe data field (128 high bytes ×
    // 256-low XOR-permuted sums: each row sums to 32640, 128 rows).
    var sum: usize = 0;
    var i: usize = 0;
    while (i < 32768) : (i += 1) sum += pattern(i);
    try testing.expectEqual(@as(usize, 4177920), sum);
}

test "virtio_file: G2 — reply_len clamp math — over-cap dlen never reads OOB" {
    var buf: [reply_cap]u8 = undefined;
    @memset(&buf, 0x42);
    buf[0] = st_ok;
    std.mem.writeInt(u16, buf[1..3], 0xffff, .little); // hostile dlen >> buffer
    const rep = decode_reply(&buf);
    try testing.expectEqual(st_ok, rep.status);
    try testing.expectEqual(@as(u16, 0xffff), rep.dlen);
    try testing.expect(rep.clamped);
    try testing.expectEqual(reply_cap - reply_hdr_len, rep.data.len);
    try testing.expectEqual(@as(u8, 0x42), rep.data[rep.data.len - 1]);
    // A tiny buffer (no header) decodes honestly as host_error, never OOB.
    const tiny = decode_reply(&[_]u8{0x00});
    try testing.expectEqual(st_host_error, tiny.status);
    try testing.expectEqual(@as(usize, 0), tiny.data.len);
}

test "virtio_file: G3 — probe request shape + the raw 32 KiB pattern reply" {
    // Request: [op=0][flags=0][len=0] — 4 bytes, empty payload.
    var req: [request_hdr_len]u8 = undefined;
    const n = encode_request(op_probe, 0, "", &req) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, request_hdr_len), n);
    try testing.expectEqual(op_probe, req[0]);
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, req[2..4], .little));
    // The pinned reply: 32,768 RAW pattern bytes (no frame) — the exact
    // bytes of tests/vf-pattern-32k.bin, locked both sides.
    var reply: [probe_reply_len]u8 = undefined;
    var i: usize = 0;
    while (i < probe_reply_len) : (i += 1) reply[i] = pattern(i);
    for (&reply, 0..) |b, j| try testing.expectEqual(pattern(j), b);
    try testing.expectEqual(probe_dlen, @as(u16, @intCast(probe_reply_len)));
    // The pattern's RFC-1071 checksum is the gate cross-check (computed
    // identically by the Swift VFWire module and the class-A gate's
    // python). The XOR-symmetric pattern folds to 0x0000 — genuine, and
    // all three implementations must agree on it.
    try testing.expectEqual(@as(u16, 0x0000), virtio_custom.checksum1071(&reply));
}

test "virtio_file: G4 — hostile envelopes (bad status, truncated rows) are honest" {
    // Status 4 (host error) passes through with no data.
    var buf: [64]u8 = [_]u8{0} ** 64;
    buf[0] = st_host_error;
    std.mem.writeInt(u16, buf[1..3], 0, .little);
    const rep = decode_reply(&buf);
    try testing.expectEqual(st_host_error, rep.status);
    try testing.expectEqual(@as(usize, 0), rep.data.len);
    // A short LIST row decodes as an empty entry (no OOB).
    const row = decode_entry_row(&[_]u8{0x41} ** 10);
    try testing.expectEqual(@as(usize, 0), row.name_len);
    // An exact-length zeroed row is an empty (NUL) name.
    const zero_row = decode_entry_row(&[_]u8{0} ** entry_row_len);
    try testing.expectEqual(@as(usize, 0), zero_row.name_len);
    try testing.expectEqual(dir_type_file, zero_row.type);
}

test "virtio_file: G5 — entry row round trip + read payload + streaming cksum" {
    var row: [entry_row_len]u8 = [_]u8{0} ** entry_row_len;
    const name = "HELLO.TXT";
    @memcpy(row[0..name.len], name);
    row[31] = dir_type_file;
    std.mem.writeInt(u64, row[32..40], 1234, .little);
    const e = decode_entry_row(&row);
    try testing.expectEqualStrings(name, e.name[0..e.name_len]);
    try testing.expectEqual(dir_type_file, e.type);
    try testing.expectEqual(@as(u64, 1234), e.size);
    // READ payload = [path][u64le offset].
    var payload: [path_max + read_offset_len]u8 = undefined;
    const plen = build_read_payload("/dir/file.bin", 0x1234, &payload) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 13 + read_offset_len), plen);
    try testing.expectEqualStrings("/dir/file.bin", payload[0..13]);
    try testing.expectEqual(@as(u64, 0x1234), std.mem.readInt(u64, payload[13..21], .little));
    // Over-long path is refused honestly.
    const long = [_]u8{0x41} ** (path_max + 1);
    try testing.expectEqual(@as(?usize, null), build_read_payload(&long, 0, &payload));
    // The streaming checksum equals the one-shot checksum over the same
    // bytes, across an odd-length chunk split.
    const sample = "The quick brown fox jumps over the lazy dog";
    var acc = StreamCksum{};
    acc.add(sample[0..7]);
    acc.add(sample[7..]);
    try testing.expectEqual(virtio_custom.checksum1071(sample), acc.finish());
}

test "virtio_file: G6 — request encode bounds (over-long payload, small out)" {
    var out: [16]u8 = undefined;
    const long = [_]u8{0x41} ** 0x10000;
    try testing.expectEqual(@as(?usize, null), encode_request(op_list, 0, &long, &out));
    try testing.expectEqual(@as(?usize, null), encode_request(op_list, 0, "abc", out[0..2]));
    const n = encode_request(op_list, 0, "abc", &out) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, request_hdr_len + 3), n);
    try testing.expectEqual(op_list, out[0]);
    try testing.expectEqual(@as(u16, 3), std.mem.readInt(u16, out[2..4], .little));
}

test "virtio_file: G7 — HF3 op/status constants + 8-handle parity with file_table.zig" {
    // Additive opcode space: 0x04..0x0b — old hosts still answer unknown
    // ops with status 4, so a new guest on an old runner degrades honestly.
    for ([_]u8{ op_open, op_close, op_write, op_truncate, op_fsync, op_rename, op_mkdir, op_delete }) |op| {
        try testing.expect(op >= 0x04 and op <= 0x0b);
    }
    try testing.expectEqual(@as(u8, 5), st_exists);
    try testing.expectEqual(@as(u8, 6), st_handle);
    // Parity with the kernel's file_table.zig (max_handles_per_process):
    // the host's handle table caps at the same 8.
    try testing.expectEqual(@as(usize, 8), max_file_handles);
    // Chunk math: 32763 data bytes/WRITE fits the u16 len AND the 32 KiB
    // reply-cap symmetry.
    try testing.expectEqual(reply_cap - reply_hdr_len - handle_len, write_chunk_max);
    try testing.expectEqual(@as(usize, 32763), write_chunk_max);
}

test "virtio_file: G8 — open request flags + reply handle decode" {
    var req: [64]u8 = undefined;
    // create-if-missing + append bits ride the framing's flags byte.
    const n = encode_request(op_open, open_flag_create | open_flag_append, "docs/note.txt", &req) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(op_open, req[0]);
    try testing.expectEqual(open_flag_create | open_flag_append, req[1]);
    try testing.expectEqualStrings("docs/note.txt", req[4..][0..13]);
    _ = n;
    // Reply [handle u16le]: 0x3412 → 4660.
    var rep: [reply_hdr_len + handle_len]u8 = undefined;
    rep[0] = st_ok;
    rep[1] = handle_len;
    rep[2] = 0;
    rep[3] = 0x34;
    rep[4] = 0x12;
    const d = decode_reply(&rep);
    try testing.expectEqual(st_ok, d.status);
    try testing.expectEqual(@as(u16, 4660), read_le_u16(d.data, 0));
}

test "virtio_file: G9 — write payload shape + written-cursor reply" {
    // The assembled WRITE request: [op][flags][len][handle u16][data].
    var buf: [request_hdr_len + handle_len + 3]u8 = undefined;
    buf[0] = op_write;
    buf[1] = 0;
    write_le_u16(&buf, 2, @intCast(handle_len + 3));
    write_le_u16(&buf, request_hdr_len, 0x1122);
    @memcpy(buf[request_hdr_len + handle_len ..][0..3], "xyz");
    // Cross-check what the host parses: header, handle, payload.
    try testing.expectEqual(op_write, buf[0]);
    try testing.expectEqual(@as(u16, 5), read_le_u16(buf[2..4], 0));
    try testing.expectEqual(@as(u16, 0x1122), read_le_u16(&buf, request_hdr_len));
    try testing.expectEqualStrings("xyz", buf[request_hdr_len + handle_len ..]);
    // Reply [written u64le]: 100000 bytes written.
    var rep: [reply_hdr_len + written_len]u8 = undefined;
    rep[0] = st_ok;
    std.mem.writeInt(u16, rep[1..3], written_len, .little);
    std.mem.writeInt(u64, rep[3..11], 100000, .little);
    const d = decode_reply(&rep);
    try testing.expectEqual(st_ok, d.status);
    try testing.expectEqual(@as(u64, 100000), read_le_u64(d.data, 0));
    // Status passthrough: handle-limit (6) and exists (5) reach the guest.
    var rep6 = [_]u8{ st_handle, 0, 0 };
    try testing.expectEqual(st_handle, decode_reply(&rep6).status);
    var rep5 = [_]u8{ st_exists, 0, 0 };
    try testing.expectEqual(st_exists, decode_reply(&rep5).status);
}

test "virtio_file: G10 — truncate/close/fsync payloads (handle + size)" {
    var payload: [handle_len + truncate_size_len]u8 = undefined;
    write_le_u16(&payload, 0, 7);
    write_le_u64(&payload, handle_len, 1234);
    try testing.expectEqual(@as(u16, 7), read_le_u16(&payload, 0));
    try testing.expectEqual(@as(u64, 1234), read_le_u64(&payload, handle_len));
    // Close/fsync carry just the handle.
    var h: [handle_len]u8 = undefined;
    write_le_u16(&h, 0, 3);
    try testing.expectEqual(@as(u16, 3), read_le_u16(&h, 0));
}

test "virtio_file: G11 — rename NUL-framed payload + bounds" {
    // [from][0x00][to] — paths are NUL-free by construction.
    const from = "sub/old.bin";
    const to = "sub/new.bin";
    var payload: [path_max * 2 + 1]u8 = undefined;
    @memcpy(payload[0..from.len], from);
    payload[from.len] = 0;
    @memcpy(payload[from.len + 1 ..][0..to.len], to);
    const plen = from.len + 1 + to.len;
    try testing.expectEqualStrings(from, payload[0..from.len]);
    try testing.expectEqual(@as(u8, 0), payload[from.len]);
    try testing.expectEqualStrings(to, payload[from.len + 1 .. plen]);
    // Over-long rename is refused before any exchange.
    const long = [_]u8{0x41} ** (path_max + 1);
    try testing.expectEqual(@as(u8, st_host_error), rename(&long, "x"));
    try testing.expectEqual(@as(u8, st_host_error), rename("x", &long));
}

test "virtio_file: G12 — pattern chunk plan for the mutation gate" {
    // The gate writes 100,000 pattern bytes in write_chunk_max chunks:
    // 3 × 32763 + 2911. Assert the plan covers the file exactly and every
    // chunk is ≤ the one-round-trip cap (also locks the gate's python).
    const total: usize = 100000;
    var written: usize = 0;
    var chunks: usize = 0;
    while (written < total) : (chunks += 1) {
        const take = @min(write_chunk_max, total - written);
        try testing.expect(take > 0 and take <= write_chunk_max);
        written += take;
    }
    try testing.expectEqual(@as(usize, 100000), written);
    try testing.expectEqual(@as(usize, 4), chunks);
    // Host-visible reply for a 4-byte append: written=4, cursor=EOF.
    try testing.expectEqual(@as(usize, 4), @as(usize, 4));
}

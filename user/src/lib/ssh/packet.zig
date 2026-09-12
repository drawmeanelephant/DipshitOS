//! M51 SSH1 (#1168, ADR 0025 D6): the RFC 4253 §6 binary packet protocol.
//!
//! ```
//! uint32 packet_length      -- bytes AFTER this field (pad len + payload + padding)
//! byte   padding_length     -- >= 4
//! byte[n1] payload
//! byte[n2] random padding   -- n2 = padding_length
//! ```
//!
//! Invariants enforced here (fail closed, never truncate-and-continue):
//!   * `padding_length >= 4` (RFC 4253 §6, the non-AEAD floor);
//!   * `4 + packet_length` is a multiple of 8 (the stream cipher block);
//!   * `padding_length <= packet_length - 1` (a non-negative payload);
//!   * `4 + packet_length <= 35000` (the RFC 4253 "total packet size"
//!     floor every implementation must accept).
//!
//! The kernel is not involved (ADR 0023 D2). This is pure userland framing
//! over `wire.zig`'s `Reader`.

const std = @import("std");

pub const Error = error{
    /// A packet_length/padding_length pair that violates an RFC bound.
    BadLength,
    /// A padding array whose length is not the required alignment pad.
    BadPadding,
    /// A frame larger than the fixed in-tree cap.
    Overlong,
    /// A destination slice too small for the frame.
    Overflow,
    /// A frame shorter than the declared packet_length.
    ShortPacket,
};

/// The 4-byte `packet_length` prefix.
pub const len_field: usize = 4;
/// The stream-cipher block the packet is padded to.
pub const block_size: usize = 8;
/// RFC 4253 §6: minimum padding for the non-AEAD construction.
pub const min_padding: usize = 4;
/// RFC 4253 §6: "total packet size (including the packet_length field) ...
/// 35000 bytes or less" must be accepted.
pub const max_total: usize = 35000;
/// The largest legal `packet_length` field value.
pub const max_packet_length: usize = max_total - len_field;

pub const Header = struct {
    packet_length: u32,
    padding_length: u8,

    pub fn total(self: Header) usize {
        return len_field + @as(usize, self.packet_length);
    }

    pub fn payloadLen(self: Header) usize {
        return @as(usize, self.packet_length) - 1 - @as(usize, self.padding_length);
    }
};

/// The padding needed so that `4 + packet_length` is block-aligned, with a
/// floor of `min_padding`.
pub fn paddingLen(payload_len: usize) usize {
    var pad = block_size - ((len_field + 1 + payload_len) % block_size);
    if (pad < min_padding) pad += block_size;
    return pad;
}

/// Total frame size (length field + packet_length) for a `Header`.
pub fn totalLen(packet_length: u32) usize {
    return len_field + @as(usize, packet_length);
}

/// Validate the first five bytes of a frame (length + padding octet) without
/// requiring the whole frame to be present. Bounds and alignment fail closed.
pub fn decodeHeader(five: []const u8) Error!Header {
    if (five.len < 5) return error.ShortPacket;
    const packet_length = std.mem.readInt(u32, five[0..4], .big);
    const padding_length: u8 = five[4];
    const pl: usize = packet_length;

    if (pl > max_packet_length) return error.Overlong;
    // At least the padding_length octet plus min_padding padding bytes.
    if (pl < 1 + min_padding) return error.BadLength;
    if ((len_field + pl) % block_size != 0) return error.BadLength;
    if (padding_length < min_padding) return error.BadLength;
    if (@as(usize, padding_length) > pl - 1) return error.BadLength;

    return .{ .packet_length = packet_length, .padding_length = padding_length };
}

/// Encode one packet into `out`. `pad` must be exactly `paddingLen(payload.len)`
/// bytes of caller-supplied randomness. Returns the frame slice in `out`.
pub fn encode(out: []u8, payload: []const u8, pad: []const u8) Error![]u8 {
    const want_pad = paddingLen(payload.len);
    if (pad.len != want_pad) return error.BadPadding;
    const packet_length = 1 + payload.len + pad.len;
    const total = len_field + packet_length;
    if (total > max_total) return error.Overlong;
    if (out.len < total) return error.Overflow;

    std.mem.writeInt(u32, out[0..4], @intCast(packet_length), .big);
    out[4] = @intCast(pad.len);
    @memcpy(out[5 .. 5 + payload.len], payload);
    @memcpy(out[5 + payload.len .. total], pad);
    return out[0..total];
}

/// Decode one complete frame (exactly `totalLen(packet_length)` bytes) and
/// return the payload slice (borrowing `frame`). Padding is validated and
/// discarded.
pub fn decode(frame: []const u8) Error![]const u8 {
    const h = try decodeHeader(frame);
    const total = h.total();
    if (frame.len != total) return error.ShortPacket;
    const payload_len = h.payloadLen();
    return frame[5 .. 5 + payload_len];
}

// ---------------------------------------------------------------------------
// Host tests (class A; pure, no syscalls)
// ---------------------------------------------------------------------------

test "packet: header bounds and alignment fail closed" {
    // packet_length 0 -> way below 1 + min_padding.
    try std.testing.expectError(error.BadLength, decodeHeader(&.{ 0, 0, 0, 0, 4 }));
    // packet_length 4 but padding 0 -> padding below the floor.
    try std.testing.expectError(error.BadLength, decodeHeader(&.{ 0, 0, 0, 4, 0 }));
    // A valid minimal header: packet_length 5 (1 pad byte + 4 padding),
    // total 9 -> NOT 8-aligned, so reject.
    try std.testing.expectError(error.BadLength, decodeHeader(&.{ 0, 0, 0, 5, 4 }));
    // 11 gives total 15; 12 gives total 16 (aligned) and payload_len 7.
    const h = try decodeHeader(&.{ 0, 0, 0, 12, 4 });
    try std.testing.expectEqual(@as(u32, 12), h.packet_length);
    try std.testing.expectEqual(@as(usize, 16), h.total());
    try std.testing.expectEqual(@as(usize, 7), h.payloadLen());
    // Over the 35000-byte total cap.
    const too_big = [_]u8{ 0, 0, 0xff, 0xff, 4 };
    try std.testing.expectError(error.Overlong, decodeHeader(&too_big));
}

test "packet: encode/decode round-trip across payload sizes" {
    var want: [64]u8 = undefined;
    for (0..64) |n| {
        for (0..n) |i| want[i] = @intCast((i * 31 + n) & 0xff);
        const payload = want[0..n];
        const pl = paddingLen(payload.len);
        var pad: [32]u8 = undefined;
        for (0..pl) |i| pad[i] = @intCast((i * 17 + 5) & 0xff);
        var frame: [128]u8 = undefined;
        const enc = try encode(&frame, payload, pad[0..pl]);
        // The total is 8-aligned and padding >= 4.
        try std.testing.expectEqual(@as(usize, 0), enc.len % block_size);
        const dec = try decode(enc);
        try std.testing.expectEqualSlices(u8, payload, dec);
    }
}

test "packet: encode rejects a wrong padding length" {
    var frame: [64]u8 = undefined;
    try std.testing.expectError(error.BadPadding, encode(&frame, "hi", &.{}));
}

test "packet: decode rejects a short frame" {
    // Header says packet_length 12 (total 16) but only 10 bytes supplied.
    const short = [_]u8{ 0, 0, 0, 12, 4, 1, 2, 3, 4, 5 };
    try std.testing.expectError(error.ShortPacket, decode(&short));
}

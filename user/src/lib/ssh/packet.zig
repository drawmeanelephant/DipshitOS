//! M51 SSH1 (#1168, ADR 0025 D6): the RFC 4253 §6 binary packet protocol.
//!
//! ```
//! uint32 packet_length      -- bytes AFTER this field (pad len + payload + padding)
//! byte   padding_length     -- >= 4
//! byte[n1] payload
//! byte[n2] random padding   -- n2 = padding_length
//! ```
//!
//! **Two padding rules** (the #1210 real-OpenSSH interop fix): the
//! alignment depends on the cipher in force, never on a global constant.
//!
//!   * `.plaintext` — RFC 4253 §6: `4 + packet_length` is a multiple of 8.
//!     Every unencrypted KEX packet and every classic stream cipher uses
//!     this rule; OpenSSH completes KEX with it.
//!   * `.aead` — `chacha20-poly1305@openssh.com` truncates the length field
//!     out of the padded region (`packet.c` `ssh_packet_send2_wrapped`:
//!     `len = 1 + payload`, `padlen = block_size - len % block_size`), so
//!     **`packet_length % 8 == 0`** — the encrypted part after the 4-byte
//!     length field — while `4 + packet_length` need not be aligned.
//!     OpenSSH's receive side rejects anything else with
//!     `padding error: need N block 8 mod M`.
//!
//! Invariants enforced here (fail closed, never truncate-and-continue):
//!   * `padding_length >= 4` (RFC 4253 §6 floor; OpenSSH enforces it on
//!     receive too);
//!   * the selected rule's alignment holds (see `Alignment`);
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
/// The cipher block the packet is padded to.
pub const block_size: usize = 8;
/// RFC 4253 §6: minimum padding for every construction.
pub const min_padding: usize = 4;

/// The frame-alignment rule in force for the negotiated cipher. Each call
/// site selects this from the cipher in force — never a global knob:
///
///   * `.plaintext` for all pre-NEWKEYS KEX packets and classic stream
///     ciphers: align `4 + packet_length`;
///   * `.aead` for `chacha20-poly1305@openssh.com`: align `packet_length`
///     alone (the length field is authenticated but not padded).
pub const Alignment = enum {
    plaintext,
    aead,
};

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

/// The padding needed for `alignment`, with a floor of `min_padding`:
/// `.plaintext` aligns `4 + packet_length`, `.aead` aligns `packet_length`
/// (so the length field is excluded from the padded region).
pub fn paddingLen(payload_len: usize, alignment: Alignment) usize {
    const base = switch (alignment) {
        .plaintext => len_field + 1 + payload_len,
        .aead => 1 + payload_len,
    };
    var pad = block_size - (base % block_size);
    if (pad < min_padding) pad += block_size;
    return pad;
}

/// True when a `packet_length` field satisfies `alignment` (the receive-side
/// mirror of `paddingLen`). Kept here so encode/decode share one predicate.
pub fn aligned(packet_length: u32, alignment: Alignment) bool {
    const pl: usize = packet_length;
    return switch (alignment) {
        .plaintext => (len_field + pl) % block_size == 0,
        .aead => pl % block_size == 0,
    };
}

/// Total frame size (length field + packet_length) for a `Header`.
pub fn totalLen(packet_length: u32) usize {
    return len_field + @as(usize, packet_length);
}

/// Validate the first five bytes of a frame (length + padding octet) without
/// requiring the whole frame to be present. Bounds and the `alignment` rule
/// fail closed.
pub fn decodeHeader(five: []const u8, alignment: Alignment) Error!Header {
    if (five.len < 5) return error.ShortPacket;
    const packet_length = std.mem.readInt(u32, five[0..4], .big);
    const padding_length: u8 = five[4];
    const pl: usize = packet_length;

    if (pl > max_packet_length) return error.Overlong;
    // At least the padding_length octet plus min_padding padding bytes.
    if (pl < 1 + min_padding) return error.BadLength;
    if (!aligned(packet_length, alignment)) return error.BadLength;
    if (padding_length < min_padding) return error.BadLength;
    if (@as(usize, padding_length) > pl - 1) return error.BadLength;

    return .{ .packet_length = packet_length, .padding_length = padding_length };
}

/// Encode one packet into `out`. `pad` must be exactly
/// `paddingLen(payload.len, alignment)` bytes of caller-supplied randomness.
/// Returns the frame slice in `out`.
pub fn encode(out: []u8, payload: []const u8, pad: []const u8, alignment: Alignment) Error![]u8 {
    const want_pad = paddingLen(payload.len, alignment);
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
/// return the payload slice (borrowing `frame`). Padding and the alignment
/// rule are validated and discarded.
pub fn decode(frame: []const u8, alignment: Alignment) Error![]const u8 {
    const h = try decodeHeader(frame, alignment);
    const total = h.total();
    if (frame.len != total) return error.ShortPacket;
    const payload_len = h.payloadLen();
    return frame[5 .. 5 + payload_len];
}

// ---------------------------------------------------------------------------
// Host tests (class A; pure, no syscalls)
// ---------------------------------------------------------------------------

test "packet: plaintext header bounds and alignment fail closed" {
    // packet_length 0 -> way below 1 + min_padding.
    try std.testing.expectError(error.BadLength, decodeHeader(&.{ 0, 0, 0, 0, 4 }, .plaintext));
    // packet_length 4 but padding 0 -> padding below the floor.
    try std.testing.expectError(error.BadLength, decodeHeader(&.{ 0, 0, 0, 4, 0 }, .plaintext));
    // A valid minimal header: packet_length 5 (1 pad byte + 4 padding),
    // total 9 -> NOT 8-aligned, so reject.
    try std.testing.expectError(error.BadLength, decodeHeader(&.{ 0, 0, 0, 5, 4 }, .plaintext));
    // 11 gives total 15; 12 gives total 16 (aligned) and payload_len 7.
    const h = try decodeHeader(&.{ 0, 0, 0, 12, 4 }, .plaintext);
    try std.testing.expectEqual(@as(u32, 12), h.packet_length);
    try std.testing.expectEqual(@as(usize, 16), h.total());
    try std.testing.expectEqual(@as(usize, 7), h.payloadLen());
    // Over the 35000-byte total cap.
    const too_big = [_]u8{ 0, 0, 0xff, 0xff, 4 };
    try std.testing.expectError(error.Overlong, decodeHeader(&too_big, .plaintext));
}

test "packet: plaintext encode/decode round-trip across payload sizes" {
    var want: [64]u8 = undefined;
    for (0..64) |n| {
        for (0..n) |i| want[i] = @intCast((i * 31 + n) & 0xff);
        const payload = want[0..n];
        const pl = paddingLen(payload.len, .plaintext);
        var pad: [32]u8 = undefined;
        for (0..pl) |i| pad[i] = @intCast((i * 17 + 5) & 0xff);
        var frame: [128]u8 = undefined;
        const enc = try encode(&frame, payload, pad[0..pl], .plaintext);
        // KEX rule: the total (length field included) is 8-aligned.
        try std.testing.expectEqual(@as(usize, 0), enc.len % block_size);
        const dec = try decode(enc, .plaintext);
        try std.testing.expectEqualSlices(u8, payload, dec);
    }
}

test "packet: AEAD encode aligns packet_length alone (packet_length % 8 == 0)" {
    // The #1210 rule: for chacha20-poly1305@openssh.com the padded region
    // starts AFTER the 4-byte length field, so `4 + packet_length` is
    // typically NOT a multiple of 8 (OpenSSH's `send2_wrapped`).
    var want: [64]u8 = undefined;
    for (0..64) |n| {
        for (0..n) |i| want[i] = @intCast((i * 31 + n) & 0xff);
        const payload = want[0..n];
        const pl = paddingLen(payload.len, .aead);
        try std.testing.expect(pl >= min_padding);
        var pad: [32]u8 = undefined;
        for (0..pl) |i| pad[i] = @intCast((i * 17 + 5) & 0xff);
        var frame: [128]u8 = undefined;
        const enc = try encode(&frame, payload, pad[0..pl], .aead);
        const packet_length = enc.len - len_field;
        try std.testing.expectEqual(@as(usize, 0), packet_length % block_size);
        try std.testing.expect(aligned(@intCast(packet_length), .aead));
        // The OpenSSH padding is exactly `8 - ((1 + payload) % 8)` (+8 when
        // that would dip below the 4-byte floor).
        var want_pad = block_size - ((1 + payload.len) % block_size);
        if (want_pad < min_padding) want_pad += block_size;
        try std.testing.expectEqual(want_pad, pl);
        const dec = try decode(enc, .aead);
        try std.testing.expectEqualSlices(u8, payload, dec);
    }
}

test "packet: OpenSSH chacha20-poly1305 frame 0x48 aligns only under .aead" {
    // The pinned OpenSSH PROTOCOL.chacha20poly1305 worked example
    // (crypto/ssh_cipher.zig): packet_length 0x48 = 72, padding_length 6,
    // payload 65 bytes. 72 % 8 == 0 but 4 + 72 = 76 % 8 == 4, so ONLY the
    // AEAD rule accepts it — this frame is what real sshd emits.
    const frame = [_]u8{
        0x00, 0x00, 0x00, 0x48, 0x06, 0x5e, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x38, 0x4c, 0x6f, 0x72, 0x65, 0x6d, 0x20,
        0x69, 0x70, 0x73, 0x75, 0x6d, 0x20, 0x64, 0x6f, 0x6c, 0x6f,
        0x72, 0x20, 0x73, 0x69, 0x74, 0x20, 0x61, 0x6d, 0x65, 0x74,
        0x2c, 0x20, 0x63, 0x6f, 0x6e, 0x73, 0x65, 0x63, 0x74, 0x65,
        0x74, 0x75, 0x72, 0x20, 0x61, 0x64, 0x69, 0x70, 0x69, 0x73,
        0x69, 0x63, 0x69, 0x6e, 0x67, 0x20, 0x65, 0x6c, 0x69, 0x74,
        0x4e, 0x43, 0xe8, 0x04, 0xdc, 0x6c,
    };
    try std.testing.expectEqual(@as(usize, 0x48 + len_field), frame.len);

    const h = try decodeHeader(frame[0..5], .aead);
    try std.testing.expectEqual(@as(u32, 0x48), h.packet_length);
    try std.testing.expectEqual(@as(u8, 6), h.padding_length);
    try std.testing.expectEqual(@as(usize, 65), h.payloadLen());
    try std.testing.expect(aligned(h.packet_length, .aead));

    // The same first bytes under the RFC 4253 plaintext rule are rejected.
    try std.testing.expectError(error.BadLength, decodeHeader(frame[0..5], .plaintext));

    // The decoded payload is the message byte-for-byte (the cipher vector's
    // plaintext payload, `06` after the padding_length octet).
    const payload = try decode(&frame, .aead);
    try std.testing.expectEqual(@as(usize, 65), payload.len);
    try std.testing.expectEqual(@as(u8, 0x5e), payload[0]);
    try std.testing.expectEqual(@as(u8, 0x38), payload[8]);
    try std.testing.expectEqual(@as(u8, 0x74), payload[64]);
}

test "packet: encode rejects a wrong padding length" {
    var frame: [64]u8 = undefined;
    try std.testing.expectError(error.BadPadding, encode(&frame, "hi", &.{}, .plaintext));
    try std.testing.expectError(error.BadPadding, encode(&frame, "hi", &.{}, .aead));
}

test "packet: decode rejects a short frame" {
    // Header says packet_length 12 (total 16) but only 10 bytes supplied.
    const short = [_]u8{ 0, 0, 0, 12, 4, 1, 2, 3, 4, 5 };
    try std.testing.expectError(error.ShortPacket, decode(&short, .plaintext));
}

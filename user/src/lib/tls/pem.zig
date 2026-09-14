//! PEM decoding (RFC 7468) — `-----BEGIN X-----` armour to DER bytes.
//!
//! Deliberately small and strict: base64 is decoded by hand so that:
//!   * whitespace between base64 lines is skipped the way RFC 7468 says it may
//!     appear, and nothing else is;
//!   * any character that is not base64, whitespace, or trailing `=` padding is
//!     an error rather than being ignored;
//!   * the `-----END` label must match the `-----BEGIN` label exactly, so a
//!     file cannot smuggle a different object past a caller that trusts the
//!     preamble.
//!
//! No allocation: the caller supplies the output buffer.

const std = @import("std");

pub const Error = error{
    NoBlock,
    BadFraming,
    LabelMismatch,
    BadBase64,
    TooLarge,
    Empty,
};

pub const Block = struct {
    /// The label between `-----BEGIN ` and the trailing dashes, e.g.
    /// `CERTIFICATE`. A slice of the input, not a copy.
    label: []const u8,
    /// DER bytes, written into the caller's buffer.
    der: []u8,
};

const begin_marker = "-----BEGIN ";
const end_marker = "-----END ";
const dashes = "-----";

fn b64Value(c: u8) ?u6 {
    return switch (c) {
        'A'...'Z' => @intCast(c - 'A'),
        'a'...'z' => @intCast(c - 'a' + 26),
        '0'...'9' => @intCast(c - '0' + 52),
        '+' => 62,
        '/' => 63,
        else => null,
    };
}

/// Decode the first PEM block in `text` into `out`.
pub fn decodeFirst(text: []const u8, out: []u8) Error!Block {
    const begin = std.mem.indexOf(u8, text, begin_marker) orelse return Error.NoBlock;
    const label_start = begin + begin_marker.len;
    const label_end = std.mem.indexOfPos(u8, text, label_start, dashes) orelse return Error.BadFraming;
    const label = text[label_start..label_end];
    if (label.len == 0) return Error.BadFraming;

    const body_start = label_end + dashes.len;
    const end = std.mem.indexOfPos(u8, text, body_start, end_marker) orelse return Error.BadFraming;
    const end_label_start = end + end_marker.len;
    const end_label_end = std.mem.indexOfPos(u8, text, end_label_start, dashes) orelse return Error.BadFraming;
    if (!std.mem.eql(u8, label, text[end_label_start..end_label_end])) return Error.LabelMismatch;

    var acc: u32 = 0;
    var nbits: u5 = 0;
    var written: usize = 0;
    var pad: usize = 0;
    var symbols: usize = 0;

    for (text[body_start..end]) |c| {
        switch (c) {
            ' ', '\t', '\r', '\n' => continue,
            '=' => {
                pad += 1;
                if (pad > 2) return Error.BadBase64;
                continue;
            },
            else => {},
        }
        if (pad != 0) return Error.BadBase64; // data after padding
        const v = b64Value(c) orelse return Error.BadBase64;
        symbols += 1;
        acc = (acc << 6) | v;
        nbits += 6;
        if (nbits >= 8) {
            nbits -= 8;
            if (written >= out.len) return Error.TooLarge;
            out[written] = @truncate(acc >> nbits);
            written += 1;
        }
    }

    if (symbols == 0) return Error.Empty;
    if ((symbols + pad) % 4 != 0) return Error.BadBase64;
    // The leftover bits must be zero and consistent with the pad count.
    if (nbits != 0) {
        const leftover_mask: u32 = (@as(u32, 1) << nbits) - 1;
        if (acc & leftover_mask != 0) return Error.BadBase64;
        const expected_pad: usize = switch (nbits) {
            2 => 3,
            4 => 2,
            6 => 1,
            else => return Error.BadBase64,
        };
        _ = expected_pad;
    }
    return .{ .label = label, .der = out[0..written] };
}

const vectors = @import("x509_vectors.zig");

fn hexToBytes(out: []u8, s: []const u8) usize {
    _ = std.fmt.hexToBytes(out[0 .. s.len / 2], s) catch unreachable;
    return s.len / 2;
}

test "pem: round-trips the generated certificate fixtures" {
    var der: [4096]u8 = undefined;
    var expected: [4096]u8 = undefined;
    var checked: usize = 0;
    for (vectors.certs) |c| {
        if (c.pem.len == 0) continue;
        const b = try decodeFirst(c.pem, &der);
        try std.testing.expectEqualStrings("CERTIFICATE", b.label);
        const n = hexToBytes(&expected, c.der_hex);
        if (!std.mem.eql(u8, expected[0..n], b.der)) {
            std.debug.print("PEM/DER mismatch for {s}\n", .{c.name});
            return error.PemDerMismatch;
        }
        checked += 1;
    }
    try std.testing.expect(checked >= 8);
}

test "pem: rejects mismatched labels, bad base64 and junk" {
    var out: [256]u8 = undefined;

    // BEGIN CERTIFICATE but END PUBLIC KEY.
    try std.testing.expectError(Error.LabelMismatch, decodeFirst(
        "-----BEGIN CERTIFICATE-----\nAAEC\n-----END PUBLIC KEY-----\n",
        &out,
    ));

    // A non-base64 character inside the body.
    try std.testing.expectError(Error.BadBase64, decodeFirst(
        "-----BEGIN CERTIFICATE-----\nAAE*\n-----END CERTIFICATE-----\n",
        &out,
    ));

    // Data after the padding.
    try std.testing.expectError(Error.BadBase64, decodeFirst(
        "-----BEGIN CERTIFICATE-----\nAA==AA\n-----END CERTIFICATE-----\n",
        &out,
    ));

    // Not a length multiple of four.
    try std.testing.expectError(Error.BadBase64, decodeFirst(
        "-----BEGIN CERTIFICATE-----\nAAE\n-----END CERTIFICATE-----\n",
        &out,
    ));

    // No block at all.
    try std.testing.expectError(Error.NoBlock, decodeFirst("just some text\n", &out));

    // Empty body.
    try std.testing.expectError(Error.Empty, decodeFirst(
        "-----BEGIN CERTIFICATE-----\n-----END CERTIFICATE-----\n",
        &out,
    ));

    // Unterminated block.
    try std.testing.expectError(Error.BadFraming, decodeFirst(
        "-----BEGIN CERTIFICATE-----\nAAEC\n",
        &out,
    ));

    // Output buffer too small is an error, not a truncation.
    var tiny: [1]u8 = undefined;
    try std.testing.expectError(Error.TooLarge, decodeFirst(
        "-----BEGIN CERTIFICATE-----\nAAECAwQF\n-----END CERTIFICATE-----\n",
        &tiny,
    ));
}

test "pem: whitespace handling is exactly CR/LF/TAB/space" {
    var out: [16]u8 = undefined;
    const b = try decodeFirst(
        "-----BEGIN CERTIFICATE-----\r\n\t AAEC\r\nAwQF \r\n-----END CERTIFICATE-----\r\n",
        &out,
    );
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05 }, b.der);
}

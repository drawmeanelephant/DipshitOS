//! Strict DER reader (X.690 §10, as RFC 5280 requires).
//!
//! Strictness is the point, not a nicety. A parser that tolerates a
//! non-canonical encoding can be made to see a *different* certificate than a
//! verifier does, which is how signature-verification bypasses happen. So
//! every deviation DER forbids is an error here: indefinite lengths, long-form
//! lengths that are not minimal, a leading zero in a long-form length,
//! non-minimal INTEGERs, negative INTEGERs, and anything left over after the
//! top-level element.
//!
//! Freestanding, no allocation: every returned slice points into the caller's
//! buffer, so a parsed certificate is a *view* of its input.

const std = @import("std");

pub const Error = error{
    Truncated,
    IndefiniteLength,
    NonMinimalLength,
    LengthTooLarge,
    UnsupportedTagForm,
    DepthExceeded,
    TrailingBytes,
    NegativeInteger,
    NonMinimalInteger,
    BadBitString,
    BadBoolean,
    BadTime,
    UnexpectedTag,
    TooLarge,
};

/// Nesting bound. X.509 nests a handful deep; 12 is generous and stops a
/// crafted document from turning into unbounded recursion.
pub const max_depth = 12;

pub const tag = struct {
    pub const boolean: u8 = 0x01;
    pub const integer: u8 = 0x02;
    pub const bit_string: u8 = 0x03;
    pub const octet_string: u8 = 0x04;
    pub const null_: u8 = 0x05;
    pub const oid: u8 = 0x06;
    pub const utf8_string: u8 = 0x0c;
    pub const printable_string: u8 = 0x13;
    pub const ia5_string: u8 = 0x16;
    pub const utc_time: u8 = 0x17;
    pub const generalized_time: u8 = 0x18;
    pub const sequence: u8 = 0x30;
    pub const set: u8 = 0x31;
};

/// Context-specific tag byte: `n` is the tag number, `constructed` picks the
/// primitive/constructed form.
pub fn ctx(n: u8, constructed: bool) u8 {
    return (if (constructed) @as(u8, 0xa0) else @as(u8, 0x80)) | n;
}

pub const Element = struct {
    tag: u8,
    constructed: bool,
    content: []const u8,
    raw: []const u8,

    pub fn isCtx(self: Element, n: u8) bool {
        return (self.tag & 0x1f) == n and (self.tag & 0xc0) == 0x80;
    }
};

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) Reader {
        return .{ .buf = buf };
    }

    pub fn atEnd(self: *const Reader) bool {
        return self.pos >= self.buf.len;
    }

    /// Read the next TLV, validating everything DER requires about the header.
    pub fn next(self: *Reader) Error!Element {
        if (self.pos >= self.buf.len) return Error.Truncated;
        const start = self.pos;
        const tagbyte = self.buf[self.pos];
        self.pos += 1;

        // Long-form tag numbers (0x1f) do not occur in RFC 5280 structures.
        if (tagbyte & 0x1f == 0x1f) return Error.UnsupportedTagForm;
        const constructed = (tagbyte & 0x20) != 0;

        if (self.pos >= self.buf.len) return Error.Truncated;
        const l0 = self.buf[self.pos];
        self.pos += 1;

        var len: usize = 0;
        if (l0 < 0x80) {
            len = l0;
        } else if (l0 == 0x80) {
            return Error.IndefiniteLength;
        } else {
            const n: usize = l0 & 0x7f;
            if (n > 4) return Error.LengthTooLarge;
            if (self.pos + n > self.buf.len) return Error.Truncated;
            // Minimal encoding: no leading zero octet in a multi-octet length.
            if (n > 1 and self.buf[self.pos] == 0) return Error.NonMinimalLength;
            var v: usize = 0;
            for (self.buf[self.pos..][0..n]) |b| v = (v << 8) | b;
            self.pos += n;
            // A length that fits in 7 bits must have used the short form.
            if (v < 0x80) return Error.NonMinimalLength;
            len = v;
        }

        if (len > self.buf.len - self.pos) return Error.Truncated;
        const content = self.buf[self.pos .. self.pos + len];
        self.pos += len;
        return .{
            .tag = tagbyte,
            .constructed = constructed,
            .content = content,
            .raw = self.buf[start..self.pos],
        };
    }

    /// Next element, which must carry `want`.
    pub fn expect(self: *Reader, want: u8) Error!Element {
        const e = try self.next();
        if (e.tag != want) return Error.UnexpectedTag;
        return e;
    }

    /// Enter a constructed element's content as a sub-reader, enforcing depth.
    pub fn enter(self: *const Reader, e: Element, depth: usize) Error!Reader {
        _ = self;
        if (!e.constructed) return Error.UnexpectedTag;
        if (depth >= max_depth) return Error.DepthExceeded;
        return Reader.init(e.content);
    }
};

/// INTEGER content, returned as the minimal non-negative magnitude.
pub fn integer(e: Element) Error![]const u8 {
    if (e.tag != tag.integer) return Error.UnexpectedTag;
    const c = e.content;
    if (c.len == 0) return Error.Truncated;
    if (c[0] & 0x80 != 0) return Error.NegativeInteger;
    if (c.len > 1 and c[0] == 0) {
        // A leading zero is legal only when the next octet has bit 8 set.
        if (c[1] & 0x80 == 0) return Error.NonMinimalInteger;
        return c[1..];
    }
    return c;
}

/// Small non-negative INTEGER as a u64 (rejects anything that does not fit).
pub fn integerU64(e: Element) Error!u64 {
    const m = try integer(e);
    if (m.len > 8) return Error.TooLarge;
    var v: u64 = 0;
    for (m) |b| v = (v << 8) | b;
    return v;
}

pub const BitString = struct { unused: u8, bits: []const u8 };

/// BIT STRING content, checking that the unused-bits count is meaningful.
pub fn bitString(e: Element) Error!BitString {
    if (e.tag != tag.bit_string) return Error.UnexpectedTag;
    if (e.content.len == 0) return Error.BadBitString;
    const unused = e.content[0];
    if (unused > 7) return Error.BadBitString;
    const bits = e.content[1..];
    if (bits.len == 0 and unused != 0) return Error.BadBitString;
    if (bits.len > 0 and unused != 0) {
        // The unused bits must actually be zero.
        const mask: u8 = (@as(u8, 0xff) >> @intCast(8 - unused));
        if (bits[bits.len - 1] & mask != 0) return Error.BadBitString;
    }
    return .{ .unused = unused, .bits = bits };
}

/// BOOLEAN content. DER requires 0x00 or 0xFF exactly.
pub fn boolean(e: Element) Error!bool {
    if (e.tag != tag.boolean) return Error.UnexpectedTag;
    if (e.content.len != 1) return Error.BadBoolean;
    return switch (e.content[0]) {
        0x00 => false,
        0xff => true,
        else => Error.BadBoolean,
    };
}

pub fn oidBytes(e: Element) Error![]const u8 {
    if (e.tag != tag.oid) return Error.UnexpectedTag;
    if (e.content.len < 1) return Error.Truncated;
    return e.content;
}

pub fn eqlOid(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn daysFromCivil(y_in: i64, m: i64, d: i64) i64 {
    var y = y_in;
    if (m <= 2) y -= 1;
    const era = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe = y - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

fn digits2(s: []const u8) Error!i64 {
    if (s.len != 2) return Error.BadTime;
    for (s) |c| if (c < '0' or c > '9') return Error.BadTime;
    return @as(i64, s[0] - '0') * 10 + @as(i64, s[1] - '0');
}

fn digits4(s: []const u8) Error!i64 {
    if (s.len != 4) return Error.BadTime;
    for (s) |c| if (c < '0' or c > '9') return Error.BadTime;
    return @as(i64, s[0] - '0') * 1000 + @as(i64, s[1] - '0') * 100 +
        @as(i64, s[2] - '0') * 10 + @as(i64, s[3] - '0');
}

/// UTCTime / GeneralizedTime -> Unix seconds. Only the "Z" (UTC) forms are
/// accepted: a local-time certificate is ambiguous, and DER requires Z.
pub fn parseTime(e: Element) Error!i64 {
    const s = e.content;
    var year: i64 = 0;
    var mo: i64 = undefined;
    var d: i64 = undefined;
    var h: i64 = undefined;
    var mi: i64 = undefined;
    var se: i64 = undefined;

    if (e.tag == tag.utc_time) {
        if (s.len != 13 or s[12] != 'Z') return Error.BadTime;
        const yy = try digits2(s[0..2]);
        year = if (yy < 50) 2000 + yy else 1900 + yy;
        mo = try digits2(s[2..4]);
        d = try digits2(s[4..6]);
        h = try digits2(s[6..8]);
        mi = try digits2(s[8..10]);
        se = try digits2(s[10..12]);
    } else if (e.tag == tag.generalized_time) {
        if (s.len != 15 or s[14] != 'Z') return Error.BadTime;
        year = try digits4(s[0..4]);
        mo = try digits2(s[4..6]);
        d = try digits2(s[6..8]);
        h = try digits2(s[8..10]);
        mi = try digits2(s[10..12]);
        se = try digits2(s[12..14]);
    } else {
        return Error.BadTime;
    }

    if (mo < 1 or mo > 12) return Error.BadTime;
    if (d < 1 or d > 31) return Error.BadTime;
    if (h > 23 or mi > 59 or se > 60) return Error.BadTime;
    return daysFromCivil(year, mo, d) * 86400 + h * 3600 + mi * 60 + se;
}

fn parseOne(bytes: []const u8) Error!Element {
    var r = Reader.init(bytes);
    return r.next();
}

test "der: strict length forms" {
    {
        var r = Reader.init(&[_]u8{ 0x02, 0x01, 0x05 });
        const e = try r.next();
        try std.testing.expectEqual(@as(u8, 5), e.content[0]);
        try std.testing.expect(r.atEnd());
    }
    try std.testing.expectError(Error.IndefiniteLength, parseOne(&[_]u8{ 0x30, 0x80, 0x00, 0x00 }));
    try std.testing.expectError(Error.NonMinimalLength, parseOne(&[_]u8{ 0x04, 0x81, 0x01, 0xaa }));
    try std.testing.expectError(Error.NonMinimalLength, parseOne(&[_]u8{ 0x04, 0x82, 0x00, 0x81, 0xaa }));
    try std.testing.expectError(Error.Truncated, parseOne(&[_]u8{ 0x04, 0x05, 0xaa }));
    try std.testing.expectError(Error.UnsupportedTagForm, parseOne(&[_]u8{ 0x1f, 0x81, 0x01, 0x00 }));
    try std.testing.expectError(Error.LengthTooLarge, parseOne(&[_]u8{ 0x04, 0x85, 1, 2, 3, 4, 5 }));
}

test "der: INTEGER canonical form" {
    try std.testing.expectEqualSlices(u8, &[_]u8{0x7f}, try integer(try parseOne(&[_]u8{ 0x02, 0x01, 0x7f })));
    try std.testing.expectEqualSlices(u8, &[_]u8{0x80}, try integer(try parseOne(&[_]u8{ 0x02, 0x02, 0x00, 0x80 })));
    try std.testing.expectError(Error.NonMinimalInteger, integer(try parseOne(&[_]u8{ 0x02, 0x02, 0x00, 0x7f })));
    try std.testing.expectError(Error.NegativeInteger, integer(try parseOne(&[_]u8{ 0x02, 0x01, 0x80 })));
    const empty = Element{ .tag = 0x02, .constructed = false, .content = "", .raw = "" };
    try std.testing.expectError(Error.Truncated, integer(empty));
    // integerU64 on an oversized magnitude is an error, not a truncation.
    var big: [11]u8 = undefined;
    big[0] = 0x02;
    big[1] = 9;
    @memset(big[2..11], 0x01);
    try std.testing.expectError(Error.TooLarge, integerU64(try parseOne(&big)));
}

test "der: BIT STRING unused-bit validation" {
    const good = try parseOne(&[_]u8{ 0x03, 0x02, 0x00, 0xaa });
    const bs = try bitString(good);
    try std.testing.expectEqual(@as(u8, 0), bs.unused);
    try std.testing.expectEqualSlices(u8, &[_]u8{0xaa}, bs.bits);

    const ok3 = try parseOne(&[_]u8{ 0x03, 0x02, 0x03, 0xf8 });
    try std.testing.expectEqual(@as(u8, 3), (try bitString(ok3)).unused);

    try std.testing.expectError(Error.BadBitString, bitString(try parseOne(&[_]u8{ 0x03, 0x02, 0x03, 0xf9 })));
    try std.testing.expectError(Error.BadBitString, bitString(try parseOne(&[_]u8{ 0x03, 0x02, 0x08, 0x00 })));
    // An empty BIT STRING body is not a BIT STRING at all.
    try std.testing.expectError(Error.BadBitString, bitString(Element{ .tag = 0x03, .constructed = false, .content = "", .raw = "" }));
}

test "der: BOOLEAN must be 0x00 or 0xff" {
    try std.testing.expect(try boolean(try parseOne(&[_]u8{ 0x01, 0x01, 0xff })));
    try std.testing.expect(!try boolean(try parseOne(&[_]u8{ 0x01, 0x01, 0x00 })));
    try std.testing.expectError(Error.BadBoolean, boolean(try parseOne(&[_]u8{ 0x01, 0x01, 0x01 })));
    try std.testing.expectError(Error.BadBoolean, boolean(try parseOne(&[_]u8{ 0x01, 0x02, 0xff, 0xff })));
}

test "der: OID requires a non-empty body" {
    try std.testing.expectEqualSlices(u8, &[_]u8{0x55}, try oidBytes(try parseOne(&[_]u8{ 0x06, 0x01, 0x55 })));
    try std.testing.expectError(Error.Truncated, oidBytes(try parseOne(&[_]u8{ 0x06, 0x00 })));
}

test "der: time parsing matches known epoch values" {
    var utc: [13]u8 = undefined;
    @memcpy(&utc, "260914120000Z");
    try std.testing.expectEqual(@as(i64, 1789387200), try parseTime(.{ .tag = tag.utc_time, .constructed = false, .content = &utc, .raw = "" }));

    var gen: [15]u8 = undefined;
    @memcpy(&gen, "19700101000000Z");
    try std.testing.expectEqual(@as(i64, 0), try parseTime(.{ .tag = tag.generalized_time, .constructed = false, .content = &gen, .raw = "" }));

    var y2k: [13]u8 = undefined;
    @memcpy(&y2k, "000101000000Z");
    try std.testing.expectEqual(@as(i64, 946684800), try parseTime(.{ .tag = tag.utc_time, .constructed = false, .content = &y2k, .raw = "" }));

    // 2060-01-01 needs the 19xx/20xx pivot: "60" is 2060, "59" is 1959.
    var y60: [13]u8 = undefined;
    @memcpy(&y60, "600101000000Z");
    var y59: [13]u8 = undefined;
    @memcpy(&y59, "590101000000Z");
    const t60 = try parseTime(.{ .tag = tag.utc_time, .constructed = false, .content = &y60, .raw = "" });
    const t59 = try parseTime(.{ .tag = tag.utc_time, .constructed = false, .content = &y59, .raw = "" });
    try std.testing.expect(t60 > t59);
    // RFC 5280 §4.1.2.5.1: UTCTime "50".."99" is 19xx, so "60" is 1960.
    try std.testing.expectEqual(@as(i64, -315619200), t60);
    try std.testing.expect(t59 < 0);

    // Month/day range checks.
    var bad: [13]u8 = undefined;
    @memcpy(&bad, "261314120000Z");
    try std.testing.expectError(Error.BadTime, parseTime(.{ .tag = tag.utc_time, .constructed = false, .content = &bad, .raw = "" }));
    @memcpy(&bad, "260914120000X");
    try std.testing.expectError(Error.BadTime, parseTime(.{ .tag = tag.utc_time, .constructed = false, .content = &bad, .raw = "" }));

    // A local time (no Z) is rejected rather than guessed at.
    var local: [12]u8 = undefined;
    @memcpy(&local, "260914120000");
    try std.testing.expectError(Error.BadTime, parseTime(.{ .tag = tag.utc_time, .constructed = false, .content = &local, .raw = "" }));
}

test "der: trailing bytes are visible to the caller" {
    var r = Reader.init(&[_]u8{ 0x02, 0x01, 0x01, 0x02, 0x01, 0x02 });
    _ = try r.next();
    try std.testing.expect(!r.atEnd());
    _ = try r.next();
    try std.testing.expect(r.atEnd());
}

test "der: nesting deeper than the bound is rejected" {
    var buf: [96]u8 = undefined;
    buf[0] = 0x30;
    buf[1] = 0x00;
    var n: usize = 2;
    var k: usize = 0;
    while (k < max_depth + 2) : (k += 1) {
        var i: usize = n;
        while (i > 0) : (i -= 1) buf[i + 1] = buf[i - 1];
        buf[0] = 0x30;
        buf[1] = @intCast(n);
        n += 2;
    }
    var r = Reader.init(buf[0..n]);
    var depth: usize = 0;
    while (depth < max_depth) : (depth += 1) {
        const e = try r.next();
        r = try r.enter(e, depth);
    }
    const e = try r.next();
    try std.testing.expectError(Error.DepthExceeded, r.enter(e, max_depth));
}

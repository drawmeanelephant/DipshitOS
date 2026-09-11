//! ChaCha20 (RFC 7539 / RFC 8439 §2.3–2.4), M47 CP2, ADR 0023 D2.
//!
//! This is the ONE ChaCha20 in the tree: `kernel/src/csprng.zig` imports
//! this file for its keystream, and `crypto/aead.zig` builds
//! ChaCha20-Poly1305 on it. Pure and freestanding — only `std.mem` and
//! integer ops, no allocation, no I/O, no kernel dependency.
//!
//! Verified against the RFC 7539 §2.3.2 block-function vector and the
//! §2.4.2 114-byte ciphertext vector as class-A `zig test`.

const std = @import("std");

pub const key_len = 32;
pub const nonce_len = 12;
pub const block_len = 64;

// RFC 7539 §2.3 constants: "expa" "nd 3" "2-by" "te k".
const c0: u32 = 0x61707865;
const c1: u32 = 0x3320646e;
const c2: u32 = 0x79622d32;
const c3: u32 = 0x6b206574;

fn rotl(x: u32, n: u5) u32 {
    return (x << n) | (x >> @intCast(32 - @as(u6, n)));
}

/// RFC 7539 §2.1 quarter round over four state words addressed by index.
pub fn quarterRound(state: *[16]u32, a: usize, b: usize, c: usize, d: usize) void {
    state[a] +%= state[b];
    state[d] ^= state[a];
    state[d] = rotl(state[d], 16);
    state[c] +%= state[d];
    state[b] ^= state[c];
    state[b] = rotl(state[b], 12);
    state[a] +%= state[b];
    state[d] ^= state[a];
    state[d] = rotl(state[d], 8);
    state[c] +%= state[d];
    state[b] ^= state[c];
    state[b] = rotl(state[b], 7);
}

/// RFC 7539 §2.3.1/§2.3.2: one 64-byte ChaCha20 block. `counter` is the
/// 32-bit block count (state word 12); `nonce` is 12 bytes (words 13–15).
pub fn block(key: *const [key_len]u8, counter: u32, nonce: *const [nonce_len]u8, out: *[block_len]u8) void {
    var state: [16]u32 = undefined;
    state[0] = c0;
    state[1] = c1;
    state[2] = c2;
    state[3] = c3;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        state[4 + i] = std.mem.readInt(u32, key[i * 4 ..][0..4], .little);
    }
    state[12] = counter;
    var j: usize = 0;
    while (j < 3) : (j += 1) {
        state[13 + j] = std.mem.readInt(u32, nonce[j * 4 ..][0..4], .little);
    }
    var working = state;
    var round: usize = 0;
    while (round < 10) : (round += 1) {
        quarterRound(&working, 0, 4, 8, 12);
        quarterRound(&working, 1, 5, 9, 13);
        quarterRound(&working, 2, 6, 10, 14);
        quarterRound(&working, 3, 7, 11, 15);
        quarterRound(&working, 0, 5, 10, 15);
        quarterRound(&working, 1, 6, 11, 12);
        quarterRound(&working, 2, 7, 8, 13);
        quarterRound(&working, 3, 4, 9, 14);
    }
    var k: usize = 0;
    while (k < 16) : (k += 1) {
        std.mem.writeInt(u32, out[k * 4 ..][0..4], working[k] +% state[k], .little);
    }
}

/// XOR `in` with the ChaCha20 keystream starting at block `counter`.
/// `out.len` must equal `in.len`; `out` and `in` may alias. No allocation.
pub fn xorStream(out: []u8, in: []const u8, key: *const [key_len]u8, counter: u32, nonce: *const [nonce_len]u8) void {
    var ctr = counter;
    var ks: [block_len]u8 = undefined;
    var off: usize = 0;
    while (off < in.len) {
        block(key, ctr, nonce, &ks);
        ctr +%= 1;
        const take = @min(block_len, in.len - off);
        for (0..take) |i| out[off + i] = in[off + i] ^ ks[i];
        off += take;
    }
}

// ---------------------------------------------------------------------------
// Host tests — RFC 7539 §2.3.2 / §2.4.2 (identical to RFC 8439)
// ---------------------------------------------------------------------------

test "chacha20: RFC 7539 §2.3.2 block-function vector" {
    var key: [key_len]u8 = undefined;
    var i: usize = 0;
    while (i < key_len) : (i += 1) key[i] = @intCast(i);
    const nonce = [nonce_len]u8{ 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x4a, 0x00, 0x00, 0x00, 0x00 };
    var out: [block_len]u8 = undefined;
    block(&key, 1, &nonce, &out);
    const expected = [block_len]u8{
        0x10, 0xf1, 0xe7, 0xe4, 0xd1, 0x3b, 0x59, 0x15, 0x50, 0x0f, 0xdd, 0x1f, 0xa3, 0x20, 0x71, 0xc4,
        0xc7, 0xd1, 0xf4, 0xc7, 0x33, 0xc0, 0x68, 0x03, 0x04, 0x22, 0xaa, 0x9a, 0xc3, 0xd4, 0x6c, 0x4e,
        0xd2, 0x82, 0x64, 0x46, 0x07, 0x9f, 0xaa, 0x09, 0x14, 0xc2, 0xd7, 0x05, 0xd9, 0x8b, 0x02, 0xa2,
        0xb5, 0x12, 0x9c, 0xd1, 0xde, 0x16, 0x4e, 0xb9, 0xcb, 0xd0, 0x83, 0xe8, 0xa2, 0x50, 0x3c, 0x4e,
    };
    try std.testing.expectEqual(expected, out);
}

test "chacha20: RFC 7539 §2.4.2 114-byte ciphertext vector" {
    var key: [key_len]u8 = undefined;
    var i: usize = 0;
    while (i < key_len) : (i += 1) key[i] = @intCast(i);
    const nonce = [nonce_len]u8{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x4a, 0x00, 0x00, 0x00, 0x00 };
    const plaintext =
        "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.";
    var out: [114]u8 = undefined;
    xorStream(&out, plaintext, &key, 1, &nonce);
    const expected = [114]u8{
        0x6e, 0x2e, 0x35, 0x9a, 0x25, 0x68, 0xf9, 0x80, 0x41, 0xba, 0x07, 0x28, 0xdd, 0x0d, 0x69, 0x81,
        0xe9, 0x7e, 0x7a, 0xec, 0x1d, 0x43, 0x60, 0xc2, 0x0a, 0x27, 0xaf, 0xcc, 0xfd, 0x9f, 0xae, 0x0b,
        0xf9, 0x1b, 0x65, 0xc5, 0x52, 0x47, 0x33, 0xab, 0x8f, 0x59, 0x3d, 0xab, 0xcd, 0x62, 0xb3, 0x57,
        0x16, 0x39, 0xd6, 0x24, 0xe6, 0x51, 0x52, 0xab, 0x8f, 0x53, 0x0c, 0x35, 0x9f, 0x08, 0x61, 0xd8,
        0x07, 0xca, 0x0d, 0xbf, 0x50, 0x0d, 0x6a, 0x61, 0x56, 0xa3, 0x8e, 0x08, 0x8a, 0x22, 0xb6, 0x5e,
        0x52, 0xbc, 0x51, 0x4d, 0x16, 0xcc, 0xf8, 0x06, 0x81, 0x8c, 0xe9, 0x1a, 0xb7, 0x79, 0x37, 0x36,
        0x5a, 0xf9, 0x0b, 0xbf, 0x74, 0xa3, 0x5b, 0xe6, 0xb4, 0x0b, 0x8e, 0xed, 0xf2, 0x78, 0x5e, 0x42,
        0x87, 0x4d,
    };
    try std.testing.expectEqual(expected, out);
}

test "chacha20: xorStream is an involution (stream continuity across blocks)" {
    var key: [key_len]u8 = undefined;
    for (0..key_len) |i| key[i] = @truncate(i * 7 + 3);
    const nonce = [nonce_len]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 };
    var msg: [200]u8 = undefined;
    for (0..msg.len) |i| msg[i] = @truncate(i * 13 + 1);
    var ct: [200]u8 = undefined;
    var back: [200]u8 = undefined;
    xorStream(&ct, &msg, &key, 1, &nonce);
    xorStream(&back, &ct, &key, 1, &nonce);
    try std.testing.expectEqualSlices(u8, &msg, &back);
}

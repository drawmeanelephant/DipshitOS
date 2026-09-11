//! VirelaiOS crypto primitives library (M47, ADR 0023).
//!
//! One freestanding, host-tested, allocation-free crypto library shared by
//! userland apps and the kernel's CSPRNG. Every submodule is pure Zig over
//! `std.mem`/integer ops — no libc, no POSIX, no allocator, no I/O, no
//! randomness. This root re-exports the surface and carries the
//! cross-primitive integration tests; its `test` blocks (and every imported
//! submodule's) run under `zig build test`.
//!
//! Cards: CP1 SHA-256/512 + HMAC (#1115); CP2 ChaCha20-Poly1305 (#1116);
//! CP3 X25519 (#1117); CP4 Ed25519 (#1118); CP5 ct + demo (#1119).

pub const ct = @import("crypto/ct.zig");
pub const sha256 = @import("crypto/sha256.zig");
pub const sha512 = @import("crypto/sha512.zig");
pub const hmac = @import("crypto/hmac.zig");
pub const chacha20 = @import("crypto/chacha20.zig");
pub const poly1305 = @import("crypto/poly1305.zig");
pub const aead = @import("crypto/aead.zig");
pub const curve25519 = @import("crypto/curve25519.zig");
pub const x25519 = @import("crypto/x25519.zig");
pub const ed25519 = @import("crypto/ed25519.zig");

const std = @import("std");

test "crypto: HMAC-SHA256 and Ed25519 compose (a signed, authenticated transcript)" {
    // A tiny end-to-end composition: an Ed25519 key signs a transcript whose
    // integrity is also MAC'd. This is an integration smoke, not a protocol.
    const seed = [_]u8{0x42} ** 32;
    var pk: [32]u8 = undefined;
    ed25519.derivePublicKey(&pk, &seed);

    const transcript = "M47 crypto primitives: SHA-256, ChaCha20-Poly1305, X25519, Ed25519";
    var sig: [64]u8 = undefined;
    ed25519.sign(&sig, transcript, &seed);
    try std.testing.expect(ed25519.verify(&sig, transcript, &pk));

    var mac: [32]u8 = undefined;
    hmac.hmacSha256(&mac, &pk, transcript);
    try std.testing.expect(!ct.ctEq(&mac, &([_]u8{0} ** 32)));
}

test "crypto: AEAD then X25519 shared-secret consistency" {
    // Derive a shared secret each way and use it as an AEAD key.
    const a_sk = [_]u8{0x11} ** 32;
    const b_sk = [_]u8{0x22} ** 32;
    var a_pk: [32]u8 = undefined;
    var b_pk: [32]u8 = undefined;
    x25519.scalarmultBase(&a_pk, &a_sk);
    x25519.scalarmultBase(&b_pk, &b_sk);
    var s1: [32]u8 = undefined;
    var s2: [32]u8 = undefined;
    x25519.scalarmult(&s1, &a_sk, &b_pk);
    x25519.scalarmult(&s2, &b_sk, &a_pk);
    try std.testing.expect(ct.ctEq(&s1, &s2));

    const nonce = [_]u8{0} ** 12;
    var ctbuf: [5]u8 = undefined;
    var tag: [16]u8 = undefined;
    aead.seal(&ctbuf, &tag, "hello", "aad", &nonce, &s1);
    var pt: [5]u8 = undefined;
    try std.testing.expect(aead.open(&pt, &ctbuf, &tag, "aad", &nonce, &s2));
    try std.testing.expectEqualSlices(u8, "hello", &pt);
}

// M51 SSH5 (#1172, ADR 0025 D4/D8): the Swift half of the
// `chacha20-poly1305@openssh.com` cipher and the RFC 4253 §7.2 KDF.
//
// The runner hosts a minimal SSH-2 server, so the host must speak the same
// cipher as the guest's `user/src/lib/crypto/ssh_cipher.zig`. That Zig
// construction is implemented to the authoritative OpenSSH
// `PROTOCOL.chacha20poly1305` file (NOT the IETF draft, which inverts the
// K_1/K_2 names): the 64-byte key splits, K_2 = key[0..32] keys the AEAD
// (Poly1305 key = the first 32 bytes of `ChaCha20(K_2, seq, 0)`, payload
// encrypted from block counter 1), K_1 = key[32..64] encrypts only the
// 4-byte length at counter 0, and the tag is Encrypt-then-MAC Poly1305 over
// `enc_length || enc_payload`.
//
// DRIFT GUARD (ADR 0023 D2 precedent): `Tests/VMRunnerTests/VSSHTests.swift`
// pins the same OpenSSH vector `crypto/ssh_cipher.zig` pins (the
// draft-ietf-sshm-chacha20-poly1305-04 Appendix A worked example, key
// `8bbff685…`, seq 7, tag `95349e85…`) plus the RFC 8439 ChaCha20 and
// Poly1305 vectors, so the two implementations cannot silently diverge.
//
// No allocation-heavy streaming: one-shot over caller arrays; Poly1305 uses
// 26-bit limbs so every product fits a UInt64 (no UInt128 dependency).

import CryptoKit
import Foundation

/// RFC 4253 §6 / RFC 4251 §5 packet framing errors.
public enum SSHPacketError: Error, Equatable {
    case short
    case overlong
    case badLength
    case badPadding
}

/// A byte cursor with the SSH wire types (RFC 4251 §5).
public struct SSHReader {
    public let bytes: [UInt8]
    public var pos: Int

    public init(_ bytes: [UInt8], pos: Int = 0) {
        self.bytes = bytes
        self.pos = pos
    }

    public var remaining: Int { bytes.count - pos }

    public mutating func byte() throws -> UInt8 {
        guard remaining >= 1 else { throw SSHPacketError.short }
        let b = bytes[pos]
        pos += 1
        return b
    }

    public mutating func bool() throws -> Bool {
        let b = try byte()
        switch b {
        case 0: return false
        case 1: return true
        default: throw SSHPacketError.badLength
        }
    }

    public mutating func uint32() throws -> UInt32 {
        guard remaining >= 4 else { throw SSHPacketError.short }
        let v = (UInt32(bytes[pos]) << 24) | (UInt32(bytes[pos + 1]) << 16)
            | (UInt32(bytes[pos + 2]) << 8) | UInt32(bytes[pos + 3])
        pos += 4
        return v
    }

    public mutating func string() throws -> [UInt8] {
        let n = Int(try uint32())
        guard n <= remaining else { throw SSHPacketError.short }
        let s = Array(bytes[pos ..< pos + n])
        pos += n
        return s
    }

    public mutating func stringUTF8() throws -> String {
        guard let s = String(bytes: try string(), encoding: .utf8) else {
            throw SSHPacketError.badLength
        }
        return s
    }

    public mutating func nameList() throws -> [String] {
        let raw = try string()
        guard let text = String(bytes: raw, encoding: .utf8) else {
            throw SSHPacketError.badLength
        }
        if text.isEmpty { return [] }
        let parts = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !parts.contains(where: { $0.isEmpty }) else { throw SSHPacketError.badLength }
        return parts
    }
}

/// The SSH wire writer (append-only).
public struct SSHWriter {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public mutating func byte(_ v: UInt8) { bytes.append(v) }

    public mutating func bool(_ v: Bool) { bytes.append(v ? 1 : 0) }

    public mutating func uint32(_ v: UInt32) {
        bytes.append(UInt8((v >> 24) & 0xff))
        bytes.append(UInt8((v >> 16) & 0xff))
        bytes.append(UInt8((v >> 8) & 0xff))
        bytes.append(UInt8(v & 0xff))
    }

    public mutating func string(_ s: [UInt8]) {
        uint32(UInt32(s.count))
        bytes.append(contentsOf: s)
    }

    public mutating func string(_ s: String) {
        string(Array(s.utf8))
    }

    public mutating func nameList(_ names: [String]) {
        string(names.joined(separator: ","))
    }

    public mutating func raw(_ b: [UInt8]) { bytes.append(contentsOf: b) }
}

/// The frame-alignment rule in force for the negotiated cipher (#1210).
/// Mirrors `user/src/lib/ssh/packet.zig`'s `Alignment`:
///
///   * `.plaintext` — RFC 4253 §6: `4 + packet_length` is a multiple of 8
///     (all pre-NEWKEYS KEX packets; the rule OpenSSH completes KEX with);
///   * `.aead` — `chacha20-poly1305@openssh.com`: `packet_length` alone is
///     padded to the block size (`packet.c ssh_packet_send2_wrapped`); the
///     4-byte length field is authenticated but outside the padded region.
public enum SSHPacketAlignment {
    case plaintext
    case aead
}

/// RFC 4253 §6 binary packet framing. `encode` validates the same
/// invariants `user/src/lib/ssh/packet.zig` enforces: padding ≥ 4, the
/// selected `alignment` rule, the total ≤ 35000.
public enum SSHPacket {
    public static let lenField = 4
    public static let blockSize = 8
    public static let minPadding = 4
    public static let maxTotal = 35000

    public static func paddingLen(_ payloadLen: Int, alignment: SSHPacketAlignment) -> Int {
        let base = alignment == .plaintext ? lenField + 1 + payloadLen : 1 + payloadLen
        var pad = blockSize - (base % blockSize)
        if pad < minPadding { pad += blockSize }
        return pad
    }

    public static func encode(
        payload: [UInt8], pad: [UInt8], alignment: SSHPacketAlignment
    ) throws -> [UInt8] {
        guard pad.count == paddingLen(payload.count, alignment: alignment) else {
            throw SSHPacketError.badPadding
        }
        let packetLength = 1 + payload.count + pad.count
        let total = lenField + packetLength
        guard total <= maxTotal else { throw SSHPacketError.overlong }
        var out = [UInt8]()
        out.reserveCapacity(total)
        out.append(UInt8((packetLength >> 24) & 0xff))
        out.append(UInt8((packetLength >> 16) & 0xff))
        out.append(UInt8((packetLength >> 8) & 0xff))
        out.append(UInt8(packetLength & 0xff))
        out.append(UInt8(pad.count))
        out.append(contentsOf: payload)
        out.append(contentsOf: pad)
        return out
    }

    /// Decode exactly one frame (`4 + packet_length` bytes) to its payload.
    public static func decode(
        _ frame: [UInt8], alignment: SSHPacketAlignment
    ) throws -> [UInt8] {
        guard frame.count >= 5 else { throw SSHPacketError.short }
        let packetLength = (Int(frame[0]) << 24) | (Int(frame[1]) << 16)
            | (Int(frame[2]) << 8) | Int(frame[3])
        let padding = Int(frame[4])
        guard packetLength <= maxTotal - lenField else { throw SSHPacketError.overlong }
        guard packetLength >= 1 + minPadding else { throw SSHPacketError.badLength }
        let aligned = alignment == .plaintext
            ? (lenField + packetLength) % blockSize == 0
            : packetLength % blockSize == 0
        guard aligned else { throw SSHPacketError.badLength }
        guard padding >= minPadding, padding <= packetLength - 1 else {
            throw SSHPacketError.badLength
        }
        guard frame.count == lenField + packetLength else { throw SSHPacketError.short }
        return Array(frame[5 ..< 5 + (packetLength - 1 - padding)])
    }
}

/// djb ChaCha20: 64-bit block counter (state words 12–13) and an 8-byte
/// nonce (words 14–15), both little-endian. This is the variant
/// `user/src/lib/crypto/chacha20_ssh.zig` implements, not RFC 8439's
/// 32-bit-counter/96-bit-nonce layout.
public enum SSHChaCha20 {
    public static let keyLength = 32
    public static let nonceLength = 8
    public static let blockLength = 64

    @inline(__always)
    private static func load32LE(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16)
            | (UInt32(b[o + 3]) << 24)
    }

    @inline(__always)
    private static func store32LE(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
        b[o] = UInt8(v & 0xff)
        b[o + 1] = UInt8((v >> 8) & 0xff)
        b[o + 2] = UInt8((v >> 16) & 0xff)
        b[o + 3] = UInt8((v >> 24) & 0xff)
    }

    @inline(__always)
    private static func rotl(_ v: UInt32, _ n: UInt32) -> UInt32 {
        (v << n) | (v >> (32 - n))
    }

    @inline(__always)
    private static func quarterRound(
        _ s: inout [UInt32], _ a: Int, _ b: Int, _ c: Int, _ d: Int
    ) {
        s[a] = s[a] &+ s[b]; s[d] ^= s[a]; s[d] = rotl(s[d], 16)
        s[c] = s[c] &+ s[d]; s[b] ^= s[c]; s[b] = rotl(s[b], 12)
        s[a] = s[a] &+ s[b]; s[d] ^= s[a]; s[d] = rotl(s[d], 8)
        s[c] = s[c] &+ s[d]; s[b] ^= s[c]; s[b] = rotl(s[b], 7)
    }

    /// One 64-byte block at `counter`/`nonce`.
    public static func block(key: [UInt8], counter: UInt64, nonce: [UInt8]) -> [UInt8] {
        precondition(key.count == keyLength && nonce.count == nonceLength)
        var state = [UInt32](repeating: 0, count: 16)
        state[0] = 0x61707865
        state[1] = 0x3320646e
        state[2] = 0x79622d32
        state[3] = 0x6b206574
        for i in 0 ..< 8 { state[4 + i] = load32LE(key, i * 4) }
        state[12] = UInt32(truncatingIfNeeded: counter)
        state[13] = UInt32(truncatingIfNeeded: counter >> 32)
        state[14] = load32LE(nonce, 0)
        state[15] = load32LE(nonce, 4)

        var w = state
        for _ in 0 ..< 10 {
            quarterRound(&w, 0, 4, 8, 12)
            quarterRound(&w, 1, 5, 9, 13)
            quarterRound(&w, 2, 6, 10, 14)
            quarterRound(&w, 3, 7, 11, 15)
            quarterRound(&w, 0, 5, 10, 15)
            quarterRound(&w, 1, 6, 11, 12)
            quarterRound(&w, 2, 7, 8, 13)
            quarterRound(&w, 3, 4, 9, 14)
        }
        var out = [UInt8](repeating: 0, count: blockLength)
        for k in 0 ..< 16 {
            store32LE(&out, k * 4, w[k] &+ state[k])
        }
        return out
    }

    /// XOR `input` with the keystream from block `counter`; the 64-bit
    /// counter continues across block boundaries.
    public static func xorStream(
        input: [UInt8], key: [UInt8], counter: UInt64, nonce: [UInt8]
    ) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: input.count)
        var ctr = counter
        var off = 0
        while off < input.count {
            let ks = block(key: key, counter: ctr, nonce: nonce)
            ctr &+= 1
            let take = min(blockLength, input.count - off)
            for i in 0 ..< take { out[off + i] = input[off + i] ^ ks[i] }
            off += take
        }
        return out
    }
}

/// Poly1305 (RFC 8439 §2.5), one-shot; 26-bit limbs, UInt64 products.
public enum SSHPoly1305 {
    public static func tag(message: [UInt8], key: [UInt8]) -> [UInt8] {
        precondition(key.count == 32)
        var r = [UInt32](repeating: 0, count: 5)
        r[0] = le32(key, 0) & 0x3ffffff
        r[1] = (le32(key, 3) >> 2) & 0x3ffff03
        r[2] = (le32(key, 6) >> 4) & 0x3ffc0ff
        r[3] = (le32(key, 9) >> 6) & 0x3f03fff
        r[4] = (le32(key, 12) >> 8) & 0x00fffff
        let s1 = r[1] &* 5
        let s2 = r[2] &* 5
        let s3 = r[3] &* 5
        let s4 = r[4] &* 5

        var h = [UInt32](repeating: 0, count: 5)

        var off = 0
        while off < message.count {
            let n = min(16, message.count - off)
            var blk = [UInt8](repeating: 0, count: 16)
            for i in 0 ..< n { blk[i] = message[off + i] }
            // The implicit 1 bit: at 2^(8n) for a partial block, at 2^128
            // (limb-4 bit 24) for a full one.
            if n < 16 { blk[n] = 1 }
            h[0] = h[0] &+ (le32(blk, 0) & 0x3ffffff)
            h[1] = h[1] &+ ((le32(blk, 3) >> 2) & 0x3ffffff)
            h[2] = h[2] &+ ((le32(blk, 6) >> 4) & 0x3ffffff)
            h[3] = h[3] &+ ((le32(blk, 9) >> 6) & 0x3ffffff)
            h[4] = h[4] &+ ((le32(blk, 12) >> 8) | (n == 16 ? (UInt32(1) << 24) : 0))

            let d0 = UInt64(h[0]) &* UInt64(r[0]) &+ UInt64(h[1]) &* UInt64(s4)
                &+ UInt64(h[2]) &* UInt64(s3) &+ UInt64(h[3]) &* UInt64(s2)
                &+ UInt64(h[4]) &* UInt64(s1)
            var d1 = UInt64(h[0]) &* UInt64(r[1]) &+ UInt64(h[1]) &* UInt64(r[0])
                &+ UInt64(h[2]) &* UInt64(s4) &+ UInt64(h[3]) &* UInt64(s3)
                &+ UInt64(h[4]) &* UInt64(s2)
            var d2 = UInt64(h[0]) &* UInt64(r[2]) &+ UInt64(h[1]) &* UInt64(r[1])
                &+ UInt64(h[2]) &* UInt64(r[0]) &+ UInt64(h[3]) &* UInt64(s4)
                &+ UInt64(h[4]) &* UInt64(s3)
            var d3 = UInt64(h[0]) &* UInt64(r[3]) &+ UInt64(h[1]) &* UInt64(r[2])
                &+ UInt64(h[2]) &* UInt64(r[1]) &+ UInt64(h[3]) &* UInt64(r[0])
                &+ UInt64(h[4]) &* UInt64(s4)
            var d4 = UInt64(h[0]) &* UInt64(r[4]) &+ UInt64(h[1]) &* UInt64(r[3])
                &+ UInt64(h[2]) &* UInt64(r[2]) &+ UInt64(h[3]) &* UInt64(r[1])
                &+ UInt64(h[4]) &* UInt64(r[0])

            var c = UInt32(truncatingIfNeeded: d0 >> 26); h[0] = UInt32(truncatingIfNeeded: d0) & 0x3ffffff
            d1 &+= UInt64(c); c = UInt32(truncatingIfNeeded: d1 >> 26); h[1] = UInt32(truncatingIfNeeded: d1) & 0x3ffffff
            d2 &+= UInt64(c); c = UInt32(truncatingIfNeeded: d2 >> 26); h[2] = UInt32(truncatingIfNeeded: d2) & 0x3ffffff
            d3 &+= UInt64(c); c = UInt32(truncatingIfNeeded: d3 >> 26); h[3] = UInt32(truncatingIfNeeded: d3) & 0x3ffffff
            d4 &+= UInt64(c); c = UInt32(truncatingIfNeeded: d4 >> 26); h[4] = UInt32(truncatingIfNeeded: d4) & 0x3ffffff
            h[0] = h[0] &+ c &* 5
            c = h[0] >> 26; h[0] &= 0x3ffffff
            h[1] = h[1] &+ c
            off += n
        }

        // Fully carry h.
        var c = h[1] >> 26; h[1] &= 0x3ffffff; h[2] = h[2] &+ c
        c = h[2] >> 26; h[2] &= 0x3ffffff; h[3] = h[3] &+ c
        c = h[3] >> 26; h[3] &= 0x3ffffff; h[4] = h[4] &+ c
        c = h[4] >> 26; h[4] &= 0x3ffffff; h[0] = h[0] &+ c &* 5
        c = h[0] >> 26; h[0] &= 0x3ffffff; h[1] = h[1] &+ c

        // h + -p, selected when h >= p.
        var g = [UInt32](repeating: 0, count: 5)
        g[0] = h[0] &+ 5; c = g[0] >> 26; g[0] &= 0x3ffffff
        g[1] = h[1] &+ c; c = g[1] >> 26; g[1] &= 0x3ffffff
        g[2] = h[2] &+ c; c = g[2] >> 26; g[2] &= 0x3ffffff
        g[3] = h[3] &+ c; c = g[3] >> 26; g[3] &= 0x3ffffff
        g[4] = h[4] &+ c &- (UInt32(1) << 26)
        var mask: UInt32 = (g[4] >> 31) &- 1
        for i in 0 ..< 5 { g[i] &= mask }
        mask = ~mask
        for i in 0 ..< 5 { h[i] = (h[i] & mask) | g[i] }

        // h mod 2^128 as four 32-bit words.
        var hh = [UInt32](repeating: 0, count: 4)
        hh[0] = (h[0] | (h[1] << 26)) & 0xffffffff
        hh[1] = ((h[1] >> 6) | (h[2] << 20)) & 0xffffffff
        hh[2] = ((h[2] >> 12) | (h[3] << 14)) & 0xffffffff
        hh[3] = ((h[3] >> 18) | (h[4] << 8)) & 0xffffffff

        var pad = [UInt32](repeating: 0, count: 4)
        for i in 0 ..< 4 { pad[i] = le32(key, 16 + i * 4) }
        var carry = UInt64(hh[0]) &+ UInt64(pad[0]); hh[0] = UInt32(truncatingIfNeeded: carry)
        carry = UInt64(hh[1]) &+ UInt64(pad[1]) &+ (carry >> 32); hh[1] = UInt32(truncatingIfNeeded: carry)
        carry = UInt64(hh[2]) &+ UInt64(pad[2]) &+ (carry >> 32); hh[2] = UInt32(truncatingIfNeeded: carry)
        carry = UInt64(hh[3]) &+ UInt64(pad[3]) &+ (carry >> 32); hh[3] = UInt32(truncatingIfNeeded: carry)

        var out = [UInt8](repeating: 0, count: 16)
        for i in 0 ..< 4 { store32le(&out, i * 4, hh[i]) }
        return out
    }

    @inline(__always)
    private static func le32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16)
            | (UInt32(b[o + 3]) << 24)
    }

    @inline(__always)
    private static func store32le(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
        b[o] = UInt8(v & 0xff)
        b[o + 1] = UInt8((v >> 8) & 0xff)
        b[o + 2] = UInt8((v >> 16) & 0xff)
        b[o + 3] = UInt8((v >> 24) & 0xff)
    }
}

/// The OpenSSH `chacha20-poly1305@openssh.com` construction (64-byte key).
public struct SSHOpenSSHCipher {
    public static let keyLength = 64
    public static let tagLength = 16
    public static let lengthLength = 4

    public let key: [UInt8]

    public init(key: [UInt8]) {
        precondition(key.count == Self.keyLength)
        self.key = key
    }

    /// SSH wire encoding of the packet sequence number is big-endian.
    private func seqNonce(_ seq: UInt64) -> [UInt8] {
        [UInt8((seq >> 56) & 0xff), UInt8((seq >> 48) & 0xff),
         UInt8((seq >> 40) & 0xff), UInt8((seq >> 32) & 0xff),
         UInt8((seq >> 24) & 0xff), UInt8((seq >> 16) & 0xff),
         UInt8((seq >> 8) & 0xff), UInt8(seq & 0xff)]
    }

    /// The per-packet Poly1305 key: the first 32 bytes of
    /// `ChaCha20(K_2, seq, 0)` with K_2 = key[0..32].
    private func polyKey(_ seq: UInt64) -> [UInt8] {
        let block = SSHChaCha20.block(
            key: Array(key[0 ..< 32]), counter: 0, nonce: seqNonce(seq)
        )
        return Array(block[0 ..< 32])
    }

    /// Decrypt just the 4-byte length field (the OpenSSH "length first"
    /// step). The result is unauthenticated until `open`.
    public func decryptLength(_ encrypted: [UInt8], seq: UInt64) -> UInt32 {
        precondition(encrypted.count == Self.lengthLength)
        let plain = SSHChaCha20.xorStream(
            input: encrypted, key: Array(key[32 ..< 64]), counter: 0, nonce: seqNonce(seq)
        )
        return (UInt32(plain[0]) << 24) | (UInt32(plain[1]) << 16)
            | (UInt32(plain[2]) << 8) | UInt32(plain[3])
    }

    /// Seal one complete `length || rest` packet; returns the ciphertext
    /// (same length) and its 16-byte tag over the ciphertext.
    public func seal(_ plaintext: [UInt8], seq: UInt64) -> (ciphertext: [UInt8], tag: [UInt8]) {
        precondition(plaintext.count >= Self.lengthLength)
        var ciphertext = plaintext
        let nonce = seqNonce(seq)
        let encLen = SSHChaCha20.xorStream(
            input: Array(plaintext[0 ..< 4]), key: Array(key[32 ..< 64]), counter: 0, nonce: nonce
        )
        for i in 0 ..< 4 { ciphertext[i] = encLen[i] }
        let encBody = SSHChaCha20.xorStream(
            input: Array(plaintext[4...]), key: Array(key[0 ..< 32]), counter: 1, nonce: nonce
        )
        for i in 0 ..< encBody.count { ciphertext[4 + i] = encBody[i] }
        let tag = SSHPoly1305.tag(message: ciphertext, key: polyKey(seq))
        return (ciphertext, tag)
    }

    /// Authenticate then decrypt. Returns nil (no plaintext) on a tag
    /// mismatch; the comparison is constant-time over the 16 tag bytes.
    public func open(ciphertext: [UInt8], tag: [UInt8], seq: UInt64) -> [UInt8]? {
        precondition(ciphertext.count >= Self.lengthLength && tag.count == Self.tagLength)
        let expected = SSHPoly1305.tag(message: ciphertext, key: polyKey(seq))
        guard Self.constantTimeEquals(expected, tag) else { return nil }
        let nonce = seqNonce(seq)
        let plainLen = SSHChaCha20.xorStream(
            input: Array(ciphertext[0 ..< 4]), key: Array(key[32 ..< 64]), counter: 0, nonce: nonce
        )
        let plainBody = SSHChaCha20.xorStream(
            input: Array(ciphertext[4...]), key: Array(key[0 ..< 32]), counter: 1, nonce: nonce
        )
        return plainLen + plainBody
    }

    /// Constant-time byte equality (no early exit), mirroring `ct.ctEq`.
    public static func constantTimeEquals(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var acc: UInt8 = 0
        for i in 0 ..< a.count { acc |= a[i] ^ b[i] }
        return acc == 0
    }
}

/// The RFC 4253 §8 exchange hash and §7.2 key derivation, byte-identical
/// to `user/src/lib/ssh/kex.zig`'s `exchangeHash`/`deriveKey`.
public enum SSHKDF {
    /// `H = SHA256(string V_C || string V_S || string I_C || string I_S ||
    /// string K_S || string Q_C || string Q_S || mpint K)`. `kMpint` is the
    /// already length-prefixed mpint string.
    public static func exchangeHash(
        vc: [UInt8], vs: [UInt8], ic: [UInt8], isI: [UInt8],
        ks: [UInt8], qc: [UInt8], qs: [UInt8], kMpint: [UInt8]
    ) -> [UInt8] {
        var w = SSHWriter()
        w.string(vc); w.string(vs)
        w.string(ic); w.string(isI)
        w.string(ks); w.string(qc); w.string(qs)
        w.raw(kMpint)
        return Array(SHA256.hash(data: Data(w.bytes)))
    }

    /// RFC 4253 §7.2: first block `HASH(K || H || letter || session_id)`,
    /// extension blocks `HASH(K || H || key-so-far)`. `kMpint` carries its
    /// string length (the Zig implementation consumes the same bytes).
    public static func deriveKey(
        length: Int, kMpint: [UInt8], h: [UInt8], letter: UInt8, sessionId: [UInt8]
    ) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(length)
        var first = Data(kMpint)
        first.append(contentsOf: h)
        first.append(letter)
        first.append(contentsOf: sessionId)
        out.append(contentsOf: SHA256.hash(data: first))
        while out.count < length {
            var next = Data(kMpint)
            next.append(contentsOf: h)
            next.append(contentsOf: out)
            out.append(contentsOf: SHA256.hash(data: next))
        }
        return Array(out[0 ..< length])
    }

    /// RFC 8731 §3.1 / RFC 4251 §5: the X25519 output as a network-order
    /// unsigned integer, minimally encoded as an mpint string.
    public static func mpint(_ raw: [UInt8]) -> [UInt8] {
        var start = 0
        while start < raw.count && raw[start] == 0 { start += 1 }
        var body = Array(raw[start...])
        if let first = body.first, (first & 0x80) != 0 {
            body.insert(0, at: 0)
        }
        var w = SSHWriter()
        w.string(body)
        return w.bytes
    }
}

/// The fixed, published fixtures the `:ssh` responder uses unless flags
/// override them. Host key = RFC 8032 §7.1 TEST 1; accepted user key =
/// RFC 8032 §7.1 TEST 2. The specs seed the same values into
/// `SSH/KNOWN_HOSTS` / `SECRETS.TXT`.
public enum SSHFixtures {
    public static let hostKeySeedHex =
        "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
    public static let hostPublicKeyHex =
        "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a"
    public static let userKeySeedHex =
        "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb"
    public static let userPublicKeyHex =
        "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c"
    /// RFC 8032 §7.1 TEST 3 — the "wrong user key" fixture's public key.
    public static let wrongUserKeySeedHex =
        "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7"
    public static let wrongUserPublicKeyHex =
        "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025"

    public static let defaultMarker = "VIRELAI-SSH5-OK\n"

    /// The OpenSSH `PROTOCOL.chacha20poly1305` worked example (the same
    /// vector `crypto/ssh_cipher.zig` pins): key from Figure 5, the packet
    /// of Figure 4 at sequence 7, ciphertext Figure 12, tag Figure 17.
    public static let opensshVectorKeyHex =
        "8bbff6855fc102338c373e73aac0c914" +
        "f076a905b2444a32eecaffeae22becc5" +
        "e9b7a7a5825a8249346ec1c28301cf39" +
        "4543fc7569887d76e168f37562ac0740"
    public static let opensshVectorPlainHex =
        "00000048065e00000000000000384c6f" +
        "72656d20697073756d20646f6c6f7220" +
        "73697420616d65742c20636f6e736563" +
        "7465747572206164697069736963696e" +
        "6720656c69744e43e804dc6c"
    public static let opensshVectorCiphertextHex =
        "2c3ecce4a5bc05895bf07a7ba956b6c6" +
        "8829ac7c83b780b7000ecde745afc705" +
        "bbc378ce03a280236b87b53bed583966" +
        "2302b164b6286a48cd1e097138e3cb90" +
        "9b8b2b829dd18d2a35ff82d9"
    public static let opensshVectorTagHex = "95349e855bf02c298ef775f2d1a7e8b8"

    /// The ADR 0023 D2 drift guard, runnable at runtime: the hand-rolled
    /// Swift cipher must reproduce the OpenSSH vector the guest's Zig
    /// implementation pins. The runner refuses to serve `:ssh` when this
    /// returns false.
    public static func cipherSelfCheck() -> Bool {
        guard let key = hex(opensshVectorKeyHex),
              let plain = hex(opensshVectorPlainHex),
              let wantCiphertext = hex(opensshVectorCiphertextHex),
              let wantTag = hex(opensshVectorTagHex)
        else { return false }
        let cipher = SSHOpenSSHCipher(key: key)
        let (ciphertext, tag) = cipher.seal(plain, seq: 7)
        guard ciphertext == wantCiphertext, tag == wantTag else { return false }
        guard cipher.open(ciphertext: ciphertext, tag: tag, seq: 7) == plain else {
            return false
        }
        var tamperedTag = tag
        tamperedTag[0] ^= 0x01
        guard cipher.open(ciphertext: ciphertext, tag: tamperedTag, seq: 7) == nil else {
            return false
        }
        guard cipher.decryptLength(Array(ciphertext[0 ..< 4]), seq: 7) == 0x48 else {
            return false
        }
        // #1210 frame-alignment drift guard: the pinned OpenSSH frame's
        // packet_length (0x48 = 72) is a multiple of 8 while 4 + 72 is not,
        // so only the AEAD rule accepts it and it carries 65 payload bytes
        // with 6 padding bytes (the same numbers `packet.zig` pins).
        guard let framePayload = try? SSHPacket.decode(plain, alignment: .aead),
              framePayload.count == 65,
              (try? SSHPacket.decode(plain, alignment: .plaintext)) == nil,
              SSHPacket.paddingLen(framePayload.count, alignment: .aead) == 6
        else { return false }
        return true
    }

    public static func hex(_ text: String) -> [UInt8]? {
        let chars = Array(text.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    public static func hexString(_ bytes: [UInt8]) -> String {
        let table = Array("0123456789abcdef")
        var out = ""
        for b in bytes {
            out.append(table[Int(b >> 4)])
            out.append(table[Int(b & 0xf)])
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 0x30 ... 0x39: return c - 0x30
        case 0x61 ... 0x66: return c - 0x61 + 10
        case 0x41 ... 0x46: return c - 0x41 + 10
        default: return nil
        }
    }
}

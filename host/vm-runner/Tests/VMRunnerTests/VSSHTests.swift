// M51 SSH5 (#1172): class-A tests for the VSSH module.
//
// DRIFT GUARD (ADR 0023 D2 / ADR 0025 D8): the Swift cipher and KEX are
// tied to the guest's Zig implementation by the SAME pinned vectors —
//
//   * ChaCha20 djb block vectors from `crypto/chacha20_ssh.zig`;
//   * Poly1305 RFC 8439 §2.5.2;
//   * the full OpenSSH `PROTOCOL.chacha20poly1305` worked example pinned by
//     `crypto/ssh_cipher.zig` (key `8bbff685…`, seq 7, tag `95349e85…`);
//   * the KEX transcript `user/src/lib/ssh/kex.zig` pins: RFC 7748 §6.1
//     X25519 (K = `4a5d9d5b…`), RFC 8032 §7.1 TEST 1 host key signing H
//     (`15c9cacb…`, sig `c1b0702f…`) and the derived C2S/S2C keys.
//
// The server tests then drive the real `SSHServer` byte stream through a
// scripted CryptoKit client: KEX → userauth (`none` → `publickey`) → one
// `session` channel → fixed `exec` → marker + exit-status + EOF/CLOSE, and
// the negative knobs (tampered tag, rejected key).

import CryptoKit
import XCTest

@testable import VSSH

final class VSSHTests: XCTestCase {
    // MARK: - pinned vectors

    /// RFC 7748 §6.1 Alice/Bob (the `kex.zig` Vector).
    static let aliceSecretHex =
        "77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a"
    static let alicePublicHex =
        "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"
    static let bobSecretHex =
        "5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb"
    static let bobPublicHex =
        "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"
    static let sharedSecretHex =
        "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"
    static let sharedMpintHex =
        "000000204a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"

    static let pinnedICHex =
        "14000102030405060708090a0b0c0d0e0f0000002e637572766532353531392d7368613235" +
        "362c637572766532353531392d736861323536406c69627373682e6f72670000000b7373682d65643235" +
        "3531390000001d63686163686132302d706f6c7931333035406f70656e7373682e636f6d0000001d6368" +
        "6163686132302d706f6c7931333035406f70656e7373682e636f6d0000000000000000000000046e6f6e" +
        "65000000046e6f6e6500000000000000000000000000"
    /// The RFC 8032 §7.1 TEST 1 host key transcript's expected H and keys.
    static let pinnedHHex =
        "15c9cacbd36588f06a5189f221597e1e4d13f2f8c1fe9951f62b85afb957136d"
    static let pinnedKeyC2SHex =
        "205c0be510c7725ad0588a426feab9a7a35f56ef9377fb131b97f146f65ee8ea" +
        "4ce1f50dd2da22701781fe559f36f83216d87a049c88d00dbeb1ed81a1579a12"
    static let pinnedKeyS2CHex =
        "dea53158377f125f836602073e10929e33f1efb1112b4947f8b57c3e4c43c099" +
        "b3591a8bd466ddbffafe013263081f35813b9ba4277d52c72105cce6bb452a4f"
    static let pinnedHostSignatureHex =
        "c1b0702fd849722c5c05b28966e64bfc7ee94a2b2639f8f1cf1baab0ce47340" +
        "19e88a52a430d12a8ec94363a340e1dd6fbaa7fdb3bc61b104aba877ba5deca0d"

    /// The OpenSSH `PROTOCOL.chacha20poly1305` vector (`ssh_cipher.zig`).
    static let opensshKeyHex =
        "8bbff6855fc102338c373e73aac0c914" +
        "f076a905b2444a32eecaffeae22becc5" +
        "e9b7a7a5825a8249346ec1c28301cf39" +
        "4543fc7569887d76e168f37562ac0740"
    static let opensshPlainHex =
        "00000048065e00000000000000384c6f" +
        "72656d20697073756d20646f6c6f7220" +
        "73697420616d65742c20636f6e736563" +
        "7465747572206164697069736963696e" +
        "6720656c69744e43e804dc6c"
    static let opensshCiphertextHex =
        "2c3ecce4a5bc05895bf07a7ba956b6c6" +
        "8829ac7c83b780b7000ecde745afc705" +
        "bbc378ce03a280236b87b53bed583966" +
        "2302b164b6286a48cd1e097138e3cb90" +
        "9b8b2b829dd18d2a35ff82d9"
    static let opensshTagHex = "95349e855bf02c298ef775f2d1a7e8b8"

    private func hex(_ text: String) -> [UInt8] {
        guard let bytes = SSHFixtures.hex(text) else {
            fatalError("test hex literal is malformed")
        }
        return bytes
    }

    // MARK: - crypto primitives

    func testChaCha20DjbPinnedBlocks() throws {
        let zeroKey = [UInt8](repeating: 0, count: 32)
        let zeroNonce = [UInt8](repeating: 0, count: 8)
        XCTAssertEqual(
            SSHChaCha20.block(key: zeroKey, counter: 0, nonce: zeroNonce),
            hex("76b8e0ada0f13d90405d6ae55386bd28bdd219b8a08ded1aa836efcc8b770dc7" +
                "da41597c5157488d7724e03fb8d84a376a43b8f41518a11cc387b669b2ee6586")
        )
        XCTAssertEqual(
            SSHChaCha20.block(key: zeroKey, counter: 1, nonce: zeroNonce),
            hex("9f07e7be5551387a98ba977c732d080dcb0f29a048e3656912c6533e32ee7aed" +
                "29b721769ce64e43d57133b074d839d531ed1f28510afb45ace10a1f4b794d6f")
        )
        XCTAssertEqual(
            SSHChaCha20.block(key: zeroKey, counter: 2, nonce: zeroNonce),
            hex("2d09a0e663266ce1ae7ed1081968a0758e718e997bd362c6b0c34634a9a0b35d" +
                "012737681f7b5d0f281e3afde458bc1e73d2d313c9cf94c05ff3716240a248f2")
        )
        // xorStream is an involution with 64-bit counter continuity.
        let key = (0 ..< 32).map { UInt8(($0 * 5 + 1) & 0xff) }
        let nonce = hex("0908070605040302")
        let msg = (0 ..< 200).map { UInt8(($0 * 11 + 7) & 0xff) }
        let ct = SSHChaCha20.xorStream(input: msg, key: key, counter: 1, nonce: nonce)
        XCTAssertEqual(SSHChaCha20.xorStream(input: ct, key: key, counter: 1, nonce: nonce), msg)
    }

    func testPoly1305RFC8439Vector() throws {
        let key = hex("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b")
        let message = Array("Cryptographic Forum Research Group".utf8)
        XCTAssertEqual(
            SSHPoly1305.tag(message: message, key: key),
            hex("a8061dc1305136c6c22b8baf0c0127a9")
        )
    }

    func testOpenSSHCipherPinnedVector() throws {
        let key = hex(Self.opensshKeyHex)
        let plain = hex(Self.opensshPlainHex)
        let cipher = SSHOpenSSHCipher(key: key)
        let (ct, tag) = cipher.seal(plain, seq: 7)
        XCTAssertEqual(ct, hex(Self.opensshCiphertextHex))
        XCTAssertEqual(tag, hex(Self.opensshTagHex))
        XCTAssertEqual(cipher.decryptLength(Array(ct[0 ..< 4]), seq: 7), 0x48)
        XCTAssertEqual(cipher.open(ciphertext: ct, tag: tag, seq: 7), plain)

        var badTag = tag
        badTag[0] ^= 0x01
        XCTAssertNil(cipher.open(ciphertext: ct, tag: badTag, seq: 7))
        var badCt = ct
        badCt[ct.count - 1] ^= 0x01
        XCTAssertNil(cipher.open(ciphertext: badCt, tag: tag, seq: 7))
        // A peer that resets the sequence number cannot open the frame.
        XCTAssertNil(cipher.open(ciphertext: ct, tag: tag, seq: 6))

        // #1210 frame-alignment vector: the pinned OpenSSH frame's
        // packet_length (0x48 = 72) is a multiple of 8 while 4 + 72 = 76 is
        // not. ONLY the AEAD rule accepts it; the RFC 4253 plaintext rule
        // rejects the exact frame real sshd emits (and sends).
        XCTAssertEqual(SSHPacket.paddingLen(65, alignment: .aead), 6)
        let payload = try SSHPacket.decode(plain, alignment: .aead)
        XCTAssertEqual(payload.count, 65)
        XCTAssertEqual(payload, Array(plain[5 ..< 5 + 65]))
        XCTAssertThrowsError(try SSHPacket.decode(plain, alignment: .plaintext)) { error in
            XCTAssertEqual(error as? SSHPacketError, .badLength)
        }
    }

    func testOpenSSHCipherZeroKeyPinsSplitKeyConstruction() throws {
        // With an all-zero 64-byte key at seq 0, the Poly key derivation
        // yields the RFC 8439 A.1 zero block (`76b8e0ad…`), and the sealed
        // length/payload bytes match the Zig `ssh_cipher.zig` KAT.
        let cipher = SSHOpenSSHCipher(key: [UInt8](repeating: 0, count: 64))
        let (ct, tag) = cipher.seal(hex("0000000401aabbcc"), seq: 0)
        XCTAssertEqual(ct, hex("76b8e0a99ead5c72"))
        XCTAssertEqual(tag, hex("eff46ab54f68eb25915e3dc319448e9c"))
        XCTAssertEqual(cipher.decryptLength(Array(ct[0 ..< 4]), seq: 0), 4)
    }

    func testX25519AndMpintPinned() throws {
        let alice = try! Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data(hex(Self.aliceSecretHex))
        )
        let bob = try! Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data(hex(Self.bobSecretHex))
        )
        XCTAssertEqual(Array(alice.publicKey.rawRepresentation), hex(Self.alicePublicHex))
        XCTAssertEqual(Array(bob.publicKey.rawRepresentation), hex(Self.bobPublicHex))
        let shared = try! alice.sharedSecretFromKeyAgreement(with: bob.publicKey)
        let raw = shared.withUnsafeBytes { Array($0) }
        XCTAssertEqual(raw, hex(Self.sharedSecretHex))
        XCTAssertEqual(SSHKDF.mpint(raw), hex(Self.sharedMpintHex))
    }

    func testExchangeHashAndKDFPinned() throws {
        let hostSeed = hex(SSHFixtures.hostKeySeedHex)
        let hostKey = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(hostSeed))
        XCTAssertEqual(Array(hostKey.publicKey.rawRepresentation), hex(SSHFixtures.hostPublicKeyHex))

        // The deterministic transcript must reproduce `kex.zig`'s H from the
        // pinned inputs (I_C, I_S, RFC 7748 Q_C/Q_S/K, RFC 8032 TEST 1 host).
        let pinnedIS = hex(
            "14f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff0000002e637572766532353531392d7368613235" +
            "362c637572766532353531392d736861323536406c69627373682e6f72670000000b7373682d65643235" +
            "3531390000001d63686163686132302d706f6c7931333035406f70656e7373682e636f6d0000001d6368" +
            "6163686132302d706f6c7931333035406f70656e7373682e636f6d00000017686d61632d736861322d32" +
            "35362c686d61632d7368613100000017686d61632d736861322d3235362c686d61632d73686131000000" +
            "046e6f6e65000000046e6f6e6500000000000000000000000000"
        )
        let hPinned = SSHKDF.exchangeHash(
            vc: Array("SSH-2.0-VirelaiOS_1.0".utf8),
            vs: Array("SSH-2.0-OpenSSH_9.6".utf8),
            ic: hex(Self.pinnedICHex), isI: pinnedIS,
            ks: hex("0000000b7373682d6564323535313900000020" +
                SSHFixtures.hostPublicKeyHex),
            qc: hex(Self.alicePublicHex), qs: hex(Self.bobPublicHex),
            kMpint: hex(Self.sharedMpintHex)
        )
        XCTAssertEqual(hPinned, hex(Self.pinnedHHex))

        // CryptoKit's Ed25519 signs with a hedged (randomized) nonce: the
        // bytes differ per call (observed), so the tie is verification —
        // OpenSSL's pinned signature must verify over the pinned H, and our
        // own signature must too.
        XCTAssertTrue(hostKey.publicKey.isValidSignature(
            Data(hex(Self.pinnedHostSignatureHex)), for: Data(hPinned)
        ))
        let signature = try! hostKey.signature(for: Data(hPinned))
        XCTAssertTrue(hostKey.publicKey.isValidSignature(signature, for: Data(hPinned)))

        let keyC2S = SSHKDF.deriveKey(
            length: 64, kMpint: hex(Self.sharedMpintHex), h: hPinned,
            letter: 0x43, sessionId: hPinned
        )
        let keyS2C = SSHKDF.deriveKey(
            length: 64, kMpint: hex(Self.sharedMpintHex), h: hPinned,
            letter: 0x44, sessionId: hPinned
        )
        XCTAssertEqual(keyC2S, hex(Self.pinnedKeyC2SHex))
        XCTAssertEqual(keyS2C, hex(Self.pinnedKeyS2CHex))
    }

    // MARK: - the server state machine (scripted CryptoKit client)

    private func plainFrame(_ payload: [UInt8], pad: UInt8 = 0x33) -> [UInt8] {
        let padding = [UInt8](
            repeating: pad, count: SSHPacket.paddingLen(payload.count, alignment: .plaintext)
        )
        return try! SSHPacket.encode(payload: payload, pad: padding, alignment: .plaintext)
    }

    /// A CryptoKit client that speaks the OpenSSH cipher at the wire level.
    private final class ScriptedClient {
        private let send: SSHOpenSSHCipher
        private let recv: SSHOpenSSHCipher
        private var sendSeq: UInt64 = 3
        private var recvSeq: UInt64 = 3
        private var rx: [UInt8] = []
        private(set) var openFailed = false

        init(c2s: [UInt8], s2c: [UInt8]) {
            send = SSHOpenSSHCipher(key: c2s)
            recv = SSHOpenSSHCipher(key: s2c)
        }

        func packet(_ payload: [UInt8]) -> [UInt8] {
            let padding = [UInt8](
                repeating: 0x44, count: SSHPacket.paddingLen(payload.count, alignment: .aead)
            )
            let frame = try! SSHPacket.encode(
                payload: payload, pad: padding, alignment: .aead
            )
            let (ct, tag) = send.seal(frame, seq: sendSeq)
            sendSeq += 1
            return ct + tag
        }

        func feed(_ bytes: [UInt8]) -> [[UInt8]] {
            rx.append(contentsOf: bytes)
            var decoded: [[UInt8]] = []
            while rx.count >= 4 {
                let length = Int(recv.decryptLength(Array(rx[0 ..< 4]), seq: recvSeq))
                guard length >= 5 else { break }
                let ctLength = 4 + length
                let wire = ctLength + SSHOpenSSHCipher.tagLength
                guard rx.count >= wire else { break }
                // The tag covers enc_length || enc_payload.
                let ct = Array(rx[0 ..< ctLength])
                let tag = Array(rx[ctLength ..< wire])
                guard let plain = recv.open(ciphertext: ct, tag: tag, seq: recvSeq) else {
                    openFailed = true
                    return decoded
                }
                rx.removeFirst(wire)
                recvSeq += 1
                if let payload = try? SSHPacket.decode(plain, alignment: .aead) {
                    decoded.append(payload)
                }
            }
            return decoded
        }
    }

    private func serverConfig(
        tamper: Bool = false, rejectKey: Bool = false
    ) -> SSHServer.Config {
        SSHServer.Config(
            hostKeySeed: hex(SSHFixtures.hostKeySeedHex),
            acceptedUserKey: hex(SSHFixtures.userPublicKeyHex),
            marker: "VIRELAI-SSH5-OK\n",
            exitStatus: 0,
            tamperFirstServerTag: tamper,
            rejectPublicKey: rejectKey,
            cookieOverride: hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff"),
            ephemeralOverride: hex(Self.bobSecretHex)
        )
    }

    /// Parse a version line + the plaintext frames from server output.
    private func parsePlainOutput(_ bytes: [UInt8]) -> (String?, [[UInt8]]) {
        var frames: [[UInt8]] = []
        var versionLine: String?
        var i = 0
        if let nl = bytes.firstIndex(of: 0x0a), nl < 128 {
            var line = Array(bytes[0 ..< nl])
            if line.last == 0x0d { line.removeLast() }
            versionLine = String(bytes: line, encoding: .utf8)
            i = nl + 1
        }
        while i + 4 <= bytes.count {
            let length = (Int(bytes[i]) << 24) | (Int(bytes[i + 1]) << 16)
                | (Int(bytes[i + 2]) << 8) | Int(bytes[i + 3])
            let total = 4 + length
            guard total >= 5, i + total <= bytes.count else { break }
            if let payload = try? SSHPacket.decode(
                Array(bytes[i ..< i + total]), alignment: .plaintext
            ) {
                frames.append(payload)
            }
            i += total
        }
        return (versionLine, frames)
    }

    /// Drive a fresh server through KEX with the pinned determinism
    /// overrides; returns the server, the derived client keys, H, and the
    /// server's emitted KEXINIT.
    private func runKex(
        tamper: Bool = false, rejectKey: Bool = false
    ) throws -> (server: SSHServer, c2s: [UInt8], s2c: [UInt8], h: [UInt8], iS: [UInt8]) {
        let server = SSHServer(config: serverConfig(tamper: tamper, rejectKey: rejectKey))
        let clientVersion = "SSH-2.0-VirelaiOS_1.0"
        let iC = hex(Self.pinnedICHex)
        let qC = hex(Self.alicePublicHex)
        var ecdh = SSHWriter()
        ecdh.byte(SSHServer.msgKexEcdhInit)
        ecdh.string(qC)

        var input = Array((clientVersion + "\r\n").utf8)
        input += plainFrame(iC, pad: 0x21)
        input += plainFrame(ecdh.bytes, pad: 0x22)
        let (versionLine, frames) = parsePlainOutput(server.feed(input))
        XCTAssertEqual(versionLine, "SSH-2.0-VirelaiOS_1.0")
        XCTAssertEqual(frames.count, 3, "expected KEXINIT + ECDH_REPLY + NEWKEYS")
        let iS = frames[0]

        // The offered suite is exactly ADR 0025 D2.
        var kr = SSHReader(iS)
        XCTAssertEqual(try kr.byte(), SSHServer.msgKexInit)
        kr.pos += 16
        XCTAssertEqual(try kr.nameList(), ["curve25519-sha256", "curve25519-sha256@libssh.org"])
        XCTAssertEqual(try kr.nameList(), ["ssh-ed25519"])
        XCTAssertEqual(try kr.nameList(), ["chacha20-poly1305@openssh.com"])
        XCTAssertEqual(try kr.nameList(), ["chacha20-poly1305@openssh.com"])
        XCTAssertEqual(try kr.nameList(), [])
        XCTAssertEqual(try kr.nameList(), [])
        XCTAssertEqual(try kr.nameList(), ["none"])
        XCTAssertEqual(try kr.nameList(), ["none"])

        var rr = SSHReader(frames[1])
        XCTAssertEqual(try rr.byte(), SSHServer.msgKexEcdhReply)
        let kS = try rr.string()
        let qS = try rr.string()
        let sigBlob = try rr.string()
        XCTAssertEqual(frames[2], [SSHServer.msgNewKeys])

        // K is RFC 7748's pinned shared secret; H is recomputed independently.
        let alice = try! Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data(hex(Self.aliceSecretHex))
        )
        let bobPublic = try! Curve25519.KeyAgreement.PublicKey(rawRepresentation: Data(qS))
        let shared = try! alice.sharedSecretFromKeyAgreement(with: bobPublic)
        let kRaw = shared.withUnsafeBytes { Array($0) }
        XCTAssertEqual(kRaw, hex(Self.sharedSecretHex))
        let kMpint = SSHKDF.mpint(kRaw)
        let h = SSHKDF.exchangeHash(
            vc: Array(clientVersion.utf8), vs: Array("SSH-2.0-VirelaiOS_1.0".utf8),
            ic: iC, isI: iS, ks: kS, qc: qC, qs: qS, kMpint: kMpint
        )

        // The server's host-key signature verifies over our recomputed H.
        var sr = SSHReader(sigBlob)
        XCTAssertEqual(try sr.stringUTF8(), "ssh-ed25519")
        let signature = try sr.string()
        let hostPub = try! Curve25519.Signing.PublicKey(
            rawRepresentation: Data(hex(SSHFixtures.hostPublicKeyHex))
        )
        XCTAssertTrue(hostPub.isValidSignature(Data(signature), for: Data(h)))

        // Feed the client NEWKEYS; the server installs the cipher.
        _ = server.feed(plainFrame([SSHServer.msgNewKeys], pad: 0x23))
        XCTAssertEqual(server.phase, .encrypted)

        let c2s = SSHKDF.deriveKey(
            length: 64, kMpint: kMpint, h: h, letter: 0x43, sessionId: h
        )
        let s2c = SSHKDF.deriveKey(
            length: 64, kMpint: kMpint, h: h, letter: 0x44, sessionId: h
        )
        return (server, c2s, s2c, h, iS)
    }

    func testServerKexThenAuthThenExec() throws {
        let (server, c2s, s2c, h, _) = try runKex()
        let client = ScriptedClient(c2s: c2s, s2c: s2c)

        // SERVICE_REQUEST → SERVICE_ACCEPT.
        var service = SSHWriter()
        service.byte(SSHServer.msgServiceRequest)
        service.string("ssh-userauth")
        var responses = client.feed(server.feed(client.packet(service.bytes)))
        XCTAssertEqual(responses.count, 1)
        var sr = SSHReader(responses[0])
        XCTAssertEqual(try sr.byte(), SSHServer.msgServiceAccept)
        XCTAssertEqual(try sr.stringUTF8(), "ssh-userauth")

        // none probe → USERAUTH_FAILURE offering publickey.
        var none = SSHWriter()
        none.byte(SSHServer.msgUserauthRequest)
        none.string("alice")
        none.string("ssh-connection")
        none.string("none")
        responses = client.feed(server.feed(client.packet(none.bytes)))
        XCTAssertEqual(responses.count, 1)
        var nr = SSHReader(responses[0])
        XCTAssertEqual(try nr.byte(), SSHServer.msgUserauthFailure)
        XCTAssertEqual(try nr.nameList(), ["publickey"])
        XCTAssertFalse(try nr.bool())

        // publickey with the pinned RFC 8032 TEST 2 key → SUCCESS.
        let userSeed = hex(SSHFixtures.userKeySeedHex)
        let userKey = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(userSeed))
        let keyBlob = { () -> [UInt8] in
            var w = SSHWriter()
            w.string("ssh-ed25519")
            w.string(Array(userKey.publicKey.rawRepresentation))
            return w.bytes
        }()
        var signed = SSHWriter()
        signed.string(h)
        signed.byte(SSHServer.msgUserauthRequest)
        signed.string("alice")
        signed.string("ssh-connection")
        signed.string("publickey")
        signed.bool(true)
        signed.string("ssh-ed25519")
        signed.string(keyBlob)
        let signature = try! userKey.signature(for: Data(signed.bytes))
        var sigBlob = SSHWriter()
        sigBlob.string("ssh-ed25519")
        sigBlob.string(Array(signature))
        var auth = SSHWriter()
        auth.byte(SSHServer.msgUserauthRequest)
        auth.string("alice")
        auth.string("ssh-connection")
        auth.string("publickey")
        auth.bool(true)
        auth.string("ssh-ed25519")
        auth.string(keyBlob)
        auth.string(sigBlob.bytes)
        responses = client.feed(server.feed(client.packet(auth.bytes)))
        XCTAssertEqual(responses, [[SSHServer.msgUserauthSuccess]])

        // CHANNEL_OPEN session → OPEN_CONFIRMATION (server channel 42).
        var open = SSHWriter()
        open.byte(SSHServer.msgChannelOpen)
        open.string("session")
        open.uint32(0)
        open.uint32(1 << 17)
        open.uint32(32768)
        responses = client.feed(server.feed(client.packet(open.bytes)))
        XCTAssertEqual(responses.count, 1)
        var cr = SSHReader(responses[0])
        XCTAssertEqual(try cr.byte(), SSHServer.msgChannelOpenConfirmation)
        XCTAssertEqual(try cr.uint32(), 0) // recipient = our channel
        XCTAssertEqual(try cr.uint32(), 42) // server channel
        _ = try cr.uint32()
        _ = try cr.uint32()

        // exec → CHANNEL_SUCCESS, DATA(marker), exit-status, EOF, CLOSE.
        var exec = SSHWriter()
        exec.byte(SSHServer.msgChannelRequest)
        exec.uint32(42)
        exec.string("exec")
        exec.bool(true)
        exec.string("uname -a")
        responses = client.feed(server.feed(client.packet(exec.bytes)))
        XCTAssertEqual(responses.count, 5)
        var ok = SSHReader(responses[0])
        XCTAssertEqual(try ok.byte(), SSHServer.msgChannelSuccess)
        XCTAssertEqual(try ok.uint32(), 0)
        var data = SSHReader(responses[1])
        XCTAssertEqual(try data.byte(), SSHServer.msgChannelData)
        XCTAssertEqual(try data.uint32(), 0)
        XCTAssertEqual(try data.string(), Array("VIRELAI-SSH5-OK\n".utf8))
        var exitStatus = SSHReader(responses[2])
        XCTAssertEqual(try exitStatus.byte(), SSHServer.msgChannelRequest)
        XCTAssertEqual(try exitStatus.uint32(), 0)
        XCTAssertEqual(try exitStatus.stringUTF8(), "exit-status")
        XCTAssertFalse(try exitStatus.bool())
        XCTAssertEqual(try exitStatus.uint32(), 0)
        let eofExpected: [UInt8] = [SSHServer.msgChannelEof, 0, 0, 0, 0]
        let closeExpected: [UInt8] = [SSHServer.msgChannelClose, 0, 0, 0, 0]
        XCTAssertEqual(responses[3], eofExpected)
        XCTAssertEqual(responses[4], closeExpected)
        XCTAssertTrue(server.events.contains { $0.contains("publickey accepted") })
        XCTAssertTrue(server.events.contains { $0.contains("exec command=uname -a") })
    }

    func testAEADFramesAlignPacketLengthToBlockSize() throws {
        // #1210: after NEWKEYS the responder must pad packet_length alone
        // (OpenSSH `ssh_packet_send2_wrapped`), not `4 + packet_length` —
        // real sshd rejects the latter with
        // `padding error: need N block 8 mod M`.
        let (server, c2s, s2c, _, _) = try runKex()
        let client = ScriptedClient(c2s: c2s, s2c: s2c)
        var service = SSHWriter()
        service.byte(SSHServer.msgServiceRequest)
        service.string("ssh-userauth")

        // SERVICE_ACCEPT is the first encrypted server packet (send seq 3
        // after the KEXINIT/ECDH_REPLY/NEWKEYS plaintext frames).
        let serverBytes = server.feed(client.packet(service.bytes))
        let length = Int(
            SSHOpenSSHCipher(key: s2c).decryptLength(Array(serverBytes[0 ..< 4]), seq: 3)
        )
        XCTAssertEqual(length % SSHPacket.blockSize, 0, "AEAD packet_length is block-aligned")
        XCTAssertEqual(length, 24)
        XCTAssertNotEqual((SSHPacket.lenField + length) % SSHPacket.blockSize, 0)

        // The client's AEAD decoder reads the same frame back.
        let responses = client.feed(serverBytes)
        XCTAssertEqual(responses.count, 1)
        var sr = SSHReader(responses[0])
        XCTAssertEqual(try sr.byte(), SSHServer.msgServiceAccept)
        XCTAssertEqual(try sr.stringUTF8(), "ssh-userauth")
    }

    func testServerRejectsTamperedFirstServerTag() throws {
        let (server, c2s, s2c, _, _) = try runKex(tamper: true)
        let client = ScriptedClient(c2s: c2s, s2c: s2c)
        var service = SSHWriter()
        service.byte(SSHServer.msgServiceRequest)
        service.string("ssh-userauth")
        _ = client.feed(server.feed(client.packet(service.bytes)))
        // The SERVICE_ACCEPT tag was flipped: the client must fail closed.
        XCTAssertTrue(client.openFailed)
    }

    func testServerRejectsUnpinnedUserKey() throws {
        let (server, c2s, s2c, h, _) = try runKex(rejectKey: true)
        let client = ScriptedClient(c2s: c2s, s2c: s2c)
        var service = SSHWriter()
        service.byte(SSHServer.msgServiceRequest)
        service.string("ssh-userauth")
        var responses = client.feed(server.feed(client.packet(service.bytes)))
        XCTAssertEqual(responses.count, 1)
        var none = SSHWriter()
        none.byte(SSHServer.msgUserauthRequest)
        none.string("alice")
        none.string("ssh-connection")
        none.string("none")
        responses = client.feed(server.feed(client.packet(none.bytes)))
        XCTAssertEqual(responses.count, 1)

        let userKey = try! Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(hex(SSHFixtures.userKeySeedHex))
        )
        var keyBlob = SSHWriter()
        keyBlob.string("ssh-ed25519")
        keyBlob.string(Array(userKey.publicKey.rawRepresentation))
        var signed = SSHWriter()
        signed.string(h)
        signed.byte(SSHServer.msgUserauthRequest)
        signed.string("alice")
        signed.string("ssh-connection")
        signed.string("publickey")
        signed.bool(true)
        signed.string("ssh-ed25519")
        signed.string(keyBlob.bytes)
        let signature = try! userKey.signature(for: Data(signed.bytes))
        var sigBlob = SSHWriter()
        sigBlob.string("ssh-ed25519")
        sigBlob.string(Array(signature))
        var auth = SSHWriter()
        auth.byte(SSHServer.msgUserauthRequest)
        auth.string("alice")
        auth.string("ssh-connection")
        auth.string("publickey")
        auth.bool(true)
        auth.string("ssh-ed25519")
        auth.string(keyBlob.bytes)
        auth.string(sigBlob.bytes)
        responses = client.feed(server.feed(client.packet(auth.bytes)))
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses[0][0], SSHServer.msgUserauthFailure)
        XCTAssertTrue(server.events.contains { $0.contains("publickey rejected") })
    }

    func testWireReaderWriterFramingBounds() throws {
        var w = SSHWriter()
        w.byte(0x05)
        w.string("ssh-userauth")
        var r = SSHReader(w.bytes)
        XCTAssertEqual(try r.byte(), 5)
        XCTAssertEqual(try r.stringUTF8(), "ssh-userauth")
        XCTAssertEqual(r.remaining, 0)
        var short = SSHReader([0, 0, 0, 4, 0x61])
        XCTAssertThrowsError(try short.string())
        // Packet padding bounds mirror packet.zig: the plaintext rule pads
        // to `4 + packet_length` (11 for an empty payload), the AEAD rule
        // pads packet_length alone (7).
        XCTAssertEqual(SSHPacket.paddingLen(0, alignment: .plaintext), 11)
        XCTAssertEqual(SSHPacket.paddingLen(0, alignment: .aead), 7)
        XCTAssertThrowsError(try SSHPacket.decode([0, 0, 0, 4, 0], alignment: .plaintext))
        XCTAssertThrowsError(try SSHPacket.decode([0, 0, 0, 4, 0], alignment: .aead))
        // An AEAD-aligned frame that violates the plaintext rule (and vice
        // versa): 12 gives 4 + 12 = 16 (plaintext OK, AEAD 12 % 8 != 0);
        // 16 gives 4 + 16 = 20 (AEAD OK, plaintext 20 % 8 != 0).
        XCTAssertThrowsError(try SSHPacket.decode([0, 0, 0, 12, 4], alignment: .aead))
        XCTAssertThrowsError(try SSHPacket.decode([0, 0, 0, 16, 4], alignment: .plaintext))
    }

    func testFixturesDeriveThePinnedPublicKeys() throws {
        let host = try! Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(hex(SSHFixtures.hostKeySeedHex))
        )
        XCTAssertEqual(
            Array(host.publicKey.rawRepresentation), hex(SSHFixtures.hostPublicKeyHex)
        )
        let user = try! Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(hex(SSHFixtures.userKeySeedHex))
        )
        XCTAssertEqual(
            Array(user.publicKey.rawRepresentation), hex(SSHFixtures.userPublicKeyHex)
        )
        let wrong = try! Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(hex(SSHFixtures.wrongUserKeySeedHex))
        )
        XCTAssertEqual(
            Array(wrong.publicKey.rawRepresentation), hex(SSHFixtures.wrongUserPublicKeyHex)
        )
    }
}

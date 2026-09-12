// M51 SSH5 (#1172, ADR 0025 D2/D8): the minimal SSH-2 **server** the runner
// hosts behind `--net-tcp-respond <ip>:<port>:ssh`.
//
// This is the deterministic peer for the class-B endpoint gate, not a
// general sshd. It implements exactly the ADR 0025 D2 profile:
//
//   * version exchange (`SSH-2.0-VirelaiOS_1.0`);
//   * KEXINIT offering one suite — `curve25519-sha256` (+ the
//     `@libssh.org` alias), `ssh-ed25519`, `chacha20-poly1305@openssh.com`,
//     no MAC (AEAD), `none` compression;
//   * `curve25519-sha256` KEX (CryptoKit X25519) with a **pinned**
//     `ssh-ed25519` host key (CryptoKit Ed25519) signing the RFC 4253 §8
//     exchange hash H;
//   * the RFC 4253 §7.2 KDF, NEWKEYS, then the OpenSSH AEAD from
//     `SSHCrypto.swift` (hand-rolled djb ChaCha20 + Poly1305, pinned to
//     SSH-P2's vectors);
//   * `publickey` ssh-ed25519 userauth against a **pinned** client public
//     key (accept that key, reject every other key and every bad
//     signature);
//   * one `session` channel (`CHANNEL_OPEN` → `OPEN_CONFIRMATION`), one
//     `exec` request answered with a fixed marker + `exit-status`, then
//     EOF/CLOSE.
//
// The server is a pure byte-stream state machine: `feed(_:)` appends
// inbound TCP bytes and returns outbound bytes. The VMRunner integration
// paces the outbound bytes one ≤192-byte segment per guest ACK (the guest
// kernel RX is a single 192-byte slot with no reassembly).
//
// Negative-proof knobs (spec-only): `tamperFirstServerTag` corrupts the tag
// of the first encrypted server packet; `rejectPublicKey` refuses the
// pinned key; `cookieOverride`/`ephemeralOverride` make the KEX transcript
// deterministic for the class-A tests.
//
// No Virtualization imports, no I/O, no force unwraps on network data.

import CryptoKit
import Foundation

public final class SSHServer {
    public struct Config {
        /// The pinned `ssh-ed25519` host key (32-byte seed).
        public var hostKeySeed: [UInt8]
        /// The pinned client `ssh-ed25519` public key (32 bytes).
        public var acceptedUserKey: [UInt8]
        /// Accepted user name (nil accepts any user, logged).
        public var user: String?
        /// The fixed `exec` output.
        public var marker: String
        /// The fixed remote `exit-status`.
        public var exitStatus: UInt32
        /// NEGATIVE MODE: flip one bit of the first encrypted server tag.
        public var tamperFirstServerTag: Bool
        /// NEGATIVE MODE: refuse the pinned client key.
        public var rejectPublicKey: Bool
        /// Deterministic KEXINIT cookie (16 bytes) for tests.
        public var cookieOverride: [UInt8]?
        /// Deterministic ephemeral X25519 secret (32 bytes) for tests.
        public var ephemeralOverride: [UInt8]?
        /// Our identification line, without CR LF.
        public var versionLine: String

        public init(
            hostKeySeed: [UInt8],
            acceptedUserKey: [UInt8],
            user: String? = nil,
            marker: String = SSHFixtures.defaultMarker,
            exitStatus: UInt32 = 0,
            tamperFirstServerTag: Bool = false,
            rejectPublicKey: Bool = false,
            cookieOverride: [UInt8]? = nil,
            ephemeralOverride: [UInt8]? = nil,
            versionLine: String = "SSH-2.0-VirelaiOS_1.0"
        ) {
            self.hostKeySeed = hostKeySeed
            self.acceptedUserKey = acceptedUserKey
            self.user = user
            self.marker = marker
            self.exitStatus = exitStatus
            self.tamperFirstServerTag = tamperFirstServerTag
            self.rejectPublicKey = rejectPublicKey
            self.cookieOverride = cookieOverride
            self.ephemeralOverride = ephemeralOverride
            self.versionLine = versionLine
        }
    }

    public enum Phase: Equatable {
        case version
        case kex
        case encrypted
        case failed
        case closed
    }

    // SSH message numbers (RFC 4253 §12, RFC 4252 §6, RFC 4254 §9).
    public static let msgDisconnect: UInt8 = 1
    public static let msgIgnore: UInt8 = 2
    public static let msgDebug: UInt8 = 4
    public static let msgServiceRequest: UInt8 = 5
    public static let msgServiceAccept: UInt8 = 6
    public static let msgKexInit: UInt8 = 20
    public static let msgNewKeys: UInt8 = 21
    public static let msgKexEcdhInit: UInt8 = 30
    public static let msgKexEcdhReply: UInt8 = 31
    public static let msgUserauthRequest: UInt8 = 50
    public static let msgUserauthFailure: UInt8 = 51
    public static let msgUserauthSuccess: UInt8 = 52
    public static let msgChannelOpen: UInt8 = 90
    public static let msgChannelOpenConfirmation: UInt8 = 91
    public static let msgChannelWindowAdjust: UInt8 = 93
    public static let msgChannelData: UInt8 = 94
    public static let msgChannelEof: UInt8 = 96
    public static let msgChannelClose: UInt8 = 97
    public static let msgChannelRequest: UInt8 = 98
    public static let msgChannelSuccess: UInt8 = 99
    public static let msgChannelFailure: UInt8 = 100

    public static let serviceUsereauth = "ssh-userauth"
    public static let serviceConnection = "ssh-connection"
    public static let methodNone = "none"
    public static let methodPublickey = "publickey"
    public static let algorithmEd25519 = "ssh-ed25519"
    public static let sessionType = "session"
    public static let requestExec = "exec"
    public static let requestExitStatus = "exit-status"

    public static let localWindow: UInt32 = 1 << 17
    public static let localMaxPacket: UInt32 = 32768

    private let config: Config
    private let hostKey: Curve25519.Signing.PrivateKey
    public let hostPublicKey: [UInt8]

    public private(set) var phase: Phase = .version
    /// Every protocol-progress line (the runner prints these; tests assert).
    public private(set) var events: [String] = []
    /// Optional live log sink (the runner prints `SSH-SRV: <line>`).
    public var logSink: ((String) -> Void)?

    private var input: [UInt8] = []
    private var out: [UInt8] = []

    private var bannerLines = 0
    private var clientVersion = ""
    private var iC: [UInt8] = []
    private var iS: [UInt8] = []
    private var qC: [UInt8] = []
    private var qS: [UInt8] = []
    private var sessionId: [UInt8] = []
    private var sendCipher: SSHOpenSSHCipher?
    private var recvCipher: SSHOpenSSHCipher?
    private var sendSeq: UInt64 = 0
    private var recvSeq: UInt64 = 0
    private var tamperPending = false

    private var clientChannel: UInt32 = 0
    private var serverChannel: UInt32 = 42
    private var remoteWindow: UInt32 = 0
    private var remoteMaxPacket: UInt32 = 0
    private var execRan = false

    public init(config: Config) {
        self.config = config
        let key = try! Curve25519.Signing.PrivateKey(
            rawRepresentation: Data(config.hostKeySeed)
        )
        hostKey = key
        hostPublicKey = Array(key.publicKey.rawRepresentation)
        tamperPending = config.tamperFirstServerTag
    }

    /// Append inbound bytes and return the outbound bytes produced so far.
    public func feed(_ data: [UInt8]) -> [UInt8] {
        guard phase != .failed, phase != .closed else { return [] }
        input.append(contentsOf: data)
        process()
        let result = out
        out.removeAll(keepingCapacity: true)
        return result
    }

    public var isClosed: Bool { phase == .closed || phase == .failed }

    // MARK: - logging

    private func log(_ line: String) {
        events.append(line)
        logSink?(line)
    }

    // MARK: - the state machine

    private func process() {
        while !isClosed {
            switch phase {
            case .version:
                guard readVersionLine() else { return }
            case .kex:
                guard let payload = nextPlainPacket() else { return }
                handleKexPacket(payload)
            case .encrypted:
                guard let payload = nextEncryptedPacket() else { return }
                handleEncrypted(payload)
            case .failed, .closed:
                return
            }
        }
    }

    /// Read one CR-LF-terminated identification line (banners skipped,
    /// bounded), reply with our version + KEXINIT, and enter `.kex`.
    private func readVersionLine() -> Bool {
        while true {
            guard let nl = input.firstIndex(of: 0x0a) else { return false }
            let raw = Array(input[0 ..< nl])
            input.removeFirst(nl + 1)
            var line = raw
            if line.last == 0x0d { line.removeLast() }
            if line.count < 4 || Array(line[0 ..< 4]) != Array("SSH-".utf8) {
                bannerLines += 1
                if bannerLines > 64 { fail("too many banner lines") }
                continue
            }
            guard let text = String(bytes: line, encoding: .utf8),
                  text.hasPrefix("SSH-2.0-") || text.hasPrefix("SSH-1.99-")
            else {
                fail("bad identification line")
                return false
            }
            clientVersion = text
            log("version received: \(text)")

            var greeting = Array(config.versionLine.utf8)
            greeting.append(contentsOf: [0x0d, 0x0a])
            out.append(contentsOf: greeting)

            var w = SSHWriter()
            w.byte(Self.msgKexInit)
            let cookie = config.cookieOverride ?? randomBytes(16)
            w.raw(cookie)
            w.nameList(["curve25519-sha256", "curve25519-sha256@libssh.org"])
            w.nameList(["ssh-ed25519"])
            w.nameList(["chacha20-poly1305@openssh.com"])
            w.nameList(["chacha20-poly1305@openssh.com"])
            w.nameList([]) // MAC c2s (AEAD: none)
            w.nameList([]) // MAC s2c
            w.nameList(["none"])
            w.nameList(["none"])
            w.nameList([]) // language c2s
            w.nameList([]) // language s2c
            w.bool(false)
            w.uint32(0)
            iS = w.bytes
            sendPacket(iS)
            log("kexinit sent (curve25519-sha256/ssh-ed25519/chacha20-poly1305@openssh.com)")
            phase = .kex
            return true
        }
    }

    private func nextPlainPacket() -> [UInt8]? {
        guard input.count >= 4 else { return nil }
        let packetLength = (Int(input[0]) << 24) | (Int(input[1]) << 16)
            | (Int(input[2]) << 8) | Int(input[3])
        guard packetLength <= SSHPacket.maxTotal - 4 else {
            fail("overlong plaintext packet")
            return nil
        }
        guard packetLength >= 5 else {
            fail("short plaintext packet")
            return nil
        }
        let total = 4 + packetLength
        guard input.count >= total else { return nil }
        let frame = Array(input[0 ..< total])
        input.removeFirst(total)
        do {
            let payload = try SSHPacket.decode(frame)
            recvSeq += 1
            return payload
        } catch {
            fail("malformed plaintext frame")
            return nil
        }
    }

    private func handleKexPacket(_ payload: [UInt8]) {
        guard let kind = payload.first else { return }
        switch kind {
        case Self.msgKexInit:
            guard parseClientKexInit(payload) else { return }
            log("kexinit received (suite negotiated)")
        case Self.msgKexEcdhInit:
            guard payload.count >= 1 else { return }
            var r = SSHReader(payload)
            guard (try? r.byte()) == Self.msgKexEcdhInit else { return }
            guard let q = try? r.string(), q.count == 32, r.remaining == 0 else {
                fail("malformed KEX_ECDH_INIT")
                return
            }
            qC = q
            performKex()
        case Self.msgNewKeys:
            guard payload == [Self.msgNewKeys] else {
                fail("malformed NEWKEYS")
                return
            }
            log("newkeys received; cipher installed")
            phase = .encrypted
        case Self.msgDisconnect:
            log("client disconnect during kex")
            phase = .closed
        case Self.msgIgnore, Self.msgDebug:
            break
        default:
            fail("unexpected kex message \(kind)")
        }
    }

    private func parseClientKexInit(_ payload: [UInt8]) -> Bool {
        var r = SSHReader(payload)
        guard (try? r.byte()) == Self.msgKexInit else { return false }
        guard r.remaining >= 16 else { fail("short KEXINIT"); return false }
        r.pos += 16 // cookie (only the echo in H matters, and the client owns I_C)
        guard let kex = try? r.nameList(),
              let hostKeyList = try? r.nameList(),
              let encC2S = try? r.nameList(),
              let encS2C = try? r.nameList(),
              let _ = try? r.nameList(), // mac c2s
              let _ = try? r.nameList(), // mac s2c
              let compC2S = try? r.nameList(),
              let compS2C = try? r.nameList(),
              let _ = try? r.nameList(), // lang c2s
              let _ = try? r.nameList(), // lang s2c
              let follows = try? r.bool(),
              let reserved = try? r.uint32(),
              r.remaining == 0, reserved == 0
        else {
            fail("malformed KEXINIT")
            return false
        }
        _ = follows // we never send a guess; first_kex_packet_follows only binds the guesser
        let kexOK = kex.contains("curve25519-sha256") || kex.contains("curve25519-sha256@libssh.org")
        let hostOK = hostKeyList.contains("ssh-ed25519")
        let cipherOK = encC2S.contains("chacha20-poly1305@openssh.com")
            && encS2C.contains("chacha20-poly1305@openssh.com")
        let compOK = compC2S.contains("none") && compS2C.contains("none")
        guard kexOK, hostOK, cipherOK, compOK else {
            fail("no common algorithm in KEXINIT (kex=\(kexOK) host=\(hostOK) cipher=\(cipherOK) comp=\(compOK))")
            return false
        }
        iC = payload
        return true
    }

    private func performKex() {
        let ephemeral = config.ephemeralOverride ?? randomBytes(32)
        guard let eph = try? Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: Data(ephemeral)
        ) else {
            fail("bad ephemeral secret")
            return
        }
        qS = Array(eph.publicKey.rawRepresentation)
        guard let qcKey = try? Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: Data(qC)
        ) else {
            fail("bad client ephemeral key")
            return
        }
        guard let shared = try? eph.sharedSecretFromKeyAgreement(with: qcKey) else {
            fail("ECDH failed")
            return
        }
        let kRaw = shared.withUnsafeBytes { Array($0) }
        if kRaw.allSatisfy({ $0 == 0 }) {
            fail("all-zero shared secret")
            return
        }
        let kMpint = SSHKDF.mpint(kRaw)

        var ks = SSHWriter()
        ks.string(Self.algorithmEd25519)
        ks.string(hostPublicKey)
        let kS = ks.bytes

        let h = SSHKDF.exchangeHash(
            vc: Array(clientVersion.utf8), vs: Array(config.versionLine.utf8),
            ic: iC, isI: iS, ks: kS, qc: qC, qs: qS, kMpint: kMpint
        )
        guard let signature = try? hostKey.signature(for: Data(h)) else {
            fail("host-key signature failed")
            return
        }
        var sigBlobW = SSHWriter()
        sigBlobW.string(Self.algorithmEd25519)
        sigBlobW.string(Array(signature))

        var reply = SSHWriter()
        reply.byte(Self.msgKexEcdhReply)
        reply.string(kS)
        reply.string(qS)
        reply.string(sigBlobW.bytes)
        sendPacket(reply.bytes)
        sendPacket([Self.msgNewKeys])

        sessionId = h
        let keyC2S = SSHKDF.deriveKey(
            length: SSHOpenSSHCipher.keyLength, kMpint: kMpint, h: h,
            letter: Character("C").asciiValue!, sessionId: h
        )
        let keyS2C = SSHKDF.deriveKey(
            length: SSHOpenSSHCipher.keyLength, kMpint: kMpint, h: h,
            letter: Character("D").asciiValue!, sessionId: h
        )
        recvCipher = SSHOpenSSHCipher(key: keyC2S)
        sendCipher = SSHOpenSSHCipher(key: keyS2C)
        log("ecdh reply sent; newkeys sent; cipher keys derived")
    }

    private func nextEncryptedPacket() -> [UInt8]? {
        guard let cipher = recvCipher else { return nil }
        guard input.count >= 4 else { return nil }
        let length = Int(cipher.decryptLength(Array(input[0 ..< 4]), seq: recvSeq))
        guard length >= 5, length <= SSHPacket.maxTotal - 4 else {
            fail("bad encrypted length")
            return nil
        }
        let ctLength = 4 + length
        let wire = ctLength + SSHOpenSSHCipher.tagLength
        guard input.count >= wire else { return nil }
        // The tag authenticates the WHOLE ciphertext: enc_length || enc_payload
        // (the OpenSSH Encrypt-then-MAC over both fields).
        let ct = Array(input[0 ..< ctLength])
        let tag = Array(input[ctLength ..< wire])
        guard let plain = cipher.open(ciphertext: ct, tag: tag, seq: recvSeq) else {
            log("mac-failure seq=\(recvSeq) — disconnecting (fail closed)")
            phase = .failed
            return nil
        }
        input.removeFirst(wire)
        recvSeq += 1
        do {
            return try SSHPacket.decode(plain)
        } catch {
            fail("malformed encrypted frame")
            return nil
        }
    }

    private func handleEncrypted(_ payload: [UInt8]) {
        guard let kind = payload.first else { return }
        switch kind {
        case Self.msgIgnore, Self.msgDebug:
            break
        case Self.msgDisconnect:
            log("client disconnect")
            phase = .closed
        case Self.msgServiceRequest:
            handleServiceRequest(payload)
        case Self.msgUserauthRequest:
            handleUserauthRequest(payload)
        case Self.msgChannelOpen:
            handleChannelOpen(payload)
        case Self.msgChannelRequest:
            handleChannelRequest(payload)
        case Self.msgChannelWindowAdjust:
            var r = SSHReader(payload)
            _ = try? r.byte()
            if let _ = try? r.uint32(), let add = try? r.uint32() {
                remoteWindow &+= add
            }
        case Self.msgChannelEof, Self.msgChannelClose:
            log("channel eof/close from client")
            phase = .closed
        default:
            log("unhandled message \(kind)")
        }
    }

    private func handleServiceRequest(_ payload: [UInt8]) {
        var r = SSHReader(payload)
        _ = try? r.byte()
        guard let name = try? r.stringUTF8(), r.remaining == 0 else {
            fail("malformed service request")
            return
        }
        guard name == Self.serviceUsereauth else {
            fail("unsupported service \(name)")
            return
        }
        var w = SSHWriter()
        w.byte(Self.msgServiceAccept)
        w.string(Self.serviceUsereauth)
        sendPacket(w.bytes)
        log("service-accept ssh-userauth")
    }

    private func handleUserauthRequest(_ payload: [UInt8]) {
        var r = SSHReader(payload)
        _ = try? r.byte()
        guard let user = try? r.stringUTF8(),
              let service = try? r.stringUTF8(),
              let method = try? r.stringUTF8()
        else {
            fail("malformed userauth request")
            return
        }
        if method == Self.methodNone {
            log("userauth none requested; offering publickey")
            sendUserauthFailure()
            return
        }
        guard method == Self.methodPublickey, service == Self.serviceConnection else {
            fail("unsupported userauth method \(method)")
            return
        }
        guard let hasSignature = try? r.bool(),
              let algorithm = try? r.stringUTF8(),
              let keyBlob = try? r.string()
        else {
            fail("malformed publickey request")
            return
        }
        let sigOffset = r.pos
        let keyMatches = algorithm == Self.algorithmEd25519
            && SSHOpenSSHCipher.constantTimeEquals(keyBlob, expectedKeyBlob())
        if !keyMatches {
            log("publickey rejected: key does not match the pinned client key")
            sendUserauthFailure()
            return
        }
        if config.rejectPublicKey {
            log("publickey rejected: negative-mode policy")
            sendUserauthFailure()
            return
        }
        if config.user != nil, config.user != user {
            log("publickey rejected: user \(user) not accepted")
            sendUserauthFailure()
            return
        }
        guard hasSignature else {
            // The query form (no signature) is not supported: the gate
            // client always sends the signed form.
            log("publickey rejected: no signature")
            sendUserauthFailure()
            return
        }
        guard let sigBlob = try? r.string(), r.remaining == 0 else {
            fail("malformed publickey signature")
            return
        }
        var sr = SSHReader(sigBlob)
        guard let sigAlg = try? sr.stringUTF8(),
              let signature = try? sr.string(), sr.remaining == 0,
              sigAlg == Self.algorithmEd25519
        else {
            log("publickey rejected: malformed signature blob")
            sendUserauthFailure()
            return
        }
        var signed = SSHWriter()
        signed.string(sessionId)
        signed.raw(Array(payload[0 ..< sigOffset]))
        guard let clientKey = try? Curve25519.Signing.PublicKey(
            rawRepresentation: Data(config.acceptedUserKey)
        ), clientKey.isValidSignature(Data(signature), for: Data(signed.bytes)) else {
            log("publickey rejected: signature does not verify")
            sendUserauthFailure()
            return
        }
        sendPacket([Self.msgUserauthSuccess])
        log("publickey accepted user=\(user) key=ssh-ed25519")
    }

    private func expectedKeyBlob() -> [UInt8] {
        var w = SSHWriter()
        w.string(Self.algorithmEd25519)
        w.string(config.acceptedUserKey)
        return w.bytes
    }

    private func sendUserauthFailure() {
        var w = SSHWriter()
        w.byte(Self.msgUserauthFailure)
        w.nameList([Self.methodPublickey])
        w.bool(false)
        sendPacket(w.bytes)
    }

    private func handleChannelOpen(_ payload: [UInt8]) {
        var r = SSHReader(payload)
        _ = try? r.byte()
        guard let type = try? r.stringUTF8(),
              let sender = try? r.uint32(),
              let window = try? r.uint32(),
              let maxPacket = try? r.uint32(),
              r.remaining == 0
        else {
            fail("malformed channel open")
            return
        }
        guard type == Self.sessionType, maxPacket > 0 else {
            fail("unsupported channel type \(type)")
            return
        }
        clientChannel = sender
        remoteWindow = window
        remoteMaxPacket = maxPacket
        var w = SSHWriter()
        w.byte(Self.msgChannelOpenConfirmation)
        w.uint32(sender)
        w.uint32(serverChannel)
        w.uint32(Self.localWindow)
        w.uint32(Self.localMaxPacket)
        sendPacket(w.bytes)
        log("channel open session confirmed (remote id \(sender))")
    }

    private func handleChannelRequest(_ payload: [UInt8]) {
        var r = SSHReader(payload)
        _ = try? r.byte()
        guard let recipient = try? r.uint32(), recipient == serverChannel,
              let request = try? r.stringUTF8(),
              let wantReply = try? r.bool()
        else {
            fail("malformed channel request")
            return
        }
        if request == Self.requestExec {
            guard let command = try? r.stringUTF8(), r.remaining == 0 else {
                fail("malformed exec request")
                return
            }
            guard !execRan else {
                fail("second exec request")
                return
            }
            execRan = true
            if wantReply {
                var w = SSHWriter()
                w.byte(Self.msgChannelSuccess)
                w.uint32(clientChannel)
                sendPacket(w.bytes)
            }
            sendChannelData(Array(config.marker.utf8))
            sendExitStatus(config.exitStatus)
            sendPacket(channelHeader(Self.msgChannelEof))
            sendPacket(channelHeader(Self.msgChannelClose))
            log("exec command=\(command) -> marker \(config.marker.count) bytes, exit-status \(config.exitStatus)")
            return
        }
        if wantReply {
            var w = SSHWriter()
            w.byte(Self.msgChannelFailure)
            w.uint32(clientChannel)
            sendPacket(w.bytes)
        }
        log("channel request \(request) refused")
    }

    private func channelHeader(_ kind: UInt8) -> [UInt8] {
        var w = SSHWriter()
        w.byte(kind)
        w.uint32(clientChannel)
        return w.bytes
    }

    private func sendChannelData(_ data: [UInt8]) {
        var off = 0
        while off < data.count {
            let room = min(
                data.count - off,
                min(Int(remoteWindow), min(Int(remoteMaxPacket), 32768))
            )
            guard room > 0 else { break }
            var w = SSHWriter()
            w.byte(Self.msgChannelData)
            w.uint32(clientChannel)
            w.string(Array(data[off ..< off + room]))
            sendPacket(w.bytes)
            remoteWindow -= UInt32(room)
            off += room
        }
    }

    private func sendExitStatus(_ status: UInt32) {
        var w = SSHWriter()
        w.byte(Self.msgChannelRequest)
        w.uint32(clientChannel)
        w.string(Self.requestExitStatus)
        w.bool(false)
        w.uint32(status)
        sendPacket(w.bytes)
    }

    // MARK: - framing

    private func sendPacket(_ payload: [UInt8]) {
        guard let frame = try? SSHPacket.encode(payload: payload, pad: deterministicPad(payload.count)) else {
            fail("could not frame outbound packet")
            return
        }
        if let cipher = sendCipher {
            var (ciphertext, tag) = cipher.seal(frame, seq: sendSeq)
            if tamperPending {
                tag[0] ^= 0x01
                tamperPending = false
                log("tamper: flipped the first encrypted packet tag (negative mode)")
            }
            out.append(contentsOf: ciphertext)
            out.append(contentsOf: tag)
        } else {
            out.append(contentsOf: frame)
        }
        sendSeq += 1
    }

    private func deterministicPad(_ payloadLen: Int) -> [UInt8] {
        let n = SSHPacket.paddingLen(payloadLen)
        return (0 ..< n).map { UInt8(0x5a ^ (($0 * 7) & 0xff)) }
    }

    private func randomBytes(_ n: Int) -> [UInt8] {
        var rng = SystemRandomNumberGenerator()
        return (0 ..< n).map { _ in UInt8.random(in: 0 ... 255, using: &rng) }
    }

    private func fail(_ reason: String) {
        log("protocol failure: \(reason)")
        phase = .failed
    }
}

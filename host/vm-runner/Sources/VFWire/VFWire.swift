// VFWire.swift — pure wire-format encode/decode for the M34 host file
// channel (issues #735/#736): the guest userland filesystem is a macOS
// folder served over custom-virtio queue 5.
//
// ZERO Virtualization imports — this module must build and test on any
// host, so `swift test` runs without a VM. Every byte layout here is
// pinned by the checked-in fixtures (tests/vf-*.bin) and mirrored by the
// guest kernel module kernel/src/virtio_file.zig.
//
// Wire:
//   request  [op u8][flags u8][len u16le][payload]
//   reply    [status u8][dlen u16le][data]
// Ops: VF_PROBE 0x00 (transport-only — the reply is the RAW 32,768-byte
// pattern, no frame), LIST 0x01, READ 0x02 ([path][u64le offset]), STAT
// 0x03. Status: 0 ok, 1 not found, 2 is a directory, 3 truncated, 4 host
// error.

import Foundation

public enum VFWire {
    // Ops
    public static let opProbe: UInt8 = 0x00
    public static let opList: UInt8 = 0x01
    public static let opRead: UInt8 = 0x02
    public static let opStat: UInt8 = 0x03

    // Reply statuses
    public static let stOk: UInt8 = 0
    public static let stNotFound: UInt8 = 1
    public static let stIsDir: UInt8 = 2
    public static let stTruncated: UInt8 = 3
    public static let stHostError: UInt8 = 4

    // Frame constants (mirror kernel/src/virtio_file.zig)
    public static let requestHdrLen = 4 // [op][flags][len u16le]
    public static let replyHdrLen = 3 // [status][dlen u16le]
    public static let pathMax = 255
    public static let replyCap = 32768 // full-cap device-write reply (HF1)
    public static let listMaxEntries = 128
    public static let entryRowLen = 40 // [name 31][type u8][size u64le]
    public static let readOffsetLen = 8

    public static let dirTypeFile: UInt8 = 0
    public static let dirTypeDir: UInt8 = 1

    // The VF_PROBE reply pattern (both sides compute it without storing
    // 32 KiB): pattern[i] = (i & 0xff) ^ ((i >> 8) & 0xff). The full
    // 32,768 bytes are the checked-in fixture tests/vf-pattern-32k.bin
    // (sha256-pinned by the class-A gate).
    public static func pattern(_ i: Int) -> UInt8 {
        UInt8((i & 0xff) ^ ((i >> 8) & 0xff))
    }

    /// Encode a request: [op][flags][len u16le][payload]. nil when the
    /// payload exceeds the u16 length field.
    public static func encodeRequest(op: UInt8, flags: UInt8, payload: [UInt8]) -> [UInt8]? {
        guard payload.count <= 0xffff else { return nil }
        var out = [UInt8](repeating: 0, count: requestHdrLen + payload.count)
        out[0] = op
        out[1] = flags
        out[2] = UInt8(payload.count & 0xff)
        out[3] = UInt8((payload.count >> 8) & 0xff)
        out.replaceSubrange(requestHdrLen..., with: payload)
        return out
    }

    /// A decoded reply: status, declared data length, and the data —
    /// CLAMPED to the buffer (never OOB); `clamped` reports truncation.
    public struct Reply {
        public let status: UInt8
        public let dlen: UInt16
        public let data: [UInt8]
        public let clamped: Bool
    }

    /// Decode a reply buffer: [status u8][dlen u16le][data]. A buffer
    /// shorter than the header decodes as host_error with empty data.
    public static func decodeReply(_ buf: [UInt8]) -> Reply {
        guard buf.count >= replyHdrLen else {
            return Reply(status: stHostError, dlen: 0, data: [], clamped: true)
        }
        let status = buf[0]
        let dlen = UInt16(buf[1]) | (UInt16(buf[2]) << 8)
        let avail = buf.count - replyHdrLen
        let take = min(Int(dlen), avail)
        return Reply(
            status: status,
            dlen: dlen,
            data: Array(buf[replyHdrLen..<(replyHdrLen + take)]),
            clamped: take < Int(dlen)
        )
    }

    /// Encode a reply: [status u8][dlen u16le][data] (dlen = data count).
    public static func encodeReply(status: UInt8, data: [UInt8]) -> [UInt8] {
        precondition(data.count <= 0xffff)
        var out = [UInt8](repeating: 0, count: replyHdrLen + data.count)
        out[0] = status
        out[1] = UInt8(data.count & 0xff)
        out[2] = UInt8((data.count >> 8) & 0xff)
        out.replaceSubrange(replyHdrLen..., with: data)
        return out
    }

    /// One LIST row: [name 31 B NUL-padded][type u8][size u64le].
    public struct DirEntry {
        public let name: String
        public let type: UInt8
        public let size: UInt64

        public init(name: String, type: UInt8, size: UInt64) {
            self.name = name
            self.type = type
            self.size = size
        }
    }

    public static func encodeEntryRow(_ e: DirEntry) -> [UInt8] {
        var row = [UInt8](repeating: 0, count: entryRowLen)
        let nameBytes = Array(e.name.utf8.prefix(31))
        row.replaceSubrange(0..<nameBytes.count, with: nameBytes)
        row[31] = e.type
        var size = e.size
        for i in 0..<8 {
            row[32 + i] = UInt8(size & 0xff)
            size >>= 8
        }
        return row
    }

    /// Build a READ payload: [path][u64le offset]. nil for over-long paths.
    public static func buildReadPayload(path: String, offset: UInt64) -> [UInt8]? {
        let p = Array(path.utf8)
        guard p.count <= pathMax else { return nil }
        var out = p
        var off = offset
        for _ in 0..<8 {
            out.append(UInt8(off & 0xff))
            off >>= 8
        }
        return out
    }

    /// RFC-1071 one's-complement checksum (big-endian word semantics,
    /// mirroring the guest's checksum1071 and the gate's python cross-
    /// check). u64 accumulator: 32 KiB of pattern sums ~33M before the
    /// fold — safe, but kept u64 for parity with the guest.
    public static func checksum1071(_ data: [UInt8]) -> UInt16 {
        var sum: UInt64 = 0
        var i = 0
        while i + 1 < data.count {
            sum += (UInt64(data[i]) << 8) | UInt64(data[i + 1])
            i += 2
        }
        if i < data.count { sum += UInt64(data[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return UInt16(~sum & 0xffff)
    }

    // ------------------------------------------------------------------
    // Path defense (HF1 scope): resolve a guest path INSIDE the share
    // root. The protocol is stateless and the share is a plain macOS
    // folder, so the attack surface is the path: reject absolute paths,
    // `..` traversal, and symlink escapes.
    // ------------------------------------------------------------------

    /// Resolve `path` (relative, '/' separated; "" = the root) under
    /// `root`. Returns nil when the path is absolute, contains `..`, or
    /// would escape the share root via a symlink after standardization.
    public static func resolveSubpath(root: URL, path: String) -> URL? {
        // An absolute path is refused outright (the protocol is
        // root-relative; a leading '/' is never valid).
        if path.hasPrefix("/") { return nil }
        let rootURL = root.resolvingSymlinksInPath()
        let rootPath = rootURL.path
        var url = rootURL
        let comps = path.split(separator: "/", omittingEmptySubsequences: true)
        for c in comps {
            if c == ".." { return nil }
            if c == "." { continue }
            guard !c.isEmpty else { continue }
            // A single component must not smuggle separators or escapes.
            if c.contains("\\") { return nil }
            url = url.appendingPathComponent(String(c))
        }
        // Symlink-escape check: the fully symlink-RESOLVED path must still
        // live under the share root (standardizedFileURL is syntactic
        // only — it does not chase symlinks).
        let resolved = url.resolvingSymlinksInPath().path
        guard resolved == rootPath || resolved.hasPrefix(rootPath + "/") else { return nil }
        return URL(fileURLWithPath: resolved)
    }
}

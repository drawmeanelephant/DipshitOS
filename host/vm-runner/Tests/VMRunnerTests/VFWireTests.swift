// VFWireTests.swift — S1–S4 for M34 HF1 (issue #735): byte-parity of the
// wire-format encode/decode against the checked-in fixtures (the SAME
// bytes the guest Zig module pins), plus the path-defense policy. Runs
// with `swift test` — no VM, no Virtualization (VFWire is pure).
import XCTest
@testable import VFWire

final class VFWireTests: XCTestCase {
    /// The repo's checked-in fixture dir: tests/ (four levels up from this
    /// test file, which lives at host/vm-runner/Tests/VMRunnerTests/).
    private var fixturesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/VMRunnerTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // vm-runner
            .deletingLastPathComponent() // host
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("tests", isDirectory: true)
    }

    private func fixture(_ name: String) throws -> [UInt8] {
        let url = fixturesDir.appendingPathComponent(name)
        return [UInt8](try Data(contentsOf: url))
    }

    /// S1 — generator parity: the pattern generator reproduces the shared
    /// 32 KiB fixture byte-for-byte (the class-A gate sha256-pins the
    /// file; the guest Zig generator locks the same bytes).
    func testS1PatternGeneratorParity() throws {
        let fixture = try fixture("vf-pattern-32k.bin")
        XCTAssertEqual(fixture.count, VFWire.replyCap, "fixture must be the full 32 KiB")
        for i in 0..<fixture.count {
            XCTAssertEqual(fixture[i], VFWire.pattern(i), "pattern mismatch at index \(i)")
        }
    }

    /// S2 — request encode parity: encodeRequest + buildReadPayload
    /// reproduce vf-req-read.bin exactly (the guest's encoder locks the
    /// same bytes).
    func testS2RequestEncodeParity() throws {
        let expected = try fixture("vf-req-read.bin")
        let payload = try XCTUnwrap(VFWire.buildReadPayload(path: "fixture.bin", offset: 0))
        let encoded = try XCTUnwrap(VFWire.encodeRequest(op: VFWire.opRead, flags: 0, payload: payload))
        XCTAssertEqual(encoded, expected)
        XCTAssertEqual(expected.count, VFWire.requestHdrLen + "fixture.bin".utf8.count + VFWire.readOffsetLen)
    }

    /// S3 — reply decode parity: the checked-in replies decode to the
    /// pinned fields; hostile dlen clamps, never OOB.
    func testS3ReplyDecodeParity() throws {
        let read = try fixture("vf-reply-read.bin")
        let rep = VFWire.decodeReply(read)
        XCTAssertEqual(rep.status, VFWire.stOk)
        XCTAssertEqual(rep.dlen, 5)
        XCTAssertEqual(rep.data, Array("hello".utf8))
        XCTAssertFalse(rep.clamped)

        let list = try fixture("vf-reply-list.bin")
        let lrep = VFWire.decodeReply(list)
        XCTAssertEqual(lrep.status, VFWire.stOk)
        XCTAssertEqual(lrep.dlen, 80)
        XCTAssertEqual(lrep.data.count, 2 * VFWire.entryRowLen)

        // Hostile envelope: dlen 0xffff into a 64-byte buffer clamps.
        var hostile = [UInt8](repeating: 0x42, count: 64)
        hostile[0] = VFWire.stOk
        hostile[1] = 0xff
        hostile[2] = 0xff
        let hrep = VFWire.decodeReply(hostile)
        XCTAssertEqual(hrep.dlen, 0xffff)
        XCTAssertTrue(hrep.clamped)
        XCTAssertEqual(hrep.data.count, 64 - VFWire.replyHdrLen)
        // A sub-header buffer decodes honestly as host_error.
        let tiny = VFWire.decodeReply([0x00])
        XCTAssertEqual(tiny.status, VFWire.stHostError)
        XCTAssertEqual(tiny.data.count, 0)
    }

    /// S4 — path-defense policy: in-root paths resolve; `..`, absolute
    /// paths, and symlink escapes are refused.
    func testS4PathDefense() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vf-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // In-root paths resolve (root itself is the empty path).
        XCTAssertNotNil(VFWire.resolveSubpath(root: root, path: ""))
        let ok = try XCTUnwrap(VFWire.resolveSubpath(root: root, path: "a/b/c.txt"))
        XCTAssertEqual(ok.lastPathComponent, "c.txt")

        // Refused: absolute, .. traversal, backslash smuggling.
        XCTAssertNil(VFWire.resolveSubpath(root: root, path: "/etc/passwd"))
        XCTAssertNil(VFWire.resolveSubpath(root: root, path: "../escape"))
        XCTAssertNil(VFWire.resolveSubpath(root: root, path: "a/../../escape"))
        XCTAssertNil(VFWire.resolveSubpath(root: root, path: "a\\..\\escape"))

        // Symlink escape: a link inside the root pointing outside.
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("vf-outside-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = root.appendingPathComponent("evil")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertNil(VFWire.resolveSubpath(root: root, path: "evil"))
    }

    /// Cross-check: the RFC-1071 checksum the guest prints for the probe
    /// reply is stable (the gate greps the guest's `cksum=0x…` against the
    /// same computation over the fixture).
    func testProbeChecksumStable() throws {
        let fixture = try fixture("vf-pattern-32k.bin")
        let cksum = VFWire.checksum1071(fixture)
        XCTAssertEqual(cksum, VFWire.checksum1071((0..<32768).map { VFWire.pattern($0) }))
        print("VF-CKSUM-32K: 0x\(String(format: "%04x", cksum))")
    }

    // ------------------------------------------------------------------
    // S5–S10 — HF3 (issue #737): mutation wire parity + the 8-slot
    // FileHandleTable cursor semantics (VZ-free, runs anywhere). Mirrors
    // the guest Zig tests G7–G12 byte-for-byte.
    // ------------------------------------------------------------------

    /// S5 — HF3 op/status constants, 8-handle parity, chunk math.
    func testS5Hf3ConstantsParity() {
        XCTAssertEqual(VFWire.opOpen, 0x04)
        XCTAssertEqual(VFWire.opClose, 0x05)
        XCTAssertEqual(VFWire.opWrite, 0x06)
        XCTAssertEqual(VFWire.opTruncate, 0x07)
        XCTAssertEqual(VFWire.opFsync, 0x08)
        XCTAssertEqual(VFWire.opRename, 0x09)
        XCTAssertEqual(VFWire.opMkdir, 0x0a)
        XCTAssertEqual(VFWire.opDelete, 0x0b)
        XCTAssertEqual(VFWire.stExists, 5)
        XCTAssertEqual(VFWire.stHandle, 6)
        // Parity with the kernel's file_table.zig (8 handles).
        XCTAssertEqual(VFWire.maxFileHandles, 8)
        // 32763 data bytes/WRITE round trip.
        XCTAssertEqual(VFWire.writeChunkMax, 32763)
    }

    /// S6 — write/truncate payload builders + handle parse + reply
    /// encoders (little-endian, mirroring the guest).
    func testS6PayloadBuildersAndReplyEncoders() {
        let wp = try! XCTUnwrap(VFWire.buildWritePayload(handle: 0x1122, data: Array("xyz".utf8)))
        XCTAssertEqual(wp, [0x22, 0x11, 0x78, 0x79, 0x7a])
        XCTAssertEqual(VFWire.handle(fromPayload: wp), 0x1122)
        // Over-chunk write refused honestly.
        XCTAssertNil(VFWire.buildWritePayload(handle: 0, data: [UInt8](repeating: 0, count: VFWire.writeChunkMax + 1)))

        let tp = VFWire.buildTruncatePayload(handle: 7, size: 1234)
        XCTAssertEqual(VFWire.handle(fromPayload: tp), 7)
        var size: UInt64 = 0
        for i in 0..<8 { size |= UInt64(tp[2 + i]) << (8 * i) }
        XCTAssertEqual(size, 1234)

        // OPEN reply [handle u16le] and WRITE reply [written u64le].
        XCTAssertEqual(VFWire.encodeOpenReply(handle: 4660), [0x34, 0x12])
        let wr = VFWire.encodeWrittenReply(written: 100000)
        var written: UInt64 = 0
        for i in 0..<8 { written |= UInt64(wr[i]) << (8 * i) }
        XCTAssertEqual(written, 100000)
    }

    /// S7 — rename NUL framing + bounds.
    func testS7RenameFraming() {
        let rp = try! XCTUnwrap(VFWire.buildRenamePayload(from: "sub/old.bin", to: "sub/new.bin"))
        let nul = rp.firstIndex(of: 0)!
        XCTAssertEqual(String(bytes: rp[0..<nul], encoding: .utf8), "sub/old.bin")
        XCTAssertEqual(String(bytes: rp[(nul + 1)...], encoding: .utf8), "sub/new.bin")
        XCTAssertNil(VFWire.buildRenamePayload(from: "", to: "x"))
    }

    /// S8 — the 8-slot table: cursor advance + truncate clamp.
    func testS8HandleTableCursorAndTruncate() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vf-hf3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("cur.bin")
        FileManager.default.createFile(atPath: url.path, contents: nil)

        let table = FileHandleTable()
        let fh = try FileHandle(forUpdating: url)
        let (h, st) = table.open(path: "cur.bin", fh: fh, append: false)
        XCTAssertEqual(st, VFWire.stOk)
        XCTAssertEqual(h, 0)

        let (w1, ws1) = table.write(h, data: Array("hello".utf8))
        XCTAssertEqual(ws1, VFWire.stOk)
        XCTAssertEqual(w1, 5)
        // Second write lands AFTER the first (cursor advanced):
        let (w2, _) = table.write(h, data: Array("world".utf8))
        XCTAssertEqual(w2, 5)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "helloworld")

        // Read-modify-write truncate: shrink to 5 clamps the cursor.
        XCTAssertEqual(table.truncate(h, size: 5), VFWire.stOk)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "hello")
        XCTAssertEqual(table.close(h), VFWire.stOk)
    }

    /// S9 — append handles write at EOF regardless of cursor.
    func testS9HandleTableAppend() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vf-hf3a-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("app.bin")
        try Data("base".utf8).write(to: url)

        let table = FileHandleTable()
        let fh = try FileHandle(forUpdating: url)
        let (h, st) = table.open(path: "app.bin", fh: fh, append: true)
        XCTAssertEqual(st, VFWire.stOk)
        let (w, _) = table.write(h, data: Array("-more".utf8))
        XCTAssertEqual(w, 5)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "base-more")
        _ = table.close(h)
    }

    /// S10 — 8-slot cap (parity with the kernel ABI): the ninth open is
    /// refused with stHandle; closing frees a slot.
    func testS10HandleTableCap() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vf-hf3c-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let table = FileHandleTable()
        var handles: [Int] = []
        for i in 0..<VFWire.maxFileHandles {
            let url = dir.appendingPathComponent("f\(i).bin")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let fh = try FileHandle(forUpdating: url)
            let (h, st) = table.open(path: "f\(i).bin", fh: fh, append: false)
            XCTAssertEqual(st, VFWire.stOk)
            handles.append(h)
        }
        // Ninth open → stHandle (table full).
        let extraURL = dir.appendingPathComponent("extra.bin")
        FileManager.default.createFile(atPath: extraURL.path, contents: nil)
        let extraFh = try FileHandle(forUpdating: extraURL)
        let (_, stFull) = table.open(path: "extra.bin", fh: extraFh, append: false)
        XCTAssertEqual(stFull, VFWire.stHandle)
        try? extraFh.close()

        // Close frees a slot: the retry succeeds.
        XCTAssertEqual(table.close(handles[0]), VFWire.stOk)
        let retryFh = try FileHandle(forUpdating: extraURL)
        let (h2, st2) = table.open(path: "extra.bin", fh: retryFh, append: false)
        XCTAssertEqual(st2, VFWire.stOk)
        XCTAssertEqual(h2, handles[0], "freed slot must be reused")
        _ = table.close(h2)
    }
}

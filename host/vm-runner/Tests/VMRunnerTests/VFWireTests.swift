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
}

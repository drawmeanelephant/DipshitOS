// DipshitOS VM runner for the Apple Virtualization.framework path.
//
// Usage: VMRunner <disk-image> [serial-log] [--screen <png>]
//         [--timeout <s>] [--expect <line>] [--terminal-marker <line>]
//         [--console] [--debug-input] [--dump-marker <file>]
//         [--nvram-console <file>]
//
// * --nvram-console <file> (M1.5 VZ serial-gate successor, claim 0015):
//   before exiting, reconstruct the kernel's post-exit console stream from
//   the EFI variable store (artifacts/efi-vars.bin). In nvram-console
//   builds the kernel writes every console byte as chunked EFI variables
//   `DipshitC0`, `DipshitC1`, ... via runtime SetVariable — the one
//   post-exit-safe device channel on VZ (post-exit access to the
//   virtio-pci transport hangs, claim 0013). Each chunk value is prefixed
//   with the in-band marker `DIPSHITC <idx>:`; the host byte-scans the
//   store (file order == write order), validates the chunk indices, and
//   concatenates the payloads. The reconstructed text is written to
//   <file> and printed. In this mode the exit code is 0 iff reconstructed
//   output is non-empty — the NVRAM channel, not the (silent) serial
//   channel, is the gate. The serial evidence gate above is unchanged
//   when the flag is absent.
//
//   NOTE: the reconstructed bytes travelled the NVRAM variable channel,
//   NOT the virtio serial pipe — vm-serial.log stays 0 B. This is the
//   fallback channel claim 0013 named, and it makes post-exit console
//   evidence observable on VZ for the first time.
// * --dump-marker <file> (ADR 0004 D4 fixed-memory-marker fallback, gate
//   work item 3, claim 0009): before exiting, read the EFI variable store
//   (artifacts/efi-vars.bin) and save the ordered ladder of M2_* marker
//   instances the kernel wrote (the kernel persists each takeover stage as
//   the non-volatile variable `DipshitM2` via runtime SetVariable, which
//   survives ExitBootServices on VZ). In this mode the exit code is 0 iff at
//   least one marker instance was found — the marker channel, not the
//   (silent) serial channel, is the gate. The serial evidence gate above is
//   unchanged when the flag is absent.
//
//   NOTE: the original memory-dump form (scanning this process's address
//   space for the BSS marker, on the assumption that the in-process VZ guest
//   RAM is host-mapped) is provably impossible on VZ: a full submap-aware
//   walk finds no 256 MiB guest-RAM region and every M2_* hit is this
//   runner's own constant array (claim 0009, artifacts/marker-dump.txt). The
//   NVRAM ladder is the working form of the fallback.
//
// Two modes:
//   * default (evidence gate): starts the VZ guest, captures the
//     virtio-console serial stream to the log, and reports success only
//     after the requested serial line and terminal line have both been
//     observed. This is the milestone-two evidence path (`zig build run`)
//     and is unchanged by the M1.5 console work.
//   * --console (M1.5 host plumbing): duplex serial attachment. The
//     attachment's fileHandleForReading is a real host input source (stdin
//     forwarded through a pipe), guest output is teed live to the terminal
//     AND to the serial log, and the host terminal is put into character
//     mode with its original settings restored on normal exit, on
//     ^C / SIGTERM / SIGHUP, and on failure.
//
// Honest limits (see docs/status.md, ADR 0004):
//   * The guest serial console has NO RX path. Bytes forwarded to the
//     serial attachment enter the guest's virtio-console input device, but
//     nothing in this slice proves the kernel received them — guest RX is a
//     separate milestone slice. `--debug-input` only shows bytes handed to
//     the attachment, not guest receipt.
//   * The VZ serial gate is blocked as of 2026-08-06 (vm-serial.log empty in
//     every saved run), so console mode currently shows no guest output.
// No guest filesystem or POSIX dependency is added; the guest is untouched.

import AppKit
import Darwin
import Foundation
import Virtualization

// Diagnostics and the console tee must survive signal exits (SIGINT/SIGTERM),
// so stdout is unbuffered: print() reaches the terminal/file immediately.
setbuf(stdout, nil)

let arguments = CommandLine.arguments
let diskImagePath = arguments.count > 1 ? arguments[1] : "artifacts/disk.img"
var serialLogPath = "artifacts/vm-serial.log"
var screenshotPath: String?
var timeout: TimeInterval = 30
var timeoutExplicit = false
var expectLine = "firmware has agreed to cooperate"
var terminalMarker: String?
var consoleMode = false
var debugInput = false
var markerDumpPath: String?
var nvramConsolePath: String?

var idx = 2
while idx < arguments.count {
    let arg = arguments[idx]
    if arg == "--screen", idx + 1 < arguments.count {
        screenshotPath = arguments[idx + 1]
        idx += 2
    } else if arg == "--timeout", idx + 1 < arguments.count {
        timeout = TimeInterval(arguments[idx + 1]) ?? 30
        timeoutExplicit = true
        idx += 2
    } else if arg == "--expect", idx + 1 < arguments.count {
        expectLine = arguments[idx + 1]
        idx += 2
    } else if arg == "--terminal-marker", idx + 1 < arguments.count {
        terminalMarker = arguments[idx + 1]
        idx += 2
    } else if arg == "--console" {
        consoleMode = true
        idx += 1
    } else if arg == "--debug-input" {
        debugInput = true
        idx += 1
    } else if arg == "--dump-marker", idx + 1 < arguments.count {
        markerDumpPath = arguments[idx + 1]
        idx += 2
    } else if arg == "--nvram-console", idx + 1 < arguments.count {
        nvramConsolePath = arguments[idx + 1]
        idx += 2
    } else {
        serialLogPath = arg
        idx += 1
    }
}

// Console sessions run until the VM stops or the user ends the session,
// unless an explicit --timeout was requested.
let consoleTimeout: TimeInterval = (consoleMode && !timeoutExplicit) ? 0 : timeout

// ---------------------------------------------------------------------------
// Terminal state management (used in console mode; no-ops elsewhere).
// ---------------------------------------------------------------------------

var originalTermios: termios?
var terminalRaw = false

func setupTerminal() {
    guard consoleMode else { return }
    guard isatty(STDIN_FILENO) == 1 else {
        print("  terminal: stdin is not a TTY — character mode skipped (piped input is still forwarded to the guest)")
        return
    }
    var t = termios()
    guard tcgetattr(STDIN_FILENO, &t) == 0 else {
        print("  terminal: WARNING — could not read terminal settings (tcgetattr failed); terminal left untouched")
        return
    }
    originalTermios = t
    // Character-oriented input: disable canonical line buffering and echo.
    // ISIG stays on so ^C still raises SIGINT (documented: it ends the host
    // console session rather than reaching the guest). ICRNL off so Enter is
    // forwarded as \r (0x0d); IXON off so ^S/^Q pass through to the guest.
    // Backspace is forwarded as the raw byte the terminal sends (typically
    // 0x7f). No host-side line editing is performed.
    t.c_lflag &= ~tcflag_t(ICANON | ECHO)
    t.c_iflag &= ~tcflag_t(ICRNL | IXON)
    withUnsafeMutableBytes(of: &t.c_cc) { raw in
        raw[Int(VMIN)] = 1
        raw[Int(VTIME)] = 0
    }
    guard tcsetattr(STDIN_FILENO, TCSANOW, &t) == 0 else {
        print("  terminal: WARNING — could not apply character mode (tcsetattr failed); input stays canonical")
        originalTermios = nil
        return
    }
    terminalRaw = true
    print("  terminal: character mode enabled (no echo, no line editing; Ctrl-C ends the session)")
}

func restoreTerminal() {
    guard terminalRaw, var orig = originalTermios else { return }
    terminalRaw = false
    originalTermios = nil
    tcsetattr(STDIN_FILENO, TCSANOW, &orig)
}

atexit { restoreTerminal() }

func fail(_ message: String) -> Never {
    restoreTerminal()
    FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8))
    exit(1)
}

func hostArchitecture() -> String {
    var u = utsname()
    uname(&u)
    return withUnsafeBytes(of: &u.machine) { raw -> String in
        var s = ""
        for byte in raw {
            if byte == 0 { break }
            s.append(String(UnicodeScalar(byte)))
        }
        return s
    }
}

guard hostArchitecture() == "arm64" else {
    fail("Unsupported host architecture '\(hostArchitecture())' -- Apple silicon is required.")
}
let osVersion = ProcessInfo.processInfo.operatingSystemVersion
guard osVersion.majorVersion >= 13 else {
    fail("macOS \(osVersion.majorVersion) is too old for Virtualization.framework UEFI boot.")
}

let diskURL = URL(fileURLWithPath: diskImagePath)
guard FileManager.default.fileExists(atPath: diskURL.path) else {
    fail("Disk image not found at '\(diskImagePath)'. Run 'zig build image' first.")
}
let artifactsDir = URL(fileURLWithPath: "artifacts")
try? FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)
let varsURL = artifactsDir.appendingPathComponent("efi-vars.bin")
let variableStore: VZEFIVariableStore
if FileManager.default.fileExists(atPath: varsURL.path) {
    variableStore = VZEFIVariableStore(url: varsURL)
} else {
    do {
        variableStore = try VZEFIVariableStore(creatingVariableStoreAt: varsURL, options: .allowOverwrite)
    } catch {
        fail("Could not create EFI variable store at \(varsURL.path): \(error)")
    }
}

let bootLoader = VZEFIBootLoader()
bootLoader.variableStore = variableStore
let config = VZVirtualMachineConfiguration()
config.bootLoader = bootLoader
config.memorySize = 256 * 1024 * 1024
config.cpuCount = 2

do {
    let attachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
    config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
} catch {
    fail("Could not attach disk image '\(diskImagePath)': \(error)")
}

// ---------------------------------------------------------------------------
// Serial plumbing: evidence path (unchanged) vs console path (duplex + tee).
// ---------------------------------------------------------------------------

// Console-mode duplex pipes. The attachment reads host input from
// consoleInputPipe's read end (we forward stdin into its write end) and
// writes guest output to consoleOutputPipe's write end (we tee its read end
// to the terminal and the log). Non-console mode never touches these.
let consoleInputPipe = Pipe()
let consoleOutputPipe = Pipe()
var serialLogHandle: FileHandle?

let serialURL = URL(fileURLWithPath: serialLogPath)
FileManager.default.createFile(atPath: serialURL.path, contents: nil)
if consoleMode {
    do {
        serialLogHandle = try FileHandle(forWritingTo: serialURL)
    } catch {
        fail("Could not open serial log at \(serialURL.path): \(error)")
    }
}

let serialConfig = VZVirtioConsoleDeviceSerialPortConfiguration()
if consoleMode {
    // Duplex attachment: the host-to-guest input handle is non-nil.
    serialConfig.attachment = VZFileHandleSerialPortAttachment(
        fileHandleForReading: consoleInputPipe.fileHandleForReading,
        fileHandleForWriting: consoleOutputPipe.fileHandleForWriting
    )
} else {
    // Evidence path: output-only attachment, exactly as before.
    let serialHandle: FileHandle
    do {
        serialHandle = try FileHandle(forWritingTo: serialURL)
    } catch {
        fail("Could not open serial log at \(serialURL.path): \(error)")
    }
    serialConfig.attachment = VZFileHandleSerialPortAttachment(
        fileHandleForReading: nil,
        fileHandleForWriting: serialHandle
    )
}
config.serialPorts = [serialConfig]
config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

var machineView: VZVirtualMachineView?
if screenshotPath != nil {
    let graphics = VZVirtioGraphicsDeviceConfiguration()
    graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1280, heightInPixels: 720)]
    config.graphicsDevices = [graphics]
} else {
    config.graphicsDevices = []
}
config.networkDevices = []
do { try config.validate() } catch { fail("Invalid VM configuration: \(error)") }

final class Runner: NSObject {
    let vm: VZVirtualMachine
    let queue = DispatchQueue(label: "dipshitos.vm")
    init(configuration: VZVirtualMachineConfiguration) {
        vm = VZVirtualMachine(configuration: configuration, queue: queue)
        super.init()
    }
}

let runner = Runner(configuration: config)
// Set when vm.start completes successfully; consolePoll only treats a
// .stopped/.error state as "session over" after the VM has actually started
// (a fresh VZVirtualMachine is .stopped until boot begins).
var vmDidStart = false
let startTime = Date()
let deadline = startTime.addingTimeInterval(timeout)
let consoleStart = Date()
let consoleDeadline = consoleStart.addingTimeInterval(consoleTimeout)
var lastText = ""
var screenshotSaved = false
var serialMatched = false
var terminalMatched = terminalMarker == nil
var evidenceSince: Date?
let terminalDwell: TimeInterval = 2

print("DIPSHITOS VM runner")
print("  host: arm64 (Apple silicon), macOS \(osVersion.majorVersion).\(osVersion.minorVersion)")
print("  disk: \(diskImagePath)")
print("  memory: 256 MiB, cpus: 2")
if consoleMode {
    print("  mode: interactive console")
    print("  serial log: \(serialLogPath)  (guest output teed to terminal + log)")
    print("  interactive input: enabled — stdin → serial attachment (fileHandleForReading non-nil)")
    print("  NOTE: guest RX is not implemented (ADR 0004) — bytes are forwarded to the serial attachment, but nothing yet proves the kernel received them")
    print("  NOTE: the VZ serial gate is blocked as of this run — no guest serial output is expected until that gate passes")
    print("  controls: Ctrl-C ends the session and restores the terminal; Backspace/Enter are forwarded raw (no host line editing)")
} else {
    print("  serial log: \(serialLogPath)  (timeout: \(Int(timeout))s)")
    print("  expecting: \"\(expectLine)\"")
    if let terminalMarker { print("  terminal marker: \"\(terminalMarker)\"") }
    if let markerDumpPath {
        print("  marker dump: \(markerDumpPath)  (ADR 0004 D4 fallback — NVRAM ladder; exit 0 iff an M2_* marker is found)")
    }
    if let nvramConsolePath {
        print("  nvram console: \(nvramConsolePath)  (claim 0015 — post-exit console stream from the NVRAM channel; exit 0 iff bytes were found)")
    }
}

runner.queue.async {
    runner.vm.start { result in
        if case .failure(let error) = result {
            restoreTerminal()
            FileHandle.standardError.write(Data("ERROR: VM failed to start: \(error)\n".utf8))
            exit(1)
        }
        vmDidStart = true
    }
}

var captureTimes: [TimeInterval] = [5, 10, 15]
func captureScreenshot(at t: TimeInterval) {
    guard let view = machineView,
          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    let path: String
    if let base = screenshotPath {
        let dot = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension
        path = ext.isEmpty ? "\(dot)-\(Int(t))s" : "\(dot)-\(Int(t))s.\(ext)"
    } else {
        path = "artifacts/vm-screen-\(Int(t))s.png"
    }
    do {
        try data.write(to: URL(fileURLWithPath: path))
        print("SUCCESS: framebuffer screenshot saved to \(path) (\(data.count) bytes).")
        screenshotSaved = true
    } catch { print("WARNING: could not write screenshot: \(error)") }
}

func finish(success: Bool) {
    let wantDump = markerDumpPath != nil
    let wantNvram = nvramConsolePath != nil
    runner.queue.async {
        runner.vm.stop { _ in
            // Exit code: the serial evidence `success` is the default; each
            // NVRAM-gated channel (marker ladder, nvram console) flips it to
            // true when its bytes are found. With no such flag the original
            // serial-gate semantics are unchanged.
            var finalSuccess = success
            if wantDump, let dumpPath = markerDumpPath {
                // ADR 0004 D4 fixed-memory-marker fallback (working form, claim
                // 0009): the kernel persists its takeover stage as the EFI
                // non-volatile variable `DipshitM2` (runtime SetVariable survives
                // ExitBootServices on VZ — observed), and the host reads the
                // store after the VM stops. The memory-scan variant is impossible
                // on VZ: guest RAM is not mapped into the runner process
                // (observed — a full submap-aware walk finds no 256 MiB region
                // and every M2_* hit is the runner's own constant array). The
                // NVRAM ladder is the gate here; the exit code becomes 0 iff at
                // least one marker instance is present in the store.
                print("marker ladder: reading EFI variable store")
                let ladder = readMarkerLadder(from: varsURL)
                writeMarkerDump(to: dumpPath, ladder: ladder)
                if ladder.isEmpty {
                    print("MARKER-GATE: no M2_* marker in the EFI variable store (kernel died before its first marker write, or SetVariable failed)")
                } else {
                    finalSuccess = true
                    for (name, _) in ladder {
                        print("MARKER-GATE: \(name)")
                    }
                }
            }
            if wantNvram, let path = nvramConsolePath {
                print("nvram console: reconstructing console stream from EFI variable store")
                let result = readNvramConsole(from: varsURL)
                writeNvramConsole(to: path, result: result)
                if result.text.isEmpty {
                    print("NVRAM-CONSOLE: no console chunks in the EFI variable store (kernel wrote nothing, or SetVariable failed post-exit)")
                } else {
                    finalSuccess = true
                    print("NVRAM-CONSOLE: \(result.chunks) chunk(s) reconstructed\(result.complete ? "" : " (INCOMPLETE — missing chunk index \(result.missing!))"), \(result.text.count) bytes")
                }
            }
            exit(finalSuccess ? 0 : 1)
        }
    }
}

// ---------------------------------------------------------------------------
// ADR 0004 D4 fixed-memory-marker fallback (working form, claim 0009): the
// kernel writes each takeover stage as the EFI non-volatile variable
// `DipshitM2` (VendorGuid M2M2_DIPSHITOS-M). EFI runtime services survive
// ExitBootServices on VZ, so after the run the host reads the variable store
// (artifacts/efi-vars.bin) and sees the ordered ladder of stages the kernel
// reached. A missing later stage names the crash window: a ladder ending at
// M2_MAPD! (identity map built, pre-install) with no M2_MMUP! means the MMU
// switch itself faulted — observed on every VZ run (claim 0009).
// ---------------------------------------------------------------------------

// The kernel's stage words, little-endian as stored by SetVariable. The LE
// byte strings are distinctive ASCII (e.g. "YRTNE_2M" for M2_ENTRY), so a
// plain byte scan of the store finds every instance in file order; the store
// is append-per-write, so file order == write order and the LAST instance is
// the kernel's final stage.
let markerNeedles: [(name: String, leBytes: [UInt8])] = [
    ("M2_TABLE", [0x45, 0x4c, 0x42, 0x41, 0x54, 0x5f, 0x32, 0x4d]), // ELBAT_2M
    ("M2_SERIA", [0x41, 0x49, 0x52, 0x45, 0x53, 0x5f, 0x32, 0x4d]), // AIRES_2M
    ("M2_ENTRY", [0x59, 0x52, 0x54, 0x4e, 0x45, 0x5f, 0x32, 0x4d]), // YRTNE_2M
    ("M2_CMAP!", [0x21, 0x50, 0x41, 0x4d, 0x43, 0x5f, 0x32, 0x4d]), // !PAMC_2M
    ("M2_MAPD!", [0x21, 0x44, 0x50, 0x41, 0x4d, 0x5f, 0x32, 0x4d]), // !DPAM_2M
    ("M2_PREX!", [0x21, 0x58, 0x45, 0x52, 0x50, 0x5f, 0x32, 0x4d]), // !XERP_2M
    ("M2_EXIT!", [0x21, 0x54, 0x49, 0x58, 0x45, 0x5f, 0x32, 0x4d]), // !TIXE_2M
    ("M2_MMUP!", [0x21, 0x50, 0x55, 0x4d, 0x4d, 0x5f, 0x32, 0x4d]), // !PUMM_2M
    ("M2_READY", [0x59, 0x44, 0x41, 0x45, 0x52, 0x5f, 0x32, 0x4d]), // YDAER_2M
    ("M2_RAW!", [0x21, 0x57, 0x41, 0x52, 0x5f, 0x32, 0x4d, 0x00]), // !WAR_2M\0 (claim 0013 probe stage; 7-char word, u64-padded with 0x00)
    ("M2_TXOK!", [0x21, 0x4b, 0x4f, 0x58, 0x54, 0x5f, 0x32, 0x4d]), // !KOXT_2M (claim 0013: first TX returned)
]

/// Read the EFI variable store and return the marker ladder (name, store
/// offset), in file order. Byte-scan only — no struct-layout assumption
/// beyond the value being present: the marker strings are distinctive 8-byte
/// ASCII sequences, and every hit is checked against the needle table.
func readMarkerLadder(from storeURL: URL) -> [(name: String, offset: Int)] {
    guard let data = try? Data(contentsOf: storeURL) else { return [] }
    let bytes = [UInt8](data)
    var hits: [(name: String, offset: Int)] = []
    var i = 0
    while i + 8 <= bytes.count {
        for (name, needle) in markerNeedles {
            var match = true
            var j = 0
            while j < 8 {
                if bytes[i + j] != needle[j] { match = false; break }
                j += 1
            }
            if match { hits.append((name, i)) }
        }
        i += 1
    }
    hits.sort { $0.offset < $1.offset }
    return hits
}

// ---------------------------------------------------------------------------
// Claim 0015: NVRAM console reconstruction. The kernel persists console
// bytes as chunked EFI variables DipshitC0..N (runtime SetVariable — the
// proven post-exit-safe channel on VZ), each value prefixed with the
// in-band marker "DIPSHITC <4-digit-index>:" inside the value bytes. A
// plain byte scan of the store finds every chunk in file order (the store
// is append-per-write), exactly like the marker ladder — no struct-layout
// parsing. Payloads are concatenated after validating the indices are
// sequential from 0 (a gap means a SetVariable call was dropped; reported
// honestly).
// ---------------------------------------------------------------------------

struct NvramConsoleResult {
    var text: String = ""
    var chunks: Int = 0
    var complete: Bool = true
    var missing: Int? = nil
}

func readNvramConsole(from storeURL: URL) -> NvramConsoleResult {
    var result = NvramConsoleResult()
    guard let data = try? Data(contentsOf: storeURL) else { return result }
    let bytes = [UInt8](data)
    let prefix = Array("DIPSHITC ".utf8) // 9 bytes; +4 digits + ":" = marker at i+13
    let endMarker = Array("DIPSHITC-END".utf8) // 12 bytes; closes every chunk value
    guard prefix.count == 9, endMarker.count == 12 else { return result }

    // Find every chunk start marker, in file order.
    var starts: [(index: Int, pos: Int)] = []
    var i = 0
    while i + 14 <= bytes.count {
        if bytes[i..<(i + 9)].elementsEqual(prefix) {
            var ok = true
            var index = 0
            for k in 9..<13 {
                let c = bytes[i + k]
                guard c >= 0x30, c <= 0x39 else { ok = false; break }
                index = index * 10 + Int(c - 0x30)
            }
            if ok, bytes[i + 13] == 0x3a { // ":"
                starts.append((index, i))
                i += 14
                continue
            }
        }
        i += 1
    }

    // Payload of each chunk = bytes between its start marker and the first
    // DIPSHITC-END after it. The end marker is written atomically with the
    // value by the kernel, so this delimits payloads exactly without parsing
    // the store's structure (variable headers / GUIDs / other variables sit
    // between chunks). Validate the index sequence 0..n-1: a dropped
    // SetVariable shows as a gap and is reported honestly.
    var expected = 0
    var out = Data()
    var sawUnterminated = false
    for (n, (index, pos)) in starts.enumerated() {
        if index != expected {
            result.complete = false
            result.missing = expected
        }
        expected = index + 1
        let payloadStart = pos + 14
        let searchStart = (n + 1 < starts.count) ? min(payloadStart, starts[n + 1].pos) : payloadStart
        var end = -1
        var j = searchStart
        while j + 12 <= bytes.count {
            if bytes[j..<(j + 12)].elementsEqual(endMarker) {
                end = j
                break
            }
            j += 1
        }
        if end < 0 {
            sawUnterminated = true
            continue // no end marker: skip the chunk rather than swallow the store tail
        }
        out.append(contentsOf: bytes[payloadStart..<end])
    }
    result.chunks = starts.count
    if sawUnterminated {
        result.complete = false
        if result.missing == nil { result.missing = expected }
    }
    if result.chunks == 0 { return result }

    result.text = String(decoding: out, as: UTF8.self)
    return result
}

func writeNvramConsole(to path: String, result: NvramConsoleResult) {
    var lines: [String] = []
    lines.append("DIPSHITOS nvram console — claim 0015 (post-exit console bytes via the NVRAM variable channel)")
    lines.append("date=\(ISO8601DateFormatter().string(from: Date()))")
    lines.append("store=\(varsURL.path)")
    lines.append("chunks=\(result.chunks) complete=\(result.complete)\(result.missing.map { " missing=\($0)" } ?? "") bytes=\(result.text.count)")
    lines.append("NOTE: these bytes rode the NVRAM variable channel (runtime SetVariable), not the virtio serial pipe.")
    lines.append("")
    lines.append("----- reconstructed console stream -----")
    lines.append(result.text)
    lines.append("----------------------------------------")
    let text = lines.joined(separator: "\n") + "\n"
    do {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        print("nvram console output saved to \(path) (\(result.chunks) chunk(s), \(result.text.count) bytes)")
    } catch {
        FileHandle.standardError.write(Data("ERROR: could not write nvram console output to \(path): \(error)\n".utf8))
    }
}

func writeMarkerDump(to path: String, ladder: [(name: String, offset: Int)]) {
    var lines: [String] = []
    lines.append("DIPSHITOS marker dump — ADR 0004 D4 fixed-memory-marker fallback (NVRAM ladder)")
    lines.append("date=\(ISO8601DateFormatter().string(from: Date()))")
    lines.append("store=\(varsURL.path)")
    lines.append("")
    lines.append("marker ladder (file order == write order):")
    if ladder.isEmpty {
        lines.append("  (none — no M2_* marker instance in the store)")
    } else {
        for (name, offset) in ladder {
            lines.append("  \(name) @0x\(String(format: "%x", offset))")
        }
    }
    let text = lines.joined(separator: "\n") + "\n"
    do {
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        print("marker dump saved to \(path) (\(ladder.count) marker instance(s))")
    } catch {
        FileHandle.standardError.write(Data("ERROR: could not write marker dump to \(path): \(error)\n".utf8))
    }
}

func poll() {
    if let data = try? Data(contentsOf: serialURL), let text = String(data: data, encoding: .utf8) {
        if !text.isEmpty { lastText = text }
        serialMatched = text.contains(expectLine)
        if let terminalMarker { terminalMatched = text.contains(terminalMarker) }
        if serialMatched && terminalMatched {
            if evidenceSince == nil { evidenceSince = Date() }
            if Date().timeIntervalSince(evidenceSince!) >= terminalDwell {
                if runner.vm.state != .running {
                    print("FAILURE: VM left the running state during terminal dwell (state=\(runner.vm.state.rawValue)).")
                    finish(success: false)
                    return
                }
                print("SUCCESS: requested serial evidence remained present during terminal dwell.")
                print("----- captured serial console -----")
                print(text)
                print("-----------------------------------")
                finish(success: true)
                return
            }
        } else {
            evidenceSince = nil
        }
    }

    if screenshotPath != nil {
        let elapsed = Date().timeIntervalSince(startTime)
        if let next = captureTimes.first(where: { $0 <= elapsed }) {
            captureTimes.removeAll { $0 == next }
            captureScreenshot(at: next)
        }
    }

    if Date() > deadline {
        if screenshotSaved && terminalMarker == nil {
            print("Timed out waiting for serial output, but a framebuffer screenshot was captured.")
            finish(success: true)
        } else {
            print("FAILURE: requested evidence not observed within \(Int(timeout))s (serial=\(serialMatched), terminal=\(terminalMatched)).")
            if !lastText.isEmpty { print("----- captured serial console (partial) -----\n\(lastText)\n---------------------------------------------") }
            finish(success: false)
        }
        return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { poll() }
}

// ---------------------------------------------------------------------------
// Console mode: streaming tee, stdin forwarding, signal-safe exit.
// ---------------------------------------------------------------------------

func startConsoleStreams() {
    // Guest output → terminal + serial log. Streaming tee: each chunk is
    // written as it arrives; the log is never reloaded to show new bytes.
    let teeQueue = DispatchQueue(label: "dipshitos.tee")
    var logWriteWarned = false
    teeQueue.async {
        let fd = consoleOutputPipe.fileHandleForReading.fileDescriptor
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            var n: Int
            repeat { n = read(fd, &buf, buf.count) } while n < 0 && errno == EINTR
            if n <= 0 { break } // guest serial closed
            let data = Data(bytes: buf, count: n)
            try? FileHandle.standardOutput.write(contentsOf: data)
            do {
                try serialLogHandle?.write(contentsOf: data)
            } catch {
                if !logWriteWarned {
                    logWriteWarned = true
                    FileHandle.standardError.write(Data("WARNING: could not write guest output to \(serialLogPath): \(error)\n".utf8))
                }
            }
        }
        try? serialLogHandle?.synchronize()
    }

    // Host stdin → guest serial input (raw bytes, character-oriented).
    let inputQueue = DispatchQueue(label: "dipshitos.stdin")
    inputQueue.async {
        var buf = [UInt8](repeating: 0, count: 1024)
        while true {
            var n: Int
            repeat { n = read(STDIN_FILENO, &buf, buf.count) } while n < 0 && errno == EINTR
            if n <= 0 { break } // EOF: stop forwarding and close the guest input side
            let data = Data(bytes: buf, count: n)
            if debugInput {
                let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
                FileHandle.standardError.write(Data("input → serial attachment: \(data.count) bytes: \(hex)\n".utf8))
            }
            do { try consoleInputPipe.fileHandleForWriting.write(contentsOf: data) }
            catch { break }
        }
        try? consoleInputPipe.fileHandleForWriting.close()
    }
}

var signalSources: [DispatchSourceSignal] = []

func installSignalHandlers() {
    guard consoleMode else { return }
    for sig: Int32 in [SIGINT, SIGTERM, SIGHUP] {
        signal(sig, SIG_IGN) // suppress default termination; the source below handles it
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler {
            restoreTerminal()
            FileHandle.standardError.write(Data("console: caught signal \(sig) — terminal restored, exiting\n".utf8))
            Thread.sleep(forTimeInterval: 0.4) // let the tee thread drain guest output into the log
            exit(128 + sig)
        }
        src.resume()
        signalSources.append(src)
    }
}

func consolePoll() {
    let state = runner.vm.state
    if vmDidStart && (state == .stopped || state == .error) {
        print("console: VM ended (state=\(state.rawValue)) — ending session")
        Thread.sleep(forTimeInterval: 0.5) // let the tee drain before exit
        exitWithTerminalRestore(0)
    }
    if consoleTimeout > 0, Date() > consoleDeadline {
        print("console: session timed out after \(Int(consoleTimeout))s (VM state=\(state.rawValue)) — ending session")
        Thread.sleep(forTimeInterval: 0.5)
        exitWithTerminalRestore(0)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { consolePoll() }
}

func exitWithTerminalRestore(_ code: Int32) -> Never {
    restoreTerminal()
    exit(code)
}

if consoleMode {
    // Install signal handlers BEFORE engaging raw/character mode so there is
    // never a window where the terminal is raw with no restore path.
    installSignalHandlers()
    setupTerminal()
    startConsoleStreams()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { consolePoll() }
} else {
    if screenshotPath != nil {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        let view = VZVirtualMachineView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        view.virtualMachine = runner.vm
        window.setContentSize(NSSize(width: 1280, height: 720))
        window.contentView = view
        window.center()
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        machineView = view
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { poll() }
}
RunLoop.main.run()

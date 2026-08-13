// DipshitOS VM runner for the Apple Virtualization.framework path.
//
// Usage: VMRunner <disk-image> [serial-log] [--screen <png>]
//         [--timeout <s>] [--expect <line>] [--terminal-marker <line>]
//         [--console] [--debug-input] [--dump-marker <file>]
//         [--nvram-console <file>] [--script <file>]
//         [--script-after <text>] [--script-expect <text>] [--custom-virtio]
//         [--script2 <file> --script2-after <text>] (claim 4613: a second
//          scripted phase, forwarded once after its own serial marker)
//         [--script3 <file> --script3-after <text>] (claim 7786: a third
//          scripted phase, forwarded once after its own serial marker)
//         [--net <capture-file>] (milestone five card N1, claim 1373: attach
//          one VZVirtioNetworkDeviceConfiguration with a
//          VZFileHandleNetworkDeviceAttachment so the guest's virtio-net TX
//          frames are captured byte-exactly to <capture-file> (raw Ethernet
//          bytes, host writes them as they arrive). The guest MAC is FIXED
//          (02:00:00:00:00:01) so the guest-side VIRTIO_NET_F_MAC read is
//          deterministic and gate-assertable. OFF by default: without the
//          flag config.networkDevices stays [] — every existing gate is
//          byte-identical. VZNAT is a later card's option.)
//         [--net-inject <file>] [--net-inject-after <text>] (milestone five
//          card N2, claim 6076: the host->guest RX direction of the SAME
//          --net attachment — the file's bytes are written into the socket
//          end VZ delivers from, exactly ONCE, when <text> appears in the
//          serial log (default "net: rx-armed" — the guest's queue-0 RX
//          buffer is guaranteed supplied by then; deterministic, not a
//          sleep). Requires --net. OFF by default: the default VM — and the
//          29-gate aggregate — stays byte-identical. The injected bytes are
//          the KNOWN raw Ethernet frame the guest's net recv must print
//          byte-exact; the guest's netsend echo proves the round trip.)
//
// * --custom-virtio (macOS 27 spike, audit step 3): attaches one
//   default-off VZCustomVirtioDeviceConfiguration so the guest's PCI
//   discovery can observe it on a real VZ boot (VID 0x1af4, DID 0x1082,
//   class 0x00/0x00, 2 queues). Without the flag the VM configuration is
//   byte-identical to before — all existing gates are unchanged. NOTE:
//   Xcode 27 beta 4 exposes no host-triggered guest-interrupt API; the
//   spike proves discovery + queue transport (audit step 4) and the
//   used-ring IRQ via returnToQueue (audit step 5, claim 0828).
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
import ScreenCaptureKit
import Virtualization

// Diagnostics and the console tee must survive signal exits (SIGINT/SIGTERM),
// so stdout is unbuffered: print() reaches the terminal/file immediately.
setbuf(stdout, nil)

let arguments = CommandLine.arguments
let diskImagePath = arguments.count > 1 ? arguments[1] : "artifacts/disk.img"
var serialLogPath = "artifacts/vm-serial.log"
var screenshotPath: String?
// Milestone six card G1 (claim 6053): `--display` attaches the virtio-gpu
// device and shows the VM window for the whole session (the machine boots
// to a screen). OFF by default — without the flag config.graphicsDevices
// stays [] exactly as before, so every existing gate stays byte-identical.
// `--screenshot <path>` remains the evidence capture (the two combine:
// `--display --screenshot`).
var displayMode = false
var timeout: TimeInterval = 30
var timeoutExplicit = false
var expectLine = "firmware has agreed to cooperate"
var terminalMarker: String?
var consoleMode = false
var debugInput = false
var markerDumpPath: String?
var nvramConsolePath: String?
var scriptPath: String?
var scriptAfter: String?
var scriptExpect: String?
// Claim 4613: a second scripted phase. The primary --script is forwarded
// in ONE burst (claim 6684), so a scripted command that must land AFTER a
// background program exits and is reaped (the long-lived gate's re-exec
// into the freed pool slot) cannot be in the same burst: --script2 is
// forwarded once after its own serial marker (the reap line) instead.
var script2Path: String?
var script2After: String?
// Card 3c (claim 7786): a THIRD scripted phase. The primary --script is
// forwarded in ONE burst (claim 6684) and --script2 handles the next
// phase (claim 4613); --script3 covers the post-reap snapshot that must
// land after a background process is killed AND reaped (the kill gate's
// procs/pages/re-exec read) — forwarded once after its own serial marker
// via the identical machinery.
var script3Path: String?
var script3After: String?
var customVirtioEnabled = false
// Milestone five card N1 (claim 1373): `--net <capture-file>` attaches the
// virtio-net device; the guest's TX frames are captured byte-exactly to the
// file. nil = default (no network device attached, config.networkDevices
// stays [] — the default VM is unchanged).
var netCapturePath: String?
// Milestone five card N2 (claim 6076): `--net-inject <file>` writes the
// file's bytes into the runner's end of the SAME datagram socketpair VZ
// delivers guest-bound frames from, exactly ONCE, when the trigger marker
// appears in the serial log (default: the guest's `net: rx-armed` line —
// the RX buffer is guaranteed supplied; deterministic, not a sleep). nil =
// no injection (the default VM is unchanged).
var netInjectPath: String?
var netInjectAfter: String?
// Milestone five card N3 (claim 7293): `--net-arp-respond <host-ip>`
// answers the guest's ARP requests from the HOST side — a tiny
// deterministic host-side ARP responder inside the capture thread: when a
// captured datagram is an ARP request (ethertype 0x0806, op 1, htype 1,
// ptype 0x0800, hlen 6, plen 4), the synthesized reply (host MAC
// 02:00:00:00:00:02 at the given IP — the same fixed address as the
// guest's fallback_mac) is written into the SAME attachment socket end
// `--net-inject` writes (VZ reads fds[0], so the guest receives it).
// Driven by the guest's actual request bytes, not a sleep. nil = the
// guest's ARP requests go unanswered (the default VM is unchanged).
var netArpRespondHostIP: [UInt8]?
// Milestone five card N4 (claim 0148): `--net-icmp-respond <host-ip>`
// answers the guest's ICMP ECHO REQUESTS from the HOST side — a tiny
// deterministic host-side ICMP responder inside the capture thread: when
// a captured datagram is an ICMP echo request for the given IP (ethertype
// 0x0800, protocol 1, type 8, dst IP match, non-fragment), the
// synthesized echo reply (type 0, id/seq/payload echoed byte-exact, both
// checksums recomputed) is written into the SAME attachment socket end
// the ARP responder writes (VZ reads fds[0], so the guest receives it).
// Driven by the guest's actual request bytes, not a sleep. nil = the
// guest's echo requests go unanswered (the default VM is unchanged).
var netIcmpRespondHostIP: [UInt8]?
// Milestone five card N5 (claim 8552): `--net-udp-respond <host-ip>:<host-port>`
// answers the guest's UDP datagrams from the HOST side — a tiny
// deterministic host-side UDP responder inside the capture thread: when
// a captured datagram is a UDP datagram for the given ip:port (ethertype
// 0x0800, version 4/IHL 5, non-fragment, protocol 17, dst IP + dst port
// match), the synthesized reply (FROM host-ip:host-port TO the sender's
// ip:src-port, the SAME payload byte-exact, both checksums recomputed)
// is written into the SAME attachment socket end (VZ reads fds[0], so the
// guest receives it). Driven by the guest's actual datagram bytes, not a
// sleep. nil = the guest's datagrams go unanswered (the default VM is
// unchanged).
var netUdpRespondHostIP: [UInt8]?
var netUdpRespondHostPort: UInt16?

var idx = 2
while idx < arguments.count {
    let arg = arguments[idx]
    if arg == "--screen", idx + 1 < arguments.count {
        screenshotPath = arguments[idx + 1]
        idx += 2
    } else if arg == "--display" {
        displayMode = true
        idx += 1
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
    } else if arg == "--script", idx + 1 < arguments.count {
        scriptPath = arguments[idx + 1]
        idx += 2
    } else if arg == "--script-after", idx + 1 < arguments.count {
        scriptAfter = arguments[idx + 1]
        idx += 2
    } else if arg == "--script-expect", idx + 1 < arguments.count {
        scriptExpect = arguments[idx + 1]
        idx += 2
    } else if arg == "--script2", idx + 1 < arguments.count {
        script2Path = arguments[idx + 1]
        idx += 2
    } else if arg == "--script2-after", idx + 1 < arguments.count {
        script2After = arguments[idx + 1]
        idx += 2
    } else if arg == "--script3", idx + 1 < arguments.count {
        script3Path = arguments[idx + 1]
        idx += 2
    } else if arg == "--script3-after", idx + 1 < arguments.count {
        script3After = arguments[idx + 1]
        idx += 2
    } else if arg == "--custom-virtio" {
        customVirtioEnabled = true
        idx += 1
    } else if arg == "--net", idx + 1 < arguments.count {
        netCapturePath = arguments[idx + 1]
        idx += 2
    } else if arg == "--net-inject", idx + 1 < arguments.count {
        netInjectPath = arguments[idx + 1]
        idx += 2
    } else if arg == "--net-inject-after", idx + 1 < arguments.count {
        netInjectAfter = arguments[idx + 1]
        idx += 2
    } else if arg == "--net-arp-respond", idx + 1 < arguments.count {
        // Parse the dotted-quad host IP now (fail early, like --timeout).
        let parts = arguments[idx + 1].split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else {
            fail("--net-arp-respond requires a dotted-quad IPv4 address, got '\(arguments[idx + 1])'.")
        }
        netArpRespondHostIP = parts
        idx += 2
    } else if arg == "--net-icmp-respond", idx + 1 < arguments.count {
        // Parse the dotted-quad host IP now (fail early, like --timeout).
        let parts = arguments[idx + 1].split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else {
            fail("--net-icmp-respond requires a dotted-quad IPv4 address, got '\(arguments[idx + 1])'.")
        }
        netIcmpRespondHostIP = parts
        idx += 2
    } else if arg == "--net-udp-respond", idx + 1 < arguments.count {
        // Parse the host ip:port now (fail early, like --timeout).
        let halves = arguments[idx + 1].split(separator: ":")
        guard halves.count == 2, let port = UInt16(halves[1]) else {
            fail("--net-udp-respond requires '<host-ip>:<host-port>', got '\(arguments[idx + 1])'.")
        }
        let parts = halves[0].split(separator: ".").compactMap { UInt8($0) }
        guard parts.count == 4 else {
            fail("--net-udp-respond requires a dotted-quad IPv4 address, got '\(arguments[idx + 1])'.")
        }
        netUdpRespondHostIP = parts
        netUdpRespondHostPort = port
        idx += 2
    } else {
        serialLogPath = arg
        idx += 1
    }
}

// Console sessions run until the VM stops or the user ends the session,
// unless an explicit --timeout was requested. Script mode is a non-
// interactive variant of the duplex console plumbing (claim 6684).
let consoleTimeout: TimeInterval = (consoleMode && !timeoutExplicit) ? 0 : timeout
let scriptMode = scriptPath != nil

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
// Project requirement: macOS 27+ (Apple silicon + Virtualization.framework).
// macOS 27 is the floor — the host-side custom-virtio interrupt path
// (VZCustomVirtioDevice) and the project's SDK/toolchain target assume it.
guard osVersion.majorVersion >= 27 else {
    fail("macOS \(osVersion.majorVersion) is too old — this project requires macOS 27 or newer (Apple silicon + Virtualization.framework).")
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
if consoleMode || scriptMode {
    do {
        serialLogHandle = try FileHandle(forWritingTo: serialURL)
    } catch {
        fail("Could not open serial log at \(serialURL.path): \(error)")
    }
}

let serialConfig = VZVirtioConsoleDeviceSerialPortConfiguration()
if consoleMode || scriptMode {
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
var machineWindow: NSWindow?
// Milestone six card G1 (claim 6053): the virtio-gpu device is attached
// under `--display` (the milestone's mode — the machine boots to a
// screen) as well as under `--screenshot` (the evidence capture). The
// default VM attaches NO graphics device — config.graphicsDevices stays
// [] and every existing gate stays byte-identical.
if screenshotPath != nil || displayMode {
    let graphics = VZVirtioGraphicsDeviceConfiguration()
    graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1280, heightInPixels: 720)]
    config.graphicsDevices = [graphics]
} else {
    config.graphicsDevices = []
}
// Milestone five card N1 (claim 1373): the virtio-net device, attached only
// under `--net <capture-file>`. VZFileHandleNetworkDeviceAttachment transmits
// raw data-link frames over ONE connected datagram socket: VZ holds one end
// (every guest-transmitted frame arrives as a datagram; host->guest frames
// would be written into the same socket — that is card N2's RX direction),
// and the runner reads the other end and appends each datagram to the
// capture file byte-exactly. The guest MAC is FIXED on the host config
// (VZMACAddress "02:00:00:00:00:01", locally administered) so the guest's
// VIRTIO_NET_F_MAC read is deterministic and gate-assertable. Without the
// flag the config is exactly as before: networkDevices = [] — every existing
// gate stays byte-identical.
var netCaptureHandle: FileHandle? // capture file (append)
var netCaptureSocket: FileHandle? // the socket end VZ transmits to
var netCaptureReadSocket: FileHandle? // the runner's read end
var netCaptureStop = false
var netCaptureThread: Thread?
var netCaptureDone = DispatchSemaphore(value: 0)
if netInjectPath != nil, netCapturePath == nil {
    fail("--net-inject requires --net (the injection writes into the SAME attachment's socket).")
}
if netArpRespondHostIP != nil, netCapturePath == nil {
    fail("--net-arp-respond requires --net (the ARP reply is written into the SAME attachment's socket).")
}
if netIcmpRespondHostIP != nil, netCapturePath == nil {
    fail("--net-icmp-respond requires --net (the ICMP reply is written into the SAME attachment's socket).")
}
if netUdpRespondHostIP != nil, netCapturePath == nil {
    fail("--net-udp-respond requires --net (the UDP reply is written into the SAME attachment's socket).")
}

if let netCapturePath {
    let netURL = URL(fileURLWithPath: netCapturePath)
    FileManager.default.createFile(atPath: netURL.path, contents: nil)
    guard let netCaptureFile = try? FileHandle(forWritingTo: netURL) else {
        fail("Could not open net capture file at '\(netCapturePath)'.")
    }
    netCaptureHandle = netCaptureFile
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
        fail("Could not create the net attachment datagram socketpair (errno \(errno)).")
    }
    netCaptureSocket = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
    netCaptureReadSocket = FileHandle(fileDescriptor: fds[1], closeOnDealloc: true)
    // Reader thread: drain the runner's socket end into the capture file.
    // One datagram per read (SOCK_DGRAM); a 4096-byte buffer covers the
    // largest N1 frame (1514 B) with headroom.
    netCaptureThread = Thread {
        // Card N3 (claim 7293): the host-side ARP responder's fixed MAC —
        // the same locally-administered address as the guest's
        // fallback_mac, so the reply the guest learns is deterministic and
        // gate-assertable.
        let arpHostMAC: [UInt8] = [0x02, 0x00, 0x00, 0x00, 0x00, 0x02]
        var buf = [UInt8](repeating: 0, count: 4096)
        while !netCaptureStop {
            let n = read(netCaptureReadSocket!.fileDescriptor, &buf, buf.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            try? netCaptureFile.write(contentsOf: Data(bytes: buf, count: n))
            // Card N3: if the guest asked an ARP request, answer it from
            // the host. The reply is written into the runner's socket end
            // (fds[1]) — the card-N2 host→guest direction (VZ reads
            // fds[0]), so the guest receives it; the capture file above
            // keeps only guest TX (byte-exact, unchanged).
            if let hostIP = netArpRespondHostIP, isArpRequest(buf, n) {
                var reply = [UInt8](repeating: 0, count: 42)
                buildArpReply(&reply, buf, n, arpHostMAC, hostIP)
                try? netCaptureReadSocket!.write(contentsOf: Data(reply))
                print("NET-ARP: answered the guest's ARP request for \(buf[28]).\(buf[29]).\(buf[30]).\(buf[31]) with host MAC 02:00:00:00:00:02")
            }
            // Card N4: if the guest pinged our address, echo it back from
            // the host (same socket direction; the capture file above
            // keeps only guest TX, byte-exact, unchanged).
            if let hostIP = netIcmpRespondHostIP, isIcmpEchoRequest(buf, n, hostIP) {
                var reply = [UInt8](repeating: 0, count: n)
                buildIcmpEchoReply(&reply, buf, n, arpHostMAC, hostIP)
                try? netCaptureReadSocket!.write(contentsOf: Data(reply))
                print("NET-ICMP: answered the guest's echo request for \(hostIP[0]).\(hostIP[1]).\(hostIP[2]).\(hostIP[3]) (id \(reply[38] << 8 | reply[39]), seq \(reply[40] << 8 | reply[41]))")
            }
            // Card N5: if the guest sent a UDP datagram to our ip:port,
            // echo it back from the host (same socket direction; the
            // capture file above keeps only guest TX, byte-exact,
            // unchanged).
            if let hostIP = netUdpRespondHostIP, let hostPort = netUdpRespondHostPort,
               isUdpDatagram(buf, n, hostIP, hostPort) {
                var reply = [UInt8](repeating: 0, count: n)
                buildUdpReply(&reply, buf, n, arpHostMAC, hostIP, hostPort)
                try? netCaptureReadSocket!.write(contentsOf: Data(reply))
                let srcPort = (UInt16(buf[34]) << 8) | UInt16(buf[35])
                print("NET-UDP: answered the guest's datagram for \(hostIP[0]).\(hostIP[1]).\(hostIP[2]).\(hostIP[3]):\(hostPort) (reply to guest src port \(srcPort), \(n - 42) payload bytes)")
            }
        }
        try? netCaptureFile.synchronize()
        netCaptureDone.signal()
    }
    netCaptureThread?.start()
    let netAttachment = VZFileHandleNetworkDeviceAttachment(fileHandle: netCaptureSocket!)
    let netConfig = VZVirtioNetworkDeviceConfiguration()
    netConfig.attachment = netAttachment
    guard let fixedMAC = VZMACAddress(string: "02:00:00:00:00:01") else {
        fail("Could not parse the fixed net MAC address.")
    }
    netConfig.macAddress = fixedMAC
    config.networkDevices = [netConfig]
} else {
    config.networkDevices = []
}
#if SPIKE
if customVirtioEnabled, #available(macOS 27.0, *) {
    // The runtime guard above already requires macOS 27+; the availability
    // check exists only because the manifest floor (.v26, for the CI
    // toolchain) is below the custom-virtio APIs' 27.0 introduction. The
    // whole spike is additionally gated behind the SPIKE define: the CI
    // toolchain's SDK (macOS 26) does not declare the custom-virtio types
    // at all, so the base `swift build` must not reference them.
    print(CustomVirtioSpike.attach(to: config))
}
#endif
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
    print("  NOTE: guest RX is the polled virtio receive queue (claim 6684) — host bytes reach the kernel via the serial attachment")
    print("  controls: Ctrl-C ends the session and restores the terminal; Backspace/Enter are forwarded raw (no host line editing)")
} else if scriptMode {
    print("  mode: scripted input (non-interactive; claim 6684)")
    print("  serial log: \(serialLogPath)  (guest output teed to log)")
    print("  script: \(scriptPath!)  (forwarded once after the configured serial marker appears)")
    if let scriptAfter { print("  script-after: \"\(scriptAfter)\"  (forward once after this serial text appears)") }
    if let script2Path { print("  script2: \(script2Path)  (claim 4613: forwarded once after script2-after appears)") }
    if let script2After { print("  script2-after: \"\(script2After)\"  (forward script2 once after this serial text appears)") }
    if let script3Path { print("  script3: \(script3Path)  (claim 7786: forwarded once after script3-after appears)") }
    if let script3After { print("  script3-after: \"\(script3After)\"  (forward script3 once after this serial text appears)") }
    if let scriptExpect { print("  script-expect: \"\(scriptExpect)\"  (exit 0 iff observed in the serial log)") }
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
if let netCapturePath {
    print("  net: ENABLED (milestone five card N1, claim 1373) — virtio-net device attached, guest TX frames captured byte-exactly to \(netCapturePath), fixed MAC 02:00:00:00:00:01")
}
if displayMode {
    print("  display: ENABLED (milestone six card G1, claim 6053) — virtio-gpu device attached, 1280x720 scanout window shown for the session")
}
if let netInjectPath {
    print("  net-inject: ENABLED (milestone five card N2, claim 6076) — \(netInjectPath) written into the attachment's socket once after \"\(netInjectAfter ?? "net: rx-armed")\" appears in the serial log (host→guest RX)")
}
if let hostIP = netArpRespondHostIP {
    let ipText = hostIP.map(String.init).joined(separator: ".")
    print("  net-arp-respond: ENABLED (milestone five card N3, claim 7293) — the host answers the guest's ARP requests for \(ipText) (host MAC 02:00:00:00:00:02) via the capture thread (deterministic, request-driven)")
}
if let hostIP = netIcmpRespondHostIP {
    let ipText = hostIP.map(String.init).joined(separator: ".")
    print("  net-icmp-respond: ENABLED (milestone five card N4, claim 0148) — the host answers the guest's ICMP echo requests for \(ipText) (host MAC 02:00:00:00:00:02) via the capture thread (deterministic, request-driven)")
}
if let hostIP = netUdpRespondHostIP, let hostPort = netUdpRespondHostPort {
    let ipText = hostIP.map(String.init).joined(separator: ".")
    print("  net-udp-respond: ENABLED (milestone five card N5, claim 8552) — the host answers the guest's UDP datagrams for \(ipText):\(hostPort) (host MAC 02:00:00:00:00:02) via the capture thread (deterministic, request-driven)")
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

// Milestone six card G1 (claim 6053): create the AppKit window + the
// VZVirtualMachineView the virtio-gpu scanout renders into, whenever the
// gpu device is attached (`--display` and/or `--screenshot`). Shared by
// the evidence path and script mode so a gated run can screenshot the
// guest framebuffer mid-script.
func setupDisplayWindow() {
    guard screenshotPath != nil || displayMode else { return }
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
    machineWindow = window
}

// Milestone six card G1 (claim 6053): the 5/10/15 s screenshot capture,
// shared by the evidence poll and scriptPoll so a gated scripted run can
// capture the guest framebuffer. The evidence now comes from
// ScreenCaptureKit — the runner's own window captured by ID and cropped
// to the content area, i.e. the composited pixels exactly as the operator
// sees them in `--display` (title bar excluded via the window's own frame
// geometry). The offscreen `cacheDisplay` render remains as the honest
// fallback when Screen Recording permission is unavailable (TCC not
// granted, headless CI, ...); the printed capture path says which one
// produced the PNG.
func captureScreenshot(at t: TimeInterval) {
    let path: String
    if let base = screenshotPath {
        let dot = (base as NSString).deletingPathExtension
        let ext = (base as NSString).pathExtension
        path = ext.isEmpty ? "\(dot)-\(Int(t))s" : "\(dot)-\(Int(t))s.\(ext)"
    } else {
        path = "artifacts/vm-screen-\(Int(t))s.png"
    }

    var png: Data?
    if let img = screenCaptureKitScreenshot() {
        let rep = NSBitmapImageRep(cgImage: img)
        if let data = rep.representation(using: .png, properties: [:]) {
            png = data
            print("  capture path: ScreenCaptureKit (composited window, \(img.width)x\(img.height) px)")
        }
    }
    if png == nil, let view = machineView,
       let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: rep)
        png = rep.representation(using: .png, properties: [:]) ?? png
        print("  capture path: cacheDisplay fallback (Screen Recording permission unavailable)")
    }
    guard let data = png else { return }
    do {
        try data.write(to: URL(fileURLWithPath: path))
        print("SUCCESS: framebuffer screenshot saved to \(path) (\(data.count) bytes).")
        screenshotSaved = true
    } catch { print("WARNING: could not write screenshot: \(error)") }
}

// ScreenCaptureKit path: capture OUR window by ID via a window content
// filter (SCShareableContent -> SCContentFilter(display:includingWindows:))
// and crop the title bar off, so the evidence is the composited content
// area exactly as the operator sees it in `--display`. No display-space
// coordinate math is involved — the filter captures the window and the
// title bar height comes from the window's own frame geometry. Screen
// Recording permission is required; the caller falls back to cacheDisplay
// when the capture fails.
func screenCaptureKitScreenshot() -> CGImage? {
    guard let window = machineWindow else { return nil }
    let windowID = CGWindowID(window.windowNumber)
    guard windowID > 0 else { return nil }

    let sem = DispatchSemaphore(value: 0)
    var scWindow: SCWindow?
    var display: SCDisplay?
    SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
        if let error {
            print("WARNING: SCShareableContent failed: \(error)")
        } else if let content {
            scWindow = content.windows.first { $0.windowID == windowID }
            display = content.displays.first
            if scWindow == nil {
                print("WARNING: window \(windowID) not in SCK shareable content (off-screen?)")
            }
        }
        sem.signal()
    }
    if sem.wait(timeout: .now() + 5) == .timedOut {
        print("WARNING: SCShareableContent timed out")
        return nil
    }
    guard let scWindow, let display else { return nil }

    let filter = SCContentFilter(display: display, including: [scWindow])
    let config = SCScreenshotConfiguration()
    config.showsCursor = false
    config.ignoreShadows = true

    var image: CGImage?
    let sem2 = DispatchSemaphore(value: 0)
    SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config) { output, error in
        if let error {
            print("WARNING: ScreenCaptureKit capture failed: \(error)")
        } else {
            image = output?.sdrImage
        }
        sem2.signal()
    }
    if sem2.wait(timeout: .now() + 5) == .timedOut {
        print("WARNING: ScreenCaptureKit capture timed out")
        return nil
    }
    guard let full = image else { return nil }

    // The window capture includes the title bar (the frame above the
    // content view). Crop it off using the window's own geometry so the
    // evidence is exactly the view's content area (what cacheDisplay
    // produced before, so the gate pixel math is unchanged).
    let titleBar = window.frame.height - window.contentLayoutRect.height
    let scale = filter.pointPixelScale > 0 ? CGFloat(filter.pointPixelScale) : (window.screen?.backingScaleFactor ?? 2.0)
    let crop = CGRect(x: 0,
                      y: titleBar * scale,
                      width: window.contentLayoutRect.width * scale,
                      height: window.contentLayoutRect.height * scale)
    print("  sck debug: window=\(windowID) raw=\(full.width)x\(full.height) scale=\(scale) titleBar=\(titleBar) crop=\(NSStringFromRect(crop))")
    guard crop.width > 0, crop.height > 0,
          crop.minX >= 0, crop.minY >= 0,
          crop.maxX <= Double(full.width), crop.maxY <= Double(full.height),
          let cropped = full.cropping(to: crop) else {
        return full
    }
    return cropped
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
            // Milestone five card N1 (claim 1373): the VM is stopped, so the
            // net attachment is quiescent — stop the reader (closing the
            // runner's socket end unblocks its read), join it, and close the
            // capture file so the gate can assert the guest's frames
            // byte-exactly.
            if netCaptureSocket != nil {
                netCaptureStop = true
                try? netCaptureReadSocket?.close()
                _ = netCaptureDone.wait(timeout: .now() + 2)
                try? netCaptureHandle?.close()
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
    ("M2_TXST!", [0x21, 0x54, 0x53, 0x58, 0x54, 0x5f, 0x32, 0x4d]), // !TSXT_2M (virtio flush entered, desc/avail posted)
    ("M2_TXNT!", [0x21, 0x54, 0x4e, 0x58, 0x54, 0x5f, 0x32, 0x4d]), // !TNXT_2M (notify write issued)
    ("M2_TXPL!", [0x21, 0x4c, 0x50, 0x58, 0x54, 0x5f, 0x32, 0x4d]), // !LPXT_2M (used-ring poll finished)
    ("M2_PEXT!", [0x21, 0x54, 0x58, 0x45, 0x50, 0x5f, 0x32, 0x4d]), // !TXEP_2M (claim 0017: pre-exit TX experiment entered)
    ("M2_PEXD!", [0x21, 0x44, 0x58, 0x45, 0x50, 0x5f, 0x32, 0x4d]), // !DXEP_2M (claim 0017: pre-exit TX experiment flush returned)
    ("M2_TXFL!", [0x21, 0x4c, 0x46, 0x58, 0x54, 0x5f, 0x32, 0x4d]), // !LFXT_2M (claim 0018: entered virtio flush)
    ("M2_TXDA!", [0x21, 0x41, 0x44, 0x58, 0x54, 0x5f, 0x32, 0x4d]), // !ADXT_2M (desc/avail prepared)
    ("M2_TXCC!", [0x21, 0x43, 0x43, 0x58, 0x54, 0x5f, 0x32, 0x4d]), // !CCXT_2M (DMA cache clean completed)
    ("M2_TXBR!", [0x21, 0x52, 0x42, 0x58, 0x54, 0x5f, 0x32, 0x4d]), // !RBXT_2M (before first post-exit BAR/common-cfg read)
    ("M2_TXAR!", [0x21, 0x52, 0x41, 0x58, 0x54, 0x5f, 0x32, 0x4d]), // !RAXT_2M (after that read)
    ("M2_TXBN!", [0x21, 0x4e, 0x42, 0x58, 0x54, 0x5f, 0x32, 0x4d]), // !NBXT_2M (before queue notify MMIO write)
    ("M2_TXAN!", [0x21, 0x4e, 0x41, 0x58, 0x54, 0x5f, 0x32, 0x4d]), // !NAXT_2M (after notify)
    ("M2_TXUP!", [0x21, 0x50, 0x55, 0x58, 0x54, 0x5f, 0x32, 0x4d]), // !PUXT_2M (entered used-ring poll)
    ("M2_TXUC!", [0x21, 0x43, 0x55, 0x58, 0x54, 0x5f, 0x32, 0x4d]), // !CUXT_2M (device changed used.idx)
    ("M2_TXFR!", [0x21, 0x52, 0x46, 0x58, 0x54, 0x5f, 0x32, 0x4d]), // !RFXT_2M (flush returned)
    ("M2_TRA1!", [0x21, 0x31, 0x41, 0x52, 0x54, 0x5f, 0x32, 0x4d]), // !1ART_2M (claim 0020 phase A: pre-EBS TX experiment entered)
    ("M2_TRA2!", [0x21, 0x32, 0x41, 0x52, 0x54, 0x5f, 0x32, 0x4d]), // !2ART_2M (phase A: flush returned)
    ("M2_TRAU!", [0x21, 0x55, 0x41, 0x52, 0x54, 0x5f, 0x32, 0x4d]), // !UART_2M (phase A: used.idx advanced)
    ("M2_TRB1!", [0x21, 0x31, 0x42, 0x52, 0x54, 0x5f, 0x32, 0x4d]), // !1BRT_2M (phase B: post-EBS/pre-MMU experiment entered)
    ("M2_TRB2!", [0x21, 0x32, 0x42, 0x52, 0x54, 0x5f, 0x32, 0x4d]), // !2BRT_2M (phase B: flush returned)
    ("M2_TRBU!", [0x21, 0x55, 0x42, 0x52, 0x54, 0x5f, 0x32, 0x4d]), // !UBRT_2M (phase B: used.idx advanced)
    ("M2_TRC1!", [0x21, 0x31, 0x43, 0x52, 0x54, 0x5f, 0x32, 0x4d]), // !1CRT_2M (phase C: post-MMU experiment entered)
    ("M2_TRC2!", [0x21, 0x32, 0x43, 0x52, 0x54, 0x5f, 0x32, 0x4d]), // !2CRT_2M (phase C: flush returned)
    ("M2_TRCU!", [0x21, 0x55, 0x43, 0x52, 0x54, 0x5f, 0x32, 0x4d]), // !UCRT_2M (phase C: used.idx advanced)
    ("M2_TRD1!", [0x21, 0x31, 0x44, 0x52, 0x54, 0x5f, 0x32, 0x4d]), // !1DRT_2M (phase D: final-location experiment entered)
    ("M2_TRD2!", [0x21, 0x32, 0x44, 0x52, 0x54, 0x5f, 0x32, 0x4d]), // !2DRT_2M (phase D: flush returned)
    ("M2_TRDU!", [0x21, 0x55, 0x44, 0x52, 0x54, 0x5f, 0x32, 0x4d]), // !UDRT_2M (phase D: used.idx advanced)
    ("M2_TRNX!", [0x21, 0x58, 0x4e, 0x52, 0x54, 0x5f, 0x32, 0x4d]), // !XNR T_2M (claim 0020: experiment skipped — transport not armed)
    ("M2_WP_00", [0x30, 0x30, 0x5f, 0x50, 0x57, 0x5f, 0x32, 0x4d]), // 00_PW_2M (claim 7896 walk-probe battery start)
    ("M2_WP_01", [0x31, 0x30, 0x5f, 0x50, 0x57, 0x5f, 0x32, 0x4d]), // 10_PW_2M (claim 7896: P1 kernel-BSS read returned)
    ("M2_WP_02", [0x32, 0x30, 0x5f, 0x50, 0x57, 0x5f, 0x32, 0x4d]), // 20_PW_2M (claim 7896: P2 ram-hi read returned)
    ("M2_WP_03", [0x33, 0x30, 0x5f, 0x50, 0x57, 0x5f, 0x32, 0x4d]), // 30_PW_2M (claim 7896: P3 ram-mid read returned)
    ("M2_WP_04", [0x34, 0x30, 0x5f, 0x50, 0x57, 0x5f, 0x32, 0x4d]), // 40_PW_2M (claim 7896: P4 ram-lo read returned)
    ("M2_WP_05", [0x35, 0x30, 0x5f, 0x50, 0x57, 0x5f, 0x32, 0x4d]), // 50_PW_2M (claim 7896: P5 virtio-BAR read returned — battery complete)
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

    captureScreenshotIfDue()

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

// Milestone six card G1 (claim 6053): the 5/10/15 s screenshot capture,
// shared by the evidence poll and scriptPoll so a gated scripted run can
// capture the guest framebuffer.
func captureScreenshotIfDue() {
    if screenshotPath != nil {
        let elapsed = Date().timeIntervalSince(startTime)
        if let next = captureTimes.first(where: { $0 <= elapsed }) {
            captureTimes.removeAll { $0 == next }
            captureScreenshot(at: next)
        }
    }
}

// ---------------------------------------------------------------------------
// Console mode: streaming tee, stdin forwarding, signal-safe exit.
// ---------------------------------------------------------------------------

func startGuestOutputTee() {
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
}

func startStdinForwarding() {
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

func startConsoleStreams() {
    startGuestOutputTee()
    startStdinForwarding()
}

// Claim 6684: scripted-input mode. Waits until the guest has reached the
// configured serial marker (the takeover terminal state by default), then
// forwards the script file's bytes exactly once into the serial attachment.
// The guest supplied its
// virtio RX buffer pre-exit, so nothing is lost while we wait; the settle
// delay only avoids racing the shell's very first poll.
func startScriptInput() {
    guard let scriptPath else { return }
    forwardScriptOnce(path: scriptPath, after: scriptAfter, label: "script")
}

// Claim 4613: the SECOND scripted phase. The primary --script is forwarded
// in ONE burst, so a command that must land AFTER a background program
// exits and is reaped (the long-lived gate re-execs USER.BIN into the
// freed pool slot) cannot be in the same burst. --script2 is forwarded
// once, after its own serial marker (the first USER.BIN's reap line),
// using the identical settle-then-forward machinery.
func startScript2Input() {
    guard let path = script2Path, let after = script2After else { return }
    forwardScriptOnce(path: path, after: after, label: "script2")
}

// Card 3c (claim 7786): the THIRD scripted phase. The kill gate needs a
// post-reap snapshot — the `procs | pages | exec USER.BIN | procs` read
// that proves the killed process's pages returned and its slot was
// re-used — which must land AFTER the kill's reap line, so it cannot be
// in the one-burst primary script (claim 6684) or the claim-4613 second
// phase. --script3 is forwarded once after its own serial marker using
// the same settle-then-forward machinery.
func startScript3Input() {
    guard let path = script3Path, let after = script3After else { return }
    forwardScriptOnce(path: path, after: after, label: "script3")
}

/// Forward `path` into the serial attachment exactly once, after `after`
/// appears in the serial log (default: the kernel terminal state). Shared
/// by the primary script (claim 6684) and the second phase (claim 4613).
func forwardScriptOnce(path: String, after: String?, label: String) {
    let q = DispatchQueue(label: "dipshitos.\(label)")
    q.async {
        let scriptData: Data
        do {
            scriptData = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("ERROR: could not read script file '\(path)': \(error)\n".utf8))
            exit(1)
        }
        let marker = after ?? "kernel terminal state"
        let waitDeadline = Date().addingTimeInterval(40)
        var sent = false
        while Date() < waitDeadline {
            if let text = try? String(contentsOf: serialURL, encoding: .utf8),
               text.contains(marker) {
                Thread.sleep(forTimeInterval: 0.5)
                do { try consoleInputPipe.fileHandleForWriting.write(contentsOf: scriptData) }
                catch {
                    FileHandle.standardError.write(Data("ERROR: could not forward script to the guest serial attachment: \(error)\n".utf8))
                }
                sent = true
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        if !sent {
            FileHandle.standardError.write(Data("ERROR: guest did not emit \(label)-after marker '\(marker)' within 40s; script input not sent\n".utf8))
        }
    }
}

// Claim 6076 (milestone five card N2): the host→guest RX injection. Waits
// until the trigger marker appears in the serial log (default: the guest's
// `net: rx-armed` line — the queue-0 RX buffer is guaranteed supplied and
// kicked, so the datagram cannot race an unarmed ring), then writes the
// --net-inject file's bytes into the runner's OTHER end of the attachment
// socketpair EXACTLY ONCE. Direction (observed in the claim-6076 probe):
// the attachment socket is fds[0], the reader's end is fds[1] — VZ READS
// fds[0] for host→guest packets and WRITES fds[0] for guest→host packets,
// so on a socketpair a datagram written to fds[1] is exactly what VZ's
// read on fds[0] consumes (a write to fds[0] instead would be captured by
// the runner's own reader and never reach the guest — the probe's capture
// held the injected bytes). The reader thread reads fds[1] for datagrams
// written to fds[0] (guest TX), so the two directions never race. The
// injected bytes are the raw Ethernet frame the guest's net recv must
// print byte-exact. Deterministic — a serial trigger, not a sleep.
// Requires --net (validated at parse time); a no-op without it.
func startNetInject() {
    guard let path = netInjectPath, let socket = netCaptureReadSocket else { return }
    let q = DispatchQueue(label: "dipshitos.netinject")
    q.async {
        let injectData: Data
        do {
            injectData = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("ERROR: could not read net-inject file '\(path)': \(error)\n".utf8))
            exit(1)
        }
        let marker = netInjectAfter ?? "net: rx-armed"
        let waitDeadline = Date().addingTimeInterval(40)
        var sent = false
        // Poll every 20 ms (claim 7293): a scripted gate that injects at a
        // MID-SCRIPT marker (the guest's `net ip: ip=...` echo, not a
        // boot-time marker) must not race the commands that follow the
        // marker — the guest executes the script burst in tens of ms, so a
        // 0.5 s poll would land the datagram AFTER the observation
        // commands already ran.
        while Date() < waitDeadline {
            if let text = try? String(contentsOf: serialURL, encoding: .utf8),
               text.contains(marker) {
                // One datagram per write (SOCK_DGRAM); the injected bytes
                // are the raw Ethernet frame the guest must receive.
                do {
                    try socket.write(contentsOf: injectData)
                    FileHandle.standardOutput.write(Data("NET-INJECT: sent \(injectData.count) byte(s) into the attachment socketpair (VZ reads fds[0]) after \"\(marker)\"\n".utf8))
                } catch {
                    FileHandle.standardError.write(Data("ERROR: net-inject write failed: \(error)\n".utf8))
                }
                sent = true
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if !sent {
            FileHandle.standardError.write(Data("ERROR: guest did not emit net-inject marker '\(marker)' within 40s; injection not sent\n".utf8))
        }
    }
}

// Card N3 (claim 7293): is the datagram an ARP request (Ethernet II
// ethertype 0x0806, ARP htype 1 / ptype 0x0800 / hlen 6 / plen 4, op 1)?
// The guest's request frames are raw Ethernet — dst ff*6 (broadcast),
// src own MAC, ethertype at bytes 12-13, the ARP payload at 14..42.
func isArpRequest(_ buf: [UInt8], _ n: Int) -> Bool {
    guard n >= 42 else { return false }
    guard buf[12] == 0x08 && buf[13] == 0x06 else { return false }
    guard buf[14] == 0x00 && buf[15] == 0x01 else { return false } // htype ethernet
    guard buf[16] == 0x08 && buf[17] == 0x00 else { return false } // ptype IPv4
    guard buf[18] == 0x06 && buf[19] == 0x04 else { return false } // hlen/plen
    guard buf[20] == 0x00 && buf[21] == 0x01 else { return false } // op request
    return true
}

// Card N3 (claim 7293): synthesize the 42-byte ARP REPLY to the request in
// `req` (the guest's bytes): dst = the requester's MAC, src = host MAC,
// ethertype 0x0806, op 2, sha/spa = host MAC/IP, tha/tpa = the requester's
// MAC/IP (copied from the request's sha/spa — the standard answer shape).
func buildArpReply(_ reply: inout [UInt8], _ req: [UInt8], _ n: Int, _ hostMAC: [UInt8], _ hostIP: [UInt8]) {
    _ = n
    reply[0...5] = req[22...27] // dst = the requester's MAC (its sha)
    reply[6...11] = hostMAC[0...5] // src
    reply[12] = 0x08
    reply[13] = 0x06
    reply[14] = 0x00
    reply[15] = 0x01
    reply[16] = 0x08
    reply[17] = 0x00
    reply[18] = 0x06
    reply[19] = 0x04
    reply[20] = 0x00
    reply[21] = 0x02 // op reply
    reply[22...27] = hostMAC[0...5] // sha
    reply[28...31] = hostIP[0...3] // spa
    reply[32...37] = req[22...27] // tha = the requester's MAC
    reply[38...41] = req[28...31] // tpa = the requester's IP
}

// Card N4 (claim 0148): RFC 1071 one's-complement checksum over
// `bytes[start..<end]` (big-endian 16-bit words, folded; the checksummed
// field must be zero by the caller).
@Sendable func ipChecksum(_ bytes: [UInt8], _ start: Int, _ end: Int) -> UInt16 {
    var sum: UInt32 = 0
    var i = start
    while i + 1 < end {
        sum += (UInt32(bytes[i]) << 8) | UInt32(bytes[i + 1])
        i += 2
    }
    if i < end { sum += UInt32(bytes[i]) << 8 } // trailing odd byte
    while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
    return UInt16(~sum & 0xffff)
}

// Card N4 (claim 0148): is the datagram an ICMP ECHO REQUEST for our
// address? Ethernet II ethertype 0x0800, version 4 / IHL 5 (0x45),
// protocol ICMP (1), dst IP == `hostIP`, ICMP type 8. The guest's
// `net ping` frames are raw Ethernet — header at 14..34, ICMP at 34.
func isIcmpEchoRequest(_ buf: [UInt8], _ n: Int, _ hostIP: [UInt8]) -> Bool {
    guard n >= 46 else { return false }
    guard buf[12] == 0x08 && buf[13] == 0x00 else { return false } // ethertype IPv4
    guard buf[14] == 0x45 else { return false } // version 4, IHL 5
    guard (buf[20] & 0x1f) == 0 && buf[21] == 0 else { return false } // NOT a fragment (the ICMP header would not be at 34)
    guard buf[23] == 0x01 else { return false } // protocol ICMP
    guard buf[30] == hostIP[0] && buf[31] == hostIP[1] && buf[32] == hostIP[2] && buf[33] == hostIP[3] else { return false }
    guard buf[34] == 0x08 else { return false } // ICMP echo request
    return true
}

// Card N5 (claim 8552): the UDP checksum over the IPv4 pseudo-header
// (src IP, dst IP, zero, protocol 17, UDP length) + the datagram (RFC
// 768 §2 / RFC 1071; the checksum field must be zero during the build).
@Sendable func udpChecksum(_ srcIP: [UInt8], _ dstIP: [UInt8], _ datagram: [UInt8], _ udpLen: UInt16) -> UInt16 {
    var words: [UInt16] = []
    func push(_ hi: UInt8, _ lo: UInt8) {
        words.append((UInt16(hi) << 8) | UInt16(lo))
    }
    push(srcIP[0], srcIP[1])
    push(srcIP[2], srcIP[3])
    push(dstIP[0], dstIP[1])
    push(dstIP[2], dstIP[3])
    words.append(UInt16(17)) // zero + protocol UDP
    words.append(udpLen)
    var i = 0
    while i + 1 < datagram.count {
        push(datagram[i], datagram[i + 1])
        i += 2
    }
    if i < datagram.count { push(datagram[i], 0) }
    var sum: UInt32 = 0
    for w in words { sum += UInt32(w) }
    while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
    return UInt16(~sum & 0xffff)
}

// Card N5 (claim 8552): is the datagram a UDP datagram addressed to
// `hostIP:hostPort`? Ethernet II ethertype 0x0800, version 4 / IHL 5,
// NOT a fragment, protocol UDP (17), dst IP match, dst port match.
func isUdpDatagram(_ buf: [UInt8], _ n: Int, _ hostIP: [UInt8], _ hostPort: UInt16) -> Bool {
    guard n >= 46 else { return false }
    guard buf[12] == 0x08 && buf[13] == 0x00 else { return false } // ethertype IPv4
    guard buf[14] == 0x45 else { return false } // version 4, IHL 5
    guard (buf[20] & 0x1f) == 0 && buf[21] == 0 else { return false } // NOT a fragment
    guard buf[23] == 17 else { return false } // protocol UDP
    guard buf[30] == hostIP[0] && buf[31] == hostIP[1] && buf[32] == hostIP[2] && buf[33] == hostIP[3] else { return false }
    let dstPort = (UInt16(buf[36]) << 8) | UInt16(buf[37])
    return dstPort == hostPort
}

// Card N5 (claim 8552): synthesize the UDP REPLY to the datagram in `req`
// (the guest's bytes) into `reply` (same length): Ethernet dst/src
// swapped, ethertype 0x0800, IPv4 src/dst swapped (identification
// ECHOED — deterministic), TTL 64, protocol 17, UDP src port = the host
// port, dst port = the sender's src port, the payload ECHOED byte-exact;
// the IPv4 header checksum + the UDP pseudo-header checksum recomputed.
func buildUdpReply(_ reply: inout [UInt8], _ req: [UInt8], _ n: Int, _ hostMAC: [UInt8], _ hostIP: [UInt8], _ hostPort: UInt16) {
    reply = [UInt8](repeating: 0, count: n)
    reply[0...5] = req[6...11] // dst = the sender's MAC
    reply[6...11] = hostMAC[0...5] // src
    reply[12] = 0x08
    reply[13] = 0x00 // ethertype IPv4
    reply[14] = 0x45 // version 4, IHL 5
    reply[16...17] = req[16...17] // total length (unchanged)
    reply[18...19] = req[18...19] // identification ECHOED
    reply[22] = 64 // TTL
    reply[23] = 17 // protocol UDP
    reply[26...29] = hostIP[0...3] // src = our address
    reply[30...33] = req[26...29] // dst = the sender's address
    let hdrChk = ipChecksum(reply, 14, 34)
    reply[24] = UInt8(hdrChk >> 8)
    reply[25] = UInt8(hdrChk & 0xff)
    // UDP: src = the host port, dst = the sender's src port, length
    // echoed, the payload echoed byte-exact; checksum recomputed.
    reply[34] = UInt8(hostPort >> 8)
    reply[35] = UInt8(hostPort & 0xff)
    reply[36] = req[34] // the sender's src port
    reply[37] = req[35]
    reply[38...39] = req[38...39] // UDP length (unchanged)
    let udpLen = (UInt16(req[38]) << 8) | UInt16(req[39])
    let payloadStart = 42
    if n > payloadStart {
        reply[payloadStart...n - 1] = req[payloadStart...n - 1] // payload echoed
    }
    let senderIP = [UInt8](req[26...29])
    var datagram = [UInt8](reply[34..<n])
    datagram[6] = 0
    datagram[7] = 0 // zero the checksum field during the computation
    let udpChk = udpChecksum(hostIP, senderIP, datagram, udpLen)
    reply[40] = UInt8(udpChk >> 8)
    reply[41] = UInt8(udpChk & 0xff)
}

// Card N4 (claim 0148): synthesize the ICMP ECHO REPLY to the echo
// request in `req` (the guest's bytes) into `reply` (same length):
// Ethernet dst/src swapped, ethertype 0x0800, IPv4 src/dst swapped, the
// identification ECHOED (deterministic — the gate asserts it), TTL 64,
// protocol 1, ICMP type 0 with the id/seq/payload echoed byte-exact;
// both checksums recomputed (RFC 1071).
func buildIcmpEchoReply(_ reply: inout [UInt8], _ req: [UInt8], _ n: Int, _ hostMAC: [UInt8], _ hostIP: [UInt8]) {
    reply = [UInt8](repeating: 0, count: n)
    reply[0...5] = req[6...11] // dst = the requester's MAC
    reply[6...11] = hostMAC[0...5] // src
    reply[12] = 0x08
    reply[13] = 0x00 // ethertype IPv4
    reply[14] = 0x45 // version 4, IHL 5
    reply[16...17] = req[16...17] // total length (unchanged)
    reply[18...19] = req[18...19] // identification ECHOED
    reply[22] = 64 // TTL
    reply[23] = 0x01 // protocol ICMP
    reply[26...29] = hostIP[0...3] // src = our address
    reply[30...33] = req[26...29] // dst = the requester's address
    let hdrChk = ipChecksum(reply, 14, 34)
    reply[24] = UInt8(hdrChk >> 8)
    reply[25] = UInt8(hdrChk & 0xff)
    reply[34] = 0x00 // ICMP echo reply
    reply[35] = 0x00 // code
    reply[38...n - 1] = req[38...n - 1] // id + seq + payload echoed
    let icmpChk = ipChecksum(reply, 34, n)
    reply[36] = UInt8(icmpChk >> 8)
    reply[37] = UInt8(icmpChk & 0xff)
}

// Claim 6684: script-mode lifecycle. Polls the serial log for the expected
// transcript; success (exit 0) as soon as it appears, failure on timeout or
// an early VM stop.
func scriptPoll() {
    if vmDidStart && (runner.vm.state == .stopped || runner.vm.state == .error) {
        print("FAILURE: VM ended before the expected transcript appeared (state=\(runner.vm.state.rawValue)).")
        finish(success: false)
        return
    }
    if let data = try? Data(contentsOf: serialURL), let text = String(data: data, encoding: .utf8) {
        if !text.isEmpty { lastText = text }
        if let expect = scriptExpect, text.contains(expect) {
            print("SUCCESS: expected transcript '\(expect)' observed in the serial log.")
            print("----- captured serial console -----")
            print(text)
            print("-----------------------------------")
            finish(success: true)
            return
        }
    }
    captureScreenshotIfDue()
    if Date() > deadline {
        print("FAILURE: expected transcript '\(scriptExpect ?? "<none>")' not observed within \(Int(timeout))s.")
        if !lastText.isEmpty {
            print("----- captured serial console (partial) -----")
            print(lastText)
            print("---------------------------------------------")
        }
        finish(success: scriptExpect == nil)
        return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { scriptPoll() }
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
} else if scriptMode {
    // Claim 6684: non-interactive scripted input — tee guest output to the
    // log, forward the script after the terminal state, poll for the
    // expected transcript. Milestone six card G1 (claim 6053): when the
    // gpu device is attached (`--display`/`--screenshot`), the window is
    // created here too so the scripted run can capture the framebuffer.
    setupDisplayWindow()
    startGuestOutputTee()
    startScriptInput()
    startScript2Input()
    startScript3Input()
    startNetInject()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { scriptPoll() }
} else {
    setupDisplayWindow()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { poll() }
}
RunLoop.main.run()

// ---------------------------------------------------------------------------
// macOS 27 spike (capability-audit step 3): one default-off custom virtio
// device, so the guest's PCI discovery can observe it on a real VZ boot.
//
// Compiled only with -DSPIKE (the `zig build spike-virtio` step): the CI
// toolchain's macOS 26 SDK does not declare VZCustomVirtioDevice at all, so
// this whole section must be absent from the base class-A build.
//
// Device identity (guest-facing): virtio-pci VID 0x1af4, DID = 0x1040 | 0x42
// = 0x1082 — distinct from the console's DID 0x1043 (claim 0013) and blk's
// 0x1042 (claim 6420). PCI class 0x00 / subclass 0x00, one virtqueue.
//
// SDK reality (Xcode 27 beta 4, macOS 27.0): the framework exposes NO
// host-triggered guest-interrupt API — the WWDC26 "trigger an interrupt on
// the device" claim has no public symbol; the word "interrupt" appears in
// exactly one framework header (a POSIX EINTR param). The only host->guest
// signaling is the framework-internal used-buffer notification when queue
// elements are returned via VZVirtioQueueElement.returnToQueue. This spike
// is discovery + transport evidence only; the DRIVER_OK / queue-notification
// logs below give the audit its step-4 hooks for free.
// ---------------------------------------------------------------------------

#if SPIKE

@available(macOS 27.0, *)
enum CustomVirtioSpike {
    /// Virtio device ID; PCI DID presented to the guest = 0x1040 | deviceID.
    static let deviceID: UInt16 = 0x42
    static let pciClass: UInt8 = 0x00
    static let pciSubclass: UInt8 = 0x00
    // Two queues (claims 4374/4837): queue 0 = the exchange/transport
    // queue, queue 1 = the guest log transport.
    static let queueCount: UInt16 = 2

    // The provider holds the configuration delegate *weakly* and the created
    // VZCustomVirtioDevice holds the device delegate *weakly* too, so both
    // delegates must be kept alive for the VM's whole lifetime or the device
    // silently goes deaf. Static stored properties live forever.
    static let configDelegate = CustomVirtioSpikeConfigDelegate()
    static let deviceDelegate = CustomVirtioSpikeDeviceDelegate()

    static func attach(to config: VZVirtualMachineConfiguration) -> String {
        let provider = VZCustomVirtioDeviceDelegateProvider(
            deviceQueue: DispatchQueue(label: "dipshitos.customvirtio"),
            delegate: configDelegate
        )

        let deviceConfig = VZCustomVirtioDeviceConfiguration()
        deviceConfig.deviceID = deviceID
        deviceConfig.pciClassID = pciClass
        deviceConfig.pciSubclassID = pciSubclass
        deviceConfig.virtioQueueCount = queueCount
        deviceConfig.provider = provider

        config.customVirtioDevices = [deviceConfig]

        let did = 0x1040 + Int(deviceID)  // virtio transitional PCI DID = 0x1040 + device_id (add, not OR)
        return String(
            format: "  custom virtio: ENABLED — VID 0x1af4 DID 0x%04x (virtio deviceID 0x%02x), class 0x%02x/0x%02x, %d queue(s); guest PCI discovery evidence (spike)",
            did, Int(deviceID), Int(pciClass), Int(pciSubclass), Int(queueCount)
        )
    }
}

/// Receives the created device and wires the device delegate. Called on the
/// VM's serial queue when VZVirtualMachine is created.
@available(macOS 27.0, *)
final class CustomVirtioSpikeConfigDelegate: NSObject, VZCustomVirtioDeviceConfigurationDelegate {
    func customVirtioConfiguration(_ deviceConfiguration: VZCustomVirtioDeviceConfiguration, didCreateDevice device: VZCustomVirtioDevice) {
        print("CUSTOM-VIRTIO: device created (didCreateDevice)")
        device.delegate = CustomVirtioSpike.deviceDelegate
    }
}

/// Device lifecycle + guest-driver evidence. Every method here is optional in
/// the protocol; only the ones the spike needs are implemented.
///
/// Audit step 4/5 (claim 0828): on a queue notification the delegate
/// dequeues every available element (the guest's known-payload descriptor),
/// logs the exact bytes, and returns the element via `returnToQueue` — the
/// framework then advances the used ring AND asserts the device's
/// interrupt (the framework-internal used-buffer notification, the only
/// host→guest signaling the macOS 27 SDK exposes). The callback runs on the
/// provider's deviceQueue (serial), so element access is single-threaded.
@available(macOS 27.0, *)
final class CustomVirtioSpikeDeviceDelegate: NSObject, VZCustomVirtioDeviceDelegate {
    func customVirtioDeviceDidAcceptDriverOk(_ device: VZCustomVirtioDevice) {
        print("CUSTOM-VIRTIO: guest set DRIVER_OK — negotiation complete, queues ready")
    }

    func customVirtioDevice(_ device: VZCustomVirtioDevice, didReceiveNotificationFor queue: VZVirtioQueue) {
        print("CUSTOM-VIRTIO: guest notified queue \(queue.queueIndex) (size \(queue.queueSize))")
        // Drain every available element (many may be in flight — claim
        // 4374's concurrency): queue 0 exchanges get the payload echoed
        // back verbatim; queue 1 log lines are printed to stdout and
        // answered with ACK:<len> (claim 4837). Then return each element
        // so the used ring advances (its length reflects writtenByteCount)
        // and the device IRQ asserts.
        while let element = queue.nextElement() {
            process(element: element, queueIndex: Int(queue.queueIndex))
        }
    }

    private func process(element: VZVirtioQueueElement, queueIndex: Int) {
        // Reassemble the guest's device-read spans (claim 9492: a
        // >4 KiB payload arrives as several readBuffers()).
        var bytes: [UInt8] = []
        for buffer in element.readBuffers() {
            bytes.append(contentsOf: [UInt8](buffer))
        }
        if queueIndex == 1 {
            // Guest log transport (claim 4837): print the line verbatim to
            // the runner stdout and write ACK:<len> back into the element's
            // write buffers — the guest verifies the ack.
            let line = String(bytes: bytes, encoding: .utf8) ?? "<non-utf8>"
            print("CUSTOM-VIRTIO-LOG: \(line)")
            let ack = Data("ACK:\(bytes.count)".utf8)
            do {
                try element.write(ack)
                print("CUSTOM-VIRTIO: log ack written (\(element.writtenByteCount) byte(s) into \(element.writeBuffersByteCount) byte(s) of write buffers)")
            } catch {
                print("CUSTOM-VIRTIO: log ack write FAILED: \(error)")
            }
        } else {
            // Queue-0 exchange: echo the exact reassembled payload back
            // (claim 0828's bidirectional flow, now length-agnostic). The
            // hex summary is bounded so a 12,340-byte payload does not
            // flood the runner log; the byte count + the guest's
            // byte-for-byte echo comparison carry the assertion.
            print("CUSTOM-VIRTIO: dequeued \(bytes.count) byte(s) (read \(element.readBuffersByteCount)): hex=[\(hexSummary(bytes))] ascii=\"\(printableAscii(bytes))\"")
            if element.writeBuffersByteCount >= bytes.count {
                do {
                    try element.write(Data(bytes))
                    print("CUSTOM-VIRTIO: echoed \(element.writtenByteCount) byte(s) into \(element.writeBuffersByteCount) byte(s) of write buffers")
                } catch {
                    print("CUSTOM-VIRTIO: reply write FAILED: \(error)")
                }
            } else {
                print("CUSTOM-VIRTIO: reply write skipped (write buffers \(element.writeBuffersByteCount) < \(bytes.count))")
            }
        }
        element.returnToQueue()
        print("CUSTOM-VIRTIO: returned element to queue \(queueIndex) — used ring advanced, device interrupt asserted")
    }

    /// Bounded hex rendering: full hex up to 64 bytes, otherwise the first
    /// and last 16 bytes + a 32-bit running sum (the claim-9492 big
    /// payload is 12,340 bytes of non-printable pattern).
    private func hexSummary(_ bytes: [UInt8]) -> String {
        let hex = { (slice: ArraySlice<UInt8>) in
            slice.map { String(format: "%02x", $0) }.joined(separator: " ")
        }
        if bytes.count <= 64 {
            return hex(bytes[0...])
        }
        var sum: UInt32 = 0
        for b in bytes { sum = sum &+ UInt32(b) }
        return "\(hex(bytes[0..<16]))..\(hex(bytes[(bytes.count - 16)...])) sum=0x\(String(format: "%08x", sum))"
    }

    /// The payload's ASCII form, or <binary> when any byte is non-printable
    /// (the big-payload pattern is binary by design).
    private func printableAscii(_ bytes: [UInt8]) -> String {
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7e }) else { return "<binary>" }
        return String(bytes: bytes, encoding: .utf8) ?? "<non-utf8>"
    }

    func customVirtioDeviceWillReset(_ device: VZCustomVirtioDevice) {
        print("CUSTOM-VIRTIO: device reset")
    }

    func customVirtioDeviceWillStop(_ device: VZCustomVirtioDevice) {
        print("CUSTOM-VIRTIO: device stopped")
    }
}

#endif

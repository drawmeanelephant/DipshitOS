// DipshitOS VM runner for the Apple Virtualization.framework path.
//
// Usage: VMRunner <disk-image> [serial-log] [--screen <png>]
//         [--timeout <s>] [--expect <line>] [--terminal-marker <line>]
// The runner starts the VZ guest, captures the virtio-console serial stream,
// and reports success only after the requested serial line and terminal line
// have both been observed. No guest filesystem or POSIX dependency is added.

import AppKit
import Foundation
import Virtualization

let arguments = CommandLine.arguments
let diskImagePath = arguments.count > 1 ? arguments[1] : "artifacts/disk.img"
var serialLogPath = "artifacts/vm-serial.log"
var screenshotPath: String?
var timeout: TimeInterval = 30
var expectLine = "firmware has agreed to cooperate"
var terminalMarker: String?

var idx = 2
while idx < arguments.count {
    let arg = arguments[idx]
    if arg == "--screen", idx + 1 < arguments.count {
        screenshotPath = arguments[idx + 1]
        idx += 2
    } else if arg == "--timeout", idx + 1 < arguments.count {
        timeout = TimeInterval(arguments[idx + 1]) ?? 30
        idx += 2
    } else if arg == "--expect", idx + 1 < arguments.count {
        expectLine = arguments[idx + 1]
        idx += 2
    } else if arg == "--terminal-marker", idx + 1 < arguments.count {
        terminalMarker = arguments[idx + 1]
        idx += 2
    } else {
        serialLogPath = arg
        idx += 1
    }
}

func fail(_ message: String) -> Never {
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

let serialURL = URL(fileURLWithPath: serialLogPath)
FileManager.default.createFile(atPath: serialURL.path, contents: nil)
let serialHandle: FileHandle
do {
    serialHandle = try FileHandle(forWritingTo: serialURL)
} catch {
    fail("Could not open serial log at \(serialURL.path): \(error)")
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
let serialConfig = VZVirtioConsoleDeviceSerialPortConfiguration()
serialConfig.attachment = VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: serialHandle)
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
let startTime = Date()
let deadline = startTime.addingTimeInterval(timeout)
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
print("  serial log: \(serialLogPath)  (timeout: \(Int(timeout))s)")
print("  expecting: \"\(expectLine)\"")
if let terminalMarker { print("  terminal marker: \"\(terminalMarker)\"") }

runner.queue.async {
    runner.vm.start { result in
        if case .failure(let error) = result {
            FileHandle.standardError.write(Data("ERROR: VM failed to start: \(error)\n".utf8))
            exit(1)
        }
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
    runner.queue.async { runner.vm.stop { _ in exit(success ? 0 : 1) } }
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
                    print("FAILURE: VM left the running state during terminal dwell (state=\\(runner.vm.state.rawValue)).")
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
RunLoop.main.run()

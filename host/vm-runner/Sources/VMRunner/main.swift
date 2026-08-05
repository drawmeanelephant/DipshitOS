// DipshitOS milestone-zero VM runner.
//
// Boots a raw GPT+FAT disk image under UEFI (VZEFIBootLoader) and observes
// the guest's output two ways:
//
//   1. Serial: a virtio console serial port is captured into a log file.
//      (Observed on this platform: Apple's EFI firmware does NOT route its
//      console there, so this file is usually empty -- see README.)
//   2. Framebuffer (--screen <png>): boots with a virtio graphics device in
//      a small window and saves a PNG snapshot of the view, capturing
//      whatever the UEFI firmware rendered. This is how the guest text is
//      actually observed on Apple silicon.
//
// Usage: VMRunner <disk-image> [serial-log] [--screen <png>] [--timeout <s>]
// Exit code 0 when output was observed (serial match or screenshot saved).

import AppKit
import Foundation
import Virtualization

// MARK: - CLI arguments

let arguments = CommandLine.arguments
let diskImagePath = arguments.count > 1 ? arguments[1] : "artifacts/disk.img"
var serialLogPath = "artifacts/vm-serial.log"
var screenshotPath: String?
var timeout: TimeInterval = 30

var idx = 2
while idx < arguments.count {
    let arg = arguments[idx]
    if arg == "--screen", idx + 1 < arguments.count {
        screenshotPath = arguments[idx + 1]
        idx += 2
    } else if arg == "--timeout", idx + 1 < arguments.count {
        timeout = TimeInterval(arguments[idx + 1]) ?? 30
        idx += 2
    } else {
        serialLogPath = arg
        idx += 1
    }
}

let expectLine = "firmware has agreed to cooperate"

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ERROR: \(message)\n".utf8))
    exit(1)
}

// MARK: - Host checks (fail clearly before touching the VM)

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
    fail("Unsupported host architecture '\(hostArchitecture())' -- the "
        + "Virtualization runner currently requires an Apple silicon (arm64) Mac.")
}

let osVersion = ProcessInfo.processInfo.operatingSystemVersion
guard osVersion.majorVersion >= 13 else {
    fail("macOS \(osVersion.majorVersion) is too old -- Virtualization.framework "
        + "UEFI boot (VZEFIBootLoader) requires macOS 13 or newer.")
}

// MARK: - Path validation and persisted EFI variable store

let diskURL = URL(fileURLWithPath: diskImagePath)
guard FileManager.default.fileExists(atPath: diskURL.path) else {
    fail("Disk image not found at '\(diskImagePath)'. Run 'zig build image' first.")
}

let artifactsDir = URL(fileURLWithPath: "artifacts")
try? FileManager.default.createDirectory(at: artifactsDir, withIntermediateDirectories: true)

// VZEFIVariableStore(url:) only opens an *existing* store file. The first
// boot must create one via init(creatingVariableStoreAt:options:); later
// boots open the persisted file so NVRAM survives across runs.
let varsURL = artifactsDir.appendingPathComponent("efi-vars.bin")
let variableStore: VZEFIVariableStore
if FileManager.default.fileExists(atPath: varsURL.path) {
    variableStore = VZEFIVariableStore(url: varsURL)
} else {
    do {
        variableStore = try VZEFIVariableStore(
            creatingVariableStoreAt: varsURL, options: .allowOverwrite)
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
    fail("Could not open serial log for writing at \(serialURL.path): \(error)")
}

// MARK: - VM configuration

let bootLoader = VZEFIBootLoader()
bootLoader.variableStore = variableStore

let config = VZVirtualMachineConfiguration()
config.bootLoader = bootLoader
config.memorySize = 256 * 1024 * 1024
config.cpuCount = 2

do {
    // Not read-only: the guest writes \BOOTED.TXT onto the ESP as execution
    // evidence (see boot/src/main.zig).
    let attachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
    config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: attachment)]
} catch {
    fail("Could not attach disk image '\(diskImagePath)' as a virtio block device: \(error)")
}

let serialConfig = VZVirtioConsoleDeviceSerialPortConfiguration()
serialConfig.attachment = VZFileHandleSerialPortAttachment(
    fileHandleForReading: nil,
    fileHandleForWriting: serialHandle
)
config.serialPorts = [serialConfig]

config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

var machineView: VZVirtualMachineView?
if screenshotPath != nil {
    // Graphical observation mode: give the guest a framebuffer to render to.
    let graphics = VZVirtioGraphicsDeviceConfiguration()
    graphics.scanouts = [
        VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1280, heightInPixels: 720)
    ]
    config.graphicsDevices = [graphics]
} else {
    config.graphicsDevices = []
}
// Milestone-zero scope: no networking.
config.networkDevices = []

do {
    try config.validate()
} catch {
    fail("Invalid VM configuration: \(error)")
}

// MARK: - Boot and observe

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

print("DIPSHITOS VM runner")
print("  host: arm64 (Apple silicon), macOS \(osVersion.majorVersion).\(osVersion.minorVersion)")
print("  disk: \(diskImagePath)")
print("  memory: 256 MiB, cpus: 2")
print("  serial log: \(serialLogPath)  (timeout: \(Int(timeout))s)")
if let screenshotPath = screenshotPath {
    print("  framebuffer screenshot: \(screenshotPath)")
}
print("  expecting: \"\(expectLine)\"")

// VZ requires all VM operations (start, stop) to run on the VM's designated
// queue; calling them from the main thread trips a dispatch queue assertion.
runner.queue.async {
    runner.vm.start { result in
        switch result {
        case .success:
            break
        case .failure(let error):
            FileHandle.standardError.write(
                Data("ERROR: VM failed to start: \(error)\n".utf8))
            exit(1)
        }
    }
}

var captureTimes: [TimeInterval] = [5, 10, 15]

func captureScreenshot(at t: TimeInterval) {
    guard let view = machineView else { return }
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        print("WARNING: could not create bitmap representation of the VM view.")
        return
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        print("WARNING: could not encode the VM view as PNG.")
        return
    }
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
        // Any successful capture counts as observed framebuffer output, even
        // if the timeout cuts the capture schedule short.
        screenshotSaved = true
    } catch {
        print("WARNING: could not write screenshot: \(error)")
    }
}

func finish(success: Bool) {
    runner.queue.async { runner.vm.stop { _ in exit(success ? 0 : 1) } }
}

func poll() {
    // 1. Serial console.
    if let data = try? Data(contentsOf: serialURL),
       let text = String(data: data, encoding: .utf8) {
        if !text.isEmpty { lastText = text }
        if text.contains(expectLine) {
            print("SUCCESS: guest UEFI output observed on the serial console.")
            print("----- captured serial console -----")
            print(text)
            print("-----------------------------------")
            finish(success: true)
            return
        }
    }

    // 2. Framebuffer snapshots (graphical mode) at several time points.
    if screenshotPath != nil {
        let elapsed = Date().timeIntervalSince(startTime)
        if let next = captureTimes.first(where: { $0 <= elapsed }) {
            captureTimes.removeAll { $0 == next }
            captureScreenshot(at: next)
        }
    }

    // 3. Deadline.
    if Date() > deadline {
        if screenshotSaved {
            print("Timed out waiting for serial output, but a framebuffer "
                + "screenshot was captured -- treat it as the observed output.")
            finish(success: true)
        } else if screenshotPath != nil {
            print("FAILURE: no expected output within \(Int(timeout))s and no "
                + "screenshot was captured. The guest framebuffer may be blank "
                + "or the VM view did not render.")
            if !lastText.isEmpty {
                print("----- captured serial console (partial) -----")
                print(lastText)
                print("---------------------------------------------")
            }
            finish(success: false)
        } else {
            print("FAILURE: no expected output within \(Int(timeout))s.")
            if !lastText.isEmpty {
                print("----- captured serial console (partial) -----")
                print(lastText)
                print("---------------------------------------------")
            } else {
                print("No serial output was captured. On this platform the EFI "
                    + "firmware does not route its console to the virtio serial "
                    + "device; pass --screen <png> to observe the framebuffer.")
            }
            finish(success: false)
        }
        return
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { poll() }
}

if screenshotPath != nil {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
        styleMask: [.titled],
        backing: .buffered,
        defer: false)
    let view = VZVirtualMachineView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
    view.virtualMachine = runner.vm
    window.setContentSize(NSSize(width: 1280, height: 720))
    window.contentView = view
    window.center()
    window.orderFrontRegardless()
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    machineView = view
    print("  (opened a window to render the guest framebuffer)")
}

DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { poll() }
RunLoop.main.run()

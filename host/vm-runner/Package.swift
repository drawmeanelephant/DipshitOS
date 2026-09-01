// swift-tools-version:6.2
//
// VirelaiOS milestone-zero host launcher.
// A minimal macOS CLI built on Apple's Virtualization framework that boots a
// raw GPT+FAT disk image under UEFI (VZEFIBootLoader) and captures the
// guest's serial console into a log file.
//
// M34 HF1 (issue #735): the pure-Swift VFWire module (wire-format
// encode/decode for the host file channel — zero Virtualization imports,
// so `swift test` runs without a VM) + the VMRunnerTests target locking
// byte-parity with the guest side via the checked-in fixtures.
//
// Tools version 6.2 is the floor that parses on the CI toolchain (Swift
// 6.3.3 on GitHub's macos-latest) while still exposing the macOS 26
// platform case; the target language mode stays Swift 5 to keep the
// concurrency surface small.
import PackageDescription

let package = Package(
    name: "vm-runner",
    platforms: [
        // Project requirement: macOS 27+ (Apple silicon + Virtualization.framework).
        // The manifest floor tracks the highest version the CI toolchain's
        // PackageDescription exposes (.v26; .v27 needs PackageDescription
        // 6.4 / Swift 6.4). The runtime requirement (macOS 27+) is enforced
        // in Sources/VMRunner/main.swift.
        .macOS(.v26)
    ],
    targets: [
        .target(
            name: "VFWire",
            path: "Sources/VFWire"
        ),
        .executableTarget(
            name: "VMRunner",
            dependencies: ["VFWire"],
            path: "Sources/VMRunner"
        ),
        .testTarget(
            name: "VMRunnerTests",
            dependencies: ["VFWire"]
        )
    ],
    swiftLanguageModes: [.v5]
)

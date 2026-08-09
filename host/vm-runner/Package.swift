// swift-tools-version:6.2
//
// DipshitOS milestone-zero host launcher.
// A minimal macOS CLI built on Apple's Virtualization framework that boots a
// raw GPT+FAT disk image under UEFI (VZEFIBootLoader) and captures the
// guest's serial console into a log file.
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
        .executableTarget(
            name: "VMRunner",
            path: "Sources/VMRunner"
        )
    ],
    swiftLanguageModes: [.v5]
)

// swift-tools-version:5.9
//
// DipshitOS milestone-zero host launcher.
// A minimal macOS CLI built on Apple's Virtualization framework that boots a
// raw GPT+FAT disk image under UEFI (VZEFIBootLoader) and captures the
// guest's serial console into a log file.
//
// Language mode is Swift 5 (tools-version 5.9) to keep the concurrency
// surface small while still building with the installed Swift 6.2 toolchain.
import PackageDescription

let package = Package(
    name: "vm-runner",
    platforms: [
        // VZEFIBootLoader is only available on macOS 13+ in the current SDK.
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "VMRunner",
            path: "Sources/VMRunner"
        )
    ]
)

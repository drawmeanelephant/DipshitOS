// swift-tools-version:6.4
//
// DipshitOS milestone-zero host launcher.
// A minimal macOS CLI built on Apple's Virtualization framework that boots a
// raw GPT+FAT disk image under UEFI (VZEFIBootLoader) and captures the
// guest's serial console into a log file.
//
// Tools version 6.4 exposes PackageDescription 6.4 (macOS 27 platform case);
// the target language mode stays Swift 5 to keep the concurrency surface
// small while still building with the installed Swift 6.4 toolchain.
import PackageDescription

let package = Package(
    name: "vm-runner",
    platforms: [
        // Project requirement: macOS 27+ (Apple silicon + Virtualization.framework).
        .macOS(.v27)
    ],
    targets: [
        .executableTarget(
            name: "VMRunner",
            path: "Sources/VMRunner"
        )
    ],
    swiftLanguageModes: [.v5]
)

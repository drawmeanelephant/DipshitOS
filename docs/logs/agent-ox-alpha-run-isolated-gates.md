# Log — run-isolated gates via DiskImageKit overlays

- **2026-08-24** — *ox-alpha*: Opened. Implements #523 item 2 on this host
  (macOS 27.0, Xcode 27 SDK — verified before designing). API surface taken
  from the SDK swiftinterfaces: `DiskImage(opening:.open(url:mode:.readOnly))`,
  `DiskImage.asifLayer(url:type:.overlay(blockCount:))` +
  `appending(_:)`, and the new
  `VZDiskImageStorageDeviceAttachment(diskImage:cachingMode:synchronizationMode:)`.
  Plan: --overlay-base + --vars flags in VMRunner, tools/lib/gate-run.sh
  helper, verify-live-net-tcp.sh converted as template, concurrency proven
  by running two instances simultaneously. Claim 6637.

# Log — `agent/buffy/macos27-custom-virtio-spike`

Append-only. See [`README.md`](README.md) for the convention.

- **2026-08-09** — *buffy*: claim 5844 filed at `a5888f1`; scope is the macOS 27 host requirement, the custom-virtio spike device, and the live `pci` command. SDK audit (Xcode 27 beta 4, SDK 27.0) shows no host-triggered guest-interrupt API exists in Virtualization.framework — the spike proves discovery only. · 🔄 in progress
- **2026-08-09** — *buffy*: claim 5844 complete — macOS 27+ is now the enforced host requirement (runner guard `>= 27`, `Package.swift` `.macOS(.v27)` at tools-version 6.4, docs updated), `zig build spike-virtio` boots a real VZ VM with a custom virtio device attached (device created, kernel reaches `dipshit>`, exit 0), and the live `pci` command observes **VID 0x1af4 / DID 0x1082** on the bus alongside console 0x1043 / blk 0x1042 / entropy 0x1044 (`artifacts/vm-spike-pci.log`). Rebased onto `388410c` (PR #55, claim 9187's real IRQ delivery) with both change sets intact; class A green (monitor 105, shell 129, transcript byte-identical, unit set, build, fmt, coordination). Evidence: `artifacts/vm-spike.log`, `artifacts/vm-spike-pci.log`. · ✅ done

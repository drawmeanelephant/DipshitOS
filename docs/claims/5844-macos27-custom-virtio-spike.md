# Claim: macOS 27+ host requirement, custom-virtio spike device, and live `pci` command

- **Owner:** buffy (`agent/buffy/macos27-custom-virtio-spike`)
- **Prompt / plan:** macOS 27 Virtualization capability audit (step 3) — the
  custom virtio discovery experiment; host requirement is the audit's premise.
- **Scope:** (1) make macOS 27+ the project's enforced host requirement
  (Swift runner runtime guard `>= 27`, `Package.swift` floor `.macOS(.v27)`
  at tools-version 6.4, and the requirement stated in
  README/AGENTS/status/architecture/roadmap/testing); (2) a
  `--custom-virtio` runner flag + `zig build spike-virtio` step attaching one
  `VZCustomVirtioDeviceConfiguration` (virtio-pci VID 0x1af4 / DID 0x1082 =
  deviceID 0x42, class 0x00/0x00, 1 queue) with config/device delegates that
  log creation, DRIVER_OK, queue notifications, and lifecycle; (3) a `pci`
  monitor command (registry 20→21) that walks bus 0 through the pre-exit ECAM
  window and prints VID/DID/class + all six BARs per device.
- **Depends on:** claim 0013 (ECAM discovery), claim 1517 (post-MMU access),
  claim 9187 (VZ interrupt delivery — merged as PR #55 before this branch was
  rebased; the spike + `pci` command are orthogonal to it).
- **Status:** ✅ done 2026-08-09 on `agent/buffy/macos27-custom-virtio-spike`

## Notes

Deterministic claim ID from
`bash tools/status/claim-id.sh 'agent/buffy/macos27-custom-virtio-spike' 'macos27-custom-virtio-spike'`
= `5844`.

**SDK audit finding (drives the host requirement):** the macOS 27.0 SDK
(Xcode 27 beta 4) exposes **no host-triggered guest-interrupt API** — the
word "interrupt" appears in exactly one Virtualization.framework header
(`VZDiskImageStorageDeviceAttachment.h`, a POSIX EINTR parameter). The
WWDC26 "trigger an interrupt on the device" claim has no public symbol; the
only host→guest signaling is the framework-internal used-buffer notification
when queue elements are returned (`returnToQueue`). Claim 9187's independent
audit (Hypervisor.framework `hv_gic_*`) agrees. The spike is therefore
discovery + queue-transport evidence only.

**Class B evidence (real VZ boot, macOS 27):** `zig build spike-virtio`
exits 0 — VZ accepts the custom device configuration, the device is created
(`CUSTOM-VIRTIO: device created`), and the kernel reaches `dipshit>` with
the device attached. The scripted `pci` run
(`artifacts/vm-spike-pci.log`) lists five devices: Apple bridge
(0x106b/0x1a05), virtio console (0x1043), virtio-blk (0x1042), virtio
entropy (0x1044), and the custom spike device **VID 0x1af4 / DID 0x1082**
with a real BAR (`0x50001000`).

**Class A:** monitor 105/105, shell 129/129, transcript byte-identical,
unit-test set green, `zig build` green, `swift build` green (macOS 27
floor), fmt clean, coordination indexes in sync.

Notes for the audit's next steps: the host side is ready for queue
transport (delegate logs `DRIVER_OK` + notifications); the custom device's
virtio device ID 0x42 → PCI DID 0x1082 (0x1040 + device_id, addition not
OR — a wrong OR collides with virtio-blk's 0x1042).

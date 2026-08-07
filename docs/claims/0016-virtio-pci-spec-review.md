# Claim: M1.5 — virtio-pci console TX path protocol-correctness review (spec-gated)

- **Owner:** buffy (`agent/buffy/m15-nvram-console`)
- **Prompt / plan:** task prompt 2026-08-07 — pull latest main, verify the modern
  virtio-pci console TX path against the OASIS Virtio 1.3 specification before
  any further VZ-specific debugging
- **Scope:** M1.5 virtio-pci console (kernel/src/main.zig virtio_pci_*); protocol
  correctness only — no console redesign, no RX
- **Depends on:** claim 0013 (transport decode), claim 0015 (NVRAM console gate)
- **Status:** ✅ done 2026-08-07 (evidence under `artifacts/virtio-spec-review-20260807.txt`)

## Notes

Task: determine whether the current virtio-pci TX path is actually
spec-correct, verifying every point against the authoritative primary source
(OASIS Virtio v1.3, `docs.oasis-open.org/virtio/virtio/v1.3/virtio-v1.3.html`,
fetched 2026-08-07), and not trusting prior review comments.

### Verdict: three protocol bugs found and fixed (+1 cache-coherence hardening from code review); the transport is now spec-correct

1. **Device reset readback missing (MUST violation, §4.1.4.3).** Spec: "After
   writing 0 to device_status, the driver MUST wait for a read of device_status
   to return 0 before reinitializing the device." The code wrote 0 and
   immediately wrote ACKNOWLEDGE|DRIVER. Fixed: bounded poll of device_status
   until it reads 0 (1e6 spins, then honest timeout → init fails).
2. **Queue notification width (MUST violation, §4.1.5.2.1).** VIRTIO_F_
   NOTIFICATION_DATA is not negotiated (only VERSION_1 is accepted), so "the
   driver notification MUST be a 16-bit notification" whose value is the
   virtqueue index. The code issued a 32-bit store of 1. Fixed: 16-bit store of
   the queue index (1). The code comment claiming "a 16-bit store may be
   dropped — claim 0013" is **not backed by any documented evidence** in claim
   0013 or its logs — it is an inference that was used to justify a MUST
   violation; the report flags it as such. A conforming device that does not
   offer NOTIFICATION_DATA MUST accept 2-byte notify accesses (§4.1.4.4.1).
3. **Available-ring overrun hazard (split-ring invariant, §2.7).** With queue
   size 1, the number of outstanding buffers (avail.idx − used.idx) must never
   exceed queue size; the flush posted unconditionally even when the previous
   buffer was still outstanding (the "drop on timeout" path left the buffer
   pending, and the next flush would overwrite the only ring slot). Fixed: the
   flush re-reads used.idx fresh (invalidating the device-written line) and
   drops the line without touching the rings when the ring is full.
4. **Used-ring init write vs dc ivac (found in code review, fixed).** The
   guard's dc ivac on the used ring can discard the driver's own init zeroing
   of `virtio_used` (written at queue setup, never cleaned; BSS is not trusted
   zeroed here) — the read then sees stale RAM garbage, and the guard would
   treat the ring as full and drop TX forever. Fixed: clean the used ring's
   init write to RAM at queue setup.

### Verified correct against the spec (no change made)

- Init sequence order (§3.1.1): reset → ACKNOWLEDGE → DRIVER → read device
  features (select low/high) → write driver features (only VERSION_1) →
  FEATURES_OK → re-read status (bit 3 still set) → queue setup → DRIVER_OK
  (bit 2, cumulative status 0xf). ✓
- VIRTIO_F_VERSION_1 (bit 32) required ("A driver MUST accept VIRTIO_F_VERSION_1
  if it is offered", §6.1) and checked in the high feature word. ✓
- Common-cfg register offsets (device_feature_select 0x00 / device_feature 0x04
  / driver_feature_select 0x08 / driver_feature 0x0c / device_status 0x14 /
  queue_select 0x16 / queue_size 0x18 / queue_enable 0x1c / queue_notify_off
  0x1e / queue_desc-avail-used 0x20/0x28/0x30) all match §4.1.4.3. ✓
- queue_size write of 1 is a power of 2 (§4.1.4.3 — the only power-of-2
  requirement; 1 is valid). ✓
- "The driver MUST configure the other virtqueue fields before enabling the
  virtqueue with queue_enable" — desc/avail/used GPAs are written before
  queue_enable=1. ✓ queue_enable is never written back to 0 (MUST NOT). ✓
- queue_notify_off is read-only and never written (MUST NOT write). ✓
- Notify address = cap.offset + queue_notify_off × notify_off_multiplier
  (§4.1.4.4) — matches the code's `vp_notify + qoff * mult`. ✓
- Ring alignment (desc 16 B, avail 2 B, used 4 B; §2.7.1 "MUST ensure the
  physical address of the first byte of each virtqueue part is a multiple of
  the specified alignment") — the BSS globals are declared align(16)/align(2)/
  align(4). ✓
- avail.flags = 0 (must be 0 or 1 with no EVENT_IDX, §2.7.7.1). ✓
- No notifications before DRIVER_OK; no writes to read-only fields. ✓
- Cache maintenance: dc cvac (clean) over desc/avail/tx before the notify and
  dc ivac (invalidate) over the used ring before polling are the correct
  non-coherent pattern for a DMA device reading guest RAM on AArch64; on VZ
  (coherent emulation) they are harmless defensive code. The clean is ordered
  by a dsb ish before the MMIO notify write, so the device sees the updated
  rings. ✓

### Not in scope (documented, not fixed)

- `virtio_init` (the virtio-MMIO fallback probe, `magic == 0x74726976` branch)
  reads `base+0x10` twice (low/high of a single 32-bit DeviceFeatures register)
  and uses virtio-pci common-cfg offsets (0x14/0x70) against an MMIO base — a
  broken hybrid. It never matches on VZ (the console is PCI, claim 0013) and is
  not part of the virtio-pci TX path this claim reviews; fixing it would be a
  new driver, not a correction.
- The claim-0013 feature values "`0x30000000`/`0x5`" could not be re-derived
  from current artifacts (the DipshitP* probe-dump variables were overwritten
  by later gates' fresh variable stores). The M2_READY ladder on the arming
  runs proves VERSION_1 was present and accepted (DRIVER_OK requires
  FEATURES_OK requires features_hi bit 0), so the transport did arm. Noted as
  an evidence gap, not a code issue.

### Tests / gates

A host unit test of the virtio TX path was deliberately NOT added: the transport
is embedded in the freestanding kernel (MMIO + asm + build_options), and
extracting it into a testable module is a redesign the task forbids. Validation
is the full portable gate suite plus the existing VZ evidence gates:

- `zig fmt --check`, `zig build`, `zig build -Dnvram-console=true image`,
  `bash tools/verify-unit-tests.sh`, `zig build test-console`,
  `bash tools/verify-coordination.sh`
- VZ gates (Apple silicon): `bash tools/verify-marker.sh` (pre-exit arming
  regression: the ladder must still reach M2_READY with the fixed reset/notify
  code) and `bash tools/verify-nvram-console.sh` (shell console unchanged —
  the nvram build never touches the transport).
- Evidence: `artifacts/virtio-spec-review-20260807.txt` (this claim's gate run).

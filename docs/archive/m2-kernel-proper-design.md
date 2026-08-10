> ARCHIVED — frozen historical record; do not treat as an active plan.

# Milestone two implementation design and review

Status: design complete and self-reviewed; implementation attempted, with build gates passing and VZ hardware gates blocked.
Branch: `agent/buffy/m2-kernel-proper`

This design is subordinate to ADR 0004 and `docs/m2-kernel-proper-prompt.md`.
It deliberately does not claim that any new hardware behavior is observed.
All device addresses and register layouts remain inferred until the probe
produces a saved log.

## 1. ExitBootServices sequence and failure modes

The kernel entry is a small AArch64 handoff wrapper. It receives x0=image
base, x1=image size, x2=SystemTable, and x3=the v2 handoff pointer. It first
validates x3's magic/version and mirror fields, then switches SP to
`stack_base + stack_size`, preserving 16-byte AAPCS64 alignment. The wrapper
will be a naked entry shim so no compiler-generated prologue runs on the
loader's stack; it branches to the normal Zig takeover function with the
same arguments.

The takeover function performs no MMU or device access before ExitBootServices.
It emits only a temporary pre-exit `ConOut` breadcrumb (`kernel entered`) for
failure-path diagnosis; this does not count as post-exit console evidence:

1. Read the handoff and System Table while the firmware identity map is still
   active. Validate stack bounds, image bounds, and the 4 KiB alignment
   required by v2.
2. Call `getMemoryMapInfo()` only to learn the initial descriptor count and
   descriptor size. Allocate one `EfiLoaderData` pool buffer with a margin of
   64 descriptors, then call `getMemoryMap()` into it. The buffer remains
   allocated and is adopted by the kernel after exit.
3. Preserve `map.info.key`, `map.info.descriptor_size`,
   `map.info.descriptor_version`, `map.info.len`, and the buffer pointer in a
   small post-exit map-view record. The descriptor stride, not `sizeof`, is
   used for every walk.
4. Attempt `exitBootServices(image_handle, map_key)`. On
   `error.InvalidParameter`, repeat `getMemoryMap()` into the same buffer and
   retry. The loop is exactly eight attempts; it never allocates, touches
   MMIO, changes the page tables, or calls any other service between retries.
5. If all eight attempts fail, print `ExitBootServices failed after 8 attempts`.
   This is the last permitted `ConOut` operation, then halt forever. The
   kernel never proceeds with an uncertain firmware boundary.
6. Only after success, build the identity map, install TTBR0_EL1, probe/select
   the serial transport, print the banner and map view, then enter a WFE
   wait loop. No return path exists after successful exit.

The call site contains this exact auditable prohibition comment from ADR 0004:

> After successful exit, no longer allowed: `AllocatePool`/`AllocatePages`,
> `GetMemoryMap`, `SimpleTextOutput`, `Simple File System`,
> `LoadImage`/`StartImage`, `SetTimer`, any event services, any other Boot
> Services call.

The stub's `uefi.handle` is copied into handoff offset 32 and passed to the
kernel through x3. `ExitBootServices` receives that handle, never a fabricated
kernel handle. The stale-key retry is the only expected recoverable failure;
all other pre-exit errors print a concise `ConOut` diagnostic and return a
non-zero status to the loader.

## 2. Memory ownership across the exit

| Allocation | Allocator/time | Type/alignment | Post-exit disposition |
|---|---|---|---|
| kernel image | boot stub, before jump | `AllocatePages(.any, .loader_code)`, 4 KiB | adopted executable kernel image |
| 16 KiB stack | boot stub, before jump | `AllocatePages(.any, .loader_data)`, 4 KiB; SP is 16-byte aligned | adopted kernel stack |
| v2 handoff page | boot stub, before jump | `AllocatePages(.any, .loader_data)`, one 4 KiB page | adopted handoff record |
| memory-map buffer | kernel, before exit | `AllocatePool(.loader_data)`, 8-byte EFI alignment; size+margin | adopted map authority; never freed |
| page tables | kernel image BSS, statically reserved | 4 KiB aligned fixed carve-out | adopted kernel translation tables |
| virtio queue storage | kernel image BSS, statically reserved | cache-line-safe aligned fixed carve-out | adopted console queue storage |

The page-table BSS region is fixed at 512 KiB and the console BSS region at
one 4 KiB page. Virtio queue descriptors use a one-entry descriptor table,
a separate available index/ring, and a used index/ring; these are fixed
carve-outs, not an allocator. The table
builder refuses to exceed either bound and halts at a distinctive
`M2_TABLE_OVERFLOW` marker if it would. The builder maps the kernel image,
stack, handoff page, map buffer, page-table storage, and any MMIO ranges
selected by the probe. Conventional RAM and loader/code/data regions are
Normal WB. Runtime, ACPI, reserved, unusable, and MMIO regions are never used
as general RAM; selected device windows are Device-nGnRnE and other reserved
regions are left unmapped.

## 3. Identity-map MMU setup

The map builder operates on EFI descriptors and emits VA==PA mappings. It
starts with a 4 KiB-granule level-parameterized walk: L0/L1 tables are
allocated from the static BSS pool, L2 2 MiB blocks are used when start/end
and attributes are aligned, and L3 4 KiB pages cover partial regions. It
never merges across descriptor boundaries or across attribute changes. A
fixed physical ceiling is not assumed: the highest end address in the EFI
map determines the needed translation range, while the device probe can add
specific MMIO windows before the switch.

The initial builder uses a 39-bit VA space (`T0SZ=25`, four levels, 4 KiB
granule), which covers the current EFI-described address space below 512 GiB.
This is a design default, not a hardware observation. If a future map or
probe contains an address at or above 512 GiB, the builder must select the
48-bit form (`T0SZ=16`) before the TTBR switch and record that choice. It must
reject addresses beyond the selected VA size rather than silently truncating.

MAIR_EL1 assigns index 0 to Device-nGnRnE (`0x00`) and index 1 to Normal
Inner/Outer Write-Back Read/Write Allocate (`0xff`). EFI descriptors with
`conventional_memory`, `loader_code`, `loader_data`, boot-services types, or
persistent memory map as Normal WB. Descriptor types representing runtime,
ACPI, reserved, unusable, or MMIO map as Device only when explicitly selected
for the serial transport; otherwise they remain unmapped. The descriptor's
`WB` bit is recorded in the map view but EFI type controls safety. IPS is read
from `ID_AA64MMFR0_EL1`, converted to the architecturally supported PARange
encoding, and written into TCR. TTBR0 uses the physical identity address of
the root table.

Before `msr ttbr0_el1`, the builder verifies that the currently executing
kernel image range, current stack range, handoff, map buffer, tables, and the
probe windows all have valid descriptors. It then writes TTBR0, executes
`isb; tlbi vmalle1; dsb ish; isb`, and does not alter SCTLR_EL1. The MMU is
never disabled. A synchronous abort cannot use firmware recovery: the
failure marker is a static word and the handler loops. The code keeps data
and text executable in this milestone; XN/PXN hardening is deferred.

## 4. Serial transport and mandatory device probe

The driver table is not trusted until a post-exit probe completes. Because
MMIO access itself is forbidden before exit, the probe runs immediately after
identity-map installation and before banner output. The current implementation
records probe results only in the serial stream; the fixed marker is reserved
in BSS but is not host-dumped by the current runner, so it is not treated as
observed evidence.

Candidate discovery is ordered and bounded:

1. Parse UEFI configuration-table pointers retained from the System Table for
   ACPI RSDP/XSDT. If an ACPI SPCR or DBG2 table identifies a UART, add its
   base as a candidate. An optional device-tree pointer is treated similarly
   if present. These tables are read only while their mapped regions are
   valid; malformed lengths are rejected.
2. Add only EFI memory-map descriptors whose types are
   `memory_mapped_io` or `memory_mapped_io_port_space`. On the observed
   pre-exit VZ map these are the two windows at `0x01000000` and
   `0x20050000`; those map entries are evidence of ranges, not proof of a
   serial device. The current implementation reads bounded signature windows
   within each declared descriptor and performs no arbitrary physical-memory
   sweep. ACPI SPCR/DBG2 discovery is not yet implemented and therefore is
   not claimed as an observed or implemented discovery path.
3. Discriminate layouts using signatures: virtio-mmio requires magic
   `0x74726976` at +0x00, version 1/2 at +0x04, device id 3 (console) at
   +0x08, and a nonzero vendor id at +0x0c. PL011 requires the expected
   peripheral-ID bytes in the +0xfe0..+0xffc block and a sane FR at +0x18.
   A 16550 candidate requires a sane byte-wide LSR at +5 and a successful
   scratch register round trip at +7; the scratch write is the only trial
   write and is restored immediately. Probe logs contain candidate base, all
   signature reads, selected layout, and a transport-confidence result.
4. The selected register table is then used by the driver. PL011 uses DR +0x00,
   FR +0x18 and TX-full bit 5. 16550 uses THR +0, LSR +5 and THR-empty bit 5.
   A VZ virtio-console uses the virtio-mmio common configuration and one fixed
   TX virtqueue: queue storage, descriptor, available ring, and used ring
   are all static BSS. The driver performs polled TX only; there is no RX,
   interrupt, DMA, or dynamic allocation. The current implementation accepts
   only modern virtio-mmio (version 2), negotiates VERSION_1, selects the
   console transmit queue, and submits one byte-buffer descriptor at a time,
   polling the used ring before reuse. This path remains unverified because
   no post-exit probe or serial output was captured.

The probe's saved log is the sole authority for flipping hardware-contract
entries from `[inferred]` to `[observed]`. A successful PL011/16550 log must
show the signature and a received banner byte in `vm-serial.log`. A virtio
log must show the virtio magic/version/device/vendor reads, feature/queue
initialization, and received banner. Without that evidence, the contract
stays inferred. If no candidate passes, the kernel records a fixed BSS marker
and halts, but the current host runner has no memory-dump path for that
marker; it is therefore not sufficient evidence and no serial success is
claimed.

## 5. Handoff v2 and boot-stub changes

The boot stub remains entirely in firmware-land and performs its existing
marker, loader trace, and pre-jump map evidence writes. After the kernel image
has been loaded and validated, it allocates a 16 KiB stack and one 4 KiB
handoff page using `EfiLoaderData`, fills the exact ADR 0004 layout, and
flushes the handoff/cache ranges before jumping. The jump registers are:

- x0 = content base (4 KiB aligned)
- x1 = image size
- x2 = System Table pointer
- x3 = handoff-v2 page pointer

The handoff contains magic `0x324B5344`, version 2, mirrors x0/x1/x2, the
stub image handle, stack base, stack size 16384, and flags zero at the exact
specified offsets 0..56. Any mismatch, invalid alignment, or unsupported
flags is reported through `ConOut` and returns `0x2` (bad handoff) before
ExitBootServices. The loader writes `RC.TXT` with a non-zero value and then
returns to firmware. A test-only build/image mutation changes only the magic
word and must exercise this path without calling ExitBootServices.

Once ExitBootServices succeeds, the kernel never returns to the loader. It
prints its evidence, then executes `wfe` in a self-loop. The host distinguishes a candidate success by the serial banner/map output
plus a short terminal dwell in the runner; this is not an independent proof
of CPU liveness. It distinguishes the required pre-exit failure by the
loader's non-zero `RC.TXT` and the absence of successful serial takeover
evidence.

## 6. Observable criteria and verification

The primary acceptance line is exactly:

`DipshitOS kernel has seized control.`

It is followed by a stable prefix and hexadecimal records from the captured
map, for example `memory-map descriptors=0x... descriptor_size=0x...` and
one line per descriptor. The line must be the first non-empty content in
`artifacts/vm-serial.log`; milestone-one's empty serial log is retained as a
baseline artifact.

Verification commands and saved outputs:

- `zig fmt --check` → `artifacts/m2-zig-fmt.txt`
- `zig build` → `artifacts/m2-zig-build.txt`
- `zig build image` → `artifacts/m2-zig-image.txt`
- `zig build inspect` → `artifacts/m2-zig-inspect.txt`
- `swift build --package-path host/vm-runner` → `artifacts/m2-swift-build.txt`
- `zig build run` → `artifacts/m2-vz-run.txt`, `artifacts/vm-serial.log`, and
  the FAT evidence files. The runner must wait for the kernel's WFE terminal
  state rather than treating return to the stub as success.
- A deliberately corrupted handoff → `artifacts/m2-bad-handoff.txt`, with
  `RC.TXT` showing a non-zero status and no post-exit takeover claim.
- `artifacts/m2-probe.log` records candidate reads, signatures, selected
  transport, and evidence status. Hardware-contract changes are made only
  after this file and the serial log exist.

All artifacts distinguish directly observed command/log output from inferred
architecture. If the Apple host cannot expose a usable guest serial device,
implementation and build verification still proceed, the marker evidence is
saved, and the final report names the blocked VZ gate precisely.

## Self-review against the binding checklist

- **Section 1:** sequence, two-call map sizing, pool ownership, 8 retries,
  failure text/halt, image handle source, and exact post-exit prohibition are
  specified.
- **Section 2:** every allocation has owner/type/alignment; adoption and
  reserved regions are explicit; fixed BSS carve-outs are bounded.
- **Section 3:** fresh BSS tables, 4 KiB granule, 2 MiB blocks, T0SZ policy,
  EFI-derived attributes, MAIR/TCR/IPS, TTBR0 ordering, no MMU disable, and
  abort marker are specified.
- **Section 4:** bounded probe discovery, PL011/16550/virtio discrimination,
  trial-write policy, driver API, static virtio queue, fallback marker, and
  observed-only contract flips are specified.
- **Section 5:** exact v2 offsets and x0–x3, stub allocations, validation,
  bad-magic return path, and never-return success path are specified.
- **Section 6:** exact banner, map hex format, empty-log baseline, commands,
  artifact names, observed/inferred discipline, and blocked-host handling are
  specified.
- **Scope review:** no allocator beyond fixed carve-outs, interrupts/GIC,
  timers, RX, DMA, processes, filesystems, graphics, networking, SMP,
  scheduler, syscalls, ELF loader, or QEMU path is introduced.
- **ADR review:** ADR 0004 remains accepted and the stub does not call
  ExitBootServices. No implementation code was written before this design
  and review.

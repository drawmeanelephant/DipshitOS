# DipshitOS testing

## Evidence policy

- **Observed** = the claim is backed by command output or a log file saved
  under `artifacts/`. Only observed behavior is reported as "works".
- **Inferred** = we believe it from documentation or reasoning, but have no
  log. Inferred claims are always labeled as inferred.
- We do not fabricate successful command output. If a required dependency or
  platform capability is unavailable, everything else still runs and the
  blocked step is reported precisely.

## Verification sequence

1. Print the detected tool versions.
2. Build the Zig UEFI application: `zig build`.
3. Inspect the generated binary: `zig build inspect`.
4. Create the FAT disk image: `zig build image`.
5. Inspect the disk-image contents (part of `zig build inspect`).
6. Build the Swift VM runner: `swift build --package-path host/vm-runner`.
7. Boot with Apple Virtualization.framework (Apple silicon only):
   `zig build run`. The run **gates** on the guest evidence — all four
   markers must match exactly: `\BOOTED.TXT` (loader ran), `\LOADER.TXT`
   (kernel placement), `\RC.TXT` (`kernel_rc=0x0`), and `\KERNEL.TXT`
   (byte-perfect content: `DIPSHITOS KERNEL`, `entry reached via
   handoff`).
8. Save relevant logs under `artifacts/`.

> **Regression check (ADR 0002, resolved):** the `\KERNEL.TXT` content gate
> in `zig build run` is the regression check for the loader's
> content-at-`base+0` addressing invariant (ADR 0002). A future loader
> change that reintroduces the old `base+24` layout (the 24-byte DSK1
> header loaded into RAM) makes the kernel's `adrp`+`add` references read
> 24 bytes early, so `KERNEL.TXT` is not byte-perfect and the run gate —
> and therefore CI — fails immediately.
9. Generate the project snapshot: `zig build context` →
    `artifacts/context.md`.

## Evidence artifacts

| Artifact | Produced by | Contains |
|----------|-------------|----------|
| `artifacts/inspect.txt` | `zig build inspect > artifacts/inspect.txt` | `file`, PE/COFF headers, sections, disassembly, FAT/GPT listing |
| `artifacts/vm-serial.log` | `zig build run` | Serial console captured from the VZ guest |
| `artifacts/efi-vars.bin` | VZ runner | Persisted EFI NVRAM |
| `artifacts/context.md` | `zig build context` | Full deterministic project snapshot |
| `\LOADER.TXT` on the ESP | loader (`zig build run`) | Loader-observed kernel placement: base, size, entry_offset, first 16 bytes in RAM |
| `\RC.TXT` on the ESP | loader, after the kernel returns | `kernel_rc=0x0` — the kernel ran and returned (the handoff proof) |
| `\MEMMAP.TXT` on the ESP | loader | EFI memory map (types + attributes of every region) |
| `\KERNEL.TXT` on the ESP | kernel (`zig build run`) | Kernel's own marker; **byte-perfect and byte-identical** across runs; `zig build run` gates on its content (`DIPSHITOS KERNEL`, `entry reached via handoff`) |
| `\KERNEL.BIN` on the ESP | `zig build` | Flat kernel image, verified with `elf2bin.py --info` |

## How output is observed

- **Virtualization path (observed findings on macOS 27 / Apple M4; the
  project targets Apple silicon only, no QEMU path):**
  - The virtio serial console stays empty: Apple's EFI firmware does not
    route `ConOut` there.
  - The virtio-gpu framebuffer stays blank: the firmware renders no text
    console to it (captured PNGs are gray/black, OCR finds no text).
  - Therefore the guest also writes its message to `\BOOTED.TXT` on the
    ESP through the UEFI Simple File System protocol, and `zig build run`
    prints that file back from the host. The file's presence and exact
    content is the observed proof of execution on Apple silicon.

## Results log (as verified on the development host)

- [x] `zig build` compiles `BOOTAA64.EFI` (PE32+ EFI application, AArch64)
- [x] `zig build inspect` reports a valid AArch64 PE/COFF EFI application
- [x] `zig build image` creates a GPT+FAT32 image with `EFI/BOOT/BOOTAA64.EFI`
- [x] Virtualization.framework boot executed the guest (observed via
      `\BOOTED.TXT` on the ESP)
- [x] Milestone one: `zig build run` loads `\KERNEL.BIN`, jumps, and the
      kernel returns (observed via `\RC.TXT` = `kernel_rc=0x0`, plus
      `\LOADER.TXT` base/size/first8 evidence)
- [x] `\KERNEL.TXT` is written by the kernel, byte-perfect and
      byte-identical across repeated boots (ADR 0002 corruption is
      resolved; see `artifacts/m1-fix-run{1,2,3}.txt`), and `zig build
      run` gates on its content

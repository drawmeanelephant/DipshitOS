# DipshitOS testing (milestone zero)

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
   `zig build run`.
8. Boot with QEMU when installed: `zig build run-qemu`.
9. Save relevant logs under `artifacts/`.
10. Generate the project snapshot: `zig build context` →
    `artifacts/context.md`.

## Evidence artifacts

| Artifact | Produced by | Contains |
|----------|-------------|----------|
| `artifacts/inspect.txt` | `zig build inspect > artifacts/inspect.txt` | `file`, PE/COFF headers, sections, disassembly, FAT/GPT listing |
| `artifacts/vm-serial.log` | `zig build run` | Serial console captured from the VZ guest |
| `artifacts/qemu-serial.log` | `zig build run-qemu` | Serial console from the QEMU guest (when QEMU exists) |
| `artifacts/efi-vars.bin` | VZ runner | Persisted EFI NVRAM |
| `artifacts/context.md` | `zig build context` | Full deterministic project snapshot |

## How output is observed

- **QEMU path:** `-nographic -serial stdio`; edk2 routes UEFI `ConOut` to
  the serial console. Expected message appears on the terminal and is
  captured to a log. (QEMU is not installed on the development host, so
  this path is currently reported as blocked, not observed.)
- **Virtualization path (observed findings on macOS 27 / Apple M4):**
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
- [ ] QEMU boot observed (blocked: qemu-system-aarch64 not installed)

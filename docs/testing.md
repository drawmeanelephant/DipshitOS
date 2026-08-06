# DipshitOS testing

> For the current state of each verification gate (pass/fail/blocked), see
> [`docs/status.md`](status.md). This file is the sequence and policy.

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
   `zig build run`. Milestone two gates on `vm-serial.log` containing the
   exact banner `DipshitOS kernel has seized control.`, a
   `memory-map descriptors=0x...` line, and `kernel terminal state`. The
   pre-exit loader marker `\\BOOTED.TXT` remains required. `RC.TXT` is
   expected only for a deliberate pre-exit failure fixture, not success.
8. Save command output and logs under `artifacts/m2-*.txt`, including the
   probe output and the complete serial log. State blocked VZ capabilities
   precisely rather than inferring success.

> **Historical regression check (ADR 0002, resolved):** the `\KERNEL.TXT` content gate
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
| `artifacts/vm-serial.log` | `zig build run` | Kernel serial probe, exact banner, map hex view, and terminal marker |
| `artifacts/efi-vars.bin` | VZ runner | Persisted EFI NVRAM |
| `artifacts/context.md` | `zig build context` | Full deterministic project snapshot |
| `\LOADER.TXT` on the ESP | loader (`zig build run`) | Loader-observed placement and handoff-v2 jump inputs |
| `\RC.TXT` on the ESP | loader, only after pre-exit failure | Non-zero kernel status for the bad-handoff fixture |
| `\MEMMAP.TXT` on the ESP | boot stub, before handoff | Pre-exit EFI memory map evidence |
| `\KERNEL.TXT` on the ESP | milestone-one regression only | Not written after the kernel exits Boot Services |
| `artifacts/m2-probe.log` | kernel serial output | Candidate reads, signatures, selected transport, and observed/inferred decision |
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
- [x] Milestone one remains covered by the historical evidence in
      `artifacts/m1-fix-run{1,2,3}.txt`.
- [ ] Milestone two VZ serial/MMU takeover gate: **blocked**. The directly
      observed Apple M4 / macOS 27 run produced no banner, map print, probe
      log, or terminal marker in `vm-serial.log`; no `RC.TXT` was produced.
      Do not label the hardware assumptions observed before that evidence
      exists.
- [ ] Milestone two bad-handoff failure gate: **failing** (re-verified
      2026-08-06). The VM boots and the loader writes `BOOTED.TXT`/
      `LOADER.TXT` (correct shim entry), but the kernel never returns: no
      `RC.TXT` is produced. See `docs/status.md` and
      `artifacts/m2-bad-handoff-*.txt` for the open investigation.

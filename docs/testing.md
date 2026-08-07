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
2. Check Zig formatting: `zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig`.
3. Run the M1.5 kernel monitor module unit tests:
   `bash tools/verify-unit-tests.sh` — runs `zig test` on each module
   present in `kernel/src/` (console/handoff/memmap/monitor). Modules that
   have not landed yet are skipped with a notice, so the gate stays green
   on `main` and becomes binding branch-protection evidence once each
   module merges.
4. Build the Zig UEFI application: `zig build`.
5. Inspect the generated binary: `zig build inspect`.
6. Create the FAT disk image: `zig build image`.
7. Inspect the disk-image contents (part of `zig build inspect`).
8. Build the Swift VM runner: `swift build --package-path host/vm-runner`.
9. Boot with Apple Virtualization.framework (Apple silicon only):
   `zig build run`. Milestone two gates on `vm-serial.log` containing the
   exact banner `DipshitOS kernel has seized control.`, a
   `memory-map descriptors=0x...` line, and `kernel terminal state`. The
   pre-exit loader marker `\\BOOTED.TXT` remains required. `RC.TXT` is
   expected only for a deliberate pre-exit failure fixture, not success.
9b. ADR 0004 D4 marker fallback gate (gate work item 3, claims 0009/
   0010): `bash tools/verify-marker.sh` (also `just verify-marker` /
   `zig build marker`) boots the VM and asserts the NVRAM marker ladder —
   the kernel persists each takeover stage as the EFI variable `DipshitM2`,
   and the runner saves the ordered ladder to `artifacts/marker-dump.txt`.
   The gate passes iff at least one marker instance is present; the final
   stage names the death/crash site. Claim 0009 observed the ladder ending
   at `M2_MAPD!` (MMU-takeover window); claim 0010 root-caused and fixed it
   — the ladder now runs `M2_MAPD! → M2_MMUP! → M2_SERIA`, i.e. the switch
   completes and the serial probe runs to completion finding no usable
   device. The memory-dump form is impossible on VZ (guest RAM is not
   host-mapped — observed, claim 0009).
10. Save command output and logs under `artifacts/m2-*.txt`, including the
   probe output and the complete serial log. State blocked VZ capabilities
   precisely rather than inferring success.

> **Historical regression check (ADR 0002, resolved):** the `\KERNEL.TXT` content gate
> in `zig build run` is the regression check for the loader's
> content-at-`base+0` addressing invariant (ADR 0002). A future loader
> change that reintroduces the old `base+24` layout (the 24-byte DSK1
> header loaded into RAM) makes the kernel's `adrp`+`add` references read
> 24 bytes early, so `KERNEL.TXT` is not byte-perfect and the run gate —
> and therefore CI — fails immediately.
11. Generate the project snapshot: `zig build context` →
    `artifacts/context.md`.
12. Verify the multiagent coordination surface:
    `bash tools/verify-coordination.sh` (also `just verify-coordination`
    and CI). Fails if a claim/log file is malformed or the generated
    claim/log index tables in `docs/claims/README.md` /
    `docs/logs/README.md` drift from the files; fix by running
    `bash tools/status/refresh-indexes.sh` after creating a claim file or
    branch log.

## Evidence artifacts

| Artifact | Produced by | Contains |
|----------|-------------|----------|
| `artifacts/inspect.txt` | `zig build inspect > artifacts/inspect.txt` | `file`, PE/COFF headers, sections, disassembly, FAT/GPT listing |
| `artifacts/vm-serial.log` | `zig build run` | Kernel serial probe, exact banner, map hex view, and terminal marker |
| `artifacts/efi-vars.bin` | VZ runner | Persisted EFI NVRAM; holds the `DipshitM2` marker ladder after a marker-gate run |
| `artifacts/marker-dump.txt` | `zig build marker` / `verify-marker.sh` | Ordered M2_* NVRAM marker ladder (ADR 0004 D4 fallback) |
| `artifacts/m2-marker-gate.txt` | `verify-marker.sh` | Full marker-gate run log (2026-08-07: ladder ends `M2_MAPD!`) |
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
- [ ] Milestone two VZ serial/MMU takeover gate: **blocked**. Every directly
      observed Apple M4 / macOS 27 run produced no banner, map print, probe
      log, or terminal marker in `vm-serial.log`; no `RC.TXT` was produced.
      Latest re-run 2026-08-06 21:19 (`artifacts/m2-vz-run-20260806.txt`,
      `vm-serial.log` 0 B): loader→shim jump proven by `LOADER.TXT`
      `ram_first8=0xaa0103eaaa0003e9` (= `mov x9,x0; mov x10,x1`), then the
      kernel dies before its first post-exit `uart_puts` — consistent with
      either `layout=none` (no usable MMIO serial device; `M2_SERIA` halt)
      or an early post-exit crash. Do not label the hardware assumptions
      observed before that evidence exists.
- [x] Milestone two marker fallback gate (gate work item 3, claims
      0009/0010): **passing** (2026-08-07). Claim 0009's ladder
      discriminated the serial gate: every run ended at `M2_MAPD!` — the
      identity map was built but the post-install `M2_MMUP!` stage never
      appeared, so the kernel died in the MMU-takeover window and never
      reached the serial probe. Claim 0010 then **root-caused and fixed
      it**: the ladder now runs `M2_MAPD! → M2_MMUP! → M2_SERIA` — the MMU
      switch completes on VZ and the serial probe runs to completion,
      finding no usable MMIO serial device in the declared windows
      (evidence: `artifacts/m2-mmu-takeover-gate.txt`,
      `artifacts/m2-firmware-regs.txt`, `artifacts/m2-table-walk.txt`,
      `artifacts/m2-mmu-bisect-tlbi.txt`). The VZ serial gate's remaining
      blocker is device absence, not a crash.
- [x] Milestone two bad-handoff failure gate: **passing** (fixed 2026-08-06,
      `agent/buffy/m2-badhandoff-fix`). Root cause was the naked `_start`
      shim's `bl kernel_main` overwriting the link register without
      saving/restoring the loader's `x30`, so the shim's final `ret` looped
      forever and the kernel never returned. After the two-instruction fix,
      `verify-bad-handoff.sh` exits 0 and `RC.TXT` shows
      `kernel_rc=0x0000000000000002`. Evidence:
      `artifacts/m2-badhandoff-fix-{before,after,gates,goodpath}.txt`.

# Milestone-two gate fix: the failing bad-handoff failure path

Planning-first agent prompt for DipshitOS. Feed this file to the
implementing agent. It must produce a written diagnosis plan **before**
changing any code.

- Branch: `agent/buffy/m2-kernel-proper` (suggested)
- Date: 2026-08-06
- Inputs (read first; they are binding): `AGENTS.md`, `docs/status.md`,
  `docs/testing.md`, `docs/hardware-contract.md`,
  `docs/decisions/0002-kernel-handoff.md`,
  `docs/decisions/0004-kernel-proper.md`,
  `docs/m2-kernel-proper-design.md`

---

You are working on DipshitOS, a from-scratch AArch64 operating system
(freestanding Zig guest, Swift + Virtualization.framework host, no QEMU
path). Read the inputs above before doing anything; they are binding.

## The failure (observed, re-verified 2026-08-06)

`tools/verify-bad-handoff.sh` exits non-zero with
`bad handoff did not produce a non-zero RC.TXT`. Fresh evidence from
`artifacts/bad-handoff.img` (a `-Dbad-handoff=true` build corrupts only the
handoff-v2 magic):

- `BOOTED.TXT` present → the loader executed under firmware.
- `LOADER.TXT` present: `base=0x7e4df000 size=0x823e8 entry_offset=0x18`
  and `ram_first8=0xaa0103eaaa0003e9`, which decodes to
  `mov x9, x0; mov x10, x1` — the first two instructions of the kernel's
  naked `_start` shim. The image content is at `base+0` and the jump lands
  on the shim as designed.
- `RC.TXT` **absent** → the kernel never returned to the loader, so the
  pre-exit failure path (bad magic → validate → return non-zero → stub
  writes `RC.TXT`) did not complete.
- `vm-serial.log` empty — expected for `ConOut` on VZ; this is **not**
  serial evidence either way.

Expected behavior per ADR 0004 D5: bad magic must return status `0x2`
(`bad_handoff`) to the stub, which writes `kernel_rc=0x2` and returns to
firmware.

## Working hypothesis (inferred — prove or refute)

The kernel dies very early — before it can either return (bad-handoff
path) or reach serial init (good path). The two unpassed gates
(`docs/status.md`) may share one root cause, most likely in the new naked
entry shim / stack switch in `kernel/src/main.zig` (`_start`) or in
handoff validation. Everything you conclude must be backed by saved
evidence — no guessing presented as observation (AGENTS.md).

## Scope

Fix the pre-exit failure path only.

- Do **not** change the good path's post-exit behavior: after a valid
  handoff the kernel must still reach its terminal WFE state and never
  return.
- Do **not** start the serial-console, MMU, or ExitBootServices work — that
  is a separate prompt.
- Do **not** modify the gate itself: `tools/verify-bad-handoff.sh` and the
  `-Dbad-handoff` fixture (magic-only mutation) must stay exactly as they
  are, so a "pass" cannot be engineered by weakening the check.
- No libc/POSIX; Apple Virtualization.framework only; no QEMU.

## Process rule: diagnosis-first (hard gate)

Deliver in order — no implementation code before the diagnosis:

1. A written diagnosis covering:
   - The exact entry sequence: loader jump → shim register moves → stack
     switch (`sp = stack_base + stack_size`) → `bl kernel_main` → handoff
     validation → return path back through the shim to the loader.
   - Disassembly of `_start` and of `kernel_main`'s prologue. Note that
     `zig build inspect` targets the EFI loader and the disk image, not the
     freestanding kernel ELF — disassemble the kernel ELF directly
     (e.g. `llvm-objdump -d <zig-cache-o>/dipshit-kernel`, or `zig objdump`
     if available). Verify the SP value and 16-byte AAPCS64 alignment at
     the `bl`, and that the `bl` relocation lands on `kernel_main`.
   - Ranked candidate failure points with a concrete test for each (e.g. a
     pre-return breadcrumb write, a simplified shim that returns
     immediately, an isolated handoff-validation check).
   - How the chosen fix will prove itself (which gate/command, what output).
2. Implementation of the smallest fix.
3. Verification (gates below).

## Verification gates (evidence saved under `artifacts/`)

1. `bash tools/verify-bad-handoff.sh` exits 0 **and** `RC.TXT` shows
   `kernel_rc=0x2` (proving the pre-exit return path).
2. All build gates still pass: `zig fmt --check boot/src/main.zig
   kernel/src/main.zig build.zig`, `zig build`, `zig build image`,
   `zig build inspect`, `swift build --package-path host/vm-runner`,
   `zig build context`.
3. The good path is not regressed: `zig build run` reaches exactly the
   same observable state as before the fix (no serial evidence yet; the
   kernel never returns). Record that state before and after.
4. Every command's output is saved as `artifacts/m2-badhandoff-fix-*.txt`.
5. `docs/status.md` is updated: the gate table row flips to pass **or**
   the hypothesis row is updated with what was actually observed. Flip
   `[inferred] → [observed]` hardware-contract entries only with matching
   logs.

## Definition of done

- Diagnosis written and reviewed; root cause identified with evidence.
- Bad-handoff gate passes: `RC.TXT` shows `kernel_rc=0x2`, script exits 0.
- Good path behavior unchanged; all build gates green.
- Evidence and docs updated per AGENTS.md; nothing from the serial/MMU
  follow-up snuck in.

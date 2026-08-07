# ADR 0005: Function-pointer tables must be built at runtime, not const in `.rodata` (the flat-loader relocation bug)

Status: **accepted** · Date: 2026-08-07 · Milestone: 1.5 (found by claim 0015)

## Context

The kernel ELF is **linked at address 0 with no relocation sections**. The
boot stub copies the flat image to a **runtime-chosen base** (observed on
VZ: `0x7e4d1000` / `0x7e4da000` — the loader picks a free
`EfiLoaderCode`-type window from the captured map) and jumps to it without
relocating anything. PC-relative code (`bl`, `adrp`/`add`) is correct at
any base, but **absolute addresses baked into data tables are not**.

Zig places `const` structs containing function pointers (and `const`
arrays of string slices) into `.rodata` with **link-time absolute**
addresses — e.g. `vtable.write = 0x44c4`, the image-relative offset of
`writeFn`. At runtime the function actually lives at
`runtime_base + 0x44c4`, so the first indirect call through the table
jumps to physical address `0x44c4` — instantly faulting.

Until claim 0015, **no kernel code path ever dispatched through a data
table on real hardware**: the serial console was blocked on VZ, so the
shell loop (which uses vtables) had never run; host-side tests pass
because macOS relocates test binaries, so they never exposed the bug.
Claim 0015's NVRAM-console build finally ran the shell loop post-exit on
VZ and crashed at the first vtable dispatch (observed: chunk 30
persisted — the last direct `uart_puts` line — and the first
vtable-dispatched write never did; `writeFn` was never entered).

## Decisions

### D1. Build every function-pointer table at runtime, in BSS

`&fn` evaluated inside executed code compiles to a PC-relative `adrp`/`add`
sequence, which resolves correctly at any load base. So instead of:

```zig
const vtable = console.Console.VTable{ .write = writeFn, ... }; // .rodata, link-time absolute
```

the kernel builds the table into module-level BSS storage on first use:

```zig
var vtable_storage: console.Console.VTable = undefined;
var vtable_ready = false;
fn ensure_vtable() *const console.Console.VTable {
    if (!vtable_ready) {
        vtable_storage = .{ .write = writeFn, .flush = flushFn, .readByte = readByteFn };
        vtable_ready = true;
    }
    return &vtable_storage;
}
```

The storage must be **module-level**, never a stack local (a pointer to a
stack frame would dangle). The same pattern now covers every indirect-dispatch
table in the kernel:

- `M15Console`'s console vtable (`kernel/src/main.zig`)
- `monitor.registry` — the 14-command table with `.handler = cmd_*`
  pointers (`kernel/src/monitor.zig`)
- `machine.control()` and the `disabled()`/`MockMachineControl` control
  vtables (`kernel/src/machine.zig`, `monitor.zig`)
- `BootMessages.messages` and `elephant_lines` — `const` arrays of string
  slices (same bug class: the *data pointers inside the slices* were
  link-time absolute; the garbled banner line was the symptom)
- `memmap.MapView`/`monitor` field tables and any other `const` table that
  holds pointers

### D2. Audit rule: no const data table may hold an address

A `const` table is only safe if every field is immediate data (ints,
enums, fixed-size arrays of scalars) or **Zig-resolved** — never a
function pointer and never a string slice whose `.ptr` must be relocated.
The flat loader does no relocations, so any such table must be built at
runtime. Host tests do not catch violations (the host OS relocates test
binaries); only a live VZ run does.

## Consequences

- The first vtable dispatch on real hardware (claim 0015's shell seam) is
  now observed working: the shell runs, executes the scripted
  `version`/`mem`/`echo`/`help` commands post-exit, and its output
  reconstructs through the NVRAM console channel
  (`artifacts/nvram-console-gate.txt`).
- This was a **latent kernel bug**: any future const-pointer table (a
  driver ops table, an exception-handler table, a filesystem vtable) would
  have crashed on first dispatch at the same spot. The rule in D2 is the
  guard.
- The fix costs a few dozen bytes of BSS per table — negligible. The
  runtime-built tables are indistinguishable from const tables at the call
  site, so no API changes were needed.
- Not a fix for the broader "no relocations" design (ADR 0002/0004 keep
  the flat loader by design for this milestone); this ADR only removes the
  data-table landmine the design leaves in place.

# Milestone twenty-two march — developer tools (living tracker)

> [`docs/status.md`](status.md) is the canonical source for milestone-level
> facts. This file holds M22's per-card detail and agent split.
> A card's row flips to ✅ only with real observed evidence.

## Where we are

DipshitOS can run userland apps, but every app is built on the host and
loaded as a flat binary or DSK3 image. There's no way to write, assemble,
or inspect code *on the machine itself*. The tombstone system (M15 #243)
crashes with addresses but no symbol names. M22 gives the machine basic
developer tooling — enough to write a small program, assemble it, run it,
and debug a crash.

**Two new syscall slots** (59/60) for ELF loading and strace.

## The cards, in order

| # | Card | Status | Evidence | Notes |
|---:|------|--------|----------|-------|
| D1 | **ELF loader.** `exec app.elf` loads an ELF32/ELF64 AArch64 executable from FAT. Parse ELF headers, validate architecture (AArch64 only), map PT_LOAD segments into the EL0 address space, jump to e_entry. Works alongside the existing flat-image `exec APP.BIN`. Rejects non-AArch64 ELF files with a clear error. | ✅ | `artifacts/live-elf-report.txt` — verify-live-elf PASS 1/1 on VZ: HELLO.ELF listed, `exec HELLO.ELF size=0x3a entry=0x400000`, marker line, exit 42 + reap, shell responsive | Kernel: NO new syscall slot — the issue's magic-sniff design won: `exec.exec_file` sniffs `\x7fELF` and routes to the new `kernel/src/elf.zig` parse/validate (ELF32+ELF64, ≤2 PT_LOAD segments, W^X text at `userspace.text_va`, optional data segment directly after text memory, entry inside initialized text, 256 KiB bound). Five new honest `ExecResult` refusals surfaced by `exec`. Host tests: elf.zig 7/7, exec.zig 374/374. |
| D2 | **Tiny assembler.** `asm source.txt output.bin` — a minimal AArch64 assembler for ~20 common instructions: MOV, MOVZ, MOVK, ADD, SUB, AND, ORR, LDR (literal), STR (register), BLR, RET, SVC, NOP, CMP, B, BEQ, BNE, BL, ADRP, ADD (immediate). Reads source from FAT, writes ELF32 to FAT. Enough to write "hello world" + syscall test programs on the machine. | ✅ | `artifacts/live-asm-report.txt` — verify-live-asm PASS 1/1 on VZ: `write PROG.S` stages source → `exec ASM.BIN /esp/PROG.S /esp/PROG.ELF` prints `asm: wrote 96 bytes` → `mount esp` → `exec PROG.ELF` loads via D1 and exits status 71 | New userland app `user/src/asm.zig` (ASM.BIN): two-pass assembler, statements separated by newline OR `;`, labels + `//` comments + `.word`; encodes MOV/MOVZ/MOVK/ADD/SUB/CMP/AND/ORR/EOR/LDR(literal+mem)/STR/BLR/RET/SVC/NOP/BRK/B/BL/B.cond/CBZ/CBNZ/ADR/ADRP with host tests pinning every word against known encodings (12/12). Emits minimal AArch64 ELF32 (single R+X PT_LOAD at 0x400000) matching the D1 loader contract. Bounds: 256 lines, 64 labels, 4096 output bytes, honest per-line errors. DSK1 flat images map text only (no .bss aperture), so all workspace lives on the task stack (~12.4 KiB of 16 KiB). |
| D3 | **Symbol table.** `sym` command shows loaded ELF symbols. Tombstone crash reports (M15 #243) include symbol names — the last symbol before the faulting address. `sym app.elf` reads the ELF symbol table and prints it. | ✅ | `artifacts/live-symbols-report.txt` — verify-live-symbols PASS 1/1 on VZ: CRASH.ELF's symtab populates the kernel table (`sym` lists crasher), its BRK yields a status-139 tombstone, and `crash` resolves the PC to `(in crasher+0x4)` | New `kernel/src/symbol.zig` — BSS table (32 × name/addr/size), cleared at every exec, populated by `elf.collect_symbols` (.symtab/.strtab walk, GLOBAL/WEAK FUNC+OBJECT only) in exec's ELF branch BEFORE staging rearranges the buffer. Fault path now carries PC: exceptions fault dispatcher signature gains elr, scheduler's FaultEntry stores it, and tombstone.record resolves `(in name+0xoff)` via lookup(pc), falling back to fault_addr. Monitor registry 53→54 (`sym`, list + file-inspect via 64 KiB staging). mkhello-elf.py --crash emits CRASH.ELF with a real symtab (correct ELF32 Sym layout). Tests: symbol.zig 4/4, elf.zig 8/8, tombstone.zig 27/27 incl. note resolution. |
| D4 | **Disassembler.** `disas binary.bin` — hex dump + AArch64 disassembly of raw bytes. 16 bytes per line with address, hex, and mnemonic. Useful for inspecting tombstone addresses and verifying assembler output. | ⬜ | — | New userland app `user/src/disas.zig`. Comptime decode table (same instruction set as D2, reverse direction). Reads from FAT, prints to stdout. |
| D5 | **System call tracer.** `strace cmd` — wraps exec, logs every syscall invocation with name, args, and return value to the serial console. Each syscall prints: `[strace] sys_name(args) = retval`. | ⬜ | — | Kernel: slot 60 `sys_strace_enable(pid)`. Sets a per-process trace flag. `kernel/src/syscall.zig` — when the flag is set, the dispatch wrapper prints args + return before returning to the caller. BSS trace buffer (1 KiB, flushed per syscall). |

## Agent split

| Agent | Owns | Depends on |
|-------|------|------------|
| **A — Kernel ELF + strace** | `kernel/src/elf.zig` (new) + `kernel/src/syscall.zig` (slot 59) for D1. `kernel/src/syscall.zig` (slot 60) + `kernel/src/tombstone.zig` + `kernel/src/symbol.zig` (new) for D3 + D5. | M20 done (Unicode for error messages). |
| **B — Userland tools** | `user/src/asm.zig` (new) for D2. `user/src/disas.zig` (new) for D4. | D1 (ELF loader must work to run assembler output). |

## Notes

1. **ABI budget:** 2 new syscall slots (59/60) for ELF load + strace.
   Cumulative: 61/64 after M22. Three slots remain.
2. **BSS budget:** ELF scratch ~64 bytes. Symbol table ~2.3 KiB. Strace
   buffer ~1 KiB. Assembler (userland) ~10 KiB BSS. Disassembler (userland)
   ~8 KiB BSS. Total M22 kernel BSS delta: ~3.4 KiB. Userland BSS: ~18 KiB.
3. **Gate shape:** D1: `verify-live-elf.sh` — ELF load + execute (assembler
   output). D2: `verify-live-asm.sh` — assemble + run "hello world". D3:
   `verify-live-symbols.sh` — tombstone shows symbol name. D4:
   `verify-live-disas.sh` — disassembly output matches known bytes. D5:
   `verify-live-strace.sh` — strace output shows syscall names + args.
4. **ELF scope:** Only PT_LOAD segments. No dynamic linking, no sections,
   no relocations. The ELF loader is a *consumer* — it loads what the host
   toolchain already linked. The assembler (D2) produces ELF32 with a single
   PT_LOAD segment.
5. **Scope exclusions:** No compiler (too large for the OS). No linker
   (flat images suffice). No debugger (tombstones + strace cover basics).
   No ELF shared libraries. No ELF core dumps.

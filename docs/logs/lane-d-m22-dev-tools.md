# Log — `lane-d/m22-dev-tools`

### 2026-08-22 — claim 9815

Claimed Lane D-Tools (M22, issues #324–#339, D1–D16) per
`docs/agent-concurrency-plan.md` Phase 1. Plan of record: one commit + one
PR per issue, each PR closing its issue; host tests for every module plus
the named live gates. D1 first (ELF loader) since D2/D3 depend on it.

## 2026-08-22 — claim 9815: D1 (issue #324) done — ELF loader

New `kernel/src/elf.zig`: pure ELF32/ELF64 AArch64 parse/validate (magic,
class, endianness, machine=0xB7; PT_LOAD only; ≤2 segments; W^X text at
`text_base`=0x400000 with optional writable data segment exactly at
text_base+p_memsz[0]; entry inside initialized text; file ranges disjoint +
in-bounds; ≤256 KiB). `exec.exec_file` sniffs the magic — NO new syscall
slot consumed (the issue's own recommendation over the march doc's slot 59;
ABI budget stays 56/64). Five honest ExecResult refusals mapped in
elf_exec_error + printed by monitor cmd_exec. tools/mkhello-elf.py emits a
142-byte static ELF32 (sys_write marker + exit 42); embedded by the image
builder (mkfat32 hello_file + make-image.sh generation step).

Evidence: elf.zig 7/7 host tests; exec.zig 374/374 (new ELF32 load test);
verify-live-elf.sh PASS 1/1 on real VZ (`exec: loaded HELLO.ELF
size=0x3a entry=0x400000`, marker line, `exited status=42`, reap, shell
responsive, no [EXC] parking) — artifacts/m22-elf-live.txt,
artifacts/live-elf-report.txt. verify-unit-tests all green;
verify-coordination ok; verify-bss-budget PASS.

## 2026-08-22 — claim 9815: D2 (issue #325) done + PRE-EXISTING MAIN BUG FOUND

**Bug found while gating D2 (affects all lanes):** the first userland FAT
mount after boot fails with io_failed on real VZ (VZ resets virtio-blk at
ExitBootServices; the boot-time rearm leaves the first post-boot transport
touch flaky). Every userland file_open returned -6 → FSTEST/probes died.
`tools/verify-live-fs-mutation.sh` (M13 gate) FAILS on pristine origin/main
(bisected 4265ea3..5a25e38 — all fail; FS code unchanged since c3cfc41, so
environmental/VZ-timing regression, not a code revert). Fix: single retry of
the mount in file_table.mount_partition — gate PASSes with it. Shipped as
its own PR before D2.

D2 itself: new `user/src/asm.zig` (ASM.BIN) — two-pass AArch64 assembler,
newline-or-`;` statement separators, labels, `.word`, ~25 encodings pinned
by 12 host tests; emits minimal AArch64 ELF32 (single R+X PT_LOAD at
0x400000, the D1 contract). DSK1 flat images map text only — no writable
.bss aperture — so workspace lives on the task stack (~12.4/16 KiB).
Wiring: ASM.BIN embedded via mkfat32/make-image (also restored the
previously-dropped SETTINGS.BIN positional). Gate uses two runner phases:
script2 waits for `asm: wrote` before `mount esp` + exec (userland writes
bypass the ESP window snapshot).

Evidence: asm.zig 12/12 host tests; verify-live-asm.sh PASS 1/1 on VZ
(`asm: wrote 96 bytes to /esp/PROG.ELF` → `exec PROG.ELF size=0xc` →
`exited status=71`) — artifacts/m22-asm-live.txt,
artifacts/live-asm-report.txt. verify-live-fs-mutation PASS with the retry
fix. verify-unit-tests green; verify-coordination ok.

## 2026-08-22 — claim 9815: D3 (issue #326) done — symbolized crash reports

New `kernel/src/symbol.zig` (BSS, 32 entries, reset-per-exec) +
`elf.collect_symbols` (.symtab/.strtab walk; GLOBAL/WEAK FUNC+OBJECT;
names sliced from the pre-staging buffer). exec's ELF branch harvests
BEFORE staging rearranges the buffer (first attempt collected after
staging and found nothing — the headers had been overwritten by text).
Fault plumbing now carries PC end-to-end: exceptions fault-dispatcher
signature gains elr, scheduler FaultEntry stores it, tombstone.record
resolves `(in name+0xoff)` via lookup(pc) with fault_addr fallback.
Monitor registry 53→54 (`sym`; file-inspect mode reads ≤64 KiB staging).
tools/mkhello-elf.py --crash emits CRASH.ELF carrying a real symtab —
initially with the wrong ELF32 Sym field order (name,info,... instead of
name,value,size,info,other,shndx), caught on-host and fixed in the
generator (the kernel reader was correct).

Gotchas hit + fixed along the way: shell.zig's golden help transcript
pins registry order — `sym` registered between spawn and syscalls.
Gate uses two runner phases (script2 after the status=139 line) because
the crashed task's reap prints a quantum after the exec prompt returns.

Evidence: symbol.zig 4/4, elf.zig 8/8, tombstone.zig 27/27,
shell.zig 563/563; verify-live-symbols.sh PASS 1/1 on VZ — artifacts/
m22-symbols-live.txt, artifacts/live-symbols-report.txt.
verify-unit-tests green; verify-coordination ok.




## 2026-08-22 — claim 9815: D4 (issue #327) done — disassembler

New `user/src/disas.zig` (DISAS.BIN): decoder inverse of the D2 encoder.
Covers nop/svc/brk/ret, MOVZ/MOVK (+lsl), imm12 add/sub/cmp, register
ops (incl. ORR-xzr MOV alias and SUBS-xzr CMP), B/BL/B.cond/CBZ/CBNZ
with absolute targets computed from each word's own address, ADR/ADRP/
LDR-literal, LDR/STR unsigned-offset; unknowns print `.word`. Output
line format per the issue: `00000054: 680080d2  movz x8, #3`.
`disas <file> [offset]` takes decimal or 0x-hex offsets; 4 KiB input
bound; stack-only workspace.

Wiring: DISAS.BIN positional added through build.zig/make-image/mkfat32
(slot order now SETTINGS(34) ASM(35) DISAS(36) CRASH(generated locally)
HELLO(generated locally) APPS.TXT — one ordering slip caught because
mkfat32's magic checks named the mismatch).

Evidence: disas.zig 7/7 host tests (decode known words + honest .word
fallback); verify-live-disas.sh PASS 1/1 on VZ — the gate closes the
D2→D4 round trip ON THE MACHINE: ASM.BIN's PROG.ELF decoded byte-exactly,
then the same file executed via D1 exiting status 71.
artifacts/m22-disas-live.txt, artifacts/live-disas-report.txt.
verify-unit-tests green; verify-coordination ok.

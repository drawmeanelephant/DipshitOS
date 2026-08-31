# Log — agent/buffy/strace-marker-freshline

Claim: [1714](../claims/1714-strace-marker-freshline.md)

## 2026-08-31 — fix: async-exec process stdout no longer merges onto the live shell prompt

`verify-live-strace` was red on main: `trace_write=1 trace_exit=1` (the
tracer prints `[strace 1] sys_write(...)`/`sys_exit(...)` fine) but
`hello=0` — the gate's exact-line grep for `elf: hello from HELLO.ELF`
never matched. The serial showed the marker merged onto the prompt:

```
virelai> elf: hello from HELLO.ELF
```

Root cause (proven on un-renamed origin/main — pre-existing, rename
exonerated): both `exec` and `strace exec` spawn the program asynchronously
(`exec_file` returns, the shell immediately draws its idle `virelai> ` prompt
on the next poll), and process stdout reaches the serial through the global
`write_fn` (`exception_report_writer` → `uart_puts`) independently of the
shell's console path. So when the spawned program writes while the shell is
idle at a drawn prompt, its first line lands mid-line right after the
prompt. It is a scheduling race — `verify-live-elf` usually passes only
because HELLO's output happens to beat the shell's next poll there; the
strace gate's interleaved `echo strace-mid` tips the timing the other way.

Fix in `kernel/src/main.zig` (claim 1714):
- Track begin-of-line state in `uart_putc` — the single TX choke point:
  every serial byte (kernel banner, shell prompt, process stdout, tracer
  lines) flows through it. `\n`/`\r` → at-BOL, else mid-line.
- New `process_stdout` wrapper for the `write_fn` seam: when a process
  writes while the serial cursor is mid-line (a live prompt), emit a
  leading newline first so the output starts at column 0. When the shell
  is already at a fresh line (the common foreground case) nothing is
  prepended, so existing output is byte-identical.

Verified live on real VZ hardware: `tools/verify-live-strace.sh` **PASS 1/1**.
Serial now shows the marker cleanly separated:

```
dipshit> echo strace-mid
strace-mid
dipshit>
elf: hello from HELLO.ELF
[strace 1] sys_write(0x1, 0x400020, 0x1a) = 0x1a
[strace 1] sys_exit(0x2a) = —
```

Also green: `zig build`, `zig fmt --check`, `zig build test-console` (792/792
unit tests + byte-identical mock transcript).

## 2026-08-31 — landed via PR #723

Merged to main as PR #723; claim flipped ✅. Coordination surface: claim 1714
is now done, so the VirelaiOS rename claim 5817 (`kernel/**`) keeps no
ACTIVE-file overlap on main after landing.
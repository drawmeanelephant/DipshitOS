# Claim: strace marker freshline — async-exec process stdout must not merge onto the live shell prompt

- **Owner:** buffy (`agent/buffy/strace-marker-freshline`)
- **Prompt / plan:** root-cause `verify-live-strace` never seeing HELLO.ELF's
  `elf: hello from HELLO.ELF` marker and fix the strace/ELF marker path.
- **Scope:** M22 D5 strace gate; kernel serial output begin-of-line tracking
  so process stdout starts on a fresh line. No milestone creep.
- **Touches:** kernel/src/main.zig
- **Depends on:** —
- **Heartbeat:** 2026-08-31
- **Status:** 🔄 agent/buffy/strace-marker-freshline

## Notes

`verify-live-strace` was red: `trace_write=1 trace_exit=1` (the tracer's
`[strace 1] sys_write(...)`/`sys_exit(...)` lines land correctly) but `hello=0`
— the gate's exact-line grep `grep -aFxc "elf: hello from HELLO.ELF"` never
matched. The serial showed the marker merged onto the shell prompt:

```
virelai> elf: hello from HELLO.ELF
```

Root cause: `strace exec HELLO.ELF` (and `exec`, both async via
`exec_file`) returns immediately, so the shell draws its idle `virelai> `
prompt while the spawned program is still about to write. Process stdout
routes through the global `write_fn` → `uart_puts` (serial), while the
prompt draws through the console vtable → the same `uart_putc`, so the
program's first line lands mid-line right after the prompt. This is a
scheduling race — `verify-live-elf` usually passes only because HELLO's
output happens to beat the shell's next poll there; the strace gate's
interleaved `echo` tips it the other way.

Fix: track begin-of-line state in `uart_putc` (the single TX choke point —
every serial byte for kernel banner, shell prompt, process stdout and
tracer lines flows through it) and wrap the process-stdout `write_fn` so a
mid-line write first emits a newline. When the shell is already at a fresh
line (the common foreground case) nothing is prepended, so existing output
is byte-identical. Verify live with `tools/verify-live-strace.sh`.
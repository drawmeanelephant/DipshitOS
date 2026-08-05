## Summary of Changes

Provide a clear, high-level summary of what was added, modified, or refactored.

## AGENTS.md Compliance Checklist

- [ ] Does not introduce `libc` or `POSIX` dependencies.
- [ ] Language constraints respected (Guest: Zig 0.16.0; Host: Swift).
- [ ] Out-of-scope features avoided (no premature kernel, graphics, networking, SMP, or filesystem stacks).
- [ ] Hardware assumptions updated in `docs/hardware-contract.md` if applicable.
- [ ] Design decisions documented as ADRs under `docs/decisions/` if applicable.

## Verification Evidence

State what was directly observed vs. inferred (per `AGENTS.md` evidence rules):

### Observed Results
```text
[Paste verification output from `zig build`, `zig build inspect`, `zig build run`, or `zig build run-qemu`]
```

### Inferred / Not Yet Observed
- 

## Verification Commands Run

- [ ] `zig fmt --check boot/src/main.zig kernel/src/main.zig build.zig`
- [ ] `zig build`
- [ ] `zig build image`
- [ ] `zig build inspect`
- [ ] `zig build run` or `zig build run-qemu`

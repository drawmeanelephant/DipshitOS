## Summary of Changes

Provide a clear, high-level summary of what was added, modified, or refactored.

## AGENTS.md Compliance Checklist

- [ ] Does not introduce `libc` or `POSIX` dependencies.
- [ ] Language constraints respected (Guest: Zig 0.16.0; Host: Swift).
- [ ] Out-of-milestone features avoided (see `docs/status.md` for the
      current milestone; no premature allocator, interrupts, filesystem,
      graphics, networking, SMP).
- [ ] Hardware assumptions updated in `docs/hardware-contract.md` if applicable.
- [ ] Design decisions documented as ADRs under `docs/decisions/` if applicable.
- [ ] Non-trivial work claimed in `docs/claims/` and logged in `docs/logs/`
      (AGENTS.md coordination rules).

## Verification Evidence

State what was directly observed vs. inferred (per `AGENTS.md` evidence rules):

### Observed Results
```text
[Paste verification output from `zig build`, `zig build inspect`, `zig build run`, or a gate script — never fabricate output (AGENTS.md evidence rules).]
```

### Inferred / Not Yet Observed
- 

## Verification Commands Run

- [ ] `zig fmt --check boot/src/*.zig kernel/src/*.zig build.zig`
- [ ] `bash tools/verify-unit-tests.sh`
- [ ] `zig build test-console`
- [ ] `zig build`
- [ ] `zig build image`
- [ ] `zig build inspect`
- [ ] `zig build run` (Apple silicon only; boot evidence in `vm-serial.log` / marker files)
- [ ] `bash tools/verify-coordination.sh`

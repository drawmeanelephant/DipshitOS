# Exercise 1 — Hello + GC inside the OS

**Goal:** prove the gc Go runtime boots on VirelaiOS: console output through
`svc #0`, a 1 MiB sbrk heap growth over `sys_mmap`, and a full GC cycle
(stop-the-world → mark → sweep), all observed on a real Virtualization.framework VM.

**Time:** ~2 minutes (after the one-time prerequisites in [README](README.md)).

## Steps

From the repository root:

```bash
# 1. Make sure the fixture exists (idempotent, fast after first build)
just go-toolchain

# 2. Run the go-hello gate: boots the OS in a VM, execs GOHELLO.ELF,
#    asserts the program's own output on the serial log
just gate go-hello
```

A VM window will open, the kernel boots, and the scripted console runs
`exec GOHELLO.ELF`. The gate closes the VM by itself.

## Expected output (key lines)

The gate prints its assertion summary — every `serial-contains` row with
`=1` is a line your run's serial log contained:

```
serial-contains [exec: loaded GOHELLO.ELF]=1
serial-contains [hello from virelai]=1
serial-contains [heap: wrote 1048576 bytes]=1
serial-contains [gc: cycle completed]=1
serial-contains [virelai-go OK]=1
vgate go-hello: PASS (1/1 runs)
```

Inside the VM the program also prints `GOOS=virelai GOARCH=arm64 gc runtime
alive` and a post-GC readback sum line before the final OK.

## Pass/fail check

- **PASS** if `go-hello: PASS` is printed (equivalently: exit code 0).
- **FAIL** if the gate prints `FAILED` or times out — see Troubleshooting
  in the [README](README.md) and capture the gate output.

## What this proves

| Observed line | Kernel/runtime capability |
|---|---|
| `hello from virelai` | `svc #0` console path (println → write1 → sys_write chunking) |
| `heap: wrote 1048576 bytes` | sbrk heap over demand-backed `sys_mmap` (1 MiB growth + churn) |
| `gc: cycle completed` | full GC cycle (STW at cooperative safe points, mark, sweep) |
| `virelai-go OK` | clean program exit through the syscall seam |
